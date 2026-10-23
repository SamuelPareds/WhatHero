import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/templates/meta_template.dart';

MetaTemplateModel tpl({
  String category = 'UTILITY',
  String? parameterFormat,
  List<Map<String, dynamic>> components = const [],
}) =>
    MetaTemplateModel.fromJson({
      'id': '1',
      'name': 'aviso',
      'status': 'APPROVED',
      'category': category,
      'language': 'es_MX',
      'parameter_format': ?parameterFormat,
      'components': components,
    });

void main() {
  group('variables', () {
    test('numeradas: {{1}}..{{n}} en orden y sin parameter_name', () {
      final t = tpl(components: [
        {'type': 'BODY', 'text': 'Hola {{1}}, tu pedido {{2}} salió.'},
      ]);
      expect(t.isNamed, isFalse);
      expect(t.bodyParams.map((p) => p.key), ['1', '2']);
      expect(t.buildComponents(body: ['Ana', 'A-77']), [
        {
          'type': 'body',
          'parameters': [
            {'type': 'text', 'text': 'Ana'},
            {'type': 'text', 'text': 'A-77'},
          ],
        },
      ]);
    });

    // El bug que esto cierra: el selector sólo contaba {{1}}, veía 0 variables
    // en una plantilla con nombre y Meta rechazaba el envío.
    test('con nombre: se detectan y viajan con parameter_name', () {
      final t = tpl(parameterFormat: 'NAMED', components: [
        {'type': 'HEADER', 'format': 'TEXT', 'text': 'Hola {{nombre}}'},
        {'type': 'BODY', 'text': 'Tu cita es el {{fecha}} a las {{hora}}, {{nombre}}.'},
      ]);
      expect(t.headerParams.map((p) => p.placeholder), ['{{nombre}}']);
      expect(t.bodyParams.map((p) => p.key), ['fecha', 'hora', 'nombre']);
      final body = t.buildComponents(header: ['Ana'], body: ['lunes', '10:00', 'Ana'])[1];
      expect(body['parameters'][0], {'type': 'text', 'parameter_name': 'fecha', 'text': 'lunes'});
    });

    test('sin parameter_format se deduce del texto', () {
      final t = tpl(components: [
        {'type': 'BODY', 'text': 'Hola {{nombre}}, gracias.'},
      ]);
      expect(t.isNamed, isTrue);
    });

    test('botón de enlace con variable pide el final de la URL con su índice', () {
      final t = tpl(components: [
        {'type': 'BODY', 'text': 'Tu pedido salió.'},
        {
          'type': 'BUTTONS',
          'buttons': [
            {'type': 'QUICK_REPLY', 'text': 'Gracias'},
            {'type': 'URL', 'text': 'Rastrear', 'url': 'https://t.com/p/{{1}}'},
          ],
        },
      ]);
      expect(t.buttonParams.single.index, 1);
      expect(t.buildComponents(buttons: ['A-77']), [
        {
          'type': 'button',
          'sub_type': 'url',
          'index': '1',
          'parameters': [
            {'type': 'text', 'text': 'A-77'},
          ],
        },
      ]);
    });

    test('la vista previa llena lo que hay y deja visible lo que falta', () {
      final t = tpl(parameterFormat: 'NAMED', components: [
        {'type': 'BODY', 'text': 'Hola {{nombre}}, tu cita es el {{fecha}}.'},
        {'type': 'FOOTER', 'text': 'Clínica Centro'},
      ]);
      expect(
        t.renderPreview(body: ['Ana', '']),
        'Hola Ana, tu cita es el {{fecha}}.\n\nClínica Centro',
      );
    });
  });

  group('lo que WhatHero no puede enviar se dice antes', () {
    test('texto, respuestas rápidas, enlace y llamada: se puede', () {
      final t = tpl(components: [
        {'type': 'HEADER', 'format': 'TEXT', 'text': 'Hola'},
        {'type': 'BODY', 'text': 'Mensaje'},
        {
          'type': 'BUTTONS',
          'buttons': [
            {'type': 'QUICK_REPLY', 'text': 'Sí'},
            {'type': 'URL', 'text': 'Ver', 'url': 'https://t.com'},
            {'type': 'PHONE_NUMBER', 'text': 'Llamar', 'phone_number': '+5215512345678'},
          ],
        },
      ]);
      expect(t.unsupportedReason, isNull);
    });

    test('imagen en el encabezado, botón de código, carrusel y autenticación: no', () {
      expect(
        tpl(components: [
          {'type': 'HEADER', 'format': 'IMAGE'},
          {'type': 'BODY', 'text': 'x'},
        ]).unsupportedReason,
        contains('una imagen'),
      );
      expect(
        tpl(components: [
          {'type': 'BODY', 'text': 'x'},
          {
            'type': 'BUTTONS',
            'buttons': [
              {'type': 'COPY_CODE', 'example': 'X'},
            ],
          },
        ]).unsupportedReason,
        contains('COPY_CODE'),
      );
      expect(
        tpl(components: [
          {'type': 'CAROUSEL', 'cards': []},
        ]).unsupportedReason,
        contains('CAROUSEL'),
      );
      expect(tpl(category: 'AUTHENTICATION').unsupportedReason, contains('autenticación'));
    });
  });

  test('motivo de rechazo en palabras del operador', () {
    expect(describeRejectedReason('NONE'), isNull);
    expect(describeRejectedReason(null), isNull);
    expect(describeRejectedReason('INVALID_FORMAT'), contains('variables'));
    expect(describeRejectedReason('ALGO_NUEVO'), contains('ALGO_NUEVO'));
  });
}
