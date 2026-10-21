import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// Resultado devuelto al conectar o actualizar una sesión de WhatsApp Cloud API.
class CloudApiConnectResult {
  final String sessionId;
  final String sessionKey;
  final String displayPhoneNumber;
  final String verifiedName;
  final String webhookVerifyToken;

  const CloudApiConnectResult({
    required this.sessionId,
    required this.sessionKey,
    required this.displayPhoneNumber,
    required this.verifiedName,
    required this.webhookVerifyToken,
  });
}

/// Abre el modal para conectar o actualizar un número de Meta WhatsApp Cloud API
/// (incluyendo el número de prueba gratuito de Meta for Developers).
///
/// [intoSessionId] es la sesión que se está editando ("Actualizar
/// credenciales"): el backend rechaza credenciales de otro número en vez de
/// crear una segunda sesión. Sin él, es un alta.
Future<CloudApiConnectResult?> showConnectCloudApiSheet(
  BuildContext context, {
  required String accountId,
  String? intoSessionId,
  String? initialPhoneNumberId,
  String? initialWabaId,
  String? initialAlias,
  String? tokenHint,
}) {
  final isWide = MediaQuery.of(context).size.width >= 640;
  if (isWide) {
    return showDialog<CloudApiConnectResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: _ConnectCloudApiForm(
            accountId: accountId,
            intoSessionId: intoSessionId,
            initialPhoneNumberId: initialPhoneNumberId,
            initialWabaId: initialWabaId,
            initialAlias: initialAlias,
            tokenHint: tokenHint,
            isDialog: true,
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<CloudApiConnectResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.6,
        maxChildSize: 0.96,
        expand: false,
        builder: (_, scrollController) => _ConnectCloudApiForm(
          accountId: accountId,
          intoSessionId: intoSessionId,
          initialPhoneNumberId: initialPhoneNumberId,
          initialWabaId: initialWabaId,
          initialAlias: initialAlias,
          tokenHint: tokenHint,
          scrollController: scrollController,
          isDialog: false,
        ),
      ),
    ),
  );
}

class _ConnectCloudApiForm extends StatefulWidget {
  final String accountId;
  final String? intoSessionId;
  final String? initialPhoneNumberId;
  final String? initialWabaId;
  final String? initialAlias;
  final String? tokenHint;
  final ScrollController? scrollController;
  final bool isDialog;

  const _ConnectCloudApiForm({
    required this.accountId,
    this.intoSessionId,
    this.initialPhoneNumberId,
    this.initialWabaId,
    this.initialAlias,
    this.tokenHint,
    this.scrollController,
    required this.isDialog,
  });

  @override
  State<_ConnectCloudApiForm> createState() => _ConnectCloudApiFormState();
}

class _ConnectCloudApiFormState extends State<_ConnectCloudApiForm> {
  late final TextEditingController _phoneIdController;
  late final TextEditingController _wabaIdController;
  late final TextEditingController _tokenController;
  late final TextEditingController _appSecretController;
  late final TextEditingController _aliasController;

  bool _obscureToken = true;
  bool _obscureAppSecret = true;
  bool _isSubmitting = false;
  bool _showGuide = false;
  String? _errorMessage;
  final String _verifyToken = 'whathero_meta_verify_2026';

  static const Color _errorRed = Color(0xFFF87171);

  bool get _isEditing =>
      (widget.initialPhoneNumberId != null && widget.initialPhoneNumberId!.isNotEmpty);

  // URL del túnel hacia el backend local, para probar en desarrollo:
  // `flutter run --dart-define=WEBHOOK_PUBLIC_URL=https://….trycloudflare.com`.
  static const _devTunnelUrl = String.fromEnvironment('WEBHOOK_PUBLIC_URL');

  /// URL pública del webhook para pegar en Meta: HTTPS y hacia el backend de
  /// ESTE entorno. En release es Railway. En desarrollo el backend es localhost
  /// y Meta no llega ahí; antes se mostraba la de Railway, que es producción
  /// (`accounts`) y no conoce las sesiones de `accounts_dev`. Sin túnel
  /// configurado devuelve null y la tarjeta explica cómo abrir uno.
  String? get _webhookUrl {
    if (backendUrl.startsWith('https://')) return '$backendUrl/webhook/meta';
    if (_devTunnelUrl.isNotEmpty) {
      return '${_devTunnelUrl.replaceAll(RegExp(r'/+$'), '')}/webhook/meta';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _phoneIdController = TextEditingController(text: widget.initialPhoneNumberId ?? '');
    _wabaIdController = TextEditingController(text: widget.initialWabaId ?? '');
    _tokenController = TextEditingController();
    _appSecretController = TextEditingController();
    _aliasController = TextEditingController(text: widget.initialAlias ?? '');
  }

  @override
  void dispose() {
    _phoneIdController.dispose();
    _wabaIdController.dispose();
    _tokenController.dispose();
    _appSecretController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  Future<void> _copyToClipboard(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado al portapapeles'),
        backgroundColor: accentAqua,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _submit() async {
    final phoneNumberId = _phoneIdController.text.trim();
    final wabaId = _wabaIdController.text.trim();
    final accessToken = _tokenController.text.trim();
    final appSecret = _appSecretController.text.trim();
    final alias = _aliasController.text.trim();

    // Al editar, el App Secret vacío conserva el guardado (lo decide el backend).
    if (phoneNumberId.isEmpty || wabaId.isEmpty || accessToken.isEmpty || (!_isEditing && appSecret.isEmpty)) {
      setState(() {
        _errorMessage =
            'Completa el Phone Number ID, el WABA ID, el Access Token y el App Secret que te entrega Meta.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/sessions/cloud-api/connect'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              if (widget.intoSessionId != null) 'intoSessionId': widget.intoSessionId,
              'phoneNumberId': phoneNumberId,
              'wabaId': wabaId,
              'accessToken': accessToken,
              if (appSecret.isNotEmpty) 'appSecret': appSecret,
              if (alias.isNotEmpty) 'alias': alias,
            }),
          )
          .timeout(const Duration(seconds: 20));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || body['success'] != true) {
        final msg = (body['error'] as String?) ?? 'No se pudo verificar con Meta Cloud API';
        setState(() {
          _errorMessage = msg;
          _isSubmitting = false;
        });
        return;
      }

      final result = CloudApiConnectResult(
        sessionId: (body['sessionId'] as String?) ?? phoneNumberId,
        sessionKey: (body['sessionKey'] as String?) ?? '${widget.accountId}_$phoneNumberId',
        displayPhoneNumber: (body['displayPhoneNumber'] as String?) ?? phoneNumberId,
        verifiedName: (body['verifiedName'] as String?) ?? 'WhatsApp Cloud API',
        webhookVerifyToken: (body['webhookVerifyToken'] as String?) ?? _verifyToken,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Error de conexión con el servidor: $e';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final border = Colors.white.withValues(alpha: 0.12);

    return Container(
      decoration: BoxDecoration(
        color: surfaceDark,
        borderRadius: widget.isDialog
            ? BorderRadius.circular(18)
            : const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: primaryAqua.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.cloud_done_rounded, color: primaryAqua, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isEditing
                            ? 'Configuración de WhatsApp Cloud API'
                            : 'Conectar WhatsApp Cloud API (Meta)',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Compatible con el número de prueba gratuito de Meta o número oficial',
                        style: TextStyle(fontSize: 12, color: lightText),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: lightText),
                  tooltip: 'Cerrar',
                ),
              ],
            ),
          ),
          Divider(height: 1, color: border),

          // Contenido scrollable
          Flexible(
            child: ListView(
              controller: widget.scrollController,
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                // Guía desplegable paso a paso
                InkWell(
                  onTap: () => setState(() => _showGuide = !_showGuide),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: primaryAqua.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: primaryAqua.withValues(alpha: 0.28)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.help_outline_rounded, size: 17, color: primaryAqua),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '¿Dónde encuentro estos datos en Meta for Developers?',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: white,
                                ),
                              ),
                            ),
                            Icon(
                              _showGuide ? Icons.expand_less : Icons.expand_more,
                              size: 18,
                              color: lightText,
                            ),
                          ],
                        ),
                        if (_showGuide) ...[
                          const SizedBox(height: 10),
                          const Text(
                            '1. Entra a developers.facebook.com → Tu App → WhatsApp → Configuración de la API.\n'
                            '2. En "De" selecciona el número de prueba ("Test number") o tu número oficial.\n'
                            '3. Copia el "Identificador de número de teléfono" (Phone Number ID) y el "Identificador de la cuenta de WhatsApp Business" (WABA ID).\n'
                            '4. Copia el Token de acceso temporal (dura 24h para pruebas) o un Token permanente de Usuario del Sistema.\n'
                            '5. En Configuración de la app → Básica, copia la "Clave secreta de la app" (App Secret).\n'
                            '6. En "Para" agrega tu número personal de WhatsApp a la lista permitida de Meta para recibir mensajes del número de prueba.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: lightText,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Campo: Phone Number ID
                _buildFieldLabel('Phone Number ID (Identificador de número de teléfono) *'),
                const SizedBox(height: 6),
                TextField(
                  controller: _phoneIdController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: white, fontSize: 14),
                  decoration: _inputDecoration(
                    hint: 'Ej. 105928374650192',
                    icon: Icons.pin_outlined,
                  ),
                ),

                const SizedBox(height: 14),

                // Campo: WABA ID
                _buildFieldLabel('WABA ID (Identificador de cuenta de WhatsApp Business) *'),
                const SizedBox(height: 6),
                TextField(
                  controller: _wabaIdController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: white, fontSize: 14),
                  decoration: _inputDecoration(
                    hint: 'Ej. 109485736201928',
                    icon: Icons.business_outlined,
                  ),
                ),

                const SizedBox(height: 14),

                // Campo: Access Token
                _buildFieldLabel(
                  _isEditing && widget.tokenHint != null
                      ? 'Access Token de Meta * (actual: ${widget.tokenHint})'
                      : 'Access Token de Meta (Temporal o Permanente) *',
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _tokenController,
                  obscureText: _obscureToken,
                  style: const TextStyle(color: white, fontSize: 13.5, fontFamily: 'monospace'),
                  decoration: _inputDecoration(
                    hint: 'EAAGm0PX4ZCpsBA...',
                    icon: Icons.key_rounded,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        size: 18,
                        color: lightText,
                      ),
                      onPressed: () => setState(() => _obscureToken = !_obscureToken),
                      tooltip: _obscureToken ? 'Mostrar token' : 'Ocultar token',
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Campo: App Secret. Con él se verifica la firma de cada webhook
                // de la app del cliente (ver CLAUDE.md, "☁️ WhatsApp Cloud API").
                _buildFieldLabel(
                  _isEditing
                      ? 'App Secret (déjalo vacío para conservar el actual)'
                      : 'App Secret (Clave secreta de la app) *',
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _appSecretController,
                  obscureText: _obscureAppSecret,
                  style: const TextStyle(color: white, fontSize: 13.5, fontFamily: 'monospace'),
                  decoration: _inputDecoration(
                    hint: 'Ej. 3f9a1c0e7b2d4a6f8e1c5b9d7a3e2f10',
                    icon: Icons.lock_outline_rounded,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureAppSecret ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        size: 18,
                        color: lightText,
                      ),
                      onPressed: () => setState(() => _obscureAppSecret = !_obscureAppSecret),
                      tooltip: _obscureAppSecret ? 'Mostrar App Secret' : 'Ocultar App Secret',
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Meta for Developers → tu app → Configuración de la app → Básica. WhatHero lo usa para comprobar que los mensajes que llegan vienen de Meta.',
                  style: TextStyle(fontSize: 11, color: lightText, height: 1.35),
                ),

                const SizedBox(height: 14),

                // Campo: Alias opcional
                _buildFieldLabel('Nombre o alias en WhatHero (opcional)'),
                const SizedBox(height: 6),
                TextField(
                  controller: _aliasController,
                  style: const TextStyle(color: white, fontSize: 14),
                  decoration: _inputDecoration(
                    hint: 'Ej. Meta Test Number / AgendaCool Oficial',
                    icon: Icons.label_outline_rounded,
                  ),
                ),

                const SizedBox(height: 18),

                // Tarjeta de configuración de Webhook para recibir respuestas en WhatHero
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: darkBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.webhook_rounded, size: 17, color: primaryAqua),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Webhook para recibir y responder mensajes en WhatHero',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Pega estos dos valores en Meta Developers → WhatsApp → Configuración → Webhook y activa la suscripción al campo "messages":',
                        style: TextStyle(fontSize: 11.5, color: lightText, height: 1.35),
                      ),
                      const SizedBox(height: 10),
                      if (_webhookUrl case final url?)
                        _buildCopyableRow(
                          label: 'URL de devolución de llamada (Callback URL)',
                          value: url,
                          onCopy: () => _copyToClipboard(url, 'URL del Webhook'),
                        )
                      else
                        const SelectableText(
                          'Desarrollo: Meta no llega a localhost. Abre un túnel con\n'
                          '  cloudflared tunnel --url http://localhost:3000\n'
                          'y pega https://<tu-túnel>/webhook/meta. Para verla aquí, corre la app con '
                          '--dart-define=WEBHOOK_PUBLIC_URL=https://<tu-túnel>.',
                          style: TextStyle(fontSize: 11.5, color: Colors.orangeAccent, height: 1.4),
                        ),
                      const SizedBox(height: 8),
                      _buildCopyableRow(
                        label: 'Token de verificación (Verify Token)',
                        value: _verifyToken,
                        onCopy: () => _copyToClipboard(_verifyToken, 'Token de verificación'),
                      ),
                    ],
                  ),
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _errorRed.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _errorRed.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: _errorRed,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _errorRed,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          Divider(height: 1, color: border),

          // Footer con botones
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancelar', style: TextStyle(color: lightText)),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAqua,
                    foregroundColor: darkBg,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: darkBg,
                          ),
                        )
                      : const Icon(Icons.check_circle_outline_rounded, size: 18),
                  label: Text(
                    _isSubmitting
                        ? 'Verificando con Meta...'
                        : (_isEditing ? 'Guardar y verificar' : 'Conectar número'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: white,
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    final border = Colors.white.withValues(alpha: 0.14);
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: lightText.withValues(alpha: 0.55), fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: lightText),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: darkBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: primaryAqua, width: 1.5),
      ),
    );
  }

  Widget _buildCopyableRow({
    required String label,
    required String value,
    required VoidCallback onCopy,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: surfaceDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 10.5, color: lightText),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: white,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 16),
            color: primaryAqua,
            tooltip: 'Copiar',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
