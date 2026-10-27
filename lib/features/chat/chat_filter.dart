/// Filtros de la lista de chats: la vista principal (el desplegable Todos /
/// Pendientes / Listos) y los chips que filtran DENTRO de ella (Seguimiento,
/// Con notas, etiquetas). Pendientes + VIP = los pendientes con la etiqueta VIP.
///
/// **Pendientes y Listos son las dos mitades de "Todos".** Un chat está
/// pendiente si el cliente espera una respuesta humana (contador automático) o
/// alguien lo marcó a mano; si no, está listo. No hay punto medio: responder
/// (tú o la IA) o deslizar "Listo" lo pasa a Listos, y un mensaje que nadie
/// contesta lo devuelve a Pendientes. Por eso [isChatPending] es la ÚNICA
/// definición de pendiente: si una copia se separara, un chat podría quedar en
/// las dos vistas o en ninguna.
///
/// Funciones puras sin dependencias. Tests en `test/chat_filter_test.dart`.
library;

/// La vista principal. Se recuerda por usuario (`users/{uid}/prefs/ui`).
enum InboxView { todos, pendientes, listos }

/// Chips secundarios. Filtran dentro de la vista, salvo [seguimiento].
/// `etiqueta` filtra por una etiqueta concreta del catálogo de la sesión.
enum ChatFilter { seguimiento, conNotas, etiqueta }

/// ¿El chat espera a un humano? Señal automática (`unresponded_count`, que el
/// backend sube cuando la IA no responde) o marca manual (`marked_pending`).
bool isChatPending(Map<String, dynamic>? chat) {
  final count = (chat?['unresponded_count'] as num?)?.toInt() ?? 0;
  final markedPending = chat?['marked_pending'] as bool? ?? false;
  return count > 0 || markedPending;
}

/// ¿El chat cae en la vista?
///
/// [searching]: con texto en el buscador la vista no acota. Pendientes y Listos
/// son estados del trabajo, no criterios de búsqueda: con Pendientes como vista
/// guardada, buscar a un cliente ya atendido diría que no existe.
bool matchesInboxView(
  InboxView view,
  Map<String, dynamic>? chat, {
  bool searching = false,
}) {
  if (searching) return true;
  switch (view) {
    case InboxView.todos:
      return true;
    case InboxView.pendientes:
      return isChatPending(chat);
    case InboxView.listos:
      return !isChatPending(chat);
  }
}

/// ¿El chat pasa el chip activo? `null` = ningún chip.
///
/// [knownLabelIds]: catálogo de etiquetas de la sesión. Una etiqueta activa
/// que ya no está en el catálogo no oculta nada (no filtramos por un id
/// huérfano). Con notas y etiquetas acotan también la búsqueda: ésas se eligen
/// para buscar dentro.
bool matchesChip(
  ChatFilter? chip,
  Map<String, dynamic>? chat, {
  String? labelId,
  Set<String> knownLabelIds = const {},
}) {
  switch (chip) {
    case null:
      return true;
    case ChatFilter.seguimiento:
      return (chat?['followup_status'] as String?) == 'queued';
    case ChatFilter.conNotas:
      return ((chat?['note'] as String?) ?? '').trim().isNotEmpty;
    case ChatFilter.etiqueta:
      if (labelId == null || !knownLabelIds.contains(labelId)) return true;
      final ids = ((chat?['labelIds'] as List?) ?? const []).whereType<String>();
      return ids.contains(labelId);
  }
}

/// ¿El chat se ve en la lista? La vista Y el chip.
///
/// **Seguimiento ignora la vista.** Es la cola del agente, que encola chats
/// cuyo último mensaje fue ayer, sin importar quién habló al final: mezcla
/// pendientes y listos. Combinada con Pendientes perdería parte de la cola, y
/// su chip (que cuenta la cola entera) prometería chats que no se ven.
bool chatIsVisible(
  InboxView view,
  ChatFilter? chip,
  Map<String, dynamic>? chat, {
  String? labelId,
  Set<String> knownLabelIds = const {},
  bool searching = false,
}) {
  if (!matchesChip(chip, chat, labelId: labelId, knownLabelIds: knownLabelIds)) {
    return false;
  }
  if (chip == ChatFilter.seguimiento) return true;
  return matchesInboxView(view, chat, searching: searching);
}

// Valores guardados en `users/{uid}/prefs/ui.chat_inbox_view`. No cambiarlos:
// los leen las apps ya instaladas.
const _prefTodos = 'todos';
const _prefPendientes = 'pendientes';
const _prefListos = 'listos';

/// La vista con la que abre la lista. Cualquier valor desconocido (ausente,
/// de una versión futura) abre en Todos, para que una app vieja nunca se
/// rompa con un valor nuevo.
InboxView inboxViewFromPref(String? value) {
  switch (value) {
    case _prefPendientes:
      return InboxView.pendientes;
    case _prefListos:
      return InboxView.listos;
    default:
      return InboxView.todos;
  }
}

/// Lo que se guarda al elegir [view].
String inboxViewPref(InboxView view) {
  switch (view) {
    case InboxView.todos:
      return _prefTodos;
    case InboxView.pendientes:
      return _prefPendientes;
    case InboxView.listos:
      return _prefListos;
  }
}
