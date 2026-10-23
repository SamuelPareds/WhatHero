import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/templates/template_text.dart';

void main() {
  group('nombre de la plantilla', () {
    test('se arma solo desde lo que escribe el operador', () {
      expect(finalizeTemplateName('Promo Buen Fin 2026'), 'promo_buen_fin_2026');
      expect(finalizeTemplateName('  Confirmación de cita!! '), 'confirmacion_de_cita');
      expect(finalizeTemplateName('año--nuevo'), 'ano_nuevo');
    });

    test('mientras se escribe no se comen el espacio final ni mueven el cursor', () {
      final formatter = TemplateNameFormatter();
      final typed = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: 'Promo ', selection: TextSelection.collapsed(offset: 6)),
      );
      expect(typed.text, 'promo_');
      expect(typed.selection.baseOffset, 6);

      // Un carácter inválido en medio: el cursor queda donde estaba el operador.
      final middle = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: 'ab!cd', selection: TextSelection.collapsed(offset: 3)),
      );
      expect(middle.text, 'abcd');
      expect(middle.selection.baseOffset, 2);
    });
  });

  test('variable desde una etiqueta: sólo letras y guion bajo, empieza con letra', () {
    expect(variableNameFromLabel('Fecha de la cita'), 'fecha_de_la_cita');
    expect(variableNameFromLabel('2 Código'), 'codigo');
    expect(variableNameFromLabel('123'), '');
  });

  test('variables del borrador: en orden, sin repetir, sólo las válidas', () {
    expect(draftVariables('Hola {{nombre}}, el {{fecha}}. Gracias {{nombre}}.'), ['nombre', 'fecha']);
    expect(draftVariables('Hola {{1}} y {{Nombre}}'), isEmpty);
  });

  test('el idioma por defecto sale del país de la sesión', () {
    expect(defaultTemplateLanguage('5215512345678'), 'es_MX');
    expect(defaultTemplateLanguage('5491112345678'), 'es_AR');
    expect(defaultTemplateLanguage('5511987654321'), 'pt_BR');
    expect(defaultTemplateLanguage('573001234567'), 'es');
  });
}
