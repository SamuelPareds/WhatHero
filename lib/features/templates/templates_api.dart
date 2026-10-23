import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

import 'meta_template.dart';

/// Un error del backend o de Meta, listo para mostrarle al operador.
class TemplateApiException implements Exception {
  final String message;

  /// Todos los problemas de una plantilla que no pasó la validación: el
  /// operador corrige todo de una vez.
  final List<String> details;

  const TemplateApiException(this.message, [this.details = const []]);

  @override
  String toString() => message;
}

/// Lo que contestó Meta al recibir una plantilla nueva.
class CreatedTemplate {
  final String id;
  final String status;

  /// La categoría que le asignó Meta, que puede no ser la pedida.
  final String category;
  final String requestedCategory;

  const CreatedTemplate({
    required this.id,
    required this.status,
    required this.category,
    required this.requestedCategory,
  });

  /// Meta la pasó a otra categoría (casi siempre a Marketing, que se cobra).
  bool get wasRecategorized => category != requestedCategory;
}

Map<String, dynamic> _decode(http.Response response) {
  try {
    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic>) return data;
  } catch (_) {}
  return {'error': 'Respuesta inesperada del servidor (HTTP ${response.statusCode})'};
}

TemplateApiException _failure(Map<String, dynamic> data, String fallback) {
  final errors = (data['errors'] as List<dynamic>?) ?? const [];
  return TemplateApiException(
    (data['error'] as String?) ?? fallback,
    [
      for (final e in errors)
        if (e is Map && e['message'] is String) e['message'] as String,
    ],
  );
}

/// Todas las plantillas del WABA de la sesión, en cualquier estado.
Future<List<MetaTemplateModel>> fetchMetaTemplates({
  required String accountId,
  required String sessionId,
}) async {
  final uri = Uri.parse(
    '$backendUrl/sessions/cloud-api/templates'
    '?accountId=${Uri.encodeComponent(accountId)}'
    '&sessionId=${Uri.encodeComponent(sessionId)}',
  );
  final response = await http
      .get(uri, headers: await authHeaders())
      .timeout(const Duration(seconds: 30));
  final data = _decode(response);
  if (response.statusCode != 200 || data['success'] != true) {
    throw _failure(data, 'No se pudieron cargar las plantillas');
  }
  return ((data['templates'] as List<dynamic>?) ?? const [])
      .whereType<Map>()
      .map((m) => MetaTemplateModel.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

/// Manda una plantilla a revisión de Meta. Sólo el owner.
Future<CreatedTemplate> submitMetaTemplate({
  required String accountId,
  required String sessionId,
  required Map<String, dynamic> template,
}) async {
  final http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('$backendUrl/sessions/cloud-api/templates'),
          headers: await authHeaders(),
          body: jsonEncode({'accountId': accountId, 'sessionId': sessionId, 'template': template}),
        )
        .timeout(const Duration(seconds: 30));
  } on TimeoutException {
    // Ambiguo: Meta pudo recibirla igual. Reintentar a ciegas chocaría con
    // "ya existe" y confundiría más.
    throw const TemplateApiException(
      'No sabemos si Meta la recibió: revisa la lista de plantillas antes de reintentar.',
    );
  }
  final data = _decode(response);
  if (response.statusCode != 200 || data['success'] != true) {
    throw _failure(data, 'No se pudo enviar la plantilla a revisión');
  }
  final t = Map<String, dynamic>.from(data['template'] as Map);
  return CreatedTemplate(
    id: '${t['id']}',
    status: '${t['status']}',
    category: '${t['category']}',
    requestedCategory: '${template['category']}',
  );
}

/// Elimina esa plantilla (sólo ese idioma). Sólo el owner.
Future<void> deleteMetaTemplate({
  required String accountId,
  required String sessionId,
  required MetaTemplateModel template,
}) async {
  final response = await http
      .post(
        Uri.parse('$backendUrl/sessions/cloud-api/templates/delete'),
        headers: await authHeaders(),
        body: jsonEncode({
          'accountId': accountId,
          'sessionId': sessionId,
          'templateId': template.id,
          'name': template.name,
        }),
      )
      .timeout(const Duration(seconds: 30));
  final data = _decode(response);
  if (response.statusCode != 200 || data['success'] != true) {
    throw _failure(data, 'No se pudo eliminar la plantilla');
  }
}
