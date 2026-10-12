import 'dart:async';

import 'package:flutter/foundation.dart';

/// Estado de una burbuja optimista (mensaje local aún no confirmado en Firestore).
enum PendingStatus {
  /// Emitido, esperando ack del backend → relojito 🕓.
  sending,

  /// Backend confirmó el envío (tenemos messageId real) pero el doc todavía
  /// no llega por el stream de Firestore → ✓ desde ya; la burbuja local se
  /// retira sola cuando el doc real aparece (cero flicker, cero duplicados).
  sent,

  /// El backend reportó error o pasó el timeout sin ack → "No se envió"; tap o
  /// long-press abren Reintentar / Copiar / Eliminar. El texto NUNCA se pierde.
  failed,
}

/// El motivo de un envío fallido, en palabras del operador. Lo crudo (el
/// mensaje del backend o la excepción de red) no le dice qué hacer.
String describeSendError(String? raw) {
  if (raw == null || raw.isEmpty) return 'Error desconocido';
  // 'Connection Closed' lo lanza Baileys cuando el socket de WhatsApp se cayó
  // a mitad del envío.
  if (raw.contains('Session not ready') || raw.contains('Connection Closed')) {
    return 'WhatsApp no está conectado';
  }
  if (RegExp(r'^HTTP 5\d\d').hasMatch(raw)) return 'Error del servidor';
  if (raw.contains('SocketException') ||
      raw.contains('ClientException') ||
      raw.contains('TimeoutException') ||
      raw.contains('Failed to fetch')) {
    return 'Sin conexión con el servidor';
  }
  return raw;
}

class PendingMessage {
  final String tempId;
  final String text;
  final DateTime timestamp;

  /// Payload completo del envío (to, text, sessionKey, quoted*, tempId…).
  /// Se conserva íntegro para que "Reintentar" re-emita exactamente lo mismo.
  final Map<String, dynamic> payload;

  PendingStatus status;
  String? error;

  /// Id real de WhatsApp (llega en el ack de éxito). Cuando el doc con este
  /// id aparece en el stream, la burbuja local se purga.
  String? realMessageId;

  PendingMessage({
    required this.tempId,
    required this.text,
    required this.timestamp,
    required this.payload,
    this.status = PendingStatus.sending,
  });
}

/// Mensajes salientes en vuelo, por chat. Singleton ChangeNotifier (mismo
/// patrón que AiStateService): vive fuera del widget tree para sobrevivir
/// navegación entre chats dentro de la sesión. No persiste entre reinicios
/// de la app (v1: solo texto; si la app muere en vuelo, el mensaje se pierde
/// igual que en WhatsApp Web).
class PendingMessagesService extends ChangeNotifier {
  static final PendingMessagesService _instance = PendingMessagesService._internal();
  factory PendingMessagesService() => _instance;
  PendingMessagesService._internal();

  /// Sin ack en este plazo → failed. Cubre socket caído a mitad de vuelo
  /// (el evento de error del backend nunca llegaría).
  static const ackTimeout = Duration(seconds: 25);

  // chatKey → mensajes en orden de creación (viejo → nuevo).
  final Map<String, List<PendingMessage>> _byChat = {};
  final Map<String, Timer> _timeouts = {};
  int _seq = 0;

  static String chatKey(String? sessionKey, String phone) => '$sessionKey:$phone';

  /// tempId único sin dependencia de uuid: reloj en µs + secuencia local.
  String newTempId() => 'tmp-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// ¿Hay burbujas locales en este chat? Sin ninguna, la vista no necesita
  /// juntar los `clientTempId` del snapshot.
  bool hasPendingFor(String key) => _byChat[key]?.isNotEmpty ?? false;

  /// Pendientes a renderizar: excluye los ya reconciliados (su doc real está
  /// presente en el snapshot actual del stream).
  List<PendingMessage> visibleForChat(
    String key,
    Set<String> presentDocIds, {
    Set<String> presentTempIds = const {},
  }) {
    final list = _byChat[key];
    if (list == null || list.isEmpty) return const [];
    return list
        .where((p) => !_isReconciled(p, presentDocIds, presentTempIds))
        .toList(growable: false);
  }

  void add(String key, PendingMessage message) {
    (_byChat[key] ??= []).add(message);
    _armTimeout(message);
    notifyListeners();
  }

  /// Ack de éxito del backend (socket `message_sent_success` o response HTTP).
  void onSendSuccess(String? tempId, String? realMessageId) {
    final p = _find(tempId);
    if (p == null) return;
    _timeouts.remove(p.tempId)?.cancel();
    p.status = PendingStatus.sent;
    p.realMessageId = realMessageId;
    // Sin messageId real no hay forma de reconciliar con el stream: retiramos
    // la burbuja local ya (el doc real aparecerá por su cuenta).
    if (realMessageId == null) _removeInternal(p.tempId);
    notifyListeners();
  }

  /// Ack de error del backend (socket `message_sent_error`, HTTP != 200 o timeout).
  void onSendError(String? tempId, String? error) {
    final p = _find(tempId);
    if (p == null || p.status != PendingStatus.sending) return;
    _timeouts.remove(p.tempId)?.cancel();
    p.status = PendingStatus.failed;
    p.error = error;
    notifyListeners();
  }

  /// El operador tocó "Reintentar": vuelve a sending y re-arma el timeout.
  /// El re-emit del payload lo hace la vista (socket u HTTP según conexión).
  void markRetrying(String tempId) {
    final p = _find(tempId);
    if (p == null) return;
    p.status = PendingStatus.sending;
    p.error = null;
    _armTimeout(p);
    notifyListeners();
  }

  /// El operador descartó un mensaje fallido.
  void discard(String tempId) {
    _removeInternal(tempId);
    notifyListeners();
  }

  /// Purga los pendientes cuyo doc real ya está en el stream. Llamar
  /// post-frame desde el builder de la lista (nunca durante build).
  void purgeReconciled(
    String key,
    Set<String> presentDocIds, {
    Set<String> presentTempIds = const {},
  }) {
    final list = _byChat[key];
    if (list == null || list.isEmpty) return;
    final before = list.length;
    list.removeWhere((p) {
      final done = _isReconciled(p, presentDocIds, presentTempIds);
      if (done) _timeouts.remove(p.tempId)?.cancel();
      return done;
    });
    if (list.length != before) notifyListeners();
  }

  // Su doc real ya está en el snapshot: por el id que trajo el ack, o por el
  // `clientTempId` que el backend guarda en el eco. El segundo es el que
  // importa cuando el ack se pierde (socket caído entre el envío y la
  // respuesta): el mensaje salió, y sin él la burbuja pasaba a "No se envió"
  // a los 25 s, al lado del mensaje real. Reintentarla lo duplicaba.
  // Encontrarla aquí también cancela su timeout.
  bool _isReconciled(
    PendingMessage p,
    Set<String> presentDocIds,
    Set<String> presentTempIds,
  ) =>
      (p.realMessageId != null && presentDocIds.contains(p.realMessageId)) ||
      presentTempIds.contains(p.tempId);

  void _armTimeout(PendingMessage p) {
    _timeouts.remove(p.tempId)?.cancel();
    _timeouts[p.tempId] = Timer(ackTimeout, () {
      onSendError(p.tempId, 'Sin respuesta del servidor');
    });
  }

  PendingMessage? _find(String? tempId) {
    if (tempId == null) return null;
    for (final list in _byChat.values) {
      for (final p in list) {
        if (p.tempId == tempId) return p;
      }
    }
    return null;
  }

  void _removeInternal(String tempId) {
    _timeouts.remove(tempId)?.cancel();
    for (final list in _byChat.values) {
      list.removeWhere((p) => p.tempId == tempId);
    }
  }
}
