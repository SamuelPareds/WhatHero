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
    notifyListeners();
  }

  /// Aplica el evento crudo recibido por socket. Tolerante a payloads malformados:
  /// en caso de duda, deja todo como está.
  void applySocketPayload(Map<String, dynamic> data) {
    final sessionKey = data['sessionKey'] as String?;
    final contactPhone = data['contactPhone'] as String?;
    final stateRaw = data['state'] as String?;
    if (sessionKey == null || contactPhone == null || stateRaw == null) return;

    final parsedState = AiChatState.values.firstWhere(
      (s) => s.name == stateRaw,
      orElse: () => AiChatState.idle,
    );

    DateTime? expectedRespondAt;
    final expectedRaw = data['expectedRespondAt'];
    if (expectedRaw is int) {
      expectedRespondAt = DateTime.fromMillisecondsSinceEpoch(expectedRaw);
    } else if (expectedRaw is num) {
      expectedRespondAt =
          DateTime.fromMillisecondsSinceEpoch(expectedRaw.toInt());
    }

    update(
      sessionKey: sessionKey,
      contactPhone: contactPhone,
      state: parsedState,
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
