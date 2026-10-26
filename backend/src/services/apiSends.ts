// ============================================
// API pública: enviar una plantilla aprobada desde un sistema externo.
// `POST /api/v1/messages/template` (ver CLAUDE.md, "🔑 API pública").
//
// Es el primer envío automático de WhatHero, y la regla que manda es: NUNCA
// el mismo mensaje dos veces, aunque quien llama reintente o Railway se
// redespliegue a mitad del envío. Por eso cada envío tiene un registro en
// Firestore (`{accounts}/{aid}/api_sends/{sha256(idempotencyKey)}`):
//
//   1. Se LEE antes de validar: un envío que ya salió devuelve lo mismo
//      (`replayed: true`) aunque la plantilla se haya pausado después.
//   2. Se valida todo (plantilla, variables, opt-out) SIN escribir: un rechazo
//      no consume la idempotencyKey, y corregido el problema se puede reenviar.
//   3. Se RECLAMA en una transacción (`sending`) justo antes de llamar a Meta.
//   4. Meta respondió → `sent` (antes de pintar la burbuja) o `failed` (no
//      salió: un reintento con la misma llave sí reenvía). Meta no respondió
//      (timeout, red, proceso muerto) → `in_doubt`: pudo salir, así que NO se
//      reenvía nunca. Es el precio de no duplicar.
//   5. Cada acuse del webhook trae nuestro `biz_opaque_callback_data`: pasa un
//      `sending`/`in_doubt` a `sent` y pinta la burbuja si el proceso murió
//      antes de hacerlo (applyApiSendStatus).
// ============================================
import admin from 'firebase-admin';
import { createHash } from 'crypto';
import { ACCOUNTS_COLLECTION } from '../config/env';
import type { SenderInfo } from '../types';
import { waNumberCandidates } from '../utils/phone';
import { VerifiedApiKey, apiKeyAllowsSession } from './apiKeys';
import {
  ApiSendStatusEvent,
  CloudApiError,
  MetaTemplateSummary,
  getCloudSession,
  isDeliveryStatusAdvance,
  isMarketingOptedOut,
  listMetaTemplates,
  persistOutgoingTemplate,
  postTemplateToMeta,
  resolveCanonicalChatPhone,
} from './cloudApiService';
import { buildTemplateSend, templateSendBlock } from './metaTemplates';
import { PublicApiError, mapMetaSendError } from './publicApiErrors';
import { isSessionGone } from './sessionSupervisor';

// Un `sending` más viejo que esto ya no está en vuelo: el proceso murió (o
// Firestore se colgó) a mitad del envío. Meta se corta a los 30 s.
export const IN_FLIGHT_WINDOW_MS = 2 * 60_000;
const META_SEND_TIMEOUT_MS = 30_000;
const TEMPLATE_CACHE_TTL_MS = 5 * 60_000;
const CALLBACK_PREFIX = 'whathero_api:';
const IDEMPOTENCY_KEY_MAX = 200;
const CONTACT_NAME_MAX = 100;
// Errores de Meta que dicen que la definición en cache ya no vale.
const TEMPLATE_META_ERRORS = new Set([132000, 132001, 132005, 132007, 132012, 132015, 132016]);

export interface SendInput {
  from: string;
  to: string;
  template: string;
  language: string;
  variables: Record<string, unknown>;
  contactName: string | null;
  idempotencyKey: string;
}

export interface ApiSendResponse {
  id: string;
  status: 'accepted';
  to: string;
  replayed: boolean;
  deliveryStatus?: string;
  deliveryError?: string;
}

function digitsOf(value: unknown): string {
  return typeof value === 'string' || typeof value === 'number' ? String(value).replace(/\D/g, '') : '';
}

/**
 * El cuerpo del request, validado. Lo que está mal en la forma es error de
 * quien llama (`invalid_request`, stop); un `to` que no parece teléfono es del
 * contacto (`invalid_phone`, skip).
 */
export function parseSendInput(raw: unknown): SendInput {
  const body: any = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : null;
  if (!body) throw new PublicApiError('invalid_request', 'El cuerpo tiene que ser un objeto JSON.');

  const problems: string[] = [];
  const from = digitsOf(body.from);
  if (!/^\d{6,20}$/.test(from)) {
    problems.push('"from": el número de la sesión de WhatsApp Cloud API desde la que se envía.');
  }
  if (typeof body.to !== 'string' && typeof body.to !== 'number') {
    problems.push('"to": el número del contacto, con código de país.');
  }
  const template = typeof body.template === 'string' ? body.template.trim() : '';
  if (!/^[a-z0-9_]{1,512}$/.test(template)) {
    problems.push('"template": el nombre de la plantilla, como seguimiento_onboarding.');
  }
  const language = typeof body.language === 'string' ? body.language.trim() : '';
  if (!/^[a-z]{2,3}(_[A-Z]{2})?$/.test(language)) {
    problems.push('"language": el idioma exacto de la plantilla, como es_MX.');
  }
  let variables: Record<string, unknown> = {};
  if (body.variables !== undefined && body.variables !== null) {
    if (typeof body.variables === 'object' && !Array.isArray(body.variables)) {
      variables = body.variables;
    } else {
      problems.push('"variables" tiene que ser un objeto, como {"nombre": "Ana"}.');
    }
  }
  let contactName: string | null = null;
  if (body.contactName !== undefined && body.contactName !== null) {
    const name = typeof body.contactName === 'string' ? body.contactName.replace(/\s+/g, ' ').trim() : null;
    if (name === null || name.length > CONTACT_NAME_MAX) {
      problems.push(`"contactName": texto de hasta ${CONTACT_NAME_MAX} caracteres.`);
    } else {
      contactName = name || null;
    }
  }
  const idempotencyKey = typeof body.idempotencyKey === 'string' ? body.idempotencyKey.trim() : '';
  if (!idempotencyKey || idempotencyKey.length > IDEMPOTENCY_KEY_MAX) {
    problems.push(
      `"idempotencyKey" es obligatoria (hasta ${IDEMPOTENCY_KEY_MAX} caracteres): la misma en cada reintento de un mismo mensaje.`,
    );
  }
  if (problems.length > 0) {
    throw new PublicApiError('invalid_request', problems[0], { details: problems });
  }

  const to = digitsOf(body.to);
  if (to.length < 8 || to.length > 15) {
    throw new PublicApiError('invalid_phone', '"to" no parece un número de WhatsApp: van de 8 a 15 dígitos con el código de país.');
  }
  return { from, to, template, language, variables, contactName, idempotencyKey };
}

/**
 * Qué se está pidiendo enviar. Misma idempotencyKey con otro fingerprint es un
 * error de quien llama. `to` va en dígitos tal como vino (no el canónico, que
 * puede cambiar entre reintentos) y el nombre del contacto no cuenta.
 */
export function sendFingerprint(sessionId: string, input: Pick<SendInput, 'to' | 'template' | 'language' | 'variables'>): string {
  const variables = Object.keys(input.variables)
    .sort()
    .map((k) => [k, input.variables[k]]);
  return createHash('sha256')
    .update(JSON.stringify([sessionId, input.to, input.template, input.language, variables]))
    .digest('hex');
}

/** Id del registro: la idempotencyKey puede traer cualquier carácter y Firestore no. */
export function idempotencyDocId(idempotencyKey: string): string {
  return createHash('sha256').update(idempotencyKey).digest('hex');
}

export function parseCallbackData(data: string): string | null {
  const id = data.startsWith(CALLBACK_PREFIX) ? data.slice(CALLBACK_PREFIX.length) : '';
  return /^[0-9a-f]{64}$/.test(id) ? id : null;
}

function toMillis(value: unknown): number | null {
  return typeof (value as any)?.toMillis === 'function' ? (value as any).toMillis() : null;
}

export type ExistingDecision =
  | { kind: 'replay'; response: ApiSendResponse }
  | { kind: 'reclaim' }
  | { kind: 'error'; error: PublicApiError };

/** Qué hacer con un registro que ya existe para esta idempotencyKey. */
export function decideExisting(data: Record<string, any>, fingerprint: string, nowMs: number): ExistingDecision {
  if (data.fingerprint !== fingerprint) {
    return {
      kind: 'error',
      error: new PublicApiError(
        'idempotency_conflict',
        'Esta idempotencyKey ya se usó para otro mensaje (otra sesión, número, plantilla o variables). Usa una distinta para cada mensaje.',
      ),
    };
  }
  switch (data.status) {
    case 'sent':
      return {
        kind: 'replay',
        response: {
          id: String(data.wamid),
          status: 'accepted',
          to: String(data.chat_phone),
          replayed: true,
          ...(data.delivery_status && { deliveryStatus: String(data.delivery_status) }),
          ...(data.delivery_error && { deliveryError: String(data.delivery_error) }),
        },
      };
    case 'failed':
      // Meta lo rechazó: no salió, así que reintentar no duplica nada.
      return { kind: 'reclaim' };
    case 'sending': {
      const started = toMillis(data.attempt_started_at);
      if (started !== null && nowMs - started < IN_FLIGHT_WINDOW_MS) {
        return {
          kind: 'error',
          error: new PublicApiError('in_progress', 'Este mensaje se está enviando ahora mismo. Reintenta en unos segundos.', {
            retryAfterSeconds: 10,
          }),
        };
      }
      return { kind: 'error', error: inDoubtError() };
    }
    default:
      return { kind: 'error', error: inDoubtError() };
  }
}

function inDoubtError(httpStatus?: number): PublicApiError {
  return new PublicApiError(
    'send_in_doubt',
    'Un intento con esta idempotencyKey se cortó mientras se enviaba a Meta y pudo haber salido. No lo reenviamos para no duplicarlo: revisa el chat en WhatHero.',
    httpStatus ? { httpStatus } : {},
  );
}

// ---------------------------------------------------------------------------
// Firestore y Meta
// ---------------------------------------------------------------------------

function sendsCollection(accountId: string) {
  return admin.firestore().collection(ACCOUNTS_COLLECTION).doc(accountId).collection('api_sends');
}

/** Sesión Cloud API por su número. Si no está, dice por qué. */
async function resolveApiSession(accountId: string, from: string) {
  const candidates = waNumberCandidates(from);
  for (const id of candidates) {
    if (isSessionGone(accountId, id)) continue;
    const found = getCloudSession(accountId, id);
    if (found) return found;
  }

  const col = admin.firestore().collection(ACCOUNTS_COLLECTION).doc(accountId).collection('whatsapp_sessions');
  const snaps = await admin.firestore().getAll(...candidates.map((id) => col.doc(id)));
  const doc = snaps.find((s) => s.exists && !s.get('deleting_at'));
  if (!doc) {
    throw new PublicApiError('session_not_found', `No hay una sesión con el número ${from} en esta cuenta.`);
  }
  if (doc.get('provider') !== 'cloud_api') {
    throw new PublicApiError(
      'session_not_cloud_api',
      'Esa sesión está vinculada por QR. El API sólo envía desde sesiones de WhatsApp Cloud API (la oficial de Meta).',
    );
  }
  throw new PublicApiError('session_unavailable', 'La sesión existe pero no está conectada en WhatHero. Revisa sus credenciales de Meta en la app.');
}

// Definiciones de plantillas por sesión. La categoría (marketing o utilidad) se
// lee de aquí al enviar: Meta puede cambiarla después de aprobada.
const templateCache = new Map<string, { at: number; list: MetaTemplateSummary[] }>();

function templateListError(err: unknown): PublicApiError {
  if (err instanceof CloudApiError) {
    if (err.httpStatus === 410) return new PublicApiError('session_not_found', 'Esta sesión fue eliminada.');
    if (err.code === undefined && err.httpStatus === 400) {
      return new PublicApiError('session_unavailable', 'La sesión no tiene credenciales de Meta configuradas.');
    }
    return mapMetaSendError(err);
  }
  // Timeout o red: listar no envía nada, así que reintentar es seguro.
  return new PublicApiError('meta_unavailable', 'No pudimos consultar las plantillas en Meta. Reintenta más tarde.', {
    retryAfterSeconds: 60,
  });
}

async function findTemplate(sessionKey: string, accountId: string, sessionId: string, name: string, language: string) {
  const fetchList = async () => {
    const list = await listMetaTemplates({ accountId, sessionId }).catch((err) => {
      throw templateListError(err);
    });
    templateCache.set(sessionKey, { at: Date.now(), list });
    return list;
  };
  const find = (list: MetaTemplateSummary[]) => list.find((t) => t.name === name && t.language === language);

  const cached = templateCache.get(sessionKey);
  const fresh = !!cached && Date.now() - cached.at < TEMPLATE_CACHE_TTL_MS;
  let template = find(fresh ? cached!.list : await fetchList());
  // Lo que bloquearía el envío se confirma con Meta: la plantilla pudo crearse
  // o aprobarse hace un minuto.
  if (fresh && (!template || template.status !== 'APPROVED')) template = find(await fetchList());
  if (!template) {
    throw new PublicApiError('template_not_found', `No existe la plantilla "${name}" en ${language} en la cuenta de WhatsApp de esta sesión.`);
  }
  return template;
}

function apiSender(senderName: string): SenderInfo {
  // 'bot' como reglas y recordatorios: automático, fuera de la guarda de choque.
  return { type: 'bot', name: senderName, via: 'api' };
}

function apiMessageFields(keyId: string): Record<string, any> {
  return { sentVia: 'api', apiKeyId: keyId };
}

// Registros que este proceso está enviando ahora (`aid/recordId`). Un acuse
// que llega mientras el request sigue vivo no recupera nada: el request pinta.
const inFlight = new Set<string>();

/** El envío completo. Lanza `PublicApiError`; cualquier otra cosa es un bug nuestro. */
export async function sendTemplateViaApi(key: VerifiedApiKey, raw: unknown): Promise<ApiSendResponse> {
  const input = parseSendInput(raw);
  const { sessionKey, session } = await resolveApiSession(key.accountId, input.from);
  const sessionId = session.sessionId!;
  if (!apiKeyAllowsSession(key, sessionId)) {
    throw new PublicApiError('forbidden_session', 'Esta llave no puede enviar desde esa sesión. El owner elige sus sesiones en WhatHero.');
  }

  const recordId = idempotencyDocId(input.idempotencyKey);
  const ref = sendsCollection(key.accountId).doc(recordId);
  const fingerprint = sendFingerprint(sessionId, input);

  // 1. Lo que ya se resolvió se contesta igual, sin validar de nuevo.
  const existing = await ref.get();
  if (existing.exists) {
    const decision = decideExisting(existing.data()!, fingerprint, Date.now());
    if (decision.kind === 'replay') return decision.response;
    if (decision.kind === 'error') throw decision.error;
  }

  // 2. Validar sin escribir nada.
  const template = await findTemplate(sessionKey, key.accountId, sessionId, input.template, input.language);
  const block = templateSendBlock(template);
  if (block) {
    throw new PublicApiError(block.code, block.message, block.templateStatus ? { templateStatus: block.templateStatus } : {});
  }
  const built = buildTemplateSend(template, input.variables);
  if (!built.ok) throw new PublicApiError(built.code, built.message, { variables: built.variables });

  const chatPhone = await resolveCanonicalChatPhone(key.accountId, sessionId, input.to, session);
  const category = String(template.category).toUpperCase();
  if (category === 'MARKETING' && (await isMarketingOptedOut(key.accountId, sessionId, chatPhone))) {
    throw new PublicApiError('recipient_opted_out', 'Este contacto pidió no recibir marketing de tu negocio. No le volvemos a escribir con plantillas de marketing.');
  }

  // 3. Reclamar. La transacción re-decide: otro request pudo reclamarla entre la lectura y aquí.
  const senderName = `${key.name} (API)`;
  const now = admin.firestore.Timestamp.now();
  const fields = {
    idempotency_key: input.idempotencyKey,
    fingerprint,
    key_id: key.keyId,
    session_id: sessionId,
    to: input.to,
    chat_phone: chatPhone,
    template: template.name,
    language: template.language,
    category,
    contact_name: input.contactName,
    sender_name: senderName,
    rendered_text: built.renderedText,
  };
  const claim = await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists) {
      const decision = decideExisting(snap.data()!, fingerprint, Date.now());
      if (decision.kind !== 'reclaim') return decision;
      tx.update(ref, {
        ...fields,
        status: 'sending',
        attempt_started_at: now,
        attempts: admin.firestore.FieldValue.increment(1),
        error: admin.firestore.FieldValue.delete(),
        updated_at: now,
      });
    } else {
      tx.create(ref, { ...fields, status: 'sending', attempt_started_at: now, attempts: 1, created_at: now, updated_at: now });
    }
    return { kind: 'claimed' as const };
  });
  if (claim.kind === 'replay') return claim.response;
  if (claim.kind === 'error') throw claim.error;

  // 4. Enviar. La única ventana de duda es esta llamada.
  const flightKey = `${key.accountId}/${recordId}`;
  inFlight.add(flightKey);
  try {
    let wamid: string;
    try {
      ({ wamid } = await postTemplateToMeta({
        session,
        to: chatPhone,
        templateName: template.name,
        languageCode: template.language,
        components: built.components,
        bizOpaqueCallbackData: `${CALLBACK_PREFIX}${recordId}`,
        signal: AbortSignal.timeout(META_SEND_TIMEOUT_MS),
      }));
    } catch (err) {
      const markRecord = (patch: Record<string, any>) =>
        ref.update({ ...patch, updated_at: admin.firestore.Timestamp.now() }).catch((e) =>
          console.error(`[API] No se pudo anotar el resultado del envío ${recordId}:`, e),
        );
      if (err instanceof CloudApiError) {
        // Meta respondió con un error: no salió.
        const apiError = mapMetaSendError(err);
        if (err.code !== undefined && TEMPLATE_META_ERRORS.has(err.code)) templateCache.delete(sessionKey);
        await markRecord({ status: 'failed', error: { code: apiError.code, message: apiError.message, meta_code: err.code ?? null } });
        console.warn(`[API] ${key.keyId}: Meta rechazó ${template.name} a ${chatPhone} (${apiError.code}, #${err.code ?? '-'})`);
        throw apiError;
      }
      // Sin respuesta de Meta: pudo salir. No se reenvía; el webhook lo aclara si salió.
      await markRecord({ status: 'in_doubt', error: { code: 'send_in_doubt', message: String((err as Error)?.message ?? err) } });
      console.warn(`[API] ${key.keyId}: envío ${recordId} en duda (${(err as Error)?.name}): no se reenviará.`);
      throw inDoubtError((err as Error)?.name === 'TimeoutError' ? 504 : undefined);
    }

    // Salió. Se anota ANTES de pintar: si el proceso muere aquí, nadie lo reenvía.
    await ref
      .update({ status: 'sent', wamid, sent_at: admin.firestore.Timestamp.now(), updated_at: admin.firestore.Timestamp.now() })
      .catch((e) => console.error(`[API] No se pudo anotar como enviado ${recordId} (${wamid}); el webhook lo corrige:`, e));

    // Lo que falle de aquí en adelante ya no es del envío: el mensaje salió.
    try {
      if (input.contactName) session.contactNames.set(chatPhone, input.contactName);
      await persistOutgoingTemplate({
        sessionKey,
        session,
        chatPhone,
        wamid,
        displayText: built.renderedText,
        templateName: template.name,
        languageCode: template.language,
        sender: apiSender(senderName),
        extraFields: apiMessageFields(key.keyId),
      });
      await ref.update({ bubble_saved: true });
    } catch (e) {
      console.error(`[API] El envío ${wamid} salió pero no se pudo pintar en el chat:`, e);
    }

    console.log(`[API] ${key.keyId} ("${key.name}") envió ${template.name} a ${chatPhone} desde ${sessionId} (${wamid})`);
    return { id: wamid, status: 'accepted', to: chatPhone, replayed: false };
  } finally {
    inFlight.delete(flightKey);
  }
}

/**
 * Acuse del webhook con nuestro `biz_opaque_callback_data`. Prueba que Meta lo
 * aceptó: un registro `sending`/`in_doubt` pasa a `sent`. Si el proceso murió
 * antes de pintar la burbuja, se pinta aquí con lo guardado en el registro.
 */
export async function applyApiSendStatus(ev: ApiSendStatusEvent): Promise<void> {
  const recordId = parseCallbackData(ev.callbackData);
  if (!recordId) return;
  const ref = sendsCollection(ev.accountId).doc(recordId);

  const record = await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return null;
    const data = snap.data()!;
    const now = admin.firestore.Timestamp.now();
    const patch: Record<string, any> = {};
    if (data.status !== 'sent') {
      Object.assign(patch, { status: 'sent', wamid: ev.wamid, sent_at: now, error: admin.firestore.FieldValue.delete() });
    }
    if (isDeliveryStatusAdvance(data.delivery_status, ev.status)) {
      patch.delivery_status = ev.status;
      if (ev.deliveryError) patch.delivery_error = ev.deliveryError;
    }
    if (Object.keys(patch).length > 0) tx.update(ref, { ...patch, updated_at: now });
    return data;
  });
  if (!record || record.bubble_saved || inFlight.has(`${ev.accountId}/${recordId}`)) return;

  if (record.status !== 'sent') {
    console.warn(`[API] Envío ${recordId} (${ev.wamid}) recuperado por el webhook: Meta lo aceptó aunque no alcanzamos a anotarlo.`);
  }
  const chatPhone = String(record.chat_phone || ev.chatPhone);
  const messageSnap = await admin
    .firestore()
    .collection(ACCOUNTS_COLLECTION)
    .doc(ev.accountId)
    .collection('whatsapp_sessions')
    .doc(ev.sessionId)
    .collection('chats')
    .doc(chatPhone)
    .collection('messages')
    .doc(ev.wamid)
    .get();
  if (!messageSnap.exists) {
    if (record.contact_name) ev.session.contactNames.set(chatPhone, String(record.contact_name));
    await persistOutgoingTemplate({
      sessionKey: ev.sessionKey,
      session: ev.session,
      chatPhone,
      wamid: ev.wamid,
      displayText: String(record.rendered_text || `📋 Plantilla: ${record.template} (${record.language})`),
      templateName: String(record.template),
      languageCode: String(record.language),
      sender: apiSender(String(record.sender_name || 'API')),
      extraFields: apiMessageFields(String(record.key_id)),
    });
    console.warn(`[API] Burbuja de ${ev.wamid} pintada por el webhook (el proceso murió antes de pintarla).`);
  }
  await ref.update({ bubble_saved: true });
}

/** Al eliminar una sesión: sus registros de envío (números y nombres) se van con ella. */
export async function purgeApiSendsForSession(accountId: string, sessionId: string): Promise<void> {
  const query = sendsCollection(accountId).where('session_id', '==', sessionId).limit(400);
  let total = 0;
  for (;;) {
    const snap = await query.get();
    if (snap.empty) break;
    const batch = admin.firestore().batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    total += snap.size;
  }
  if (total > 0) console.log(`[Eliminar] ${sessionId}: ${total} registro(s) de envíos del API borrados.`);
}
