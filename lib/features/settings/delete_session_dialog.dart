import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/core/utils/session_deletion.dart';

const _danger = Color(0xFFEF4444);

/// Pide confirmación y elimina la sesión (sólo el owner).
///
/// Devuelve `null` si se canceló; si no, si WhatHero alcanzó a cerrarse en el
/// WhatsApp del teléfono. Con la sesión caída no hay por dónde avisarle a
/// WhatsApp, y el owner tiene que quitarla él de Dispositivos vinculados.
///
/// El backend responde en cuanto cortó todo (sockets, IA, credenciales) y
/// purga en segundo plano: la tarjeta queda en "Eliminando…" unos minutos y
/// desaparece sola. Ver CLAUDE.md, "🗑️ Eliminar una sesión".
Future<bool?> showDeleteSessionDialog(
  BuildContext context, {
  required String accountId,
  required String sessionId,
  required String alias,
  required String phone,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeleteSessionDialog(
      accountId: accountId,
      sessionId: sessionId,
      alias: alias,
      phone: phone,
    ),
  );
}

class _DeleteSessionDialog extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String alias;
  final String phone;

  const _DeleteSessionDialog({
    required this.accountId,
    required this.sessionId,
    required this.alias,
    required this.phone,
  });

  @override
  State<_DeleteSessionDialog> createState() => _DeleteSessionDialogState();
}

class _DeleteSessionDialogState extends State<_DeleteSessionDialog> {
  final _controller = TextEditingController();
  bool _deleting = false;
  String? _error;

  bool get _confirmed => deleteConfirmationMatches(_controller.text, widget.phone);

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      final res = await http
          .post(
            Uri.parse('$backendUrl/sessions/delete'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': widget.accountId, 'sessionId': widget.sessionId}),
          )
          // El logout ante WhatsApp puede tardar hasta 5 s por socket.
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (res.statusCode == 202) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        Navigator.of(context).pop(body['loggedOut'] == true);
        return;
      }
      final body = jsonDecode(res.body);
      setState(() {
        _error = (body is Map ? body['error'] as String? : null) ?? 'Error ${res.statusCode}';
        _deleting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Sin respuesta del servidor. Revisa tu conexión y vuelve a intentarlo.';
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = deleteConfirmationDigits(widget.phone);
    return AlertDialog(
      backgroundColor: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('¿Eliminar esta sesión?', style: TextStyle(color: white, fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.alias, style: const TextStyle(color: white, fontWeight: FontWeight.bold)),
            Text(displayPhone(widget.phone), style: const TextStyle(color: lightText, fontSize: 13)),
            const SizedBox(height: 16),
            const Text('Se borra de WhatHero para siempre:', style: TextStyle(color: white, fontSize: 14)),
            const SizedBox(height: 8),
            const _Bullet('Todos los chats y mensajes, con sus fotos, videos, audios y documentos.'),
            const _Bullet('Notas, etiquetas, respuestas rápidas y mensajes internos del equipo.'),
            const _Bullet('El asistente de IA (con sus API keys), las reglas, los recordatorios y los seguimientos.'),
            const _Bullet('Los permisos de tu equipo sobre esta sesión.'),
            const SizedBox(height: 12),
            const Text(
              'WhatHero también se cierra en el WhatsApp del teléfono. Tus chats en el teléfono no se tocan.',
              style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              'Esta acción no se puede deshacer.',
              style: TextStyle(color: _danger, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Text(
              'Para confirmar, escribe los últimos 4 dígitos del número ($digits):',
              style: const TextStyle(color: white, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              enabled: !_deleting,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: white, letterSpacing: 4),
              onSubmitted: (_) {
                if (_confirmed && !_deleting) _delete();
              },
              decoration: InputDecoration(
                hintText: '····',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: darkBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 13)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.of(context).pop(),
          child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.7))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _danger,
            foregroundColor: white,
            disabledBackgroundColor: _danger.withValues(alpha: 0.25),
            disabledForegroundColor: white.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _confirmed && !_deleting ? _delete : null,
          child: _deleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(white)),
                )
              : const Text('Eliminar para siempre', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ', style: TextStyle(color: lightText, fontSize: 13)),
          Expanded(child: Text(text, style: const TextStyle(color: lightText, fontSize: 13, height: 1.4))),
        ],
      ),
    );
  }
}
