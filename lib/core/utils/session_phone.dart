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
