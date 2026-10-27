import 'phone_input.dart';

/// El número que hoy usa una sesión.
///
/// El id del doc de sesión es el número con el que se vinculó POR PRIMERA VEZ.
/// Tras un cambio de número el doc conserva su id (así no se mueve ni un
/// documento) y el número real vive en `phone_number`. Para mostrarlo o para
/// deducir el país, usar esto y no el id. Ver CLAUDE.md, "📲 Cambiar de número".
String sessionPhone(Map<String, dynamic>? data, String sessionId) {
  final phone = data?['phone_number'];
  return phone is String && phone.isNotEmpty ? phone : sessionId;
}

/// Cómo se le nombra una sesión al operador: el alias que le puso, el nombre
/// verificado de Meta (Cloud API sin alias) o, si no hay ninguno, su número.
/// Mis Cuentas, el título de la lista y el selector de cuenta la nombran igual.
String sessionDisplayName(Map<String, dynamic>? data, String sessionId) {
  for (final field in const ['alias', 'cloud_api_verified_name']) {
    final value = data?[field];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return displayPhone(sessionPhone(data, sessionId));
}
