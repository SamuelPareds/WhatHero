import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// La URL a la que un sistema externo manda sus plantillas con una llave.
String get publicApiSendUrl => '$backendUrl/api/v1/messages/template';

/// Un error del backend, listo para mostrarle al owner.
class ApiKeysException implements Exception {
  final String message;

  const ApiKeysException(this.message);

  @override
  String toString() => message;
}

/// Una llave del API pública tal como la devuelve `GET /api-keys`: nunca trae
/// el secreto, sólo la pista (`whk_1a2b3c…wxyz`). La llave completa se ve una
/// sola vez, al crearla.
class ApiKeySummary {
  final String keyId;
  final String name;
  final String hint;

  /// Puede enviar desde todas las sesiones Cloud API, incluso las que se
  /// conecten después. Si no, sólo desde [sessionIds].
  final bool allSessions;
  final List<String> sessionIds;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;

  const ApiKeySummary({
    required this.keyId,
    required this.name,
    required this.hint,
    required this.allSessions,
    required this.sessionIds,
    this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
  });

  bool get isRevoked => revokedAt != null;

  factory ApiKeySummary.fromJson(Map<String, dynamic> json) {
    DateTime? date(String field) => DateTime.tryParse('${json[field] ?? ''}');
    return ApiKeySummary(
      keyId: '${json['keyId'] ?? ''}',
      name: '${json['name'] ?? ''}',
      hint: '${json['hint'] ?? ''}',
      allSessions: json['allSessions'] == true,
      sessionIds: [for (final id in (json['sessionIds'] as List<dynamic>? ?? const [])) '$id'],
      createdAt: date('createdAt'),
      lastUsedAt: date('lastUsedAt'),
      revokedAt: date('revokedAt'),
    );
  }
}

Map<String, dynamic> _decode(http.Response response) {
  try {
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic>) return data;
  } catch (_) {}
  return {'error': 'Respuesta inesperada del servidor (HTTP ${response.statusCode})'};
}

Map<String, dynamic> _ok(http.Response response, String fallback) {
  final data = _decode(response);
  if (response.statusCode != 200 || data['success'] != true) {
    throw ApiKeysException((data['error'] as String?) ?? fallback);
  }
  return data;
}

/// Las llaves de la cuenta: activas primero, revocadas al final. Sólo el owner.
Future<List<ApiKeySummary>> fetchApiKeys({required String accountId}) async {
  final response = await http
      .get(
        Uri.parse('$backendUrl/api-keys?accountId=${Uri.encodeComponent(accountId)}'),
        headers: await authHeaders(),
      )
      .timeout(const Duration(seconds: 20));
  final data = _ok(response, 'No se pudieron cargar las llaves');
  return [
    for (final k in (data['keys'] as List<dynamic>? ?? const []))
      if (k is Map) ApiKeySummary.fromJson(Map<String, dynamic>.from(k)),
  ];
}

/// Crea una llave y devuelve la llave completa: es la única vez que existe
/// fuera del sistema que la va a usar.
Future<({String key, ApiKeySummary summary})> createApiKey({
  required String accountId,
  required String name,
  required bool allSessions,
  required List<String> sessionIds,
}) async {
  final http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('$backendUrl/api-keys'),
          headers: await authHeaders(),
          body: jsonEncode({
            'accountId': accountId,
            'name': name,
            'allSessions': allSessions,
            'sessionIds': sessionIds,
          }),
        )
        .timeout(const Duration(seconds: 20));
  } on TimeoutException {
    // Pudo crearse sin que viéramos la llave: no hay forma de recuperarla.
    throw const ApiKeysException(
      'El servidor no respondió a tiempo. Si la llave aparece en la lista, revócala y crea otra: no se puede volver a ver.',
    );
  }
  final data = _ok(response, 'No se pudo crear la llave');
  return (
    key: '${data['key']}',
    summary: ApiKeySummary.fromJson(Map<String, dynamic>.from(data['apiKey'] as Map)),
  );
}

/// Deja de funcionar en el acto. Sólo el owner.
Future<void> revokeApiKey({required String accountId, required String keyId}) async {
  final response = await http
      .post(
        Uri.parse('$backendUrl/api-keys/revoke'),
        headers: await authHeaders(),
        body: jsonEncode({'accountId': accountId, 'keyId': keyId}),
      )
      .timeout(const Duration(seconds: 20));
  _ok(response, 'No se pudo revocar la llave');
}
