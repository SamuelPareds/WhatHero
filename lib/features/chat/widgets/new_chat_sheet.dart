import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';

/// Lo que devuelve el sheet cuando el número quedó verificado.
///
/// [chatId] es el id CANÓNICO que resolvió el backend contra WhatsApp, no el
/// que tecleó el operador: es el mismo bajo el que `saveMessageToFirestore`
/// guardará el eco del saliente, así que la pantalla y Firestore no se pueden
/// desincronizar.
class NewChatTarget {
  final String chatId;
  final String? contactName;

  /// Ya existía conversación con este número (el operador tecleó a alguien que
  /// ya le había escrito). Vale la pena decírselo para que no se sorprenda de
  /// encontrar historial.
  final bool hasHistory;

  const NewChatTarget({
    required this.chatId,
    this.contactName,
    required this.hasHistory,
  });
}

/// Panel "Nuevo chat": elegir país, escribir el número nacional y verificar
/// que exista en WhatsApp antes de abrir la conversación.
///
/// Deliberadamente NO envía nada: abre el chat vacío y el operador escribe con
/// el composer de siempre, con adjuntos, respuestas rápidas e IA incluidas.
class NewChatSheet extends StatefulWidget {
  final String accountId;

  /// Número de la propia sesión de WhatsApp. De aquí sale el país por defecto:
  /// un cliente mexicano abre el panel ya en 🇲🇽 y uno colombiano en 🇨🇴.
  final String sessionId;
  final String? sessionKey;

  const NewChatSheet({
    required this.accountId,
    required this.sessionId,
    required this.sessionKey,
    super.key,
  });

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  late Country _country;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Qué prefijo le quitamos a lo último que escribió/pegó el operador. Es el
  /// aviso que enseña el formato al que ya sabe de códigos, sin sermón.
  String? _stripNotice;

  /// Evita que la reescritura del campo se procese como si fuera tecleo del
  /// usuario (y borre el aviso que acabamos de poner).
  bool _rewriting = false;

  bool _resolving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _country = countryForE164(widget.sessionId) ?? kFallbackCountry;
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_rewriting) return;
    final parsed = normalizeTyped(_controller.text, _country);

    // El campo siempre guarda dígitos pelados del número NACIONAL: si vino con
    // código de país, símbolos o cero de marcado, lo reescribimos aquí. Esto
    // es el "mucho mejor que nosotros lo quitemos".
    if (_controller.text != parsed.national) {
      _rewriting = true;
      _controller.value = TextEditingValue(
        text: parsed.national,
        selection: TextSelection.collapsed(offset: parsed.national.length),
      );
      _rewriting = false;
    }

    setState(() {
      _country = parsed.country;
      _stripNotice = parsed.stripped;
      _error = null;
    });
  }

  PhoneInput get _current => PhoneInput(_country, _controller.text);

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<Country>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CountryPicker(selected: _country),
    );
    if (picked != null && mounted) {
      setState(() {
        _country = picked;
        _stripNotice = null;
        _error = null;
      });
      _focusNode.requestFocus();
    }
  }

  Future<void> _resolveAndOpen() async {
    final input = _current;
    if (!input.isComplete || _resolving) return;

    setState(() {
      _resolving = true;
      _error = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/resolve-contact'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'sessionKey': widget.sessionKey,
              'phone': input.e164,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['exists'] == true) {
          Navigator.pop(
            context,
            NewChatTarget(
              chatId: body['chatId'] as String,
              contactName: body['contactName'] as String?,
              hasHistory: body['hasHistory'] as bool? ?? false,
            ),
          );
          return;
        }
        setState(() => _error =
            'Ese número no tiene WhatsApp. Revisa el código de país y el número.');
        return;
      }

      setState(() => _error = _errorFor(response));
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'No pudimos conectar con el servidor. Intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  String _errorFor(http.Response response) {
    String code = '';
    try {
      code = (jsonDecode(response.body) as Map<String, dynamic>)['error'] as String? ?? '';
    } catch (_) {
      // Cuerpo no-JSON (proxy, 502 de infra): caemos al genérico por status.
    }
    switch (code) {
      case 'session_not_ready':
        return 'La sesión de WhatsApp no está conectada. Revísala en Mis Cuentas.';
      case 'rate_limited':
        return 'Demasiadas consultas seguidas. Espera un minuto antes de seguir.';
      case 'lookup_failed':
        return 'No pudimos verificar el número ahora mismo. Vuelve a intentar.';
      case 'invalid_phone':
        return 'Ese número no tiene un largo válido.';
      default:
        return 'No pudimos verificar el número (error ${response.statusCode}).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = _current;
    final lengthHint = _country.minLen == _country.maxLen
        ? '${_country.minLen} dígitos'
        : '${_country.minLen} a ${_country.maxLen} dígitos';

    return Padding(
      // El teclado no puede tapar el botón de acción.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: darkBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _grabHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: lightText),
                    tooltip: 'Cerrar',
                  ),
                  const Expanded(
                    child: Text(
                      'Nuevo chat',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48), // equilibra la ✕ para centrar
                ],
              ),
            ),
            Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Escribe a un número que todavía no te ha escrito.',
                    style: TextStyle(color: lightText, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _countryButton(),
                      const SizedBox(width: 10),
                      Expanded(child: _numberField(lengthHint)),
                    ],
                  ),
                  _notice(),
                  _preview(input),
                  if (_error != null) _errorBox(_error!),
                  const SizedBox(height: 20),
                  _primaryButton(input),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grabHandle() => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 2),
          decoration: BoxDecoration(
            color: lightText.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  // Bandera + código SIEMPRE juntos: en plataformas donde el emoji de bandera
  // no renderiza (Windows) el `+52` sigue diciendo todo lo que hay que saber.
  Widget _countryButton() => Material(
        color: surfaceDark,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _resolving ? null : _pickCountry,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_country.flag, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 6),
                Text(
                  '+${_country.dial}',
                  style: const TextStyle(
                    color: white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, color: lightText, size: 20),
              ],
            ),
          ),
        ),
      );

  Widget _numberField(String lengthHint) => TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        enabled: !_resolving,
        keyboardType: TextInputType.phone,
        // Sólo dígitos y los símbolos que trae un número pegado ('+52 55…').
        // `normalizeTyped` se encarga del resto; este filtro sólo evita letras.
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s()\-.]'))],
        style: const TextStyle(color: white, fontSize: 16, letterSpacing: 0.5),
        onSubmitted: (_) => _resolveAndOpen(),
        decoration: InputDecoration(
          hintText: 'Número ($lengthHint)',
          hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
          filled: true,
          fillColor: surfaceDark,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      );

  Widget _notice() {
    if (_stripNotice == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 14, color: accentAqua),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _stripNotice == '0'
                  ? 'Quitamos el 0 inicial: no va en el formato internacional.'
                  : 'Quitamos el $_stripNotice que ya venía incluido.',
              style: const TextStyle(color: accentAqua, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview(PhoneInput input) {
    if (input.national.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        'Se abrirá el chat con ${formatE164(input.country, input.national)}',
        style: const TextStyle(color: lightText, fontSize: 13),
      ),
    );
  }

  Widget _errorBox(String message) => Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 16, color: Color(0xFFEF4444)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
              ),
            ),
          ],
        ),
      );

  Widget _primaryButton(PhoneInput input) {
    final enabled = input.isComplete && !_resolving;
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: enabled ? _resolveAndOpen : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryAqua,
          disabledBackgroundColor: surfaceDark,
          foregroundColor: darkBg,
          disabledForegroundColor: lightText.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _resolving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(darkBg),
                ),
              )
            : const Text(
                'Abrir chat',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
      ),
    );
  }
}

/// Selector de país con buscador. Los mercados del producto salen primero en
/// el catálogo, así que sin escribir nada ya se ven arriba.
class _CountryPicker extends StatefulWidget {
  final Country selected;
  const _CountryPicker({required this.selected});

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final digits = query.replaceAll(RegExp(r'\D'), '');
    final results = kCountries.where((c) {
      if (query.isEmpty) return true;
      return c.name.toLowerCase().contains(query) ||
          c.iso2.toLowerCase().contains(query) ||
          (digits.isNotEmpty && c.dial.startsWith(digits));
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: const BoxDecoration(
        color: darkBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: lightText),
                  tooltip: 'Cerrar',
                ),
                const Expanded(
                  child: Text(
                    'País',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: white,
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              autofocus: true,
              style: const TextStyle(color: white),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Buscar país o código',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                prefixIcon: const Icon(Icons.search, color: lightText, size: 20),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text(
                      'Sin resultados',
                      style: TextStyle(color: lightText),
                    ),
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, i) {
                      final c = results[i];
                      final isSelected = c.iso2 == widget.selected.iso2;
                      return ListTile(
                        leading: Text(c.flag, style: const TextStyle(fontSize: 24)),
                        title: Text(
                          c.name,
                          style: TextStyle(
                            color: isSelected ? primaryAqua : white,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        trailing: Text(
                          '+${c.dial}',
                          style: TextStyle(
                            color: isSelected ? primaryAqua : lightText,
                            fontSize: 15,
                          ),
                        ),
                        onTap: () => Navigator.pop(context, c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
