import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_client.dart';

/// Un compañero al que se le puede escribir dentro de una sesión.
@immutable
class Teammate {
  final String uid;
  final String name;
  const Teammate({required this.uid, required this.name});
}

enum InternalSendStatus { sending, sent, failed }

/// Un mensaje interno del equipo: el doc de Firestore o uno todavía en vuelo.
@immutable
class InternalMessage {
  final String id;
  final String chatId;
  final String contactName;
  final String text;
  final String authorUid;
  final String authorName;
  final List<Teammate> recipients;
  final DateTime timestamp;

  /// null = confirmado (vino de Firestore).
  final InternalSendStatus? status;
  final String? error;

  const InternalMessage({
    required this.id,
    required this.chatId,
    required this.contactName,
    required this.text,
    required this.authorUid,
    required this.authorName,
    required this.recipients,
    required this.timestamp,
    this.status,
    this.error,
  });

  /// null si al doc le falta lo mínimo (texto y hora): mejor no pintarlo que
  /// pintar una tarjeta rota.
  static InternalMessage? fromDoc(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    final text = data?['text'];
    final ts = data?['timestamp'];
    if (text is! String || ts is! Timestamp) return null;
    final raw = data?['recipients'];
    return InternalMessage(
      id: doc.id,
      chatId: data?['chatId'] as String? ?? '',
      contactName: data?['contactName'] as String? ?? '',
      text: text,
      authorUid: data?['authorUid'] as String? ?? '',
      authorName: data?['authorName'] as String? ?? 'Equipo',
      recipients: [
        if (raw is List)
          for (final r in raw)
            if (r is Map && r['uid'] is String)
              Teammate(uid: r['uid'] as String, name: (r['name'] as String?) ?? ''),
      ],
      timestamp: ts.toDate(),
    );
  }
}

class _Outgoing {
  final String id;
  final String accountId;
  final String sessionId;
  final String chatId;
  final String text;
  final List<Teammate> recipients;
  final DateTime createdAt = DateTime.now();
  InternalSendStatus status = InternalSendStatus.sending;
  String? error;

  _Outgoing({
    required this.id,
    required this.accountId,
    required this.sessionId,
    required this.chatId,
    required this.text,
    required this.recipients,
  });
}

/// Mensajes internos: el equipo se habla dentro de la conversación sin que el
/// cliente lo vea. Ver backend/src/services/internalMessages.ts.
///
/// Dos trabajos:
/// - Quién es el equipo de cada sesión (los chips de "Avisar a"), cacheado:
///   cambia poco y se consulta al abrir cada chat.
/// - Los internos en vuelo, por chat. Singleton por lo mismo que
///   PendingMessagesService: si sales del chat mientras se envía, el texto no
///   se pierde. El id lo generamos aquí y el backend lo respeta, así que un
///   reintento no duplica y la tarjeta se retira sola cuando llega el doc.
class InternalMessagesService extends ChangeNotifier {
  static final InternalMessagesService _instance = InternalMessagesService._();
  factory InternalMessagesService() => _instance;
  InternalMessagesService._();

  /// = INTERNAL_TEXT_MAX del backend.
  static const textMax = 2000;
  static const _teamTtl = Duration(minutes: 5);

  final Map<String, ({List<Teammate> team, DateTime at})> _teams = {};
  final Map<String, Future<List<Teammate>>> _teamsInFlight = {};
  final Map<String, List<_Outgoing>> _byChat = {};

  static String _chatKey(String sessionId, String chatId) => '$sessionId:$chatId';

  /// Lo que ya se sabe del equipo, sin esperar red. Sirve para pintar el
  /// candado en el primer frame en vez de que aparezca después y empuje el
  /// texto del composer.
  List<Teammate>? cachedTeammates(String accountId, String sessionId) {
    final cached = _teams['$accountId:$sessionId'];
    if (cached == null || DateTime.now().difference(cached.at) > _teamTtl) {
      return null;
    }
    return cached.team;
  }

  /// Compañeros que ven la sesión, sin mí. Vacío si estoy solo o si falló: la
  /// app esconde el modo interno en ambos casos y lo vuelve a pedir después.
  Future<List<Teammate>> teammates(String accountId, String sessionId) {
    final cached = cachedTeammates(accountId, sessionId);
    if (cached != null) return Future.value(cached);
    final key = '$accountId:$sessionId';
    return _teamsInFlight[key] ??= _fetchTeam(accountId, sessionId).then((team) {
      if (team != null) _teams[key] = (team: team, at: DateTime.now());
      return team ?? const <Teammate>[];
    }).whenComplete(() => _teamsInFlight.remove(key));
  }

  Future<List<Teammate>?> _fetchTeam(String accountId, String sessionId) async {
    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/internal-messages/teammates'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': accountId, 'sessionId': sessionId}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final raw = (jsonDecode(response.body) as Map<String, dynamic>)['teammates'];
      return [
        if (raw is List)
          for (final t in raw)
            if (t is Map && t['uid'] is String && t['name'] is String)
              Teammate(uid: t['uid'] as String, name: t['name'] as String),
      ];
    } catch (e) {
      debugPrint('[Interno] No se pudo leer el equipo: $e');
      return null;
    }
  }

  /// En vuelo para este chat, sin los que ya llegaron por el stream.
  List<InternalMessage> pendingFor(
      String sessionId, String chatId, Set<String> presentIds) {
    final list = _byChat[_chatKey(sessionId, chatId)];
    if (list == null || list.isEmpty) return const [];
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return [
      for (final o in list)
        if (!presentIds.contains(o.id) && !_deleting.contains(o.id))
          InternalMessage(
            id: o.id,
            chatId: o.chatId,
            contactName: '',
            text: o.text,
            authorUid: uid,
            authorName: '',
            recipients: o.recipients,
            timestamp: o.createdAt,
            status: o.status,
            error: o.error,
          ),
    ];
  }

  /// Retira los que ya están en Firestore. Post-frame, nunca durante build.
  void purgeReconciled(String sessionId, String chatId, Set<String> presentIds) {
    final key = _chatKey(sessionId, chatId);
    final list = _byChat[key];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((o) => presentIds.contains(o.id));
    if (list.isEmpty) _byChat.remove(key);
    if (list.length != before) notifyListeners();
  }

  Future<void> send({
    required String accountId,
    required String sessionId,
    required String chatId,
    required String text,
    required List<Teammate> recipients,
  }) {
    final o = _Outgoing(
      // autoId local, sin red. Ver la nota de la clase sobre reintentos.
      id: FirebaseFirestore.instance.collection('_').doc().id,
      accountId: accountId,
      sessionId: sessionId,
      chatId: chatId,
      text: text,
      recipients: recipients,
    );
    (_byChat[_chatKey(sessionId, chatId)] ??= []).add(o);
    notifyListeners();
    return _transmit(o);
  }

  Future<void> retry(String id) {
    final o = _find(id);
    if (o == null) return Future.value();
    o
      ..status = InternalSendStatus.sending
      ..error = null;
    notifyListeners();
    return _transmit(o);
  }

  void discard(String id) {
    for (final list in _byChat.values) {
      list.removeWhere((o) => o.id == id);
    }
    notifyListeners();
  }

  // Borrados en vuelo: se esconden ya, sin esperar a que el stream confirme.
  final Set<String> _deleting = {};

  /// ¿Se está borrando? La conversación lo esconde mientras tanto.
  bool isDeleting(String id) => _deleting.contains(id);

  /// Borra un interno propio (el backend rechaza los ajenos). Desaparece al
  /// instante; si el servidor falla vuelve a su lugar y devuelve el motivo.
  /// null = borrado.
  Future<String?> delete({
    required String accountId,
    required String sessionId,
    required String id,
  }) async {
    _deleting.add(id);
    notifyListeners();
    String? error;
    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/internal-messages/delete'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': accountId, 'sessionId': sessionId, 'id': id}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        try {
          error = (jsonDecode(response.body) as Map<String, dynamic>)['error']
              as String?;
        } catch (_) {/* cuerpo no-JSON: usamos el status */}
        error ??= 'Error ${response.statusCode}';
      }
    } on TimeoutException {
      error = 'Sin respuesta del servidor';
    } catch (_) {
      error = 'Sin conexión';
    }
    if (error == null) {
      // Si todavía era una tarjeta en vuelo ("enviado" sin confirmar por el
      // stream), ya no va a llegar nunca: sin esto quedaría pegada.
      for (final list in _byChat.values) {
        list.removeWhere((o) => o.id == id);
      }
    } else {
      _deleting.remove(id);
    }
    notifyListeners();
    return error;
  }

  Future<void> _transmit(_Outgoing o) async {
    String? error;
    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/internal-messages'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': o.accountId,
              'sessionId': o.sessionId,
              'chatId': o.chatId,
              'id': o.id,
              'text': o.text,
              'recipientUids': [for (final r in o.recipients) r.uid],
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        try {
          error = (jsonDecode(response.body) as Map<String, dynamic>)['error']
              as String?;
        } catch (_) {/* cuerpo no-JSON: usamos el status */}
        error ??= 'Error ${response.statusCode}';
      }
    } on TimeoutException {
      error = 'Sin respuesta del servidor';
    } catch (_) {
      error = 'Sin conexión';
    }
    // Confirmado queda "enviado" hasta que el doc llegue por el stream y
    // purgeReconciled lo retire. Quitarlo ya lo haría parpadear.
    o
      ..status = error == null ? InternalSendStatus.sent : InternalSendStatus.failed
      ..error = error;
    notifyListeners();
  }

  _Outgoing? _find(String id) {
    for (final list in _byChat.values) {
      for (final o in list) {
        if (o.id == id) return o;
      }
    }
    return null;
  }
}
