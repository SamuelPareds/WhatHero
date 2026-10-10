import 'package:cloud_firestore/cloud_firestore.dart';

/// Un cambio de número de la sesión: una entrada de `number_history` en el doc
/// de sesión. Hasta [until] la sesión escribía desde [phone]; desde ahí, con
/// el número siguiente. Ver CLAUDE.md, "📲 Cambiar de número".
class NumberChange {
  final String phone;
  final DateTime until;

  const NumberChange(this.phone, this.until);
}

/// Lee `number_history`, del más viejo al más nuevo. Ignora entradas rotas.
List<NumberChange> parseNumberHistory(Object? raw) {
  if (raw is! List) return const [];
  final changes = <NumberChange>[
    for (final entry in raw)
      if (entry is Map && entry['phone'] is String && entry['until'] is Timestamp)
        NumberChange(entry['phone'] as String, (entry['until'] as Timestamp).toDate()),
  ];
  changes.sort((a, b) => a.until.compareTo(b.until));
  return changes;
}

/// El cambio de número que cae entre dos entradas contiguas del chat, o null.
///
/// Va por tiempo y no por una etiqueta en cada mensaje: así no hubo que tocar
/// un solo documento al cambiar de número. Si entre las dos entradas hubo más
/// de un cambio (un número que se usó sin escribirle a este cliente), gana el
/// primero: su `phone` es el número desde el que salió la entrada de arriba.
NumberChange? numberChangeBetween(DateTime older, DateTime newer, List<NumberChange> changes) {
  for (final change in changes) {
    if (older.isBefore(change.until) && !newer.isBefore(change.until)) return change;
  }
  return null;
}

/// ¿Ese mensaje es del número anterior? Lo es si es anterior al último cambio,
/// o si llegó por la línea anterior que quedó recibiendo ([previousNumber],
/// el campo `previousNumber` del mensaje). La cuenta que hoy manda no es su
/// dueña: no puede editarlo, borrarlo para todos ni reaccionarle.
bool isFromPreviousNumber(DateTime sentAt, List<NumberChange> changes, {String? previousNumber}) {
  if (previousNumber != null && previousNumber.isNotEmpty) return true;
  return changes.isNotEmpty && sentAt.isBefore(changes.last.until);
}

/// ¿Va el aviso "Lo que envíes ahora sale del número nuevo" debajo del último
/// mensaje? Cuando lo último del chat es del número anterior: el cliente
/// todavía no conoce el nuevo y conviene presentarse.
bool showNewNumberHint({
  required DateTime? newestAt,
  required String? newestPreviousNumber,
  required List<NumberChange> changes,
}) {
  if (changes.isEmpty || newestAt == null) return false;
  return isFromPreviousNumber(newestAt, changes, previousNumber: newestPreviousNumber);
}

const _shortMonths = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

/// "9 oct 2026".
String shortDate(DateTime date) => '${date.day} ${_shortMonths[date.month - 1]} ${date.year}';
