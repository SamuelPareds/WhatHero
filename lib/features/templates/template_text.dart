import 'package:flutter/services.dart';

import 'package:crm_whatsapp/core/utils/phone_input.dart';

// Lo que escribe el operador en el editor, llevado a lo que Meta acepta. Las
// REGLAS (largos, variables al inicio o al final, botones) viven en el backend,
// `metaTemplates.ts`, que es quien decide. Acá sólo se da forma a la entrada y
// se detectan las variables para pedir sus ejemplos.

final _draftVariable = RegExp(r'\{\{([a-z][a-z_]*)\}\}');

/// Variables `{{nombre}}` de un texto, en orden y sin repetir. Misma regla que
/// `extractDraftVariables` del backend.
List<String> draftVariables(String text) {
  final seen = <String>{};
  return [
    for (final m in _draftVariable.allMatches(text))
      if (seen.add(m.group(1)!)) m.group(1)!,
  ];
}

const _accents = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ñ': 'n', 'ç': 'c',
};
final _nameChar = RegExp(r'[a-z0-9_]');

/// Minúsculas, sin acentos, espacios y guiones a `_`, sin lo que Meta no
/// acepta. Carácter por carácter: el largo de un prefijo transformado es la
/// nueva posición del cursor.
String normalizeTemplateNameChars(String input) {
  final out = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    var ch = String.fromCharCode(rune);
    ch = _accents[ch] ?? ch;
    if (ch == ' ' || ch == '-') ch = '_';
    if (_nameChar.hasMatch(ch)) out.write(ch);
  }
  return out.toString();
}

/// El nombre que se manda: además sin `__` ni `_` en las puntas.
/// "Promo Buen Fin 2026" → `promo_buen_fin_2026`.
String finalizeTemplateName(String input) => normalizeTemplateNameChars(input)
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

/// Nombre de variable a partir de lo que escribe el operador: sólo letras y
/// `_`, empezando con letra. "Fecha de la cita" → `fecha_de_la_cita`.
String variableNameFromLabel(String input) => finalizeTemplateName(input)
    .replaceAll(RegExp(r'[0-9]'), '')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// Aplica [normalizeTemplateNameChars] mientras se escribe, sin mover el cursor.
class TemplateNameFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = normalizeTemplateNameChars(newValue.text);
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    final cursor = normalizeTemplateNameChars(newValue.text.substring(0, end)).length;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
  }
}

/// Idiomas que ofrece el editor. Meta acepta más; éstos cubren a los clientes
/// de hoy. Una plantilla se envía en el idioma con el que se aprobó.
const templateLanguages = <(String, String)>[
  ('es_MX', 'Español (México)'),
  ('es', 'Español'),
  ('es_AR', 'Español (Argentina)'),
  ('es_ES', 'Español (España)'),
  ('en_US', 'Inglés (EE. UU.)'),
  ('en', 'Inglés'),
  ('pt_BR', 'Portugués (Brasil)'),
];

/// El idioma con el que abre el editor, según el país del número de la sesión.
String defaultTemplateLanguage(String sessionPhone) =>
    switch (countryForE164(sessionPhone)?.iso2) {
      'MX' => 'es_MX',
      'AR' => 'es_AR',
      'ES' => 'es_ES',
      'BR' => 'pt_BR',
      _ => 'es',
    };
