import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// Diálogo de edición de nombre de un miembro. Llama al PATCH y muestra error
/// inline si el backend rechaza (ej. permisos, nombre vacío).
///
/// Devuelve el nombre nuevo (String) si se guardó con éxito, o `null` si se
/// canceló. Esto permite a la pantalla que lo invoca refrescar su UI sin
/// re-leer Firestore.
Future<String?> showEditMemberNameDialog(
  BuildContext context, {
  required String accountId,
  required String uid,
  required String currentName,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogCtx) => _EditNameDialog(
      accountId: accountId,
      uid: uid,
      currentName: currentName,
    ),
  );
}

class _EditNameDialog extends StatefulWidget {
  final String accountId;
  final String uid;
  final String currentName;

  const _EditNameDialog({
    required this.accountId,
    required this.uid,
    required this.currentName,
  });

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  bool _saving = false;
  String? _error;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newName = _controller.text.trim();
    if (newName.isEmpty) {
      setState(() => _error = 'El nombre no puede estar vacío');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await http
          .patch(
            Uri.parse('$backendUrl/accounts/members/${widget.uid}'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'displayName': newName,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.of(context).pop(newName);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nombre actualizado'),
            backgroundColor: primaryAqua,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _error = body['error'] as String? ?? 'Error inesperado';
          _saving = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error de red: $e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Editar nombre',
        style: TextStyle(color: white, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Este nombre aparece arriba de cada mensaje saliente para identificar quién respondió.',
            style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_saving,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            keyboardType: TextInputType.name,
            style: const TextStyle(color: white),
            decoration: InputDecoration(
              hintText: 'Nombre completo',
              hintStyle: const TextStyle(color: lightText),
              filled: true,
              fillColor: darkBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancelar',
            style: TextStyle(color: lightText.withValues(alpha: 0.7)),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAqua,
            foregroundColor: darkBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(darkBg),
                  ),
                )
              : const Text(
                  'Guardar',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
      ],
    );
  }
}
