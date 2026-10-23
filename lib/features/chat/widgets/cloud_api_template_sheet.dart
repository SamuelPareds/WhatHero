import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/services/pending_messages_service.dart';
import 'package:crm_whatsapp/features/templates/meta_template.dart';
import 'package:crm_whatsapp/features/templates/templates_api.dart';
import 'package:crm_whatsapp/features/templates/templates_screen.dart';

/// Abre el selector de plantillas aprobadas de Meta Cloud API para enviarlas al
/// chat actual (`hello_world`, numeradas `{{1}}` o con nombre `{{nombre}}`).
Future<bool?> showCloudApiTemplateSheet(
  BuildContext context, {
  required String accountId,
  required String sessionId,
  required String chatPhone,
  String? contactName,
}) {
  final isWide = MediaQuery.of(context).size.width >= 640;
  if (isWide) {
    return showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 700),
          child: _CloudApiTemplateSheetContent(
            accountId: accountId,
            sessionId: sessionId,
            chatPhone: chatPhone,
            contactName: contactName,
            isDialog: true,
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.55,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => _CloudApiTemplateSheetContent(
          accountId: accountId,
          sessionId: sessionId,
          chatPhone: chatPhone,
          contactName: contactName,
          scrollController: scrollController,
          isDialog: false,
        ),
      ),
    ),
  );
}

class _CloudApiTemplateSheetContent extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String chatPhone;
  final String? contactName;
  final ScrollController? scrollController;
  final bool isDialog;

  const _CloudApiTemplateSheetContent({
    required this.accountId,
    required this.sessionId,
    required this.chatPhone,
    this.contactName,
    this.scrollController,
    required this.isDialog,
  });

  @override
  State<_CloudApiTemplateSheetContent> createState() =>
      _CloudApiTemplateSheetContentState();
}

class _CloudApiTemplateSheetContentState
    extends State<_CloudApiTemplateSheetContent> {
  bool _isLoading = true;
  bool _isSending = false;
  String? _errorMessage;
  // Un id por plantilla elegida, el mismo en cada reintento: si el primer envío
  // venció por timeout pero sí salió, el backend (sendDedupe) devuelve ese mismo
  // mensaje en vez de mandarle al cliente la plantilla dos veces (y cobrarla).
  String? _sendTempId;
  List<MetaTemplateModel> _templates = const [];
  // Mandadas a revisión que todavía no se pueden usar: sin este aviso, quien
  // acaba de crear una cree que se perdió.
  int _inReviewCount = 0;
  MetaTemplateModel? _selectedTemplate;
  final List<TextEditingController> _headerControllers = [];
  final List<TextEditingController> _bodyControllers = [];
  final List<TextEditingController> _buttonControllers = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const Color _errorRed = Color(0xFFF87171);

  static const _helloWorldFallback = MetaTemplateModel(
    id: 'hello_world_builtin',
    name: 'hello_world',
    status: 'APPROVED',
    category: 'UTILITY',
    language: 'en_US',
    components: [
      {
        'type': 'HEADER',
        'format': 'TEXT',
        'text': 'Hello World',
      },
      {
        'type': 'BODY',
        'text':
            'Welcome and congratulations!! This message demonstrates your ability to send a WhatsApp message notification from the Cloud API, hosted by Meta. Thank you for taking the time to test with us.',
      },
      {
        'type': 'FOOTER',
        'text': 'WhatsApp Business Platform sample message',
      },
    ],
  );

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  @override
  void dispose() {
    for (final c in _headerControllers) {
      c.dispose();
    }
    for (final c in _bodyControllers) {
      c.dispose();
    }
    for (final c in _buttonControllers) {
      c.dispose();
    }
    _searchController.dispose();
    super.dispose();
  }

  // Nombres de variable que casi siempre son el nombre del cliente.
  static const _contactNameKeys = {'nombre', 'name', 'first_name', 'nombre_cliente', 'cliente'};

  void _selectTemplate(MetaTemplateModel tpl) {
    for (final c in [..._headerControllers, ..._bodyControllers, ..._buttonControllers]) {
      c.dispose();
    }
    TextEditingController controller(String initial) {
      final c = TextEditingController(text: initial);
      c.addListener(() {
        if (mounted) setState(() {});
      });
      return c;
    }

    final contact = widget.contactName?.trim() ?? '';
    final hasContactName = contact.isNotEmpty && widget.contactName != widget.chatPhone;
    // Se pre-llena con el nombre del contacto: {{nombre}} en cualquier parte, o
    // el {{1}} del mensaje en las numeradas (como siempre fue).
    String prefill(TemplateParam p, {required bool inBody}) {
      if (!hasContactName) return '';
      final isName = p.named ? _contactNameKeys.contains(p.key) : (inBody && p.key == '1');
      return isName ? contact : '';
    }

    _headerControllers
      ..clear()
      ..addAll(tpl.headerParams.map((p) => controller(prefill(p, inBody: false))));
    _bodyControllers
      ..clear()
      ..addAll(tpl.bodyParams.map((p) => controller(prefill(p, inBody: true))));
    _buttonControllers
      ..clear()
      ..addAll(tpl.buttonParams.map((_) => controller('')));

    setState(() {
      _selectedTemplate = tpl;
      _errorMessage = null;
      _sendTempId = null;
    });
  }

  Future<void> _openManager() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MetaTemplatesScreen(accountId: widget.accountId, sessionId: widget.sessionId),
    ));
    if (mounted) _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final all = await fetchMetaTemplates(
        accountId: widget.accountId,
        sessionId: widget.sessionId,
      );
      final parsed = all.where((t) => t.isApproved).toList();
      _inReviewCount = all.where((t) => t.isInReview).length;

      final hasHelloWorld = parsed.any((t) => t.name == 'hello_world');
      final list = hasHelloWorld ? parsed : [_helloWorldFallback, ...parsed];

      if (!mounted) return;
      setState(() {
        _templates = list;
        _isLoading = false;
      });
      if (list.isNotEmpty) {
        _selectTemplate(list.first);
      }
    } catch (e) {
      if (!mounted) return;
      // Si falla la consulta, aún permitimos enviar `hello_world` para que el usuario pueda probar.
      setState(() {
        _templates = const [_helloWorldFallback];
        _isLoading = false;
        _errorMessage =
            'No se pudo sincronizar la lista completa desde Meta (${describeSendError(e.toString())}), pero puedes probar con hello_world.';
      });
      _selectTemplate(_helloWorldFallback);
    }
  }

  Future<void> _sendSelectedTemplate() async {
    final tpl = _selectedTemplate;
    if (tpl == null) return;

    if (tpl.unsupportedReason != null) return;

    final headerValues = _headerControllers.map((c) => c.text.trim()).toList();
    final bodyValues = _bodyControllers.map((c) => c.text.trim()).toList();
    final buttonValues = _buttonControllers.map((c) => c.text.trim()).toList();

    if ([...headerValues, ...bodyValues, ...buttonValues].any((v) => v.isEmpty)) {
      setState(() {
        _errorMessage = 'Completa todos los campos variables {{...}} de la plantilla antes de enviar.';
      });
      return;
    }

    final components = tpl.buildComponents(
      header: headerValues,
      body: bodyValues,
      buttons: buttonValues,
    );
    final previewText = tpl.renderPreview(header: headerValues, body: bodyValues);

    _sendTempId ??= 'tpl-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _isSending = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/send-template'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'sessionId': widget.sessionId,
              'to': widget.chatPhone,
              'templateName': tpl.name,
              'languageCode': tpl.language,
              if (components.isNotEmpty) 'components': components,
              'renderedPreviewText': previewText,
              'tempId': _sendTempId,
            }),
          )
          .timeout(const Duration(seconds: 20));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || body['success'] != true) {
        final rawErr = (body['error'] as String?) ??
            (body['details'] as String?) ??
            'Error enviando plantilla';
        if (!mounted) return;
        setState(() {
          _errorMessage = describeSendError(rawErr);
          _isSending = false;
        });
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = describeSendError(e.toString());
        _isSending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final border = Colors.white.withValues(alpha: 0.12);

    final filtered = _templates.where((t) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return t.name.toLowerCase().contains(q) ||
          t.bodyText.toLowerCase().contains(q) ||
          t.language.toLowerCase().contains(q);
    }).toList();

    final selected = _selectedTemplate;

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
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: primaryAqua.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.article_outlined, color: primaryAqua, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Enviar plantilla oficial (Meta Cloud API)',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Para: ${widget.contactName ?? widget.chatPhone} (${widget.chatPhone})',
                        style: const TextStyle(fontSize: 12, color: lightText),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _isloadingOrSending ? null : _loadTemplates,
                  icon: const Icon(Icons.refresh_rounded, size: 19, color: lightText),
                  tooltip: 'Sincronizar plantillas desde Meta',
                ),
                IconButton(
                  onPressed: _isSending ? null : () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close, color: lightText),
                  tooltip: 'Cerrar',
                ),
              ],
            ),
          ),
          Divider(height: 1, color: border),

          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: primaryAqua),
                    SizedBox(height: 12),
                    Text(
                      'Cargando plantillas aprobadas de Meta...',
                      style: TextStyle(color: lightText),
                    ),
                  ],
                ),
              ),
            )
          else
            Flexible(
              child: ListView(
                controller: widget.scrollController,
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                children: [
                  if (_templates.length > 3) ...[
                    TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                      style: const TextStyle(color: white, fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText: 'Buscar plantilla por nombre o texto...',
                        hintStyle: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 13),
                        prefixIcon: const Icon(Icons.search, size: 18, color: lightText),
                        filled: true,
                        fillColor: darkBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: border),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Selecciona una plantilla aprobada:',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: white,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isSending ? null : _openManager,
                        child: const Text(
                          'Administrar plantillas',
                          style: TextStyle(color: primaryAqua, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  if (_inReviewCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _inReviewCount == 1
                            ? '1 plantilla en revisión de Meta: aparecerá aquí cuando la aprueben.'
                            : '$_inReviewCount plantillas en revisión de Meta: aparecerán aquí cuando las aprueben.',
                        style: const TextStyle(fontSize: 11.5, color: collisionAmber),
                      ),
                    ),
                  const SizedBox(height: 4),

                  // Chips / tarjetas de plantillas disponibles
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: filtered.map((tpl) {
                      final isSelected = selected?.name == tpl.name &&
                          selected?.language == tpl.language;
                      final blocked = tpl.unsupportedReason != null;
                      return ChoiceChip(
                        selected: isSelected,
                        onSelected: (_) => _selectTemplate(tpl),
                        selectedColor: primaryAqua.withValues(alpha: 0.2),
                        backgroundColor: darkBg,
                        side: BorderSide(
                          color: isSelected ? primaryAqua : border,
                          width: isSelected ? 1.4 : 1,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (tpl.name == 'hello_world' || blocked) ...[
                              Icon(
                                blocked ? Icons.block_rounded : Icons.science_outlined,
                                size: 15,
                                color: blocked ? collisionAmber : primaryAqua,
                              ),
                              const SizedBox(width: 5),
                            ],
                            Text(
                              '${tpl.name} (${tpl.language})',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight:
                                    isSelected ? FontWeight.w700 : FontWeight.w500,
                                color: blocked ? lightText : white,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),

                  if (selected != null && selected.unsupportedReason != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      selected.unsupportedReason!,
                      style: const TextStyle(fontSize: 12.5, color: collisionAmber, height: 1.35),
                    ),
                  ],

                  if (selected != null && selected.unsupportedReason == null) ...[
                    const SizedBox(height: 16),

                    // Un campo por variable, con su nombre real ({{nombre}} o {{1}}).
                    if (_headerControllers.isNotEmpty ||
                        _bodyControllers.isNotEmpty ||
                        _buttonControllers.isNotEmpty) ...[
                      const Text(
                        'Variables de la plantilla:',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final (i, p) in selected.headerParams.indexed)
                        _variableField(_headerControllers[i], 'Encabezado ${p.placeholder}'),
                      for (final (i, p) in selected.bodyParams.indexed)
                        _variableField(_bodyControllers[i], 'Mensaje ${p.placeholder}'),
                      for (final (i, b) in selected.buttonParams.indexed)
                        _variableField(_buttonControllers[i], 'Final del enlace del botón "${b.buttonText}"'),
                    ],

                    // Vista previa en vivo estilo burbuja de WhatsApp
                    const Text(
                      'Vista previa del mensaje:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: lightText,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: primaryAqua.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryAqua.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: primaryAqua.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  'PLANTILLA META • ${selected.category}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: primaryAqua,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            selected.renderPreview(
                              header: _headerControllers.map((c) => c.text).toList(),
                              body: _bodyControllers.map((c) => c.text).toList(),
                            ),
                            style: const TextStyle(
                              fontSize: 13.5,
                              height: 1.4,
                              color: white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

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
                            Icons.info_outline_rounded,
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

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed:
                      _isSending ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancelar', style: TextStyle(color: lightText)),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: (_isSending ||
                          _isLoading ||
                          selected == null ||
                          selected.unsupportedReason != null)
                      ? null
                      : _sendSelectedTemplate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAqua,
                    foregroundColor: darkBg,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: _isSending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: darkBg,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 17),
                  label: Text(
                    _isSending
                        ? 'Enviando plantilla...'
                        : 'Enviar ${selected?.name ?? 'plantilla'}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool get _isloadingOrSending => _isLoading || _isSending;

  Widget _variableField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: white, fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: lightText),
          filled: true,
          fillColor: darkBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
