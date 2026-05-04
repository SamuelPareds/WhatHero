import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Headers JSON + Bearer con el ID Token del usuario actual.
///
/// Devolver vía future async permite que el caller `await`. Si no hay user
/// logueado (caso raro: race entre logout y request), regresa solo el
/// Content-Type — el endpoint responderá 401 y la UI puede manejarlo.
///
/// Uso:
///   await http.post(
///     Uri.parse('$backendUrl/start-session'),
///     headers: await authHeaders(),
///     body: jsonEncode({...}),
///   );
Future<Map<String, String>> authHeaders() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    debugPrint('[authHeaders] No hay user logueado');
    return {'Content-Type': 'application/json'};
  }
  // getIdToken() usa el cacheado mientras siga vigente; Firebase auto-refresca
  // si expiró. No forzamos true aquí: ahorra una request a Google por cada call.
  final token = await user.getIdToken();
  return {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };
}
