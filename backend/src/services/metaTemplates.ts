/**
 * Plantillas propias de Meta: qué se valida ANTES de mandarlas a revisión y cómo
 * se arma lo que recibe Meta. Puro (sin red ni Firestore) para poder testearlo.
 * Ver CLAUDE.md, "📝 Plantillas propias".
 *
 * Las reglas copian las que Meta rechaza por formato. Una plantilla rechazada
 * cuesta una ida y vuelta de revisión y, si el nombre ya estaba aprobado en otro
 * idioma, confunde al operador: preferimos decirle qué corregir antes de enviar.
 * Lo que es criterio de Meta (contenido, categoría) no se intenta adivinar.
 */

export type TemplateCategory = 'MARKETING' | 'UTILITY';

export type TemplateButtonDraft =
  | { type: 'QUICK_REPLY'; text: string }
  | { type: 'URL'; text: string; url: string }
  | { type: 'PHONE_NUMBER'; text: string; phoneNumber: string };

export interface TemplateDraft {
  name: string;
  language: string;
  category: TemplateCategory;
  headerText?: string;
  body: string;
  footer?: string;
  /** Ejemplo por variable (`nombre` → `Ana`). Meta lo exige para revisar. */
  examples: Record<string, string>;
  buttons: TemplateButtonDraft[];
}

export interface DraftError {
  /** `name`, `body`, `example.nombre`, `buttons.2`… para que la app lo ubique. */
  field: string;
  message: string;
}

// Límites de Meta (developers.facebook.com → Templates → Components).
export const TEMPLATE_LIMITS = {
  name: 512,
  header: 60,
  body: 1024,
  footer: 60,
  buttonText: 25,
  url: 2000,
  buttons: 10,
  quickReplies: 10,
  urlButtons: 2,
  phoneButtons: 1,
} as const;

const NAME_RE = /^[a-z0-9_]+$/;
const LANGUAGE_RE = /^[a-z]{2,3}(_[A-Z]{2})?$/;
const VAR_TOKEN_RE = /\{\{([^{}]*)\}\}/g;
// Meta: "lowercase characters and underscores". Exigimos que empiece con letra.
const VAR_NAME_RE = /^[a-z][a-z_]*$/;
const EMOJI_RE = /\p{Extended_Pictographic}/u;
// Lo mismo que Meta rechaza en el valor de una variable al ENVIAR.
const BAD_PARAM_WHITESPACE_RE = /[\n\r\t]| {4,}/;

function str(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/**
 * Las variables `{{nombre}}` de un texto, en orden y sin repetir. Lo que parece
 * variable pero no lo es (`{{1}}`, `{{Nombre}}`, llaves sueltas) va a `errors`.
 */
export function extractDraftVariables(
  text: string,
  field: string,
): { names: string[]; duplicates: string[]; errors: DraftError[] } {
  const names: string[] = [];
  const duplicates: string[] = [];
  const errors: DraftError[] = [];

  for (const match of text.matchAll(VAR_TOKEN_RE)) {
    const inner = match[1];
    if (!VAR_NAME_RE.test(inner)) {
      errors.push({
        field,
        message: /^\s*\d+\s*$/.test(inner)
          ? `{{${inner}}}: usa variables con nombre, como {{nombre}} o {{fecha}}.`
          : `{{${inner}}} no es una variable válida: sólo minúsculas y guion bajo, como {{fecha_cita}}.`,
      });
      continue;
    }
    if (names.includes(inner)) {
      if (!duplicates.includes(inner)) duplicates.push(inner);
    } else {
      names.push(inner);
    }
  }

  if (/[{}]/.test(text.replace(VAR_TOKEN_RE, ''))) {
    errors.push({ field, message: 'Hay llaves sueltas: una variable se escribe con dos llaves, como {{nombre}}.' });
  }
  return { names, duplicates, errors };
}

function validateButtons(raw: unknown, errors: DraftError[]): TemplateButtonDraft[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) {
    errors.push({ field: 'buttons', message: 'Botones inválidos.' });
    return [];
  }
  if (raw.length > TEMPLATE_LIMITS.buttons) {
    errors.push({ field: 'buttons', message: `Máximo ${TEMPLATE_LIMITS.buttons} botones.` });
  }

  const buttons: TemplateButtonDraft[] = [];
  const seenTexts = new Set<string>();
  const counts = { QUICK_REPLY: 0, URL: 0, PHONE_NUMBER: 0 };

  raw.forEach((b: any, i: number) => {
    const field = `buttons.${i}`;
    const text = str(b?.text).trim();
    if (!text) {
      errors.push({ field, message: `El botón ${i + 1} no tiene texto.` });
    } else if (text.length > TEMPLATE_LIMITS.buttonText) {
      errors.push({ field, message: `El texto del botón "${text}" pasa de ${TEMPLATE_LIMITS.buttonText} caracteres.` });
    } else if (/[\n\r]|\{\{|\}\}/.test(text)) {
      errors.push({ field, message: `El texto del botón "${text}" no puede llevar saltos de línea ni variables.` });
    }
    const key = text.toLowerCase();
    if (text && seenTexts.has(key)) {
      errors.push({ field, message: `Hay dos botones que dicen "${text}".` });
    }
    seenTexts.add(key);

    switch (b?.type) {
      case 'QUICK_REPLY':
        counts.QUICK_REPLY++;
        buttons.push({ type: 'QUICK_REPLY', text });
        break;
      case 'URL': {
        counts.URL++;
        const url = str(b?.url).trim();
        let valid = false;
        try {
          const parsed = new URL(url);
          valid = parsed.protocol === 'https:' || parsed.protocol === 'http:';
        } catch {
          valid = false;
        }
        if (/\{\{|\}\}/.test(url)) {
          errors.push({ field, message: 'Por ahora el enlace de un botón es fijo: sin variables.' });
        } else if (!valid) {
          errors.push({ field, message: `El enlace del botón "${text}" no es válido: escríbelo completo, con https://.` });
        } else if (url.length > TEMPLATE_LIMITS.url) {
          errors.push({ field, message: `El enlace pasa de ${TEMPLATE_LIMITS.url} caracteres.` });
        }
        buttons.push({ type: 'URL', text, url });
        break;
      }
      case 'PHONE_NUMBER': {
        counts.PHONE_NUMBER++;
        const digits = str(b?.phoneNumber).replace(/\D/g, '');
        // E.164: hasta 15 dígitos con el código de país.
        if (digits.length < 8 || digits.length > 15) {
          errors.push({ field, message: 'Escribe el teléfono del botón con código de país, como +52 55 1234 5678.' });
        }
        buttons.push({ type: 'PHONE_NUMBER', text, phoneNumber: `+${digits}` });
        break;
      }
      default:
        errors.push({ field, message: `Tipo de botón no soportado: ${String(b?.type)}.` });
    }
  });

  if (counts.QUICK_REPLY > TEMPLATE_LIMITS.quickReplies) {
    errors.push({ field: 'buttons', message: `Máximo ${TEMPLATE_LIMITS.quickReplies} respuestas rápidas.` });
  }
  if (counts.URL > TEMPLATE_LIMITS.urlButtons) {
    errors.push({ field: 'buttons', message: `Máximo ${TEMPLATE_LIMITS.urlButtons} botones de enlace.` });
  }
  if (counts.PHONE_NUMBER > TEMPLATE_LIMITS.phoneButtons) {
    errors.push({ field: 'buttons', message: 'Sólo puede haber un botón de llamada.' });
  }
  return buttons;
}

/**
 * Valida lo que manda la app (no confiable) y devuelve la plantilla limpia, o
 * todos los errores juntos: el operador corrige todo de una vez, no uno por
 * envío.
 */
export function validateTemplateDraft(raw: unknown): { draft?: TemplateDraft; errors: DraftError[] } {
  const input: any = raw && typeof raw === 'object' ? raw : {};
  const errors: DraftError[] = [];

  const name = str(input.name).trim();
  if (!name) {
    errors.push({ field: 'name', message: 'Ponle un nombre a la plantilla.' });
  } else if (!NAME_RE.test(name)) {
    errors.push({ field: 'name', message: 'El nombre sólo puede tener minúsculas, números y guion bajo, como promo_buen_fin.' });
  } else if (name.length > TEMPLATE_LIMITS.name) {
    errors.push({ field: 'name', message: `El nombre pasa de ${TEMPLATE_LIMITS.name} caracteres.` });
  }

  const language = str(input.language).trim();
  if (!LANGUAGE_RE.test(language)) {
    errors.push({ field: 'language', message: 'Elige el idioma de la plantilla.' });
  }

  const category = input.category;
  if (category !== 'MARKETING' && category !== 'UTILITY') {
    errors.push({
      field: 'category',
      message: category === 'AUTHENTICATION'
        ? 'Las plantillas de autenticación (códigos de un solo uso) no se crean desde WhatHero.'
        : 'Elige la categoría: Marketing o Utilidad.',
    });
  }

  // Encabezado: opcional, de texto, con una variable como máximo.
  const headerText = str(input.headerText).trim();
  let headerVars: string[] = [];
  if (headerText) {
    const extracted = extractDraftVariables(headerText, 'headerText');
    errors.push(...extracted.errors);
    headerVars = extracted.names;
    const plain = headerText.replace(VAR_TOKEN_RE, '');
    if (headerText.length > TEMPLATE_LIMITS.header) {
      errors.push({ field: 'headerText', message: `El encabezado pasa de ${TEMPLATE_LIMITS.header} caracteres.` });
    }
    if (headerVars.length + extracted.duplicates.length > 1) {
      errors.push({ field: 'headerText', message: 'El encabezado admite una sola variable.' });
    }
    if (/[\n\r]/.test(headerText)) {
      errors.push({ field: 'headerText', message: 'El encabezado va en una sola línea.' });
    }
    if (EMOJI_RE.test(plain) || /[*_~`]/.test(plain)) {
      errors.push({ field: 'headerText', message: 'El encabezado no admite emojis ni formato (*, _, ~).' });
    }
  }

  // Cuerpo: obligatorio. Meta rechaza (#2388299) el que empieza o termina con una variable.
  const body = str(input.body).trim();
  let bodyVars: string[] = [];
  if (!body) {
    errors.push({ field: 'body', message: 'El mensaje no puede ir vacío.' });
  } else {
    const extracted = extractDraftVariables(body, 'body');
    errors.push(...extracted.errors);
    bodyVars = extracted.names;
    if (body.length > TEMPLATE_LIMITS.body) {
      errors.push({ field: 'body', message: `El mensaje pasa de ${TEMPLATE_LIMITS.body} caracteres.` });
    }
    if (extracted.duplicates.length > 0) {
      errors.push({
        field: 'body',
        message: `Usa cada variable una sola vez: ${extracted.duplicates.map((v) => `{{${v}}}`).join(', ')}.`,
      });
    }
    if (/^\{\{[^{}]*\}\}/.test(body)) {
      errors.push({ field: 'body', message: 'Meta no acepta un mensaje que empieza con una variable: agrega texto antes, como "Hola {{nombre}}".' });
    }
    if (/\{\{[^{}]*\}\}$/.test(body)) {
      errors.push({ field: 'body', message: 'Meta no acepta un mensaje que termina con una variable: agrega una frase después.' });
    }
  }

  const footer = str(input.footer).trim();
  if (footer) {
    if (footer.length > TEMPLATE_LIMITS.footer) {
      errors.push({ field: 'footer', message: `El pie pasa de ${TEMPLATE_LIMITS.footer} caracteres.` });
    }
    if (/\{\{|\}\}/.test(footer)) {
      errors.push({ field: 'footer', message: 'El pie no admite variables.' });
    }
    if (/[\n\r]/.test(footer)) {
      errors.push({ field: 'footer', message: 'El pie va en una sola línea.' });
    }
  }

  // Un ejemplo por variable: es lo que ve quien revisa en Meta.
  const rawExamples = input.examples && typeof input.examples === 'object' ? input.examples : {};
  const examples: Record<string, string> = {};
  for (const v of [...headerVars, ...bodyVars]) {
    const example = str(rawExamples[v]).trim();
    if (!example) {
      errors.push({ field: `example.${v}`, message: `Falta el ejemplo de {{${v}}}: Meta lo exige para revisar la plantilla.` });
    } else if (BAD_PARAM_WHITESPACE_RE.test(example)) {
      errors.push({ field: `example.${v}`, message: `El ejemplo de {{${v}}} va en una sola línea, sin tabuladores.` });
    } else {
      examples[v] = example;
    }
  }

  const buttons = validateButtons(input.buttons, errors);

  if (errors.length > 0) return { errors };
  return {
    errors,
    draft: {
      name,
      language,
      category: category as TemplateCategory,
      ...(headerText ? { headerText } : {}),
      body,
      ...(footer ? { footer } : {}),
      examples,
      buttons,
    },
  };
}

function namedExamples(vars: string[], examples: Record<string, string>) {
  return vars.map((v) => ({ param_name: v, example: examples[v] }));
}

/** El cuerpo de `POST /{waba}/message_templates` para una plantilla ya validada. */
export function buildCreateTemplatePayload(draft: TemplateDraft): Record<string, any> {
  const headerVars = draft.headerText ? extractDraftVariables(draft.headerText, 'headerText').names : [];
  const bodyVars = extractDraftVariables(draft.body, 'body').names;
  const components: Record<string, any>[] = [];

  if (draft.headerText) {
    components.push({
      type: 'HEADER',
      format: 'TEXT',
      text: draft.headerText,
      ...(headerVars.length > 0 && {
        example: { header_text_named_params: namedExamples(headerVars, draft.examples) },
      }),
    });
  }
  components.push({
    type: 'BODY',
    text: draft.body,
    ...(bodyVars.length > 0 && {
      example: { body_text_named_params: namedExamples(bodyVars, draft.examples) },
    }),
  });
  if (draft.footer) {
    components.push({ type: 'FOOTER', text: draft.footer });
  }
  if (draft.buttons.length > 0) {
    // Meta exige las respuestas rápidas juntas y separadas de los demás botones
    // (QUICK_REPLY, URL, QUICK_REPLY es un error). Las ordenamos nosotros.
    const quickReplies = draft.buttons.filter((b) => b.type === 'QUICK_REPLY');
    const others = draft.buttons.filter((b) => b.type !== 'QUICK_REPLY');
    components.push({
      type: 'BUTTONS',
      buttons: [...quickReplies, ...others].map((b) => {
        if (b.type === 'URL') return { type: 'URL', text: b.text, url: b.url };
        if (b.type === 'PHONE_NUMBER') return { type: 'PHONE_NUMBER', text: b.text, phone_number: b.phoneNumber };
        return { type: 'QUICK_REPLY', text: b.text };
      }),
    });
  }

  const hasVars = headerVars.length + bodyVars.length > 0;
  return {
    name: draft.name,
    language: draft.language,
    category: draft.category,
    // Sin variables el formato da igual; con ellas, siempre con nombre: es lo
    // que permitirá llenarlas solas desde un disparador ({{nombre}} → contacto).
    ...(hasVars && { parameter_format: 'named' }),
    components,
  };
}

/**
 * Meta rechaza el envío si el valor de una variable trae saltos de línea,
 * tabuladores o 4+ espacios seguidos. Un nombre de contacto raro o un texto
 * pegado no pueden tumbar una plantilla: se colapsan los espacios.
 */
export function sanitizeTemplateParamText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

/** Aplica `sanitizeTemplateParamText` a cada parámetro de texto de un envío. */
export function sanitizeTemplateSendComponents(components: any[]): any[] {
  return components.map((component) => {
    if (!component || !Array.isArray(component.parameters)) return component;
    return {
      ...component,
      parameters: component.parameters.map((p: any) =>
        p && p.type === 'text' && typeof p.text === 'string'
          ? { ...p, text: sanitizeTemplateParamText(p.text) }
          : p,
      ),
    };
  });
}

/**
 * Traduce los errores de Meta al crear o borrar una plantilla. Sólo los códigos
 * verificados; lo demás pasa con el texto de Meta, que suele explicarse solo.
 */
export function describeTemplateApiError(err: { code?: number; subcode?: number; message?: string; details?: string }): string {
  if (err.subcode === 2388299) {
    return 'Meta no acepta un mensaje que empieza o termina con una variable.';
  }
  if (err.subcode === 2388293) {
    return 'Demasiadas variables para lo corto del mensaje: agrega texto o quita variables.';
  }
  // Verificado el 23-oct-2026 con el primer número de producción. Meta separa
  // "Cuentas de WhatsApp" (una por número) de "Cuentas de mensajes" (el WABA,
  // donde viven las plantillas), y la asignación de una no se hereda a la otra.
  // Con el usuario del sistema sólo en la de WhatsApp se envía, se listan y se
  // crean plantillas, pero borrar falla con este #100 sin subcódigo.
  if (err.code === 100 && /need permission/i.test(`${err.details ?? ''} ${err.message ?? ''}`)) {
    return 'El usuario del sistema del Access Token no está asignado a la cuenta de mensajes de esta sesión. En Configuración del negocio › Cuentas › Cuentas de mensajes, abre la del WABA ID de esta sesión › Asignar personas › tu usuario del sistema › Control total. Asignarlo sólo en "Cuentas de WhatsApp" no alcanza.';
  }
  if (err.code === 190) {
    return 'El Access Token de Meta venció o fue revocado (el temporal dura 24 h). Genera uno permanente y actualiza las credenciales de la sesión.';
  }
  // El token lista plantillas pero no puede administrar las de ESTE WABA. Pasó
  // en producción con "Control total" ya asignado: el token guardado no lleva
  // whatsapp_business_management sobre el WABA (generado antes de asignarlo,
  // sin ese permiso, o de otro usuario). Meta no le pone subcódigo: se
  // reconoce por el texto.
  if (err.code === 100 && /need permission/i.test(`${err.details ?? ''} ${err.message ?? ''}`)) {
    return 'El Access Token guardado no puede administrar las plantillas de esta cuenta de WhatsApp. Genera un token nuevo del usuario del sistema (con whatsapp_business_management y la cuenta de WhatsApp con Control total) y pégalo en "Actualizar Access Token".';
  }
  if (err.code === 200 || err.code === 10) {
    return 'El Access Token no tiene permiso para administrar plantillas (whatsapp_business_management). Genera uno con ese permiso y actualiza las credenciales de la sesión.';
  }
  if (err.code === 4 || err.code === 80008) {
    return 'Meta está limitando las solicitudes de esta cuenta. Intenta de nuevo en unos minutos.';
  }
  return err.details || err.message || 'Meta rechazó la solicitud.';
}

// ---------------------------------------------------------------------------
// Enviar una plantilla aprobada armándola en el backend (API pública)
// ---------------------------------------------------------------------------
//
// Port de `MetaTemplateModel` (lib/features/templates/meta_template.dart): quien
// llama por API sólo manda los VALORES de las variables y aquí se arman los
// `components` desde la definición que devuelve Meta. La app todavía arma los
// suyos; cuando migre, tiene que pasar por aquí (ver CLAUDE.md, "🔑 API pública").

/** Lo mínimo de una plantilla de Meta (`GET /{waba}/message_templates`) para enviarla. */
export interface TemplateDefinition {
  name: string;
  status: string;
  category: string;
  language: string;
  parameter_format?: string;
  components: Array<{
    type: string;
    format?: string;
    text?: string;
    buttons?: Array<{ type: string; text?: string; url?: string }>;
  }>;
}

export type TemplateBlockCode = 'template_not_approved' | 'template_paused' | 'template_unsupported';

export interface TemplateBlock {
  code: TemplateBlockCode;
  message: string;
  templateStatus?: string;
}

/** Largo máximo que aceptamos para el valor de una variable. */
export const TEMPLATE_PARAM_MAX = 1024;

// Igual que en la app: tolera espacios dentro de las llaves.
const SEND_PLACEHOLDER_RE = /\{\{\s*([A-Za-z0-9_]+)\s*\}\}/g;

function component(t: TemplateDefinition, type: string) {
  return t.components?.find((c) => String(c?.type).toUpperCase() === type);
}

function headerFormat(t: TemplateDefinition): string | null {
  const header = component(t, 'HEADER');
  if (!header) return null;
  return header.format ? String(header.format).toUpperCase() : header.text != null ? 'TEXT' : null;
}

function headerTextOf(t: TemplateDefinition): string {
  return headerFormat(t) === 'TEXT' ? str(component(t, 'HEADER')?.text) : '';
}

function placeholderKeys(text: string): string[] {
  return [...text.matchAll(SEND_PLACEHOLDER_RE)].map((m) => m[1]);
}

/** Con nombre (`{{nombre}}`) o numeradas (`{{1}}`). Meta lo dice; si no, se deduce. */
function isNamedTemplate(t: TemplateDefinition): boolean {
  if (t.parameter_format) return t.parameter_format.toUpperCase() === 'NAMED';
  return placeholderKeys(`${headerTextOf(t)} ${str(component(t, 'BODY')?.text)}`).some((k) => !/^\d+$/.test(k));
}

/** Las variables de un texto, en el orden en que Meta las pide. */
function sendParams(text: string, named: boolean): string[] {
  const keys = placeholderKeys(text);
  if (keys.length === 0) return [];
  if (!named) {
    // Meta espera {{1}}..{{n}} en orden, aunque el texto las use desordenadas.
    const last = Math.max(0, ...keys.map((k) => Number.parseInt(k, 10) || 0));
    return Array.from({ length: last }, (_, i) => String(i + 1));
  }
  return [...new Set(keys)];
}

/**
 * Por qué no se puede enviar esta plantilla por API, o `null` si se puede. Es
 * lo que la app marca con 🚫, más dos cosas que el API todavía no llena: el
 * final variable de un botón de enlace y una variable numerada en el encabezado
 * (con nombre comparte valores con el cuerpo; numerada chocaría con el `{{1}}`
 * del cuerpo). Las plantillas creadas desde WhatHero no tienen ninguna de las dos.
 */
export function templateSendBlock(t: TemplateDefinition): TemplateBlock | null {
  const status = String(t.status || '').toUpperCase();
  if (status === 'PAUSED') {
    return {
      code: 'template_paused',
      message: 'Meta pausó esta plantilla por su calidad. Revísala en WhatHero antes de seguir enviándola.',
      templateStatus: status,
    };
  }
  if (status !== 'APPROVED') {
    return {
      code: 'template_not_approved',
      message: `La plantilla no está aprobada por Meta (estado: ${status || 'desconocido'}).`,
      templateStatus: status,
    };
  }

  const unsupported = (message: string): TemplateBlock => ({ code: 'template_unsupported', message });
  if (String(t.category).toUpperCase() === 'AUTHENTICATION') {
    return unsupported('Es de autenticación (códigos de un solo uso): el API de WhatHero no la envía.');
  }
  const format = headerFormat(t);
  if (format && format !== 'TEXT') {
    return unsupported(`Lleva ${format.toLowerCase()} en el encabezado: el API todavía no puede enviarla.`);
  }
  for (const c of t.components ?? []) {
    const type = String(c?.type).toUpperCase();
    if (!['HEADER', 'BODY', 'FOOTER', 'BUTTONS'].includes(type)) {
      return unsupported(`Usa un formato (${type}) que el API todavía no puede enviar.`);
    }
  }
  for (const b of component(t, 'BUTTONS')?.buttons ?? []) {
    const type = String(b?.type).toUpperCase();
    if (!['QUICK_REPLY', 'URL', 'PHONE_NUMBER'].includes(type)) {
      return unsupported(`Tiene un botón de tipo ${type}: el API todavía no puede enviarla.`);
    }
    if (type === 'URL' && /\{\{/.test(str(b.url))) {
      return unsupported('Tiene un botón de enlace con final variable: el API todavía no lo llena.');
    }
  }
  if (!isNamedTemplate(t) && sendParams(headerTextOf(t), false).length > 0) {
    return unsupported('Tiene una variable numerada en el encabezado: el API todavía no la llena.');
  }
  return null;
}

export type TemplateSendBuild =
  | { ok: true; components: any[]; renderedText: string }
  | { ok: false; code: 'missing_variables' | 'invalid_variable_value'; variables: string[]; message: string };

/**
 * Los `components` del envío y el texto que queda en la burbuja, a partir de
 * los valores que mandó quien llama (`{ nombre: 'Ana' }` o `{ '1': 'Ana' }`).
 * Una variable con nombre llena el encabezado y el cuerpo por igual. Llama
 * antes a `templateSendBlock`: aquí se asume que la plantilla se puede enviar.
 */
export function buildTemplateSend(t: TemplateDefinition, variables: Record<string, unknown>): TemplateSendBuild {
  const named = isNamedTemplate(t);
  const header = headerTextOf(t);
  const body = str(component(t, 'BODY')?.text);
  const footer = str(component(t, 'FOOTER')?.text);
  const headerParams = sendParams(header, named);
  const bodyParams = sendParams(body, named);

  const missing: string[] = [];
  const invalid: string[] = [];
  const values = new Map<string, string>();
  for (const key of [...new Set([...headerParams, ...bodyParams])]) {
    const raw = variables[key];
    if (raw === undefined || raw === null) {
      missing.push(key);
      continue;
    }
    const value = typeof raw === 'string' || typeof raw === 'number' ? sanitizeTemplateParamText(String(raw)) : '';
    if (!value || value.length > TEMPLATE_PARAM_MAX) invalid.push(key);
    else values.set(key, value);
  }
  if (missing.length > 0) {
    return {
      ok: false,
      code: 'missing_variables',
      variables: missing,
      message: `La plantilla pide ${missing.map((k) => `{{${k}}}`).join(', ')} y no vino en "variables".`,
    };
  }
  if (invalid.length > 0) {
    return {
      ok: false,
      code: 'invalid_variable_value',
      variables: invalid,
      message: `${invalid.map((k) => `{{${k}}}`).join(', ')} viene vacía o pasa de ${TEMPLATE_PARAM_MAX} caracteres.`,
    };
  }

  const param = (key: string) => ({ type: 'text', ...(named && { parameter_name: key }), text: values.get(key)! });
  const components: any[] = [];
  if (headerParams.length > 0) components.push({ type: 'header', parameters: headerParams.map(param) });
  if (bodyParams.length > 0) components.push({ type: 'body', parameters: bodyParams.map(param) });

  // Igual que renderPreview de la app: encabezado, cuerpo y pie con las variables llenas.
  const fill = (text: string) => text.replace(SEND_PLACEHOLDER_RE, (whole, key) => values.get(key) ?? whole);
  const parts = [fill(header.trim()), fill(body.trim()), footer.trim()].filter(Boolean);
  const renderedText = parts.length > 0 ? parts.join('\n\n') : `📋 Plantilla: ${t.name} (${t.language})`;

  return { ok: true, components, renderedText };
}
