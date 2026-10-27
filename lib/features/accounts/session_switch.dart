// Qué sesión se ve en la ChatsScreen raíz. Ver CLAUDE.md, "🔀 Cambiar de
// cuenta". Tests en `test/session_switch_test.dart`.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:crm_whatsapp/core/utils/session_deletion.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';

import 'session_visual.dart';

/// Una sesión que el usuario puede abrir, tal como la muestran el selector de
/// cuenta del título y el dispatcher.
class SessionOption {
  /// Id del doc: el número con el que se vinculó por primera vez.
  final String id;
  final String name;

  /// El número que usa hoy (cambia tras un cambio de número; el id no).
  final String phone;
  final String? status;
  final DateTime? lastSync;
  final String? sessionKey;

  const SessionOption({
    required this.id,
    required this.name,
    required this.phone,
    this.status,
    this.lastSync,
    this.sessionKey,
  });

  factory SessionOption.fromData(String id, Map<String, dynamic>? data) => SessionOption(
        id: id,
        name: sessionDisplayName(data, id),
        phone: sessionPhone(data, id),
        status: data?['status'] as String?,
        lastSync: (data?['last_sync'] as Timestamp?)?.toDate(),
        sessionKey: data?['session_key'] as String?,
      );

  /// Conectada o reconectando: el backend la tiene (o la está levantando).
  /// `reconnecting` cuenta para que abrir la app durante un redeploy no deje
  /// al operador en otra cuenta.
  bool get isLive => status == 'connected' || status == 'reconnecting';

  SessionVisual get visual => SessionVisual.from(status, lastSync);
}

/// Orden de las sesiones en Mis Cuentas, en el selector y en la elección
/// automática: la vinculada más recientemente primero; sin `connected_at`, al
/// final. Se ordena en memoria porque `visibleSessionsQuery` no admite
/// `orderBy` (ver CLAUDE.md, "Listar sesiones").
int compareSessionsByConnectedAt(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  final ta = a?['connected_at'];
  final tb = b?['connected_at'];
  if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
  if (ta is Timestamp) return -1;
  if (tb is Timestamp) return 1;
  return 0;
}

/// Las sesiones que se pueden abrir, en orden. Las lápidas (sesiones que se
/// están eliminando) no se abren aunque digan `connected`.
List<SessionOption> visibleSessionOptions(
  Iterable<({String id, Map<String, dynamic>? data})> docs,
) {
  final alive = docs.where((d) => !isSessionDeleting(d.data)).toList()
    ..sort((a, b) => compareSessionsByConnectedAt(a.data, b.data));
  return [for (final d in alive) SessionOption.fromData(d.id, d.data)];
}

class RootPick {
  /// La sesión a mostrar; null = no hay ninguna (bienvenida).
  final String? sessionId;

  /// Se pidió una sesión que no está entre las visibles (se eliminó o ya no
  /// hay acceso). Quien la pidió tiene que enterarse.
  final bool requestRejected;

  const RootPick(this.sessionId, {this.requestRejected = false});
}

/// Elige la sesión de la ChatsScreen raíz. [sessions] son las de
/// [visibleSessionOptions].
///
/// 1. [requested] (selector, Mis Cuentas o un push), con cualquier status: una
///    sesión caída se puede abrir para leerla.
/// 2. [current], mientras siga visible, con cualquier status. Una reconexión
///    escribe `reconnecting` y antes eso sacaba al operador de su cuenta: la
///    pantalla saltaba a otra y podía contestarle al cliente de un negocio
///    desde el número de otro sin darse cuenta.
/// 3. Elección automática (al arrancar, o si la actual se eliminó o perdió el
///    acceso): primero las vivas; entre ellas, la última usada.
RootPick pickRootSession({
  required List<SessionOption> sessions,
  String? requested,
  String? current,
  String? lastUsed,
}) {
  SessionOption? find(String? id) {
    if (id == null) return null;
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  final rejected = requested != null && find(requested) == null;
  if (requested != null && !rejected) return RootPick(requested);
  if (find(current) != null) return RootPick(current, requestRejected: rejected);
  return RootPick(_autoPick(sessions, find(lastUsed)), requestRejected: rejected);
}

String? _autoPick(List<SessionOption> sessions, SessionOption? lastUsed) {
  if (sessions.isEmpty) return null;
  if (lastUsed != null && lastUsed.isLive) return lastUsed.id;
  for (final s in sessions) {
    if (s.isLive) return s.id;
  }
  return (lastUsed ?? sessions.first).id;
}
