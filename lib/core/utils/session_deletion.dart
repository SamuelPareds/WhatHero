// Eliminar una sesión de WhatsApp (sólo el owner). Ver CLAUDE.md,
// "🗑️ Eliminar una sesión".

/// ¿El owner mandó eliminar esta sesión? El backend deja el doc como lápida
/// (`deleting_at`) mientras borra todo lo suyo, y lo borra a él al final.
/// Mientras tanto la sesión no se abre, no se re-vincula ni se configura.
bool isSessionDeleting(Map<String, dynamic>? data) => data?['deleting_at'] != null;

/// Lo que hay que teclear para confirmar: los últimos 4 dígitos del número.
/// Confirma que es la sesión correcta, que es el error caro cuando una cuenta
/// tiene varias sucursales.
String deleteConfirmationDigits(String phone) {
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
}

/// ¿Lo tecleado confirma el borrado? Se ignora lo que no sea dígito, para que
/// "12 34" también cuente.
bool deleteConfirmationMatches(String typed, String phone) {
  final expected = deleteConfirmationDigits(phone);
  return expected.isNotEmpty && typed.replaceAll(RegExp(r'\D'), '') == expected;
}
