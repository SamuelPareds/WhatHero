import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crm_whatsapp/core.dart';

import 'template_text.dart';
import 'templates_api.dart';

const _errorRed = Color(0xFFF87171);

class _ButtonDraft {
  /// `QUICK_REPLY`, `URL` o `PHONE_NUMBER`.
  final String type;
  final TextEditingController text = TextEditingController();

  /// El enlace o el teléfono; sin uso en una respuesta rápida.
  final TextEditingController value = TextEditingController();

  _ButtonDraft(this.type);

  void dispose() {
    text.dispose();
    value.dispose();
  }
}

/// Crea una plantilla y la manda a revisión de Meta. Devuelve la
/// [CreatedTemplate] al salir si se envió.
///
/// No valida las reglas de Meta: eso lo hace el backend (`metaTemplates.ts`) y
/// devuelve todos los problemas juntos. Acá sólo se limitan los largos y se
/// piden los ejemplos de cada variable.
class TemplateEditorScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String defaultLanguage;

  /// `nombre|idioma` de las plantillas que ya existen, para avisar antes de
  /// chocar con Meta.
  final Set<String> existingKeys;

  const TemplateEditorScreen({
    required this.accountId,
    required this.sessionId,
    required this.defaultLanguage,
    this.existingKeys = const {},
    super.key,
  });

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  final _name = TextEditingController();
  final _header = TextEditingController();
  final _body = TextEditingController();
  final _footer = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, TextEditingController> _examples = {};
  final List<_ButtonDraft> _buttons = [];
  late String _language = widget.defaultLanguage;
  String? _category;
  bool _submitting = false;
  bool _submitted = false;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _header, _body, _footer]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _header, _body, _footer, ..._examples.values]) {
      c.dispose();
    }
    for (final b in _buttons) {
      b.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _dirty =>
      [_name, _header, _body, _footer].any((c) => c.text.trim().isNotEmpty) || _buttons.isNotEmpty;

  /// Variables del encabezado y del cuerpo, en orden y sin repetir.
  List<String> get _variables => {...draftVariables(_header.text), ...draftVariables(_body.text)}.toList();

  // Se conservan aunque la variable desaparezca: borrarla y volver a
  // escribirla no pierde el ejemplo.
  TextEditingController _exampleFor(String variable) =>
      _examples.putIfAbsent(variable, () => TextEditingController()..addListener(_changed));

  void _insertVariable(String variable) {
    final token = '{{$variable}}';
    final text = _body.text;
    final sel = _body.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _body.value = TextEditingValue(
      text: text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  Future<void> _askVariable() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('Nueva variable', style: TextStyle(color: white, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: white),
          decoration: const InputDecoration(
            hintText: 'Ej: fecha de la cita',
            hintStyle: TextStyle(color: lightText),
            helperText: 'Un dato que cambia en cada cliente',
            helperStyle: TextStyle(color: lightText),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Insertar', style: TextStyle(color: primaryAqua)),
          ),
        ],
      ),
    );
    controller.dispose();
    final variable = variableNameFromLabel(name ?? '');
    if (variable.isNotEmpty) _insertVariable(variable);
  }

  void _addButton(String type) {
    final b = _ButtonDraft(type);
    b.text.addListener(_changed);
    b.value.addListener(_changed);
    setState(() => _buttons.add(b));
  }

  void _removeButton(_ButtonDraft b) {
    setState(() => _buttons.remove(b));
    b.dispose();
  }

  int _count(String type) => _buttons.where((b) => b.type == type).length;

  Map<String, dynamic> _payload(String name) => {
        'name': name,
        'language': _language,
        'category': _category,
        'headerText': _header.text.trim(),
        'body': _body.text.trim(),
        'footer': _footer.text.trim(),
        'examples': {for (final v in _variables) v: _exampleFor(v).text.trim()},
        'buttons': [
          for (final b in _buttons)
            {
              'type': b.type,
              'text': b.text.text.trim(),
              if (b.type == 'URL') 'url': b.value.text.trim(),
              if (b.type == 'PHONE_NUMBER') 'phoneNumber': b.value.text.trim(),
            },
        ],
      };

  Future<void> _submit() async {
    final name = finalizeTemplateName(_name.text);
    // Lo que se sabe sin preguntarle a nadie; el resto lo decide el backend.
    final local = <String>[
      if (_category == null) 'Elige la categoría: Marketing o Utilidad.',
      if (widget.existingKeys.contains('$name|$_language'))
        'Ya tienes una plantilla "$name" en ese idioma: usa otro nombre.',
    ];
    if (local.isNotEmpty) return _showErrors(local);

    setState(() {
      _submitting = true;
      _errors = const [];
    });
    try {
      final created = await submitMetaTemplate(
        accountId: widget.accountId,
        sessionId: widget.sessionId,
        template: _payload(name),
      );
      if (!mounted) return;
      _submitted = true;
      Navigator.of(context).pop(created);
    } on TemplateApiException catch (e) {
      _showErrors(e.details.isNotEmpty ? e.details : [e.message]);
    } catch (e) {
      _showErrors(['No se pudo enviar: $e']);
    } finally {
      if (mounted && !_submitted) setState(() => _submitting = false);
    }
  }

  void _showErrors(List<String> errors) {
    if (!mounted) return;
    setState(() => _errors = errors);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('¿Descartar la plantilla?', style: TextStyle(color: white, fontSize: 17)),
        content: const Text('Lo que escribiste se pierde.', style: TextStyle(color: lightText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Seguir editando', style: TextStyle(color: primaryAqua)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Descartar', style: TextStyle(color: _errorRed)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty || _submitted,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: darkBg,
        appBar: AppBar(title: const Text('Nueva plantilla')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                if (_errors.isNotEmpty) _errorBox(),
                _note(
                  Icons.schedule_rounded,
                  'Meta revisa cada plantilla antes de que se pueda usar: casi siempre en minutos, '
                  'a veces hasta 24 h. Sólo las aprobadas aparecen al enviar.',
                ),
                const SizedBox(height: 20),
                _label('Nombre'),
                _field(
                  _name,
                  hint: 'Ej: recordatorio_cita',
                  maxLength: 512,
                  formatter: TemplateNameFormatter(),
                  helper: 'Interno: el cliente no lo ve. Minúsculas, números y guion bajo.',
                ),
                const SizedBox(height: 12),
                _label('Categoría'),
                _categoryPicker(),
                const SizedBox(height: 16),
                _label('Idioma'),
                _languagePicker(),
                const SizedBox(height: 20),
                _label('Encabezado (opcional)'),
                _field(_header, hint: 'Ej: Tu cita está confirmada', maxLength: 60),
                const SizedBox(height: 8),
                _label('Mensaje'),
                _field(
                  _body,
                  hint: 'Hola {{nombre}}, te recordamos tu cita del {{fecha}}. ¿Nos confirmas?',
                  maxLength: 1024,
                  maxLines: 8,
                ),
                _variableChips(),
                if (_variables.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _label('Ejemplos para Meta'),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Quien revisa en Meta ve el mensaje con estos valores. Usa datos realistas, no los de un cliente real.',
                      style: TextStyle(color: lightText, fontSize: 12),
                    ),
                  ),
                  for (final v in _variables)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _field(_exampleFor(v), hint: 'Ejemplo de {{$v}}', prefix: '{{$v}}  '),
                    ),
                ],
                const SizedBox(height: 8),
                _label('Pie (opcional)'),
                _field(
                  _footer,
                  hint: _category == 'MARKETING' ? 'Ej: Responde BAJA para no recibir promociones' : 'Ej: Clínica Centro',
                  maxLength: 60,
                ),
                const SizedBox(height: 8),
                _label('Botones (opcional)'),
                _buttonsEditor(),
                const SizedBox(height: 24),
                _label('Vista previa'),
                _preview(),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryAqua,
                foregroundColor: darkBg,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: darkBg),
                    )
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(
                _submitting ? 'Enviando a Meta…' : 'Enviar a revisión',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(color: lightText, fontSize: 13, fontWeight: FontWeight.w600)),
      );

  Widget _note(IconData icon, String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: primaryAqua.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: primaryAqua, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(color: lightText, fontSize: 12.5, height: 1.35))),
          ],
        ),
      );

  Widget _errorBox() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _errorRed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _errorRed.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Corrige esto antes de enviar:',
                style: TextStyle(color: _errorRed, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final e in _errors)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $e', style: const TextStyle(color: _errorRed, fontSize: 12.5, height: 1.35)),
              ),
          ],
        ),
      );

  Widget _field(
    TextEditingController controller, {
    String? hint,
    String? helper,
    String? prefix,
    int? maxLength,
    int maxLines = 1,
    TextInputFormatter? formatter,
  }) {
    return TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      minLines: 1,
      inputFormatters: formatter == null ? null : [formatter],
      style: const TextStyle(color: white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 13.5),
        helperText: helper,
        helperStyle: const TextStyle(color: lightText, fontSize: 11.5),
        helperMaxLines: 2,
        prefixText: prefix,
        prefixStyle: const TextStyle(color: primaryAqua, fontSize: 13, fontWeight: FontWeight.w600),
        counterStyle: const TextStyle(color: lightText, fontSize: 11),
        filled: true,
        fillColor: surfaceDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primaryAqua),
        ),
      ),
    );
  }

  Widget _categoryPicker() {
    Widget option(String value, String title, String subtitle, IconData icon) {
      final selected = _category == value;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _category = value),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected ? primaryAqua.withValues(alpha: 0.14) : surfaceDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? primaryAqua : Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: selected ? primaryAqua : lightText),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: white, fontWeight: FontWeight.w700, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(subtitle, style: const TextStyle(color: lightText, fontSize: 11.5, height: 1.3)),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              option('MARKETING', 'Marketing', 'Promociones, ofertas, reactivar clientes. Se cobra por mensaje entregado.',
                  Icons.campaign_outlined),
              const SizedBox(width: 10),
              option('UTILITY', 'Utilidad', 'Avisos de algo que el cliente ya pidió: cita, pedido, pago, trámite.',
                  Icons.event_available_outlined),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Si el contenido es promocional, Meta la pasa a Marketing aunque elijas Utilidad.',
          style: TextStyle(color: lightText, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _languagePicker() {
    return DropdownButtonFormField<String>(
      initialValue: _language,
      isExpanded: true,
      dropdownColor: surfaceDark,
      style: const TextStyle(color: white, fontSize: 14),
      decoration: InputDecoration(
        filled: true,
        fillColor: surfaceDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      ),
      items: [
        for (final (code, label) in templateLanguages)
          DropdownMenuItem(value: code, child: Text('$label · $code', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => setState(() => _language = v ?? _language),
    );
  }

  Widget _variableChips() {
    Widget chip(String label, VoidCallback onTap) => ActionChip(
          label: Text(label, style: const TextStyle(color: primaryAqua, fontSize: 12)),
          backgroundColor: primaryAqua.withValues(alpha: 0.1),
          side: BorderSide(color: primaryAqua.withValues(alpha: 0.3)),
          onPressed: onTap,
        );
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Insertar:', style: TextStyle(color: lightText, fontSize: 12)),
        chip('{{nombre}}', () => _insertVariable('nombre')),
        chip('+ Otra variable', _askVariable),
      ],
    );
  }

  Widget _buttonsEditor() {
    final total = _buttons.length;
    final canAdd = total < 10;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in _buttons) _buttonRow(b),
        Wrap(
          spacing: 8,
          children: [
            _addButtonChip('Respuesta rápida', Icons.reply_rounded, canAdd && _count('QUICK_REPLY') < 10,
                () => _addButton('QUICK_REPLY')),
            _addButtonChip('Enlace', Icons.open_in_new_rounded, canAdd && _count('URL') < 2, () => _addButton('URL')),
            _addButtonChip('Llamar', Icons.call_outlined, canAdd && _count('PHONE_NUMBER') < 1,
                () => _addButton('PHONE_NUMBER')),
          ],
        ),
      ],
    );
  }

  Widget _addButtonChip(String label, IconData icon, bool enabled, VoidCallback onTap) => ActionChip(
        avatar: Icon(icon, size: 16, color: enabled ? primaryAqua : lightText.withValues(alpha: 0.4)),
        label: Text(label, style: TextStyle(color: enabled ? white : lightText.withValues(alpha: 0.4), fontSize: 12)),
        backgroundColor: surfaceDark,
        onPressed: enabled ? onTap : null,
      );

  Widget _buttonRow(_ButtonDraft b) {
    final (icon, valueHint) = switch (b.type) {
      'URL' => (Icons.open_in_new_rounded, 'https://tutienda.com/ofertas'),
      'PHONE_NUMBER' => (Icons.call_outlined, '+52 55 1234 5678'),
      _ => (Icons.reply_rounded, null),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 0),
      decoration: BoxDecoration(
        color: surfaceDark.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 12), child: Icon(icon, color: primaryAqua, size: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                _field(b.text, hint: 'Texto del botón', maxLength: 25),
                if (valueHint != null) _field(b.value, hint: valueHint, maxLength: b.type == 'URL' ? 2000 : 20),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _removeButton(b),
            icon: const Icon(Icons.close_rounded, color: lightText, size: 18),
            tooltip: 'Quitar botón',
          ),
        ],
      ),
    );
  }

  String _fillExamples(String text) {
    var out = text;
    for (final v in _variables) {
      final example = _exampleFor(v).text.trim();
      if (example.isNotEmpty) out = out.replaceAll('{{$v}}', example);
    }
    return out;
  }

  Widget _preview() {
    final header = _header.text.trim();
    final body = _body.text.trim();
    final footer = _footer.text.trim();
    // Meta las muestra como en el payload: respuestas rápidas primero.
    final ordered = [
      ..._buttons.where((b) => b.type == 'QUICK_REPLY'),
      ..._buttons.where((b) => b.type != 'QUICK_REPLY'),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primaryAqua.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primaryAqua.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header.isNotEmpty) ...[
            Text(_fillExamples(header), style: const TextStyle(color: white, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 6),
          ],
          Text(
            body.isEmpty ? 'Escribe el mensaje para verlo aquí.' : _fillExamples(body),
            style: TextStyle(color: body.isEmpty ? lightText : white, fontSize: 13.5, height: 1.4),
          ),
          if (footer.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(footer, style: const TextStyle(color: lightText, fontSize: 11.5)),
          ],
          if (ordered.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.12)),
            for (final b in ordered)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: Text(
                    b.text.text.trim().isEmpty ? '(botón sin texto)' : b.text.text.trim(),
                    style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
