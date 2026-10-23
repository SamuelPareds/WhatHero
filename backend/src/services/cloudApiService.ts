import * as admin from 'firebase-admin';
import { createHmac, randomUUID, timingSafeEqual } from 'crypto';
import { ACCOUNTS_COLLECTION, IS_PRODUCTION } from '../config/env';
import { SenderInfo, SessionData } from '../types';
import { extractPhoneNumber, waNumberCandidates } from '../utils/phone';
import { isAiSentMessage, rememberAiSentMessage } from './aiService';
import { initializeSession, updateMediaIndexEntry } from './firestoreService';
import { isSessionGone, writeSessionStatus } from './sessionSupervisor';
import { TemplateDraft, buildCreateTemplatePayload, sanitizeTemplateSendComponents } from './metaTemplates';

const GRAPH_API_VERSION = 'v21.0';
const GRAPH_BASE_URL = `https://graph.facebook.com/${GRAPH_API_VERSION}`;

// Deduplicador en memoria para webhooks de Meta (evita procesar dos veces el
// mismo `wamid` si Meta reintenta la entrega o llega en ráfaga).
const WEBHOOK_DEDUPE_TTL_MS = 10 * 60 * 1000;
const processedWebhookMessageIds = new Map<string, number>();

function markWebhookMessageProcessed(wamid: string): boolean {
  const now = Date.now();
  for (const [id, ts] of processedWebhookMessageIds.entries()) {
    if (now - ts > WEBHOOK_DEDUPE_TTL_MS) {
      processedWebhookMessageIds.delete(id);
    }
  }
  if (processedWebhookMessageIds.has(wamid)) {
    return false;
  }
  processedWebhookMessageIds.set(wamid, now);
  return true;
}

export class CloudApiError extends Error {
  code?: number;
  subcode?: number;
  httpStatus: number;
  details?: string;
  // Motivo propio de WhatHero (no de Meta) cuando rechazamos un alta: ver
  // `decideCloudApiTarget`.
  reason?: CloudApiRejectReason;

  constructor(
    message: string,
    opts: { code?: number; subcode?: number; httpStatus: number; details?: string; reason?: CloudApiRejectReason },
  ) {
    super(message);
    this.name = 'CloudApiError';
    this.code = opts.code;
    this.subcode = opts.subcode;
    this.httpStatus = opts.httpStatus;
    this.details = opts.details;
    this.reason = opts.reason;
  }
}

export interface CloudApiDeps {
  db: admin.firestore.Firestore;
  sessions: Map<string, SessionData>;
  onUpsertedMessage: (
    sessionKey: string,
    accountId: string,
    sock: any,
    rawMessage: any,
    upsertType?: string,
  ) => Promise<void>;
  loadAllSessionConfigs: (
    sessionKey: string,
    accountId: string,
    sessionId: string,
  ) => Promise<void>;
}

let deps: CloudApiDeps | null = null;

export function initCloudApiService(d: CloudApiDeps): void {
  deps = d;
  // Arranque limpio: sin recargas ni avisos pendientes de una inicialización anterior.
  lastFullLoadAt = 0;
  fullLoadInFlight = null;
  webhookWarnedAt.clear();
  warnedMissingAppSecret = false;
}

function requireDeps(): CloudApiDeps {
  if (!deps) {
    throw new Error('cloudApiService no inicializado: falta initCloudApiService()');
  }
  return deps;
}

/**
 * Token de verificación para el webhook de Meta (`GET /webhook/meta`).
 * Se puede cambiar con `META_WEBHOOK_VERIFY_TOKEN`, pero la hoja de conexión
 * muestra el valor por defecto fijo (`_verifyToken` en
 * connect_cloud_api_sheet.dart): cambiarlo sólo de un lado hace que la
 * verificación en Meta falle. Por eso no está en `.env.example`.
 */
export function getMetaWebhookVerifyToken(): string {
  return process.env.META_WEBHOOK_VERIFY_TOKEN?.trim() || 'whathero_meta_verify_2026';
}

// Respaldo para sesiones sin App Secret propio (una app de WhatHero, el día que
// haya una). Lo normal es que cada sesión traiga el de la app del cliente.
function getMetaAppSecret(): string {
  return process.env.META_APP_SECRET?.trim() || '';
}

/**
 * `X-Hub-Signature-256` = `sha256=` + HMAC-SHA256 del cuerpo CRUDO con la clave
 * secreta de la app. Tiene que ser el cuerpo tal como llegó: re-serializar el
 * JSON parseado cambia los bytes y ninguna firma cuadraría.
 */
export function verifyMetaSignature(
  rawBody: Buffer | undefined,
  header: string | undefined,
  appSecret: string,
): boolean {
  if (!rawBody || !header || !appSecret) return false;
  const match = /^sha256=([0-9a-f]{64})$/i.exec(header.trim());
  if (!match) return false;
  const expected = createHmac('sha256', appSecret).update(rawBody).digest();
  const received = Buffer.from(match[1], 'hex');
  return received.length === expected.length && timingSafeEqual(received, expected);
}

/** El cuerpo crudo y la firma de un POST al webhook, para verificarlo. */
export interface MetaWebhookAuth {
  rawBody?: Buffer;
  signature?: string;
}

let warnedMissingAppSecret = false;

/**
 * ¿Este webhook lo firmó la app de Meta de ESTA sesión? Sin la guarda,
 * cualquiera podía inyectar mensajes falsos en el chat de un cliente (con push y
 * respuesta de la IA incluidos) conociendo sólo su `phone_number_id`.
 *
 * Se decide por sesión, no por request: cada cliente trae su propia app y cada
 * app firma con su propia clave. Un cliente que conoce la suya no puede firmar
 * cambios para el número de otro.
 *
 * Sin ninguna clave, producción falla cerrado. En desarrollo se acepta (con un
 * aviso) para poder probar con un túnel.
 */
function isSignedBySessionApp(session: SessionData, auth: MetaWebhookAuth | undefined): boolean {
  const secret = session.cloudApi?.appSecret || getMetaAppSecret();
  if (secret) return verifyMetaSignature(auth?.rawBody, auth?.signature, secret);
  if (IS_PRODUCTION) return false;
  if (!warnedMissingAppSecret) {
    warnedMissingAppSecret = true;
    console.warn('[CloudAPI Webhook] ⚠️ Sesión sin App Secret: en desarrollo se aceptan sus webhooks sin firma (en producción se rechazan).');
  }
  return true;
}

function maskAccessToken(token: string): string {
  const trimmed = token.trim();
  if (trimmed.length <= 12) return '••••••••';
  return `${trimmed.slice(0, 6)}••••${trimmed.slice(-4)}`;
}

function normalizePhoneDigits(raw: string): string {
  return raw.replace(/\D/g, '');
}

async function graphApiJson<T = any>(
  path: string,
  accessToken: string,
  init?: RequestInit,
): Promise<T> {
  const url = path.startsWith('http') ? path : `${GRAPH_BASE_URL}${path.startsWith('/') ? '' : '/'}${path}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    ...(init?.headers as Record<string, string> | undefined),
  };
  if (init?.body && typeof init.body === 'string' && !headers['Content-Type']) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetch(url, {
    ...init,
    headers,
  });

  const rawText = await response.text();
  let parsed: any = {};
  try {
    parsed = rawText ? JSON.parse(rawText) : {};
  } catch {
    parsed = { rawText };
  }

  if (!response.ok) {
    const metaErr = parsed?.error;
    const code = typeof metaErr?.code === 'number' ? metaErr.code : undefined;
    const subcode = typeof metaErr?.error_subcode === 'number' ? metaErr.error_subcode : undefined;
    const details = metaErr?.error_data?.details || metaErr?.error_user_msg || metaErr?.message || rawText;
    const formattedMsg = code
      ? `[Meta #${code}] ${details || 'Error en WhatsApp Cloud API'}`
      : details || `HTTP ${response.status} en WhatsApp Cloud API`;
    throw new CloudApiError(formattedMsg, {
      code,
      subcode,
      httpStatus: response.status,
      details,
    });
  }

  return parsed as T;
}

/**
 * Resuelve el número canónico de un chat para evitar que números de México
 * (`521...` vs `52...`) o Argentina (`549...` vs `54...`) abran dos chats
 * distintos entre lo que envía el cliente por webhook y lo que escribe el operador.
 */
export async function resolveCanonicalChatPhone(
  accountId: string,
  sessionId: string,
  rawPhoneOrJid: string,
  session?: SessionData,
): Promise<string> {
  const extracted = rawPhoneOrJid.includes('@')
    ? extractPhoneNumber(rawPhoneOrJid) || rawPhoneOrJid
    : rawPhoneOrJid;
  const digits = normalizePhoneDigits(extracted);
  if (!digits) return rawPhoneOrJid;

  const candidates = waNumberCandidates(digits);
  if (candidates.length <= 1) return digits;

  // 1. Revisar si alguno ya está en el cache de nombres de la sesión en memoria.
  if (session?.contactNames) {
    for (const cand of candidates) {
      if (session.contactNames.has(cand)) return cand;
    }
  }

  // 2. Consultar en una sola lectura batch (`getAll`) si ya existe `chats/{cand}`.
  try {
    const { db } = requireDeps();
    const chatsCol = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats');
    const refs = candidates.map((c: string) => chatsCol.doc(c));
    const snaps = await db.getAll(...refs);
    for (let i = 0; i < snaps.length; i++) {
      if (snaps[i].exists) {
        return candidates[i];
      }
    }
  } catch (err) {
    console.warn(`[CloudAPI] No se pudo verificar candidatos de número para ${digits}:`, err);
  }

  return digits;
}

/**
 * Envía un payload a `/{phoneNumberId}/messages` y, si Meta responde con
 * `#131030` (lista blanca del número de prueba) o `#131026` por diferencia
 * entre `521`/`52` (México) o `549`/`54` (Argentina), reintenta automáticamente
 * con la variante hermana.
 */
async function sendGraphMessageWithRetry(
  phoneNumberId: string,
  accessToken: string,
  toPhone: string,
  buildBody: (recipientPhone: string) => Record<string, any>,
): Promise<{ wamid: string; recipientUsed: string }> {
  const candidates = waNumberCandidates(normalizePhoneDigits(toPhone));
  const listToTry = candidates.length > 0 ? candidates : [normalizePhoneDigits(toPhone)];

  let lastError: unknown;
  for (let i = 0; i < listToTry.length; i++) {
    const candidate = listToTry[i];
    try {
      const res = await graphApiJson<{ messages?: Array<{ id: string }> }>(
        `/${phoneNumberId}/messages`,
        accessToken,
        {
          method: 'POST',
          body: JSON.stringify(buildBody(candidate)),
        },
      );
      const wamid = res?.messages?.[0]?.id || `wamid.${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      return { wamid, recipientUsed: candidate };
    } catch (err) {
      lastError = err;
      const isRetryableNumberFormat =
        err instanceof CloudApiError && (err.code === 131030 || err.code === 131026 || err.code === 100);
      if (!isRetryableNumberFormat || i === listToTry.length - 1) {
        throw err;
      }
      console.log(
        `[CloudAPI] Reintentando envío con formato alterno ${listToTry[i + 1]} tras error #${(err as CloudApiError).code} con ${candidate}`,
      );
    }
  }

  throw lastError;
}

function extFromMime(mimeType: string): string {
  const clean = mimeType.split(';')[0].trim().toLowerCase();
  const map: Record<string, string> = {
    'image/jpeg': 'jpg',
    'image/jpg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'image/gif': 'gif',
    'video/mp4': 'mp4',
    'video/3gpp': '3gp',
    'audio/ogg': 'ogg',
    'audio/opus': 'ogg',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/aac': 'aac',
    'audio/amr': 'amr',
    'application/pdf': 'pdf',
  };
  return map[clean] || 'bin';
}

/**
 * Sube un Buffer a Firebase Storage en la ruta definitiva del mensaje y
 * devuelve su URL pública con token (idéntico al formato de `mediaService.ts`).
 */
async function uploadBufferToSessionStorage(params: {
  accountId: string;
  sessionId: string;
  chatPhone: string;
  messageId: string;
  buffer: Buffer;
  mimeType: string;
}): Promise<string> {
  const ext = extFromMime(params.mimeType);
  const safeMessageId = params.messageId.replace(/[^a-zA-Z0-9_-]/g, '_');
  const storagePath = `${ACCOUNTS_COLLECTION}/${params.accountId}/whatsapp_sessions/${params.sessionId}/chats/${params.chatPhone}/media/${safeMessageId}.${ext}`;
  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  const downloadToken = randomUUID();

  await file.save(params.buffer, {
    resumable: false,
    metadata: {
      contentType: params.mimeType,
      metadata: {
        firebaseStorageDownloadTokens: downloadToken,
      },
    },
  });

  const encodedPath = encodeURIComponent(storagePath);
  return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media&token=${downloadToken}`;
}

/**
 * Sube un archivo binario a los servidores de Meta (`POST /{phoneNumberId}/media`)
 * para poder referenciar su `id` al enviar imágenes, videos, audios o documentos.
 */
async function uploadMediaToMetaGraph(
  phoneNumberId: string,
  accessToken: string,
  buffer: Buffer,
  mimeType: string,
  fileName?: string,
): Promise<string> {
  // Meta rechaza `audio/webm` o `audio/ogg; codecs=opus` si lleva parámetros extra en algunos endpoints;
  // normalizamos el mimeType para que sea aceptado por WhatsApp Cloud API.
  const baseMime = mimeType.split(';')[0].trim() || 'application/octet-stream';
  const effectiveMime = baseMime === 'audio/webm' ? 'audio/ogg' : baseMime;
  const ext = extFromMime(effectiveMime);
  const safeName = fileName || `file_${Date.now()}.${ext}`;

  const formData = new FormData();
  formData.append('messaging_product', 'whatsapp');
  formData.append('type', effectiveMime);
  const blob = new Blob([new Uint8Array(buffer)], { type: effectiveMime });
  formData.append('file', blob, safeName);

  const response = await fetch(`${GRAPH_BASE_URL}/${phoneNumberId}/media`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
    body: formData,
  });

  const rawText = await response.text();
  let parsed: any = {};
  try {
    parsed = rawText ? JSON.parse(rawText) : {};
  } catch {
    parsed = { rawText };
  }

  if (!response.ok || !parsed?.id) {
    const metaErr = parsed?.error;
    const code = typeof metaErr?.code === 'number' ? metaErr.code : undefined;
    const details = metaErr?.error_data?.details || metaErr?.message || rawText;
    throw new CloudApiError(
      code ? `[Meta #${code}] ${details}` : `Error subiendo archivo a Meta: ${details}`,
      { code, httpStatus: response.status, details },
    );
  }

  return parsed.id as string;
}

/**
 * Descarga un archivo entrante desde Meta Graph API (`GET /{mediaId}` -> `GET url`)
 * y actualiza el documento del mensaje en Firestore + `media_index`.
 */
async function downloadIncomingMetaMediaAndPersist(params: {
  accountId: string;
  sessionId: string;
  chatPhone: string;
  messageId: string;
  metaMediaId: string;
  accessToken: string;
  fallbackMime: string;
}): Promise<void> {
  const { db } = requireDeps();
  const msgRef = db
    .collection(ACCOUNTS_COLLECTION)
    .doc(params.accountId)
    .collection('whatsapp_sessions')
    .doc(params.sessionId)
    .collection('chats')
    .doc(params.chatPhone)
    .collection('messages')
    .doc(params.messageId);

  try {
    const metaInfo = await graphApiJson<{ url?: string; mime_type?: string; file_size?: number }>(
      `/${params.metaMediaId}`,
      params.accessToken,
    );
    if (!metaInfo?.url) {
      throw new Error(`Meta no devolvió URL para mediaId ${params.metaMediaId}`);
    }

    const mediaRes = await fetch(metaInfo.url, {
      headers: {
        Authorization: `Bearer ${params.accessToken}`,
      },
    });
    if (!mediaRes.ok) {
      throw new Error(`HTTP ${mediaRes.status} descargando binario de Meta`);
    }

    const arrayBuf = await mediaRes.arrayBuffer();
    const buffer = Buffer.from(arrayBuf);
    const mimeType = metaInfo.mime_type || params.fallbackMime || 'application/octet-stream';

    const mediaUrl = await uploadBufferToSessionStorage({
      accountId: params.accountId,
      sessionId: params.sessionId,
      chatPhone: params.chatPhone,
      messageId: params.messageId,
      buffer,
      mimeType,
    });

    const patch = {
      mediaStatus: 'ready',
      mediaUrl,
      mediaMime: mimeType,
      mediaSize: buffer.length,
    };

    await msgRef.set(patch, { merge: true });
    await updateMediaIndexEntry({
      accountId: params.accountId,
      sessionId: params.sessionId,
      messageId: params.messageId,
      patch,
    });
  } catch (err) {
    console.error(`[CloudAPI] Error descargando media entrante ${params.metaMediaId}:`, err);
    await msgRef.set({ mediaStatus: 'failed' }, { merge: true }).catch(() => {});
    await updateMediaIndexEntry({
      accountId: params.accountId,
      sessionId: params.sessionId,
      messageId: params.messageId,
      patch: { mediaStatus: 'failed' },
    }).catch(() => {});
  }
}

/**
 * Construye un adaptador compatible con la interfaz de `sock` de Baileys para
 * que el resto del backend (envío humano, IA, reglas por keyword, recordatorios,
 * reacciones y recibos de lectura) funcione sin bifucar su lógica.
 */
export function createCloudApiSocket(
  sessionKey: string,
  accountId: string,
  sessionId: string,
): any {
  const { sessions, onUpsertedMessage } = requireDeps();

  const sock: any = {
    isCloudApi: true,
    get user() {
      const s = sessions.get(sessionKey);
      return {
        id: `${sessionId}:0@s.whatsapp.net`,
        name: s?.cloudApi?.verifiedName || 'WhatsApp Cloud API',
      };
    },
    sendPresenceUpdate: async (_type: string, _jid?: string) => {
      // Cloud API no expone estados "composing" independientes por socket.
    },
    readMessages: async (keys: Array<{ remoteJid?: string; id?: string }>) => {
      const s = sessions.get(sessionKey);
      if (!s?.cloudApi) return;
      const { phoneNumberId, accessToken } = s.cloudApi;
      for (const k of keys) {
        if (!k?.id) continue;
        try {
          await graphApiJson(`/${phoneNumberId}/messages`, accessToken, {
            method: 'POST',
            body: JSON.stringify({
              messaging_product: 'whatsapp',
              status: 'read',
              message_id: k.id,
            }),
          });
        } catch (err) {
          console.warn(`[CloudAPI] No se pudo marcar como leído ${k.id}:`, err);
        }
      }
    },
    sendMessage: async (jid: string, content: any, options?: any) => {
      const session = sessions.get(sessionKey);
      if (!session?.cloudApi) {
        throw new Error('Sesión Cloud API no tiene credenciales activas en memoria');
      }
      const { phoneNumberId, accessToken } = session.cloudApi;
      const canonicalPhone = await resolveCanonicalChatPhone(accountId, sessionId, jid, session);
      const canonicalJid = `${canonicalPhone}@s.whatsapp.net`;
      const quotedMsgId: string | undefined = options?.quoted?.key?.id;
      const contextPayload = quotedMsgId ? { context: { message_id: quotedMsgId } } : {};

      // 1. Reacciones (`{ react: { text: emoji, key } }`)
      if (content && typeof content === 'object' && 'react' in content && content.react) {
        const targetKey = content.react.key;
        const emoji = content.react.text ?? '';
        const { wamid } = await sendGraphMessageWithRetry(
          phoneNumberId,
          accessToken,
          canonicalPhone,
          (recipient) => ({
            messaging_product: 'whatsapp',
            recipient_type: 'individual',
            to: recipient,
            type: 'reaction',
            reaction: {
              message_id: targetKey?.id,
              emoji,
            },
          }),
        );

        const syntheticReaction = {
          key: {
            remoteJid: canonicalJid,
            fromMe: true,
            id: wamid,
          },
          messageTimestamp: Math.floor(Date.now() / 1000),
          message: {
            reactionMessage: {
              key: targetKey,
              text: emoji,
            },
          },
        };
        await onUpsertedMessage(sessionKey, accountId, sock, syntheticReaction, 'notify');
        return { key: syntheticReaction.key };
      }

      // Helper para construir `contextInfo` sintético cuando se responde citando un mensaje.
      const buildSyntheticContextInfo = () => {
        if (!options?.quoted) return undefined;
        return {
          stanzaId: options.quoted.key?.id,
          participant: options.quoted.key?.fromMe
            ? `${sessionId}@s.whatsapp.net`
            : `${canonicalPhone}@s.whatsapp.net`,
          quotedMessage: options.quoted.message || { conversation: '' },
        };
      };

      // Helper para transferir `pendingSenders` y `rememberAiSentMessage` cuando
      // el caller pre-generó `options.messageId` (ej. IA o `sendAsHuman`).
      const transferPreassignedId = (realWamid: string): boolean => {
        const preId: string | undefined = options?.messageId;
        if (!preId) return false;
        if (preId !== realWamid) {
          const pending = session.pendingSenders.get(preId);
          if (pending) {
            session.pendingSenders.delete(preId);
            session.pendingSenders.set(realWamid, pending);
          }
          if (isAiSentMessage(preId)) {
            rememberAiSentMessage(realWamid);
          }
        }
        return true;
      };

      // Si el caller pasó `options.messageId` (`performSendMessage` / `aiService`),
      // `pendingSenders` ya está poblado y esperamos a que Firestore guarde antes de
      // retornar. Si no lo pasó (keyword rules, recordatorios, followups), el caller
      // hace `session.pendingSenders.set(sent.key.id, ...)` en la línea siguiente al
      // `await sock.sendMessage(...)`, por lo que despachamos en `setImmediate`.
      const dispatchOutboundUpsert = async (syntheticMsg: any, hasPreassignedId: boolean) => {
        if (hasPreassignedId) {
          await onUpsertedMessage(sessionKey, accountId, sock, syntheticMsg, 'notify');
        } else {
          setImmediate(() => {
            onUpsertedMessage(sessionKey, accountId, sock, syntheticMsg, 'notify').catch((err) =>
              console.error('[CloudAPI] Error en upsert diferido:', err),
            );
          });
        }
      };

      // 2. Mensajes de texto (`{ text }`)
      if (typeof content?.text === 'string') {
        const textBody = content.text;
        const { wamid } = await sendGraphMessageWithRetry(
          phoneNumberId,
          accessToken,
          canonicalPhone,
          (recipient) => ({
            messaging_product: 'whatsapp',
            recipient_type: 'individual',
            to: recipient,
            type: 'text',
            ...contextPayload,
            text: {
              preview_url: true,
              body: textBody,
            },
          }),
        );

        const hasPreassigned = transferPreassignedId(wamid);
        const contextInfo = buildSyntheticContextInfo();
        const syntheticMsg: any = {
          key: {
            remoteJid: canonicalJid,
            fromMe: true,
            id: wamid,
          },
          messageTimestamp: Math.floor(Date.now() / 1000),
          message: contextInfo
            ? {
                extendedTextMessage: {
                  text: textBody,
                  contextInfo,
                },
              }
            : {
                conversation: textBody,
              },
        };

        await dispatchOutboundUpsert(syntheticMsg, hasPreassigned);
        return { key: syntheticMsg.key };
      }

      // 3. Mensajes multimedia (image, video, document, audio)
      const mediaKind: 'image' | 'video' | 'document' | 'audio' | null =
        content?.image instanceof Buffer
          ? 'image'
          : content?.video instanceof Buffer
          ? 'video'
          : content?.document instanceof Buffer
          ? 'document'
          : content?.audio instanceof Buffer
          ? 'audio'
          : null;

      if (mediaKind) {
        const buffer: Buffer = content[mediaKind];
        const mimeType: string =
          content.mimetype ||
          (mediaKind === 'image'
            ? 'image/jpeg'
            : mediaKind === 'video'
            ? 'video/mp4'
            : mediaKind === 'audio'
            ? 'audio/ogg'
            : 'application/octet-stream');
        const caption: string = content.caption || '';
        const fileName: string | undefined = content.fileName;

        // Primero subimos el binario a Meta Graph API para obtener su `media_id`.
        const metaMediaId = await uploadMediaToMetaGraph(
          phoneNumberId,
          accessToken,
          buffer,
          mimeType,
          fileName,
        );

        const mediaObject: Record<string, any> = { id: metaMediaId };
        if (caption && mediaKind !== 'audio') {
          mediaObject.caption = caption;
        }
        if (mediaKind === 'document' && fileName) {
          mediaObject.filename = fileName;
        }

        const { wamid } = await sendGraphMessageWithRetry(
          phoneNumberId,
          accessToken,
          canonicalPhone,
          (recipient) => ({
            messaging_product: 'whatsapp',
            recipient_type: 'individual',
            to: recipient,
            type: mediaKind,
            ...contextPayload,
            [mediaKind]: mediaObject,
          }),
        );

        const hasPreassigned = transferPreassignedId(wamid);

        // Subimos el mismo Buffer al Storage definitivo de la sesión ANTES de
        // retornar, para que `cleanupAfterSend` pueda borrar `temp_uploads`
        // sin romper la URL del archivo en el chat.
        const mediaUrl = await uploadBufferToSessionStorage({
          accountId,
          sessionId,
          chatPhone: canonicalPhone,
          messageId: wamid,
          buffer,
          mimeType,
        });

        const contextInfo = buildSyntheticContextInfo();
        const innerMessage: Record<string, any> = {};
        if (mediaKind === 'image') {
          innerMessage.imageMessage = { caption, mimetype: mimeType, ...(contextInfo && { contextInfo }) };
        } else if (mediaKind === 'video') {
          innerMessage.videoMessage = { caption, mimetype: mimeType, ...(contextInfo && { contextInfo }) };
        } else if (mediaKind === 'document') {
          innerMessage.documentMessage = {
            caption,
            mimetype: mimeType,
            fileName: fileName || 'Documento',
            ...(contextInfo && { contextInfo }),
          };
        } else if (mediaKind === 'audio') {
          innerMessage.audioMessage = {
            mimetype: mimeType,
            ptt: !!content.ptt,
            ...(contextInfo && { contextInfo }),
          };
        }

        const syntheticMediaMsg: any = {
          key: {
            remoteJid: canonicalJid,
            fromMe: true,
            id: wamid,
          },
          messageTimestamp: Math.floor(Date.now() / 1000),
          message: innerMessage,
          __cloudMediaFields: {
            mediaType: mediaKind,
            mediaMime: mimeType,
            mediaSize: buffer.length,
            ...(fileName && { mediaFileName: fileName }),
            ...(mediaKind === 'audio' && { mediaIsPtt: !!content.ptt }),
            mediaStatus: 'ready',
            mediaUrl,
          },
        };

        await dispatchOutboundUpsert(syntheticMediaMsg, hasPreassigned);
        return { key: syntheticMediaMsg.key };
      }

      throw new Error('Tipo de mensaje no soportado en adaptador Cloud API');
    },
  };

  return sock;
}

/** `appsecret_proof` de Graph API: HMAC-SHA256 del access token con la clave secreta de la app. */
export function appSecretProof(accessToken: string, appSecret: string): string {
  return createHmac('sha256', appSecret).update(accessToken).digest('hex');
}

/**
 * Verifica las credenciales contra Meta Graph API antes de guardar la sesión.
 *
 * Con `appSecret` la consulta lleva `appsecret_proof`, y Graph la rechaza si la
 * clave no es la de la app que emitió el token. Así un App Secret mal copiado
 * se detecta acá y no después, con todos los webhooks de la sesión rechazados
 * en silencio.
 */
export async function verifyCloudApiCredentials(params: {
  phoneNumberId: string;
  wabaId: string;
  accessToken: string;
  appSecret?: string;
}): Promise<{
  sessionId: string;
  displayPhoneNumber: string;
  verifiedName: string;
  qualityRating?: string;
}> {
  const phoneId = params.phoneNumberId.trim();
  const wabaId = params.wabaId.trim();
  const token = params.accessToken.trim();

  if (!phoneId || !wabaId || !token) {
    throw new CloudApiError('Faltan credenciales requeridas (Phone Number ID, WABA ID o Access Token)', {
      httpStatus: 400,
    });
  }

  const appSecret = params.appSecret?.trim();
  const proof = appSecret ? `&appsecret_proof=${appSecretProof(token, appSecret)}` : '';
  let phoneInfo: {
    id?: string;
    display_phone_number?: string;
    verified_name?: string;
    quality_rating?: string;
  };
  try {
    phoneInfo = await graphApiJson(`/${phoneId}?fields=id,display_phone_number,verified_name,quality_rating${proof}`, token);
  } catch (err) {
    if (err instanceof CloudApiError && /appsecret_proof/i.test(`${err.details ?? ''} ${err.message}`)) {
      throw new CloudApiError(
        'El App Secret no corresponde a la app de este Access Token. Cópialo de Meta for Developers → tu app → Configuración de la app → Básica → Clave secreta de la app.',
        { httpStatus: 400, code: err.code },
      );
    }
    throw err;
  }

  const rawDisplay = phoneInfo.display_phone_number || phoneId;
  const digits = normalizePhoneDigits(rawDisplay) || phoneId;
  const verifiedName = phoneInfo.verified_name || 'WhatsApp Cloud API';

  return {
    sessionId: digits,
    displayPhoneNumber: rawDisplay,
    verifiedName,
    qualityRating: phoneInfo.quality_rating,
  };
}

/**
 * Deja la app del cliente recibiendo los webhooks de su número: comprueba que el
 * Phone Number ID sea de ese WABA y suscribe la app al WABA
 * (`POST /{waba}/subscribed_apps`).
 *
 * Meta sólo entrega los eventos de un WABA a las apps suscritas a él. Sin esto
 * el alta queda "conectada", enviar funciona y no llega ni un mensaje del
 * cliente: pasó en la primera prueba con el número de prueba (21-oct-2026). La
 * comprobación del WABA es la otra mitad: con un WABA equivocado la app quedaría
 * suscrita a una cuenta que no es la del número, igual de muda.
 *
 * Idempotente: "Actualizar credenciales" la repite y de paso repara una
 * suscripción que alguien quitó a mano. El campo `messages` del webhook es
 * configuración de la app y lo sigue activando el cliente en Meta.
 */
export async function subscribeAppToWaba(params: {
  phoneNumberId: string;
  wabaId: string;
  accessToken: string;
  appSecret: string;
}): Promise<void> {
  const { phoneNumberId, wabaId, accessToken } = params;
  const proof = `appsecret_proof=${appSecretProof(accessToken, params.appSecret)}`;
  const explain = (what: string, err: unknown) =>
    new CloudApiError(
      `${what} Revisa que el WABA ID sea el de la cuenta donde está este número y que el token tenga el permiso whatsapp_business_management.` +
        (err instanceof CloudApiError ? ` Detalle de Meta: ${err.details ?? err.message}` : ''),
      { httpStatus: 400, code: err instanceof CloudApiError ? err.code : undefined },
    );

  let numbers: { data?: Array<{ id?: string }> };
  try {
    numbers = await graphApiJson(`/${wabaId}/phone_numbers?fields=id&limit=100&${proof}`, accessToken);
  } catch (err) {
    if (err instanceof CloudApiError) throw explain('No se pudo leer la cuenta de WhatsApp Business (WABA).', err);
    throw err;
  }
  if (!(numbers.data ?? []).some((n) => n.id === phoneNumberId)) {
    throw new CloudApiError(
      'El Phone Number ID no pertenece a ese WABA ID. Cópialos los dos de la misma pantalla de Meta (WhatsApp → Configuración de la API).',
      { httpStatus: 400 },
    );
  }

  let result: { success?: boolean };
  try {
    result = await graphApiJson(`/${wabaId}/subscribed_apps?${proof}`, accessToken, { method: 'POST' });
  } catch (err) {
    if (err instanceof CloudApiError) {
      throw explain('Meta no dejó suscribir tu app a la cuenta de WhatsApp Business, y sin eso no llegan los mensajes de tus clientes.', err);
    }
    throw err;
  }
  if (result?.success !== true) {
    throw explain('Meta no confirmó la suscripción de tu app a la cuenta de WhatsApp Business.', null);
  }
}

export type CloudApiRejectReason =
  | 'wrong_number'
  | 'deleting'
  | 'phone_number_id_in_use'
  | 'in_use'
  | 'number_replaced'
  | 'qr_session_exists';

export interface CloudApiTargetFacts {
  accountId: string;
  // Número verificado con Meta, en dígitos: es el id del doc.
  digits: string;
  // La sesión que se está editando ("Actualizar credenciales"). Sin él, es un alta.
  intoSessionId?: string;
  // El doc `whatsapp_sessions/{digits}` tal como está.
  ownDoc: { exists: boolean; deleting?: boolean; provider?: string; phone?: string };
  // Ids de los docs de esta cuenta cuyo `phone_number` es `digits`.
  adoptedBy: string[];
  // Sesiones Cloud API en memoria, de cualquier cuenta, con este `phone_number_id`.
  phoneNumberIdOwners: Array<{ accountId: string; sessionId: string }>;
}

export type CloudApiTargetDecision =
  | { kind: 'connect'; sessionId: string; isNew: boolean }
  | { kind: 'reject'; reason: CloudApiRejectReason };

/**
 * A qué doc escribe un alta de Cloud API, o por qué no escribe en ninguno. Pura
 * a propósito, como `decideSessionTarget`: las reglas viven en
 * cloudApiService.test.ts.
 *
 * El alta escribía `set(merge)` sobre `{digits}` sin mirar qué había: pisaba
 * lápidas, convertía en Cloud API una sesión QR viva del mismo número (su socket
 * seguía escribiendo `status`) y dejaba conectar el mismo `phone_number_id` en
 * dos cuentas, con lo que el webhook entregaba los mensajes de una empresa en
 * el CRM de la otra.
 */
export function decideCloudApiTarget(f: CloudApiTargetFacts): CloudApiTargetDecision {
  // Credenciales de otro número nunca cambian el número de una sesión: mismo
  // principio que el QR leído con el teléfono equivocado.
  if (f.intoSessionId && f.intoSessionId !== f.digits) return { kind: 'reject', reason: 'wrong_number' };
  if (f.ownDoc.deleting) return { kind: 'reject', reason: 'deleting' };
  if (f.phoneNumberIdOwners.some((o) => o.accountId !== f.accountId || o.sessionId !== f.digits)) {
    return { kind: 'reject', reason: 'phone_number_id_in_use' };
  }
  // El número ya es el de otra sesión de la cuenta (una que cambió de número).
  if (f.adoptedBy.some((id) => id !== f.digits)) return { kind: 'reject', reason: 'in_use' };
  if (f.ownDoc.exists) {
    // El id lo ocupa una sesión que cambió a otro número y sólo conserva el id.
    if ((f.ownDoc.phone ?? f.digits) !== f.digits) return { kind: 'reject', reason: 'number_replaced' };
    // Pasar una sesión QR a Cloud API conservando su historial es fase 2.
    if (f.ownDoc.provider !== 'cloud_api') return { kind: 'reject', reason: 'qr_session_exists' };
  }
  return { kind: 'connect', sessionId: f.digits, isNew: !f.ownDoc.exists };
}

// Lo que lee el owner en la hoja de conexión.
function rejectMessage(reason: CloudApiRejectReason, digits: string): string {
  switch (reason) {
    case 'wrong_number':
      return `Estas credenciales son del número +${digits}, no de esta sesión. Para conectar otro número usa "Agregar número".`;
    case 'deleting':
      return 'Esa sesión se está eliminando. Espera a que termine para volver a conectar este número.';
    case 'phone_number_id_in_use':
      return 'Este número de Meta ya está conectado en otra cuenta o sesión de WhatHero.';
    case 'in_use':
      return 'Este número ya es el de otra de tus sesiones.';
    case 'number_replaced':
      return 'Este número fue reemplazado por otro en una de tus sesiones y no puede volver como sesión aparte.';
    case 'qr_session_exists':
      return 'Este número ya está vinculado por código QR. Pasarlo a Cloud API conservando el historial todavía no está disponible.';
  }
}

function rejectError(reason: CloudApiRejectReason, digits: string): CloudApiError {
  return new CloudApiError(rejectMessage(reason, digits), { httpStatus: 409, reason });
}

/**
 * Conecta un número de Cloud API (alta, o credenciales nuevas para una sesión
 * Cloud API que ya existe) y lo deja activo en el mapa `sessions`.
 *
 * Orden: verificar con Meta → decidir → suscribir la app al WABA → secreto →
 * doc. El doc nunca dice "connected" sin su secreto (el arranque no podría
 * hidratarlo), y lo escribe `initializeSession`, el único que crea docs de
 * sesión: no escribe sobre una
 * lápida, pone `connected_at` (por ahí ordena "Mis Cuentas") y levanta
 * `isSessionGone` si el número vuelve después de haberse eliminado.
 */
export async function connectCloudApiSession(params: {
  accountId: string;
  phoneNumberId: string;
  wabaId: string;
  accessToken: string;
  appSecret?: string;
  alias?: string;
  intoSessionId?: string;
}): Promise<{
  sessionId: string;
  sessionKey: string;
  displayPhoneNumber: string;
  verifiedName: string;
  qualityRating?: string;
}> {
  const { db, sessions, loadAllSessionConfigs } = requireDeps();
  const account = db.collection(ACCOUNTS_COLLECTION).doc(params.accountId);

  // Sin App Secret no hay cómo comprobar sus webhooks: producción los
  // rechazaría todos. "Actualizar credenciales" puede dejarlo vacío para
  // conservar el que ya estaba guardado.
  let appSecret = params.appSecret?.trim() || undefined;
  if (!appSecret && params.intoSessionId) {
    const stored = await account.collection('cloud_api_secrets').doc(params.intoSessionId).get();
    appSecret = stored.data()?.appSecret || undefined;
  }
  if (!appSecret) {
    throw new CloudApiError(
      'Falta el App Secret: WhatHero lo usa para comprobar que los mensajes que llegan vienen de Meta. Está en Meta for Developers → tu app → Configuración de la app → Básica.',
      { httpStatus: 400 },
    );
  }

  const verified = await verifyCloudApiCredentials({ ...params, appSecret });

  const sessionId = verified.sessionId;
  const sessionKey = `${params.accountId}_${sessionId}`;
  const phoneNumberId = params.phoneNumberId.trim();
  const wabaId = params.wabaId.trim();
  const accessToken = params.accessToken.trim();
  const alias = params.alias?.trim();

  const [ownSnap, adoptedSnap] = await Promise.all([
    account.collection('whatsapp_sessions').doc(sessionId).get(),
    account.collection('whatsapp_sessions').where('phone_number', '==', sessionId).get(),
  ]);
  const own = ownSnap.data();
  // Todas las sesiones Cloud API se hidratan al arrancar, así que la memoria
  // alcanza para saber quién más usa este `phone_number_id`.
  const phoneNumberIdOwners = [...sessions.values()]
    .filter((s) => s.provider === 'cloud_api' && s.cloudApi?.phoneNumberId === phoneNumberId && s.sessionId)
    .map((s) => ({ accountId: s.accountId, sessionId: s.sessionId! }));

  const decision = decideCloudApiTarget({
    accountId: params.accountId,
    digits: sessionId,
    intoSessionId: params.intoSessionId,
    ownDoc: {
      exists: ownSnap.exists,
      deleting: !!own?.deleting_at,
      provider: own?.provider,
      phone: own?.phone_number,
    },
    adoptedBy: adoptedSnap.docs.map((d) => d.id),
    phoneNumberIdOwners,
  });
  if (decision.kind === 'reject') {
    console.warn(`[CloudAPI] Alta rechazada (${decision.reason}): ${params.accountId}/${sessionId}`);
    throw rejectError(decision.reason, sessionId);
  }

  // Antes de escribir nada: si la app no queda recibiendo los webhooks del
  // número, la sesión estaría "conectada" y muda.
  await subscribeAppToWaba({ phoneNumberId, wabaId, accessToken, appSecret });

  // El access token y el App Secret viven fuera de `whatsapp_sessions`:
  // `cloud_api_secrets` no tiene regla en firestore.rules, así que ningún
  // cliente los lee (lo fija rules-tests/).
  await account.collection('cloud_api_secrets').doc(sessionId).set(
    {
      phoneNumberId,
      wabaId,
      accessToken,
      appSecret,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  const init = await initializeSession(sessionId, sessionId, sessionKey, params.accountId, {
    provider: 'cloud_api',
    cloud_api_phone_number_id: phoneNumberId,
    cloud_api_waba_id: wabaId,
    cloud_api_verified_name: verified.verifiedName,
    cloud_api_display_phone: verified.displayPhoneNumber,
    cloud_api_token_hint: maskAccessToken(accessToken),
    ...(verified.qualityRating && { cloud_api_quality_rating: verified.qualityRating }),
    ...(alias && { alias }),
    qr_code: admin.firestore.FieldValue.delete(),
    status_reason: admin.firestore.FieldValue.delete(),
  });
  // El borrado empezó entre la decisión y la escritura.
  if (init.deleting) throw rejectError('deleting', sessionId);
  if (init.failed) {
    throw new CloudApiError('No se pudo guardar la sesión en WhatHero. Intenta de nuevo.', { httpStatus: 500 });
  }

  // Hidratar la sesión en memoria con su adaptador `sock`.
  const existingMem = sessions.get(sessionKey);
  const sock = createCloudApiSocket(sessionKey, params.accountId, sessionId);
  const sessionData: SessionData = {
    sock,
    currentQR: undefined,
    isReady: true,
    sessionId,
    linkedPhone: sessionId,
    role: 'primary',
    reconnectCount: 0,
    accountId: params.accountId,
    provider: 'cloud_api',
    cloudApi: {
      phoneNumberId,
      wabaId,
      accessToken,
      appSecret,
      verifiedName: verified.verifiedName,
    },
    generation: (existingMem?.generation ?? 0) + 1,
    socketStartedAt: Date.now(),
    lastConnectedAt: Date.now(),
    lastWrittenStatus: 'connected',
    contactNames: existingMem?.contactNames ?? new Map(),
    pendingSenders: existingMem?.pendingSenders ?? new Map(),
    unreadKeys: existingMem?.unreadKeys ?? new Map(),
    aiConfig: existingMem?.aiConfig,
  };

  sessions.set(sessionKey, sessionData);
  await loadAllSessionConfigs(sessionKey, params.accountId, sessionId);

  console.log(
    `[CloudAPI] ✅ Sesión ${decision.isNew ? 'conectada' : 'actualizada'}: ${sessionKey} (${verified.displayPhoneNumber} - ${verified.verifiedName})`,
  );

  return {
    sessionId,
    sessionKey,
    displayPhoneNumber: verified.displayPhoneNumber,
    verifiedName: verified.verifiedName,
    qualityRating: verified.qualityRating,
  };
}

// Recarga completa de las sesiones Cloud API: al arrancar y, como mucho una vez
// cada 5 min, cuando llega un webhook de un `phone_number_id` desconocido.
const FULL_LOAD_MIN_INTERVAL_MS = 5 * 60_000;
let lastFullLoadAt = 0;
let fullLoadInFlight: Promise<void> | null = null;

/**
 * Carga en memoria las sesiones Cloud API de todas las cuentas, para que el
 * supervisor no las dé por fantasmas (`sweepFirestoreGhosts`) y el webhook las
 * encuentre.
 *
 * - Salta las lápidas (`deleting_at`, `isSessionGone`): hidratar una haría que
 *   sus mensajes siguieran entrando y recrearan el subárbol que el job borra.
 * - No recrea las que ya están en memoria: perderían `contactNames`,
 *   `pendingSenders` y `aiConfig`.
 * - El `status` sólo lo escribe `writeSessionStatus` (update, único escritor).
 */
export function loadCloudApiSessionsOnBoot(): Promise<void> {
  if (fullLoadInFlight) return fullLoadInFlight;
  lastFullLoadAt = Date.now();
  fullLoadInFlight = loadAllCloudApiSessions().finally(() => {
    fullLoadInFlight = null;
  });
  return fullLoadInFlight;
}

async function loadAllCloudApiSessions(): Promise<void> {
  const { db } = requireDeps();
  let accounts: admin.firestore.DocumentReference[];
  try {
    // `listDocuments` y no `get`: incluye las cuentas sin doc propio (owners
    // antiguos). Con `get` sus sesiones Cloud API no se hidrataban nunca.
    accounts = await db.collection(ACCOUNTS_COLLECTION).listDocuments();
  } catch (err) {
    console.error('[CloudAPI] No se pudieron listar las cuentas para hidratar Cloud API:', err);
    return;
  }

  let loadedCount = 0;
  for (const account of accounts) {
    // Una cuenta con datos raros no puede dejar sin hidratar al resto.
    try {
      loadedCount += await hydrateAccountCloudSessions(account);
    } catch (err) {
      console.error(`[CloudAPI] No se pudieron hidratar las sesiones Cloud API de ${account.id}:`, err);
    }
  }

  if (loadedCount > 0) {
    console.log(`[CloudAPI] 🚀 ${loadedCount} sesión(es) de Meta Cloud API hidratadas en memoria.`);
  }
}

async function hydrateAccountCloudSessions(account: admin.firestore.DocumentReference): Promise<number> {
  const { sessions, loadAllSessionConfigs } = requireDeps();
  const accountId = account.id;
  const sessionsSnap = await account.collection('whatsapp_sessions').where('provider', '==', 'cloud_api').get();

  let loaded = 0;
  for (const sDoc of sessionsSnap.docs) {
    const sData = sDoc.data();
    const sessionId = sDoc.id;
    const sessionKey = `${accountId}_${sessionId}`;
    if (sData.deleting_at || isSessionGone(accountId, sessionId)) continue;
    if (sessions.has(sessionKey)) continue;

    const secretSnap = await account.collection('cloud_api_secrets').doc(sessionId).get();
    const secretData = secretSnap.data();
    const phoneNumberId: string | undefined = secretData?.phoneNumberId || sData.cloud_api_phone_number_id;
    const wabaId: string | undefined = secretData?.wabaId || sData.cloud_api_waba_id;
    const accessToken: string | undefined = secretData?.accessToken;
    const appSecret: string | undefined = secretData?.appSecret || undefined;

    if (!phoneNumberId || !wabaId || !accessToken) {
      console.warn(`[CloudAPI] Sesión ${sessionKey} omitida: faltan secretos en cloud_api_secrets`);
      continue;
    }
    if (!appSecret && !getMetaAppSecret() && IS_PRODUCTION) {
      console.error(
        `[CloudAPI] Sesión ${sessionKey} sin App Secret: sus webhooks se rechazan hasta que el owner la reconecte con él.`,
      );
    }
    // La pudo conectar /connect mientras leíamos el secreto.
    if (sessions.has(sessionKey)) continue;

    const session: SessionData = {
      sock: createCloudApiSocket(sessionKey, accountId, sessionId),
      currentQR: undefined,
      isReady: true,
      sessionId,
      linkedPhone: sessionId,
      role: 'primary',
      reconnectCount: 0,
      accountId,
      provider: 'cloud_api',
      cloudApi: {
        phoneNumberId,
        wabaId,
        accessToken,
        appSecret,
        verifiedName: sData.cloud_api_verified_name || 'WhatsApp Cloud API',
      },
      generation: 1,
      socketStartedAt: Date.now(),
      lastConnectedAt: Date.now(),
      lastWrittenStatus: 'connected',
      contactNames: new Map(),
      pendingSenders: new Map(),
      unreadKeys: new Map(),
    };
    sessions.set(sessionKey, session);

    await writeSessionStatus(session, 'connected', { session_key: sessionKey });
    await loadAllSessionConfigs(sessionKey, accountId, sessionId);
    loaded++;
  }
  return loaded;
}

export interface MetaTemplateSummary {
  id: string;
  name: string;
  status: string;
  category: string;
  language: string;
  parameter_format?: string;
  quality_score?: { score?: string; date?: number };
  rejected_reason?: string;
  components: Array<{
    type: string;
    format?: string;
    text?: string;
    buttons?: Array<{ type: string; text: string; url?: string; phone_number?: string }>;
    example?: any;
  }>;
}

// Las llamadas de administración de plantillas no pueden colgar un request para
// siempre si Graph no contesta.
const TEMPLATE_API_TIMEOUT_MS = 20_000;
// 100 por página × 10 = 1 000 plantillas. Meta permite hasta 6 000 por WABA
// verificado; más allá de esto el selector dejaría de ser usable de todos modos.
const MAX_TEMPLATE_PAGES = 10;
const TEMPLATE_BASE_FIELDS = 'id,name,status,category,language,components,parameter_format';
// Si Graph deja de reconocer alguno, se piden sólo los básicos: perder el motivo
// de rechazo no puede dejar a nadie sin poder enviar.
const TEMPLATE_EXTRA_FIELDS = 'quality_score,rejected_reason';
let warnedTemplateExtraFields = false;

/** WABA y token de una sesión Cloud API: de memoria o, si no está cargada, del secreto. */
async function resolveWabaCredentials(
  accountId: string,
  sessionId: string,
): Promise<{ wabaId: string; accessToken: string }> {
  const { sessions, db } = requireDeps();
  if (isSessionGone(accountId, sessionId)) {
    throw new CloudApiError('Esta sesión fue eliminada', { httpStatus: 410 });
  }
  const live = sessions.get(`${accountId}_${sessionId}`)?.cloudApi;
  let wabaId = live?.wabaId;
  let accessToken = live?.accessToken;

  if (!wabaId || !accessToken) {
    const secretSnap = await db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('cloud_api_secrets')
      .doc(sessionId)
      .get();
    const secret = secretSnap.data();
    wabaId = secret?.wabaId;
    accessToken = secret?.accessToken;
  }

  if (!wabaId || !accessToken) {
    throw new CloudApiError('Esta sesión no tiene credenciales de Meta Cloud API configuradas', {
      httpStatus: 400,
    });
  }
  return { wabaId, accessToken };
}

async function fetchAllTemplates(wabaId: string, accessToken: string, fields: string): Promise<MetaTemplateSummary[]> {
  const all: MetaTemplateSummary[] = [];
  let next = `/${wabaId}/message_templates?fields=${fields}&limit=100`;
  for (let page = 0; page < MAX_TEMPLATE_PAGES && next; page++) {
    const res = await graphApiJson<{ data?: MetaTemplateSummary[]; paging?: { next?: string } }>(next, accessToken, {
      signal: AbortSignal.timeout(TEMPLATE_API_TIMEOUT_MS),
    });
    if (Array.isArray(res?.data)) all.push(...res.data);
    next = res?.paging?.next || '';
  }
  return all;
}

/**
 * Todas las plantillas del WABA de la sesión, en cualquier estado. Siempre se
 * leen de Meta, no de una copia: el estado de revisión cambia allá (aprobada,
 * pausada, recategorizada) y una copia nuestra se desincronizaría.
 */
export async function listMetaTemplates(params: {
  accountId: string;
  sessionId: string;
}): Promise<MetaTemplateSummary[]> {
  const { wabaId, accessToken } = await resolveWabaCredentials(params.accountId, params.sessionId);

  let list: MetaTemplateSummary[];
  try {
    list = await fetchAllTemplates(wabaId, accessToken, `${TEMPLATE_BASE_FIELDS},${TEMPLATE_EXTRA_FIELDS}`);
  } catch (err) {
    // #100 = "Tried accessing nonexisting field".
    if (!(err instanceof CloudApiError) || err.code !== 100) throw err;
    if (!warnedTemplateExtraFields) {
      warnedTemplateExtraFields = true;
      console.warn(`[CloudAPI] Graph rechazó ${TEMPLATE_EXTRA_FIELDS} al listar plantillas: se piden sólo los campos básicos.`, err.message);
    }
    list = await fetchAllTemplates(wabaId, accessToken, TEMPLATE_BASE_FIELDS);
  }

  // Priorizar plantillas APPROVED y poner `hello_world` primero si está presente para pruebas rápidas.
  return list.sort((a, b) => {
    const aApproved = a.status === 'APPROVED' ? 0 : 1;
    const bApproved = b.status === 'APPROVED' ? 0 : 1;
    if (aApproved !== bApproved) return aApproved - bApproved;
    if (a.name === 'hello_world' && b.name !== 'hello_world') return -1;
    if (b.name === 'hello_world' && a.name !== 'hello_world') return 1;
    return a.name.localeCompare(b.name);
  });
}

/**
 * Manda a revisión una plantilla ya validada (`validateTemplateDraft`). Meta
 * contesta con la categoría que ELLA le asignó, que puede no ser la pedida: la
 * reclasificación es automática desde abr-2025.
 */
export async function createMetaTemplate(params: {
  accountId: string;
  sessionId: string;
  draft: TemplateDraft;
}): Promise<{ id: string; status: string; category: string }> {
  const { wabaId, accessToken } = await resolveWabaCredentials(params.accountId, params.sessionId);
  const res = await graphApiJson<{ id?: string; status?: string; category?: string }>(
    `/${wabaId}/message_templates`,
    accessToken,
    {
      method: 'POST',
      body: JSON.stringify(buildCreateTemplatePayload(params.draft)),
      signal: AbortSignal.timeout(TEMPLATE_API_TIMEOUT_MS),
    },
  );
  return {
    id: String(res?.id ?? ''),
    status: String(res?.status ?? 'PENDING'),
    category: String(res?.category ?? params.draft.category),
  };
}

/**
 * Borra UNA plantilla (ese idioma). Por `hsm_id` + `name`: con `name` a secas
 * Meta borra el nombre en todos los idiomas. Si estaba aprobada, Meta no deja
 * crear otra con ese nombre durante 30 días.
 */
export async function deleteMetaTemplate(params: {
  accountId: string;
  sessionId: string;
  templateId: string;
  name: string;
}): Promise<void> {
  const { wabaId, accessToken } = await resolveWabaCredentials(params.accountId, params.sessionId);
  const query = new URLSearchParams({ hsm_id: params.templateId, name: params.name });
  await graphApiJson(`/${wabaId}/message_templates?${query.toString()}`, accessToken, {
    method: 'DELETE',
    signal: AbortSignal.timeout(TEMPLATE_API_TIMEOUT_MS),
  });
}

/**
 * Envía una plantilla aprobada de Meta (`type: 'template'`) y persiste la
 * burbuja en Firestore pasando por el flujo estándar (`onUpsertedMessage`).
 */
export async function sendMetaTemplate(params: {
  accountId: string;
  sessionId: string;
  to: string;
  templateName: string;
  languageCode: string;
  components?: any[];
  renderedPreviewText?: string;
  sender: SenderInfo;
  clientTempId?: string | null;
}): Promise<{ wamid: string; chatPhone: string }> {
  const { sessions, onUpsertedMessage } = requireDeps();
  const sessionKey = `${params.accountId}_${params.sessionId}`;
  const session = sessions.get(sessionKey);

  if (!session || session.provider !== 'cloud_api' || !session.cloudApi) {
    throw new CloudApiError('La sesión seleccionada no es una sesión activa de Meta Cloud API', {
      httpStatus: 400,
    });
  }

  const { phoneNumberId, accessToken } = session.cloudApi;
  const canonicalPhone = await resolveCanonicalChatPhone(
    params.accountId,
    params.sessionId,
    params.to,
    session,
  );
  const canonicalJid = `${canonicalPhone}@s.whatsapp.net`;

  const templatePayload: Record<string, any> = {
    name: params.templateName,
    language: {
      code: params.languageCode || 'en_US',
    },
  };
  if (Array.isArray(params.components) && params.components.length > 0) {
    templatePayload.components = sanitizeTemplateSendComponents(params.components);
  }

  const { wamid } = await sendGraphMessageWithRetry(
    phoneNumberId,
    accessToken,
    canonicalPhone,
    (recipient) => ({
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: recipient,
      type: 'template',
      template: templatePayload,
    }),
  );

  // Registrar el remitente humano/sistema antes de disparar `onUpsertedMessage`.
  session.pendingSenders.set(wamid, {
    ...params.sender,
    ...(params.clientTempId ? { tempId: params.clientTempId } : {}),
  });

  const displayBody =
    params.renderedPreviewText?.trim() ||
    `📋 Plantilla: ${params.templateName} (${params.languageCode || 'en_US'})`;

  const syntheticTemplateMsg: any = {
    key: {
      remoteJid: canonicalJid,
      fromMe: true,
      id: wamid,
    },
    messageTimestamp: Math.floor(Date.now() / 1000),
    message: {
      conversation: displayBody,
    },
    __extraMessageFields: {
      isTemplate: true,
      templateName: params.templateName,
      templateLanguage: params.languageCode || 'en_US',
    },
  };

  await onUpsertedMessage(sessionKey, params.accountId, session.sock, syntheticTemplateMsg, 'notify');

  return { wamid, chatPhone: canonicalPhone };
}

function findCloudSessionByPhoneNumberId(phoneNumberId: string): { sessionKey: string; session: SessionData } | null {
  const { sessions } = requireDeps();
  for (const [sessionKey, session] of sessions.entries()) {
    if (session.provider === 'cloud_api' && session.cloudApi?.phoneNumberId === phoneNumberId) {
      return { sessionKey, session };
    }
  }
  return null;
}

/**
 * La sesión a la que va un webhook de Meta. **Sólo por `phone_number_id`**: el
 * `display_phone_number` es público y además puede coincidir con una sesión de
 * otra cuenta.
 *
 * Todas las sesiones se hidratan al arrancar y al conectar, así que un id
 * desconocido casi siempre es un número que no está conectado en este entorno
 * (el de prueba conectado en dev con el webhook apuntando a Railway, o uno
 * eliminado). Releer todas las cuentas por cada uno era una tormenta de
 * lecturas: se recarga como mucho cada 5 min, por si el arranque falló.
 */
async function findSessionForWebhookMetadata(metadata: {
  phone_number_id?: string;
}): Promise<{ sessionKey: string; session: SessionData } | null> {
  const phoneNumberId = metadata?.phone_number_id?.trim();
  if (!phoneNumberId) return null;

  const found = findCloudSessionByPhoneNumberId(phoneNumberId);
  if (found) return found;

  // Si ya hay una recarga en curso se espera a ésa: tirar el webhook mientras
  // otra lo estaba por encontrar perdería el mensaje.
  if (fullLoadInFlight || Date.now() - lastFullLoadAt >= FULL_LOAD_MIN_INTERVAL_MS) {
    await loadCloudApiSessionsOnBoot();
    return findCloudSessionByPhoneNumberId(phoneNumberId);
  }
  return null;
}

// Un número ajeno puede mandar cientos de estados por hora: un aviso cada 10 min
// por clave alcanza para diagnosticar.
const WEBHOOK_WARN_EVERY_MS = 10 * 60_000;
const webhookWarnedAt = new Map<string, number>();

function warnWebhookThrottled(key: string, message: string): void {
  const now = Date.now();
  if (now - (webhookWarnedAt.get(key) ?? 0) < WEBHOOK_WARN_EVERY_MS) return;
  if (webhookWarnedAt.size > 1000) webhookWarnedAt.clear();
  webhookWarnedAt.set(key, now);
  console.warn(message);
}

// Orden de los acuses de Meta. `failed` es terminal: sólo llega en lugar de los
// otros, nunca después de un `delivered`.
const DELIVERY_RANK: Record<string, number> = { sent: 1, delivered: 2, read: 3, failed: 4 };

/**
 * ¿`next` avanza el estado de entrega? Meta avisa que los webhooks pueden llegar
 * desordenados, y un `delivered` tardío que pisara un `read` volvería gris la
 * ✓✓ azul. Un estado desconocido no se aplica.
 */
export function isDeliveryStatusAdvance(current: unknown, next: string): boolean {
  return (DELIVERY_RANK[next] ?? 0) > (DELIVERY_RANK[String(current)] ?? 0);
}

/**
 * Procesa el payload de eventos entrantes del webhook de Meta (`POST /webhook/meta`):
 * - Mensajes entrantes de clientes (texto, botones/interactivos, reacciones, imágenes, videos, audios, documentos, stickers)
 * - Actualizaciones de nombre de perfil (`contacts`)
 * - Estados de entrega (`statuses`: sent, delivered, read, failed)
 */
export async function handleMetaWebhookPayload(body: any, auth?: MetaWebhookAuth): Promise<void> {
  if (!body || body.object !== 'whatsapp_business_account' || !Array.isArray(body.entry)) {
    return;
  }

  const { db, onUpsertedMessage } = requireDeps();

  for (const entry of body.entry) {
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const value = change?.value;
      if (!value || value.messaging_product !== 'whatsapp') continue;

      const match = await findSessionForWebhookMetadata(value.metadata || {});
      if (!match || !match.session.sessionId) {
        const phoneNumberId = value.metadata?.phone_number_id || '(sin phone_number_id)';
        warnWebhookThrottled(
          `unknown:${phoneNumberId}`,
          `[CloudAPI Webhook] No hay sesión conectada para phone_number_id=${phoneNumberId}; se descarta.`,
        );
        continue;
      }

      const { sessionKey, session } = match;
      // Antes de tocar nada: si no lo firmó la app de esta sesión, no existe.
      if (!isSignedBySessionApp(session, auth)) {
        warnWebhookThrottled(
          `signature:${sessionKey}`,
          `[CloudAPI Webhook] ❌ Firma inválida para ${sessionKey}: se descarta. ¿El App Secret guardado es el de la app que manda el webhook?`,
        );
        continue;
      }
      const accountId = session.accountId;
      const sessionId = session.sessionId;
      if (!sessionId) continue;

      // 1. Procesar contactos (`value.contacts`) para cachear el nombre del cliente.
      const contacts = Array.isArray(value.contacts) ? value.contacts : [];
      for (const c of contacts) {
        const waId = c?.wa_id ? normalizePhoneDigits(String(c.wa_id)) : '';
        const profileName = c?.profile?.name ? String(c.profile.name).trim() : '';
        if (waId && profileName) {
          const canonicalPhone = await resolveCanonicalChatPhone(accountId, sessionId, waId, session);
          session.contactNames.set(canonicalPhone, profileName);
        }
      }

      // 2. Procesar mensajes entrantes (`value.messages`).
      const messages = Array.isArray(value.messages) ? value.messages : [];
      for (const msg of messages) {
        const wamid = String(msg?.id || '');
        if (!wamid || !markWebhookMessageProcessed(wamid)) {
          continue;
        }

        const rawFrom = String(msg?.from || '');
        const canonicalPhone = await resolveCanonicalChatPhone(accountId, sessionId, rawFrom, session);
        const remoteJid = `${canonicalPhone}@s.whatsapp.net`;
        const msgTsSeconds = msg?.timestamp ? Number(msg.timestamp) : Math.floor(Date.now() / 1000);
        const quotedWamid: string | undefined = msg?.context?.id;

        const buildContextInfo = () => {
          if (!quotedWamid) return undefined;
          return {
            stanzaId: quotedWamid,
            quotedMessage: { conversation: '' },
          };
        };

        const msgType: string = msg?.type || 'unknown';
        let syntheticMessage: any = null;
        let pendingMediaDownload: {
          metaMediaId: string;
          fallbackMime: string;
        } | null = null;

        if (msgType === 'text') {
          const textBody = msg.text?.body ?? '';
          const contextInfo = buildContextInfo();
          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: contextInfo
              ? { extendedTextMessage: { text: textBody, contextInfo } }
              : { conversation: textBody },
          };
        } else if (msgType === 'button') {
          const textBody = msg.button?.text || msg.button?.payload || '';
          const contextInfo = buildContextInfo();
          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: contextInfo
              ? { extendedTextMessage: { text: textBody, contextInfo } }
              : { conversation: textBody },
          };
        } else if (msgType === 'interactive') {
          const reply = msg.interactive?.button_reply || msg.interactive?.list_reply;
          const textBody = reply?.title
            ? reply.description
              ? `${reply.title} — ${reply.description}`
              : reply.title
            : '[Respuesta interactiva]';
          const contextInfo = buildContextInfo();
          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: contextInfo
              ? { extendedTextMessage: { text: textBody, contextInfo } }
              : { conversation: textBody },
          };
        } else if (msgType === 'reaction') {
          const targetId = msg.reaction?.message_id;
          const emoji = msg.reaction?.emoji ?? '';
          if (targetId) {
            syntheticMessage = {
              key: { remoteJid, fromMe: false, id: wamid },
              messageTimestamp: msgTsSeconds,
              message: {
                reactionMessage: {
                  key: { remoteJid, id: targetId },
                  text: emoji,
                },
              },
            };
          }
        } else if (
          msgType === 'image' ||
          msgType === 'video' ||
          msgType === 'audio' ||
          msgType === 'document' ||
          msgType === 'sticker'
        ) {
          const mediaObj = msg[msgType] || {};
          const metaMediaId: string | undefined = mediaObj.id;
          const mimeType: string = mediaObj.mime_type || 'application/octet-stream';
          const caption: string = mediaObj.caption || '';
          const fileName: string | undefined = mediaObj.filename;
          const isVoice: boolean = !!mediaObj.voice;
          const contextInfo = buildContextInfo();

          const innerMsg: Record<string, any> = {};
          if (msgType === 'image') {
            innerMsg.imageMessage = { caption, mimetype: mimeType, ...(contextInfo && { contextInfo }) };
          } else if (msgType === 'video') {
            innerMsg.videoMessage = { caption, mimetype: mimeType, ...(contextInfo && { contextInfo }) };
          } else if (msgType === 'audio') {
            innerMsg.audioMessage = {
              mimetype: mimeType,
              ptt: isVoice,
              ...(contextInfo && { contextInfo }),
            };
          } else if (msgType === 'document') {
            innerMsg.documentMessage = {
              caption,
              mimetype: mimeType,
              fileName: fileName || 'Documento',
              ...(contextInfo && { contextInfo }),
            };
          } else if (msgType === 'sticker') {
            innerMsg.stickerMessage = { mimetype: mimeType, ...(contextInfo && { contextInfo }) };
          }

          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: innerMsg,
            __cloudMediaFields: {
              mediaType: msgType,
              mediaMime: mimeType,
              ...(fileName && { mediaFileName: fileName }),
              ...(msgType === 'audio' && { mediaIsPtt: isVoice }),
              mediaStatus: metaMediaId ? 'pending' : 'failed',
            },
          };

          if (metaMediaId) {
            pendingMediaDownload = {
              metaMediaId,
              fallbackMime: mimeType,
            };
          }
        } else if (msgType === 'location') {
          const loc = msg.location || {};
          const label = loc.name || loc.address || `${loc.latitude ?? ''}, ${loc.longitude ?? ''}`;
          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: {
              conversation: `📍 Ubicación: ${label}`.trim(),
            },
          };
        } else if (msgType === 'contacts') {
          const firstContact = Array.isArray(msg.contacts) ? msg.contacts[0] : null;
          const cName = firstContact?.name?.formatted_name || 'Contacto';
          const cPhone = firstContact?.phones?.[0]?.phone || '';
          syntheticMessage = {
            key: { remoteJid, fromMe: false, id: wamid },
            messageTimestamp: msgTsSeconds,
            message: {
              conversation: `👤 Contacto: ${cName}${cPhone ? ` (${cPhone})` : ''}`,
            },
          };
        }

        if (syntheticMessage) {
          await onUpsertedMessage(sessionKey, accountId, session.sock, syntheticMessage, 'notify');

          if (pendingMediaDownload && session.cloudApi?.accessToken) {
            downloadIncomingMetaMediaAndPersist({
              accountId,
              sessionId,
              chatPhone: canonicalPhone,
              messageId: wamid,
              metaMediaId: pendingMediaDownload.metaMediaId,
              accessToken: session.cloudApi.accessToken,
              fallbackMime: pendingMediaDownload.fallbackMime,
            }).catch((err) =>
              console.error(`[CloudAPI Webhook] Error en descarga async de media ${wamid}:`, err),
            );
          }
        }
      }

      // 3. Procesar estados de entrega (`value.statuses`: sent, delivered, read, failed).
      const statuses = Array.isArray(value.statuses) ? value.statuses : [];
      for (const st of statuses) {
        const wamid = String(st?.id || '');
        const statusValue = String(st?.status || '');
        const recipientId = String(st?.recipient_id || '');
        if (!wamid || !statusValue || !recipientId) continue;

        try {
          const canonicalPhone = await resolveCanonicalChatPhone(
            accountId,
            sessionId,
            recipientId,
            session,
          );
          const msgRef = db
            .collection(ACCOUNTS_COLLECTION)
            .doc(accountId)
            .collection('whatsapp_sessions')
            .doc(sessionId)
            .collection('chats')
            .doc(canonicalPhone)
            .collection('messages')
            .doc(wamid);

          const statusPatch: Record<string, any> = {
            deliveryStatus: statusValue,
          };
          if (statusValue === 'failed' && Array.isArray(st.errors) && st.errors.length > 0) {
            const firstErr = st.errors[0];
            const errCode = firstErr?.code ? `[Meta #${firstErr.code}] ` : '';
            const errDetail =
              firstErr?.error_data?.details || firstErr?.title || firstErr?.message || 'Envío rechazado';
            statusPatch.deliveryError = `${errCode}${errDetail}`;
          }
          // Sin doc no se crea nada: ese mensaje no salió de WhatHero (lo mandó el
          // panel de Meta u otra herramienta) y no hay burbuja que marcar.
          await db.runTransaction(async (tx) => {
            const snap = await tx.get(msgRef);
            if (!snap.exists) return;
            if (!isDeliveryStatusAdvance(snap.get('deliveryStatus'), statusValue)) return;
            tx.update(msgRef, statusPatch);
          });
        } catch {
          // Ignorar silenciosamente si el documento no existe.
        }
      }
    }
  }
}
