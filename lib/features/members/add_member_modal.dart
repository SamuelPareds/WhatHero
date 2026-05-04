import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// Punto de entrada del flujo "agregar miembro".
///
/// Abre el [_AddMemberSheet] (modal bottom sheet con email + nombre).
/// Si el backend responde OK, automáticamente abre el [_CredentialsDialog]
/// para que el owner copie la contraseña temporal una sola vez.
Future<void> showAddMemberFlow(BuildContext context, String accountId) async {
  final result = await showModalBottomSheet<_CreateResult>(
    context: context,
    backgroundColor: surfaceDark,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _AddMemberSheet(accountId: accountId),
  );

  if (result == null || !context.mounted) return;

  // Mostrar credenciales en un dialog modal NO descartable: el owner debe
  // copiar el password antes de cerrar (no se vuelve a mostrar nunca).
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CredentialsDialog(
      email: result.email,
      tempPassword: result.tempPassword,
    ),
  );
}

class _CreateResult {
  final String email;
  final String tempPassword;
  _CreateResult({required this.email, required this.tempPassword});
}

class _AddMemberSheet extends StatefulWidget {
  final String accountId;
  const _AddMemberSheet({required this.accountId});

  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  final _emailCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _errorText;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    final name = _nameCtrl.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorText = 'Email inválido');
      return;
    }

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final res = await http
          .post(
            Uri.parse('$backendUrl/accounts/members'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'email': email,
              if (name.isNotEmpty) 'displayName': name,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        Navigator.of(context).pop(_CreateResult(
          email: data['email'] as String,
          tempPassword: data['tempPassword'] as String,
        ));
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _errorText = body['error'] as String? ?? 'Error inesperado';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Error de red: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        decoration: const BoxDecoration(
          color: surfaceDark,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: lightText.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'Agregar miembro',
              style: TextStyle(color: white, fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Recibirá acceso a todas las sesiones y chats de tu cuenta. '
              'Le mostraremos las credenciales temporales en el siguiente paso.',
              style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _emailCtrl,
              enabled: !_loading,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              style: const TextStyle(color: white),
              decoration: _inputDecoration('Email *'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              enabled: !_loading,
              style: const TextStyle(color: white),
              decoration: _inputDecoration('Nombre (opcional)'),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorText!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  disabledBackgroundColor: Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(darkBg),
                        ),
                      )
                    : const Text(
                        'Crear acceso',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: lightText),
      filled: true,
      fillColor: darkBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}

/// Diálogo de credenciales recién creadas. Estilo "AWS IAM Access Key":
/// se muestra UNA SOLA VEZ, no se puede cerrar al tocar fuera, exige
/// confirmación explícita de que el owner ya copió.
class _CredentialsDialog extends StatefulWidget {
  final String email;
  final String tempPassword;

  const _CredentialsDialog({
    required this.email,
    required this.tempPassword,
  });

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  bool _copied = false;

  String get _shareableText =>
      'Tu acceso a WhatHero\n\n'
      'Email: ${widget.email}\n'
      'Contraseña temporal: ${widget.tempPassword}\n\n'
      'Te pediremos cambiar la contraseña al iniciar sesión.';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _shareableText));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Credenciales copiadas al portapapeles'),
        duration: Duration(seconds: 2),
        backgroundColor: primaryAqua,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: primaryAqua.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.check_circle_outline,
                        color: primaryAqua),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Acceso creado',
                      style: TextStyle(
                          color: white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Comparte estas credenciales con el nuevo miembro. '
                'No las podrás ver de nuevo.',
                style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 20),
              _CredField(label: 'Email', value: widget.email),
              const SizedBox(height: 12),
              _CredField(
                label: 'Contraseña temporal',
                value: widget.tempPassword,
                monospace: true,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade700.withValues(alpha: 0.5)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.red.shade300, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Esta contraseña no se mostrará otra vez. '
                        'Cópiala antes de cerrar.',
                        style: TextStyle(
                          color: Colors.red.shade100,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAqua,
                    foregroundColor: darkBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text(
                    'Copiar credenciales',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onPressed: _copy,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: _copied ? white : lightText,
                  ),
                  onPressed: _copied
                      ? () => Navigator.of(context).pop()
                      : null,
                  child: Text(
                    _copied ? 'Ya las copié, cerrar' : 'Copia primero para cerrar',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredField extends StatelessWidget {
  final String label;
  final String value;
  final bool monospace;

  const _CredField({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: lightText,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: darkBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: lightText.withValues(alpha: 0.2)),
          ),
          child: SelectableText(
            value,
            style: TextStyle(
              color: white,
              fontSize: 14,
              fontFamily: monospace ? 'Courier' : null,
              fontWeight: monospace ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: monospace ? 0.5 : 0,
            ),
          ),
        ),
      ],
    );
  }
}
