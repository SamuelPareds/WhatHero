import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  TemplateDefinition,
  buildCreateTemplatePayload,
  buildTemplateSend,
  describeTemplateApiError,
  extractDraftVariables,
  sanitizeTemplateParamText,
  sanitizeTemplateSendComponents,
  templateSendBlock,
  validateTemplateDraft,
} from './metaTemplates';

function draft(overrides: Record<string, any> = {}) {
  return {
    name: 'recordatorio_cita',
    language: 'es_MX',
    category: 'UTILITY',
    body: 'Hola {{nombre}}, te esperamos el {{fecha}} en la sucursal.',
    examples: { nombre: 'Ana', fecha: 'lunes 3 de noviembre' },
    buttons: [],
    ...overrides,
  };
}

function messages(raw: Record<string, any>): string[] {
  return validateTemplateDraft(draft(raw)).errors.map((e) => e.message);
}

describe('validateTemplateDraft (lo que Meta rechazaría por formato se dice antes)', () => {
  it('una plantilla correcta pasa y sale limpia', () => {
    const { draft: d, errors } = validateTemplateDraft(draft({ name: '  recordatorio_cita ', footer: ' ' }));
    assert.deepEqual(errors, []);
    assert.equal(d?.name, 'recordatorio_cita');
    assert.equal(d?.footer, undefined, 'un pie en blanco no se manda');
  });

  it('nombre: sólo minúsculas, números y guion bajo', () => {
    assert.match(messages({ name: 'Promo Buen-Fin' })[0], /minúsculas, números y guion bajo/);
    assert.match(messages({ name: '' })[0], /Ponle un nombre/);
    assert.deepEqual(messages({ name: 'promo_2026' }), []);
  });

  it('autenticación no se crea desde WhatHero; categoría desconocida tampoco', () => {
    assert.match(messages({ category: 'AUTHENTICATION' })[0], /autenticación/);
    assert.match(messages({ category: 'PROMO' })[0], /Marketing o Utilidad/);
  });

  it('el mensaje no puede empezar ni terminar con una variable (#2388299)', () => {
    assert.match(messages({ body: '{{nombre}}, te esperamos.' })[0], /empieza con una variable/);
    assert.match(messages({ body: 'Te esperamos el {{fecha}}', examples: { fecha: 'lunes' } })[0], /termina con una variable/);
    // Con texto después ya no termina en variable.
    assert.deepEqual(messages({ body: 'Te esperamos el {{fecha}}.', examples: { fecha: 'lunes' } }), []);
  });

  it('variables: con nombre en minúsculas; las numeradas y las mal escritas se explican', () => {
    assert.match(messages({ body: 'Hola {{1}}, ¿cómo estás?' })[0], /variables con nombre/);
    assert.match(messages({ body: 'Hola {{Nombre}}, ¿cómo estás?' })[0], /no es una variable válida/);
    assert.match(messages({ body: 'Hola {nombre}, ¿cómo estás?' })[0], /llaves sueltas/);
  });

  it('cada variable una sola vez y cada una con su ejemplo', () => {
    assert.ok(messages({ body: 'Hola {{nombre}}, sí {{nombre}} tú.', examples: { nombre: 'Ana' } })
      .some((m) => /una sola vez/.test(m)));
    const errs = validateTemplateDraft(draft({ examples: { nombre: 'Ana' } })).errors;
    assert.deepEqual(errs.map((e) => e.field), ['example.fecha']);
    assert.match(messages({ examples: { nombre: 'Ana\nMaría', fecha: 'lunes' } })[0], /una sola línea/);
  });

  it('encabezado: una variable, sin emojis ni formato, 60 caracteres', () => {
    assert.deepEqual(messages({ headerText: 'Tu cita, {{nombre}}' }), []);
    assert.match(messages({ headerText: '{{nombre}} {{fecha}}' })[0], /una sola variable/);
    assert.match(messages({ headerText: 'Tu cita 🗓️' })[0], /emojis/);
    assert.match(messages({ headerText: '*Tu cita*' })[0], /emojis ni formato/);
    assert.match(messages({ headerText: 'x'.repeat(61) })[0], /60 caracteres/);
  });

  it('pie sin variables y largos de Meta', () => {
    assert.match(messages({ footer: 'Gracias {{nombre}}' })[0], /pie no admite variables/);
    assert.match(messages({ body: `Hola {{nombre}} ${'a'.repeat(1024)} {{fecha}}.` })[0], /1024/);
  });

  it('botones: límites por tipo, textos únicos, enlace completo y teléfono con país', () => {
    const qr = (text: string) => ({ type: 'QUICK_REPLY', text });
    assert.match(messages({ buttons: Array.from({ length: 11 }, (_, i) => qr(`op ${i}`)) })[0], /Máximo 10 botones/);
    assert.match(messages({ buttons: [qr('Sí'), qr('sí')] })[0], /dos botones/);
    assert.match(messages({ buttons: [qr('Un texto de más de 25 letras')] })[0], /25 caracteres/);
    assert.match(messages({ buttons: [{ type: 'URL', text: 'Ver', url: 'tienda.com' }] })[0], /https:\/\//);
    assert.match(messages({ buttons: [{ type: 'URL', text: 'Ver', url: 'https://t.com/{{1}}' }] })[0], /fijo/);
    assert.match(messages({ buttons: [{ type: 'PHONE_NUMBER', text: 'Llamar', phoneNumber: '5512345' }] })[0], /código de país/);
    const two = [{ type: 'PHONE_NUMBER', text: 'A', phoneNumber: '+52 55 1234 5678' }, { type: 'PHONE_NUMBER', text: 'B', phoneNumber: '+52 55 1234 5679' }];
    assert.match(messages({ buttons: two })[0], /un botón de llamada/);
  });

  it('junta todos los errores en una sola pasada', () => {
    const { draft: d, errors } = validateTemplateDraft({ name: 'X', language: '', category: '', body: '' });
    assert.equal(d, undefined);
    assert.deepEqual(errors.map((e) => e.field), ['name', 'language', 'category', 'body']);
  });

  it('entrada basura no revienta', () => {
    assert.ok(validateTemplateDraft(null).errors.length > 0);
    assert.ok(validateTemplateDraft({ buttons: 'x', examples: 3 }).errors.length > 0);
  });
});

describe('buildCreateTemplatePayload', () => {
  it('arma componentes con variables con nombre y sus ejemplos', () => {
    const { draft: d } = validateTemplateDraft(draft({
      category: 'MARKETING',
      headerText: 'Hola {{nombre}}',
      body: 'Tu descuento de {{porcentaje}} vence pronto, aprovecha.',
      examples: { nombre: 'Ana', porcentaje: '20%' },
      footer: 'Responde BAJA para no recibir promociones',
    }));
    assert.ok(d);
    assert.deepEqual(buildCreateTemplatePayload(d!), {
      name: 'recordatorio_cita',
      language: 'es_MX',
      category: 'MARKETING',
      parameter_format: 'named',
      components: [
        {
          type: 'HEADER',
          format: 'TEXT',
          text: 'Hola {{nombre}}',
          example: { header_text_named_params: [{ param_name: 'nombre', example: 'Ana' }] },
        },
        {
          type: 'BODY',
          text: 'Tu descuento de {{porcentaje}} vence pronto, aprovecha.',
          example: { body_text_named_params: [{ param_name: 'porcentaje', example: '20%' }] },
        },
        { type: 'FOOTER', text: 'Responde BAJA para no recibir promociones' },
      ],
    });
  });

  it('sin variables no manda parameter_format ni example', () => {
    const { draft: d } = validateTemplateDraft(draft({ body: 'Gracias por tu compra.', examples: {} }));
    const payload = buildCreateTemplatePayload(d!);
    assert.equal(payload.parameter_format, undefined);
    assert.deepEqual(payload.components, [{ type: 'BODY', text: 'Gracias por tu compra.' }]);
  });

  it('agrupa las respuestas rápidas antes que los demás botones (Meta no acepta mezclarlas)', () => {
    const { draft: d } = validateTemplateDraft(draft({
      buttons: [
        { type: 'URL', text: 'Ver tienda', url: 'https://tienda.com' },
        { type: 'QUICK_REPLY', text: 'Sí' },
        { type: 'PHONE_NUMBER', text: 'Llamar', phoneNumber: '+52 (55) 1234-5678' },
        { type: 'QUICK_REPLY', text: 'No' },
      ],
    }));
    const buttons = buildCreateTemplatePayload(d!).components.find((c: any) => c.type === 'BUTTONS').buttons;
    assert.deepEqual(buttons, [
      { type: 'QUICK_REPLY', text: 'Sí' },
      { type: 'QUICK_REPLY', text: 'No' },
      { type: 'URL', text: 'Ver tienda', url: 'https://tienda.com' },
      { type: 'PHONE_NUMBER', text: 'Llamar', phone_number: '+525512345678' },
    ]);
  });
});

describe('variables al enviar', () => {
  it('extractDraftVariables respeta el orden de aparición', () => {
    assert.deepEqual(extractDraftVariables('{{b}} y {{a}} y {{b}}', 'body').names, ['b', 'a']);
  });

  it('saltos de línea, tabuladores y 4+ espacios se colapsan (Meta los rechaza)', () => {
    assert.equal(sanitizeTemplateParamText('  Ana\nMaría\t   López  '), 'Ana María López');
    const components = sanitizeTemplateSendComponents([
      { type: 'body', parameters: [{ type: 'text', parameter_name: 'nombre', text: 'Ana\n\nMaría' }] },
      { type: 'header', parameters: [{ type: 'image', image: { link: 'https://x' } }] },
    ]);
    assert.equal(components[0].parameters[0].text, 'Ana María');
    assert.equal(components[0].parameters[0].parameter_name, 'nombre');
    assert.deepEqual(components[1].parameters[0], { type: 'image', image: { link: 'https://x' } });
  });
});

describe('describeTemplateApiError', () => {
  it('traduce los códigos conocidos y deja pasar el texto de Meta en los demás', () => {
    assert.match(describeTemplateApiError({ code: 100, subcode: 2388299 }), /empieza o termina/);
    assert.match(describeTemplateApiError({ code: 200 }), /whatsapp_business_management/);
    assert.match(describeTemplateApiError({ code: 190 }), /venció/);
    // El token creaba plantillas, pero el usuario del sistema no estaba en la cuenta de mensajes.
    assert.match(
      describeTemplateApiError({ code: 100, details: '(#100) Need permission on either WhatsApp Business Account or owner/shared business.' }),
      /Cuentas de mensajes/,
    );
    assert.equal(describeTemplateApiError({ code: 100, details: 'Ya existe contenido en este idioma' }), 'Ya existe contenido en este idioma');
  });
});

function definition(overrides: Partial<TemplateDefinition> = {}): TemplateDefinition {
  return {
    name: 'seguimiento_onboarding',
    status: 'APPROVED',
    category: 'MARKETING',
    language: 'es_MX',
    parameter_format: 'NAMED',
    components: [
      { type: 'HEADER', format: 'TEXT', text: 'Hola {{nombre}}' },
      { type: 'BODY', text: '{{nombre}}, ayer probaste AgendaCool para {{negocio}}. ¿Qué te faltó?' },
      { type: 'FOOTER', text: 'Responde BAJA para no recibir más' },
      { type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Me interesa' }] },
    ],
    ...overrides,
  };
}

describe('templateSendBlock (qué no se manda por API)', () => {
  it('sólo pasan las aprobadas; pausada y en revisión se distinguen', () => {
    assert.equal(templateSendBlock(definition()), null);
    assert.deepEqual(
      [templateSendBlock(definition({ status: 'PAUSED' }))?.code, templateSendBlock(definition({ status: 'PAUSED' }))?.templateStatus],
      ['template_paused', 'PAUSED'],
    );
    for (const status of ['PENDING', 'REJECTED', 'IN_APPEAL', 'DISABLED']) {
      assert.equal(templateSendBlock(definition({ status }))?.code, 'template_not_approved', status);
    }
  });

  it('lo que el API todavía no llena se dice antes de enviar', () => {
    const blocked = (d: Partial<TemplateDefinition>) => templateSendBlock(definition(d))?.code;
    assert.equal(blocked({ category: 'AUTHENTICATION' }), 'template_unsupported');
    assert.equal(blocked({ components: [{ type: 'HEADER', format: 'IMAGE' }, { type: 'BODY', text: 'Hola' }] }), 'template_unsupported');
    assert.equal(blocked({ components: [{ type: 'BODY', text: 'Hola' }, { type: 'CAROUSEL' }] }), 'template_unsupported');
    assert.equal(
      blocked({ components: [{ type: 'BODY', text: 'Tu pedido' }, { type: 'BUTTONS', buttons: [{ type: 'URL', text: 'Ver', url: 'https://x.com/p/{{1}}' }] }] }),
      'template_unsupported',
    );
    assert.equal(
      blocked({ parameter_format: 'POSITIONAL', components: [{ type: 'HEADER', format: 'TEXT', text: 'Hola {{1}}' }, { type: 'BODY', text: 'Tu cita es el {{1}}.' }] }),
      'template_unsupported',
    );
    // Un enlace fijo, un teléfono y las respuestas rápidas sí se mandan.
    assert.equal(
      blocked({ components: [{ type: 'BODY', text: 'Hola' }, { type: 'BUTTONS', buttons: [
        { type: 'URL', text: 'Ver', url: 'https://x.com' }, { type: 'PHONE_NUMBER', text: 'Llamar' }, { type: 'QUICK_REPLY', text: 'Sí' },
      ] }] }),
      undefined,
    );
  });
});

describe('buildTemplateSend (quien llama manda valores, WhatHero arma el mensaje)', () => {
  it('con nombre: una variable llena encabezado y cuerpo, y la burbuja lleva el texto real', () => {
    const built = buildTemplateSend(definition(), { nombre: 'Ana\nMaría', negocio: 'su estética', sobra: 'se ignora' });
    assert.ok(built.ok);
    assert.deepEqual(built.components, [
      { type: 'header', parameters: [{ type: 'text', parameter_name: 'nombre', text: 'Ana María' }] },
      { type: 'body', parameters: [
        { type: 'text', parameter_name: 'nombre', text: 'Ana María' },
        { type: 'text', parameter_name: 'negocio', text: 'su estética' },
      ] },
    ]);
    assert.equal(
      built.renderedText,
      'Hola Ana María\n\nAna María, ayer probaste AgendaCool para su estética. ¿Qué te faltó?\n\nResponde BAJA para no recibir más',
    );
  });

  it('numeradas: {{1}}..{{n}} en orden aunque el texto las desordene, sin parameter_name', () => {
    const built = buildTemplateSend(
      definition({ parameter_format: undefined, components: [{ type: 'BODY', text: 'El {{2}} te espera {{1}}.' }] }),
      { 1: 'Ana', '2': 'lunes' },
    );
    assert.ok(built.ok);
    assert.deepEqual(built.components, [
      { type: 'body', parameters: [{ type: 'text', text: 'Ana' }, { type: 'text', text: 'lunes' }] },
    ]);
    assert.equal(built.renderedText, 'El lunes te espera Ana.');
  });

  it('sin variables no manda components', () => {
    const built = buildTemplateSend(definition({ components: [{ type: 'BODY', text: 'Gracias por probarnos.' }] }), {});
    assert.ok(built.ok);
    assert.deepEqual(built.components, []);
    assert.equal(built.renderedText, 'Gracias por probarnos.');
  });

  it('una variable que no vino es error de quien llama; un valor vacío es de ese contacto', () => {
    const missing = buildTemplateSend(definition(), { nombre: 'Ana' });
    assert.equal(missing.ok, false);
    assert.equal(!missing.ok && missing.code, 'missing_variables');
    assert.deepEqual(!missing.ok && missing.variables, ['negocio']);

    const empty = buildTemplateSend(definition(), { nombre: '   ', negocio: 'x'.repeat(1025) });
    assert.equal(!empty.ok && empty.code, 'invalid_variable_value');
    assert.deepEqual(!empty.ok && empty.variables, ['nombre', 'negocio']);

    const wrongType = buildTemplateSend(definition(), { nombre: true, negocio: 'x' });
    assert.equal(!wrongType.ok && wrongType.code, 'invalid_variable_value');
  });
});
