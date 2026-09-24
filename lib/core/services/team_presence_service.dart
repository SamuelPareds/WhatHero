import 'dart:async';

import 'package:flutter/foundation.dart';

import 'presence_reporter.dart';

/// Un compañero (o una pestaña tuya en otro dispositivo) dentro de un chat.
@immutable
class TeamViewer {
  final String clientId;
  final String uid;

  /// Nombre de pila, resuelto por el backend desde `users/{uid}.displayName`.
  final String name;
  final String chatId;

  /// Tiene texto en el composer de ese chat: está respondiendo.
  final bool composing;

  const TeamViewer({
    required this.clientId,
    required this.uid,
    required this.name,
    required this.chatId,
    required this.composing,
  });
}

/// Lo que hacen LOS DEMÁS: quién está en cada chat de la sesión y quién está
/// respondiendo. La otra mitad (lo que hago yo) es `PresenceReporter`.
///
/// Mismo patrón que `AiStateService`: estado efímero que llega por socket
/// (`team_presence`), sin Firestore, y los widgets se suscriben con
/// `ListenableBuilder`. Cada payload trae el estado COMPLETO de la sesión, así
/// que aplicar uno reemplaza todo: no hay deltas que puedan desordenarse.
class TeamPresenceService extends ChangeNotifier {
  TeamPresenceService._({String Function()? myClientId})
      : _myClientId = myClientId ?? (() => PresenceReporter.instance.clientId);

  static final TeamPresenceService _instance = TeamPresenceService._();
  factory TeamPresenceService() => _instance;

  @visibleForTesting
  factory TeamPresenceService.test({required String myClientId}) =>
      TeamPresenceService._(myClientId: () => myClientId);

  /// Con el socket caído no nos enteramos de nadie que se vaya: mostrar la
  /// última foto sería mentir. Pasado esto sin reconectar, se limpia. No es
  /// inmediato porque un blip de red de dos segundos no debería vaciar la
  /// pantalla; al reconectar llega un payload fresco igual.
  static const staleAfter = Duration(seconds: 10);

  final String Function() _myClientId;

  String? _sessionPhone;
  List<TeamViewer> _viewers = const [];
  Timer? _staleTimer;

  /// Quienes están en [chatId], sin contarme a mí (esta pestaña). Se filtra
  /// por `clientId` y no por uid a propósito: en equipos que comparten login,
  /// "mi usuario en otro dispositivo" es otra persona. Los que están
  /// respondiendo van primero.
  List<TeamViewer> othersIn(String? sessionPhone, String chatId) {
    if (sessionPhone == null || sessionPhone != _sessionPhone) return const [];
    final me = _myClientId();
    final found = [
      for (final v in _viewers)
        if (v.chatId == chatId && v.clientId != me) v,
    ];
    if (found.length > 1) {
      found.sort((a, b) => (b.composing ? 1 : 0) - (a.composing ? 1 : 0));
    }
    return found;
  }

  /// Aplica el payload de `team_presence`. Tolerante a payloads malformados:
  /// descarta la entrada rota, no el resto.
  void applyPayload(Map<String, dynamic> data) {
    final sessionPhone = data['sessionPhone'];
    if (sessionPhone is! String) return;
    final raw = data['viewers'];
    final viewers = <TeamViewer>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final clientId = item['clientId'];
        final uid = item['uid'];
        final name = item['name'];
        final chatId = item['chatId'];
        if (clientId is! String ||
            uid is! String ||
            name is! String ||
            chatId is! String) {
          continue;
        }
        viewers.add(TeamViewer(
          clientId: clientId,
          uid: uid,
          name: name,
          chatId: chatId,
          composing: item['composing'] == true,
        ));
      }
    }
    _staleTimer?.cancel();
    _staleTimer = null;
    _sessionPhone = sessionPhone;
    _viewers = List.unmodifiable(viewers);
    notifyListeners();
  }

  /// Socket caído: si no vuelve en [staleAfter], vaciamos.
  void markStale() {
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, clearAll);
  }

  /// Logout / cambio de cuenta.
  void clearAll() {
    _staleTimer?.cancel();
    _staleTimer = null;
    final had = _viewers.isNotEmpty;
    _sessionPhone = null;
    _viewers = const [];
    if (had) notifyListeners();
  }
}
