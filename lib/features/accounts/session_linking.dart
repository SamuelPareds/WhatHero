import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core/config.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'link_account_screen.dart';
import 'link_result.dart';

/// Pide un QR al backend y muestra la pantalla para escanearlo. Devuelve cómo
/// terminó la vinculación, o null si el usuario salió antes de escanear o el
/// pedido falló (en ese caso ya se avisó con un toast).
///
/// - Sin [intoSessionId]: "Agregar número".
/// - Con [intoSessionId]: re-vincular esa sesión. Si se escanea otro número,
///   el backend lo rechaza salvo que venga [allowNumberChange] (sólo el owner):
///   entonces el número nuevo entra en esa sesión. Ver
///   backend/src/services/sessionTarget.ts.
Future<LinkResult?> linkWhatsApp(
  BuildContext context, {
  required String accountId,
  String? intoSessionId,
  bool allowNumberChange = false,
  bool keepPrevious = false,
  String title = 'Vincular Cuenta',
  String? hint,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  if (!SocketService().isConnected) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Conectando al servidor... intenta de nuevo')),
    );
    return null;
  }

  try {
    final response = await http
        .post(
          Uri.parse('$backendUrl/start-session'),
          headers: await authHeaders(),
          body: jsonEncode({
            'accountId': accountId,
            if (intoSessionId != null) 'intoSessionId': intoSessionId,
            if (allowNumberChange) 'allowNumberChange': true,
            if (keepPrevious) 'keepPrevious': true,
          }),
        )
        .timeout(const Duration(seconds: 10));

    final body = jsonDecode(response.body);
    if (response.statusCode != 200) {
      final error = body is Map ? body['error'] : null;
      messenger.showSnackBar(SnackBar(content: Text('${error ?? 'Error ${response.statusCode}'}')));
      return null;
    }

    final sessionKey = (body as Map<String, dynamic>)['sessionKey'] as String;
    return await navigator.push<LinkResult>(
      MaterialPageRoute(
        builder: (_) => LinkAccountScreen(
          sessionKey: sessionKey,
          accountId: accountId,
          title: title,
          hint: hint,
        ),
      ),
    );
  } catch (e) {
    debugPrint('[linkWhatsApp] Error: $e');
    messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    return null;
  }
}
