import 'dart:async';
import 'package:flutter/foundation.dart';

/// Estados efímeros del ciclo de vida de la IA por chat.
/// Coinciden 1:1 con los strings que emite el backend en el evento `ai_state`.
enum AiChatState {
  idle,
  buffering,
  thinking,
  responding,
}

/// Snapshot de estado para un chat. `expectedRespondAt` sólo viene cuando
/// estamos en `buffering` y permite renderizar countdowns si quisiéramos.
class AiChatStatus {
  final AiChatState state;
  final DateTime? expectedRespondAt;
  final DateTime updatedAt;

  const AiChatStatus({
    required this.state,
    required this.updatedAt,
    this.expectedRespondAt,
  });
}

/// Singleton que mantiene en memoria el estado IA por chat.
///
/// - Sin Firestore: los estados son efímeros (segundos) y se reciben por socket.
/// - Al (re)conectar llega la foto completa (`ai_state_snapshot`) y reemplaza
///   todo: sin ella, quien conectaba a mitad de un ciclo no veía "esperando…"
///   y contestaba encima de la IA.
/// - El backend re-emite los estados vivos cada 30 s (latido), así que un ciclo
///   largo no vence el watchdog.
/// - Salvavidas: si en 90s no hay nuevo evento (p.ej. cliente perdió la conexión
///   a mitad del ciclo), volvemos a `idle` solos para no dejar spinners zombies.
class AiStateService extends ChangeNotifier {
  static final AiStateService _instance = AiStateService._internal();
  factory AiStateService() => _instance;
  AiStateService._internal();

  static const Duration _watchdogTimeout = Duration(seconds: 90);

  final Map<String, AiChatStatus> _states = {};
  final Map<String, Timer> _watchdogs = {};

  String _key(String sessionKey, String contactPhone) =>
      '$sessionKey:$contactPhone';

  /// Devuelve el estado actual para un chat. `null` ⇒ idle (no hay nada activo).
  AiChatStatus? statusFor(String sessionKey, String contactPhone) =>
      _states[_key(sessionKey, contactPhone)];

  /// Atajo para los widgets: ¿hay algún ciclo de IA en curso ahora mismo?
  bool isActiveFor(String sessionKey, String contactPhone) {
    final status = statusFor(sessionKey, contactPhone);
    return status != null && status.state != AiChatState.idle;
  }

  /// Aplica una transición. Reinicia el watchdog en cada update.
  void update({
    required String sessionKey,
    required String contactPhone,
    required AiChatState state,
    DateTime? expectedRespondAt,
  }) {
    final key = _key(sessionKey, contactPhone);

    _watchdogs[key]?.cancel();
    _watchdogs.remove(key);

    if (state == AiChatState.idle) {
      final removed = _states.remove(key);
      if (removed != null) notifyListeners();
      return;
    }

    _store(key, state, expectedRespondAt);
    notifyListeners();
  }

  // Guarda el estado y arma su watchdog, sin notificar.
  void _store(String key, AiChatState state, DateTime? expectedRespondAt) {
    _states[key] = AiChatStatus(
      state: state,
      expectedRespondAt: expectedRespondAt,
      updatedAt: DateTime.now(),
    );
    _watchdogs[key] = Timer(_watchdogTimeout, () {
      _states.remove(key);
      _watchdogs.remove(key);
      notifyListeners();
    });
  }

  /// Aplica el evento crudo recibido por socket. Tolerante a payloads malformados:
  /// en caso de duda, deja todo como está.
  void applySocketPayload(Map<String, dynamic> data) {
    final parsed = _parse(data);
    if (parsed == null) return;
    update(
      sessionKey: parsed.sessionKey,
      contactPhone: parsed.contactPhone,
      state: parsed.state,
      expectedRespondAt: parsed.expectedRespondAt,
    );
  }

  /// Foto completa al (re)conectar (`ai_state_snapshot`). Reemplaza todo: lo
  /// que no viene en la foto terminó mientras estábamos desconectados, y su
  /// `idle` se perdió con la conexión.
  void replaceAll(List<dynamic> states) {
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    _watchdogs.clear();
    _states.clear();
    for (final raw in states) {
      if (raw is! Map) continue;
      final parsed = _parse(Map<String, dynamic>.from(raw));
      if (parsed == null || parsed.state == AiChatState.idle) continue;
      _store(
        _key(parsed.sessionKey, parsed.contactPhone),
        parsed.state,
        parsed.expectedRespondAt,
      );
    }
    notifyListeners();
  }

  ({
    String sessionKey,
    String contactPhone,
    AiChatState state,
    DateTime? expectedRespondAt,
  })? _parse(Map<String, dynamic> data) {
    final sessionKey = data['sessionKey'];
    final contactPhone = data['contactPhone'];
    final stateRaw = data['state'];
    if (sessionKey is! String || contactPhone is! String || stateRaw is! String) {
      return null;
    }

    final state = AiChatState.values.firstWhere(
      (s) => s.name == stateRaw,
      orElse: () => AiChatState.idle,
    );

    DateTime? expectedRespondAt;
    final expectedRaw = data['expectedRespondAt'];
    if (expectedRaw is num) {
      expectedRespondAt =
          DateTime.fromMillisecondsSinceEpoch(expectedRaw.toInt());
    }
    return (
      sessionKey: sessionKey,
      contactPhone: contactPhone,
      state: state,
      expectedRespondAt: expectedRespondAt,
    );
  }

  /// Limpieza dura: usado al cerrar sesión / cambiar de cuenta.
  void clearAll() {
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    _watchdogs.clear();
    final hadStates = _states.isNotEmpty;
    _states.clear();
    if (hadStates) notifyListeners();
  }

  @visibleForTesting
  void debugDump() {
    for (final entry in _states.entries) {
      debugPrint('[AiStateService] ${entry.key} → ${entry.value.state.name}');
    }
  }
}
