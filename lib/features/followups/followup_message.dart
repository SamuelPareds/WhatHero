/// Cómo se ve hoy el mensaje de una propuesta de seguimiento.
///
/// El texto guardado lleva `{faltan_dias}` y `{fecha_limite}` sin llenar: se
/// llenan al ENVIAR (backend, `renderDateVariables` en
/// `backend/src/services/followupCampaigns.ts`), para que lo aprobado hoy y
/// enviado mañana diga los días de mañana. Esto es la misma regla, sólo para
/// la vista previa de la tarjeta y del composer. Si cambias una, cambia la
/// otra: los tests de los dos lados fijan las mismas frases.
library;

const _months = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

DateTime? parseDay(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (m == null) return null;
  return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String dayString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Hoy en el dispositivo, como 'YYYY-MM-DD'.
String todayString([DateTime? now]) => dayString(now ?? DateTime.now());

int daysBetween(String from, String to) {
  final a = parseDay(from)!;
  final b = parseDay(to)!;
  return b.difference(a).inDays;
}

/// "15 de noviembre".
String formatDayMonth(String day) {
  final d = parseDay(day);
  if (d == null) return day;
  return '${d.day} de ${_months[d.month - 1]}';
}

/// "Faltan 3 días" / "Falta 1 día" / "Hoy es el último día"; null si ya pasó.
String? daysLeftPhrase(String deadline, String today) {
  final left = daysBetween(today, deadline);
  if (left < 0) return null;
  if (left == 0) return 'Hoy es el último día';
  if (left == 1) return 'Falta 1 día';
  return 'Faltan $left días';
}

bool usesDateVariables(String template) => template.contains('{faltan_dias}') || template.contains('{fecha_limite}');

/// Llena las variables de fecha. null = ya no se puede enviar.
String? renderDateVariables(String template, String? deadline, String today) {
  if (!usesDateVariables(template)) return template;
  if (deadline == null) return null;
  final phrase = daysLeftPhrase(deadline, today);
  if (phrase == null) return null;
  var out = template.replaceAll('{fecha_limite}', formatDayMonth(deadline));
  // A mitad de frase va en minúscula: "…, faltan 3 días para…".
  out = out.replaceAllMapped(RegExp(r'\{faltan_dias\}'), (m) {
    final before = out.substring(0, m.start).trimRight();
    final startsSentence = before.isEmpty || RegExp(r'[.!?¡¿:\n]$').hasMatch(before);
    return startsSentence ? phrase : phrase[0].toLowerCase() + phrase.substring(1);
  });
  return out;
}
