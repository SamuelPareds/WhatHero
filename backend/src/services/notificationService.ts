import { createHash } from 'crypto';
import admin from 'firebase-admin';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { memberHasSessionAccess, type MemberAccess } from './memberAccess';

// Acceso perezoso a Firestore — admin.firestore() solo es seguro tras initializeApp()
function getDb() {
  return admin.firestore();
}

// `ai_truncated`: el modelo cortó su respuesta por límite de tokens y preferimos
// no enviar media frase. `send_failed`: un chunk no salió ni con reintento, así
// que la respuesta quedó incompleta en el chat del cliente. `ai_failed`: el
// proveedor falló o no contestó a tiempo; antes ese mensaje se perdía en silencio.
export type HumanAttentionReason =
  | 'discriminator'
  | 'blocked_media'
  | 'unanswered_media'
  | 'ai_off'
  | 'ai_truncated'
  | 'send_failed'
  | 'ai_failed';

export interface HumanAttentionPayload {
  accountId: string;          // UID del usuario dueño de la sesión
  sessionPhone: string;       // teléfono de la sesión WhatsApp (doc id)
  sessionKey: string;         // UUID interno de la sesión activa
  chatId: string;             // contactPhone del cliente
  reason: HumanAttentionReason;
  messagePreview?: string;    // texto crudo del mensaje (truncado al armar)
  mediaType?: string;         // 'image' | 'audio' | 'video' | 'document' | ...
}

interface DeviceDoc {
  fcm_token?: string;
  platform?: 'android' | 'ios' | 'web';
}

const PREVIEW_MAX = 80;
// Un interno suele ser una instrucción ("dile que sí, pero sólo hasta el
// viernes"): le dejamos más largo antes de cortar.
const INTERNAL_PREVIEW_MAX = 160;

interface Device {
  deviceId: string;
  token: string;
  platform: string;
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

// Mapeo de tipo de media → etiqueta humana en español
const MEDIA_LABEL: Record<string, string> = {
  image: '📷 Imagen',
  video: '🎥 Video',
  audio: '🎤 Audio',
  ptt: '🎤 Audio',
  document: '📄 Documento',
  sticker: '🟦 Sticker',
};

function buildBody(payload: HumanAttentionPayload): string {
  const preview = (payload.messagePreview ?? '').replace(/\s+/g, ' ').trim();
  // Si llegó adjunto y no hay texto/caption, mostramos etiqueta amigable.
  // Aplica a blocked_media (siempre sin caption) y a ai_off cuando el
  // contacto manda sólo media (sin texto que mostrar de preview).
  if (!preview && payload.mediaType) {
    return MEDIA_LABEL[payload.mediaType] ?? '📎 Adjunto';
  }
  if (!preview) return 'Mensaje nuevo requiere atención';
  return truncate(preview, PREVIEW_MAX);
}

// Lee alias de sesión y nombre del contacto (best-effort: si falla, usamos teléfonos)
async function fetchTitleParts(
  accountId: string,
  sessionPhone: string,
  chatId: string,
): Promise<{ sessionAlias: string; contactName: string }> {
  const db = getDb();
  let sessionAlias = sessionPhone;
  let contactName = chatId;

  try {
    const [sessionSnap, chatSnap] = await Promise.all([
      db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(sessionPhone)
        .get(),
      db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(sessionPhone)
        .collection('chats')
        .doc(chatId)
        .get(),
    ]);

    const aliasRaw = sessionSnap.data()?.alias;
    if (typeof aliasRaw === 'string' && aliasRaw.trim()) {
      sessionAlias = aliasRaw.trim();
    }

    const nameRaw = chatSnap.data()?.contactName;
    if (typeof nameRaw === 'string' && nameRaw.trim()) {
      contactName = nameRaw.trim();
    }
  } catch (error) {
    console.warn('[Notify] No se pudo leer alias/contactName, usando fallbacks:', error);
  }

  return { sessionAlias, contactName };
}

// Calcula el conjunto de uids con acceso a una sesión concreta.
// Owner (uid == accountId) siempre. Cada miembro según su `access`:
//   - sin campo access → legacy "ve todo" (incluido).
//   - allSessions:true → incluido.
//   - sessions[sessionPhone] presente → incluido.
// Devuelve null si no se pudo leer members (→ caller hace fail-open por
// seguridad operativa: mejor una notif de más que perder el aviso del owner).
async function computeAllowedUids(
  accountId: string,
  sessionPhone: string,
): Promise<Set<string> | null> {
  try {
    const allowed = new Set<string>([accountId]); // owner
    const membersSnap = await getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('members')
      .get();

    membersSnap.forEach((doc) => {
      const access = doc.data()?.access as MemberAccess | undefined;
      if (memberHasSessionAccess(access, sessionPhone)) allowed.add(doc.id);
    });
    return allowed;
  } catch (error) {
    console.error('[Notify] Error computando uids con acceso:', error);
    return null;
  }
}

// Lee tokens FCM activos del usuario. Devuelve también el deviceId para limpieza posterior.
// Filtra por `allowedUids`: solo notifica a dispositivos de usuarios con acceso
// a la sesión. Un device sin campo `uid` (legacy) se incluye (fail-open) para
// no perder avisos de dispositivos viejos sin re-registrar, salvo con
// `requireUid`: un aviso dirigido a una persona no puede ir a un teléfono del
// que no sabemos el dueño.
async function fetchDeviceTokens(
  accountId: string,
  allowedUids: Set<string> | null,
  { requireUid = false }: { requireUid?: boolean } = {},
): Promise<Device[]> {
  try {
    const snap = await getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('devices')
      .get();

    const result: Device[] = [];
    snap.forEach((doc) => {
      const data = doc.data() as DeviceDoc & { uid?: string };
      if (!data?.fcm_token || typeof data.fcm_token !== 'string') return;
      if (requireUid && !data.uid) return;
      // Si tenemos lista de permitidos y el device tiene uid, filtramos.
      if (allowedUids && data.uid && !allowedUids.has(data.uid)) {
        return;
      }
      result.push({
        deviceId: doc.id,
        token: data.fcm_token,
        platform: data.platform ?? 'unknown',
      });
    });
    return result;
  } catch (error) {
    console.error('[Notify] Error leyendo dispositivos:', error);
    return [];
  }
}

// Borra docs de dispositivos cuyos tokens FCM marcó inválidos.
// Códigos de error que indican token muerto y debemos limpiarlo.
// IMPORTANTE: 'messaging/invalid-argument' NO va aquí — significa "mensaje
// malformado", no "token inválido". Si lo agregamos, un bug en el payload
// borraría todos los dispositivos de todos los usuarios. Aprendido a la mala.
const INVALID_TOKEN_ERRORS = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

async function pruneDeadTokens(
  accountId: string,
  deadDeviceIds: string[],
): Promise<void> {
  if (deadDeviceIds.length === 0) return;
  const db = getDb();
  const batch = db.batch();
  for (const deviceId of deadDeviceIds) {
    const ref = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('devices')
      .doc(deviceId);
    batch.delete(ref);
  }
  try {
    await batch.commit();
    console.log(`[Notify] Limpieza: ${deadDeviceIds.length} token(s) inválidos borrados`);
  } catch (error) {
    console.error('[Notify] Error borrando tokens muertos:', error);
  }
}

interface PushContent {
  title: string;
  body: string;
  data: Record<string, string>;
  // collapse_key/tag: si caen varias notifs del mismo tema antes de que el
  // usuario abra, el SO las colapsa en una sola en vez de spamear el shade.
  collapseTag: string;
}

// APNs acepta hasta 64 bytes de collapse-id. El tag de un chat mexicano mide
// 65 ('whathero:' + uid de 28 + dos teléfonos de 13), y el `slice(0, 64)` de
// antes se comía el último dígito del chat: en iPhone, dos clientes cuyo
// número sólo difiere en ese dígito se pisaban la notificación. El hash mide
// 40 y no colisiona.
function apnsCollapseId(tag: string): string {
  return createHash('sha1').update(tag).digest('hex');
}

// Arma el multicast, lo envía y limpia los tokens muertos. Único lugar que
// habla con FCM.
async function deliverPush(
  accountId: string,
  devices: Device[],
  push: PushContent,
  logLabel: string,
): Promise<void> {
  const { title, body, collapseTag } = push;
  const message: admin.messaging.MulticastMessage = {
    tokens: devices.map((d) => d.token),
    notification: { title, body },
    data: push.data,
    android: {
      priority: 'high',
      collapseKey: collapseTag,
      notification: {
        tag: collapseTag,
        channelId: 'human_attention',
        // sound default activado vía channel; aquí no hace falta repetir
      },
    },
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-collapse-id': apnsCollapseId(collapseTag),
      },
      payload: {
        aps: {
          sound: 'default',
          'thread-id': collapseTag,
        },
      },
    },
    webpush: {
      // Solo Urgency. NO ponemos Topic: la RFC 8030 exige base64url y nuestro
      // collapseTag tiene ':' que es inválido → FCM responde invalid-argument.
      // Sin Topic, los pushes no se colapsan a nivel push service, pero el
      // 'tag' de la Notification API sí los agrupa visualmente en el SO.
      headers: { Urgency: 'high' },
      notification: {
        // Repetimos title/body acá: si webpush.notification existe, FCM toma
        // estos campos en lugar de los top-level para web clients.
        title,
        body,
        tag: collapseTag,
        renotify: true,
        icon: '/icons/Icon-192.png',
        badge: '/favicon.png',
      },
      fcmOptions: {
        // Click → enfoca la app. Deep-link granular en Fase 4.
        link: '/',
      },
    },
  };

  try {
    const response = await admin.messaging().sendEachForMulticast(message);
    console.log(
      `[Notify] FCM enviado a ${response.successCount}/${devices.length} dispositivos (${logLabel})`
    );

    if (response.failureCount > 0) {
      const dead: string[] = [];
      response.responses.forEach((r, idx) => {
        if (r.success) return;
        const code = r.error?.code ?? '';
        console.warn(`[Notify] Fallo en token ${devices[idx].deviceId}: ${code} ${r.error?.message ?? ''}`);
        if (INVALID_TOKEN_ERRORS.has(code)) {
          dead.push(devices[idx].deviceId);
        }
      });
      await pruneDeadTokens(accountId, dead);
    }
  } catch (error) {
    console.error('[Notify] Error enviando multicast FCM:', error);
  }
}

// Punto de entrada único: dispara push FCM a todos los dispositivos del usuario
// cuando un chat necesita atención humana. Idempotente y silencioso ante errores
// (no debe romper el flujo principal de mensajes si el push falla).
export async function sendHumanAttentionNotification(
  payload: HumanAttentionPayload,
): Promise<void> {
  // Solo notificamos a quienes tienen acceso a esta sesión (permisos por
  // sesión). El owner siempre incluido.
  const allowedUids = await computeAllowedUids(
    payload.accountId,
    payload.sessionPhone,
  );

  const devices = await fetchDeviceTokens(payload.accountId, allowedUids);
  if (devices.length === 0) {
    console.log(`[Notify] Sin dispositivos con acceso para ${payload.accountId}/${payload.sessionPhone}, skip push`);
    return;
  }

  const { sessionAlias, contactName } = await fetchTitleParts(
    payload.accountId,
    payload.sessionPhone,
    payload.chatId,
  );

  await deliverPush(
    payload.accountId,
    devices,
    {
      title: `${sessionAlias} · ${contactName}`,
      body: buildBody(payload),
      data: {
        accountId: payload.accountId,
        sessionPhone: payload.sessionPhone,
        sessionKey: payload.sessionKey,
        chatId: payload.chatId,
        reason: payload.reason,
        ...(payload.mediaType ? { mediaType: payload.mediaType } : {}),
      },
      collapseTag: `whathero:${payload.accountId}:${payload.sessionPhone}:${payload.chatId}`,
    },
    `reason=${payload.reason}, chat=${payload.chatId}`,
  );
}

export interface InternalMessagePushPayload {
  accountId: string;
  sessionPhone: string;
  chatId: string;
  contactName: string;
  authorName: string;
  text: string;
  recipientUids: string[];
}

// Push de un mensaje interno, sólo a los destinatarios. Al revés que la
// atención humana, un dispositivo legacy sin `uid` NO lo recibe: este aviso
// va dirigido a una persona y no sabemos de quién es ese teléfono.
// Nunca lanza: lo llaman sin await.
export async function sendInternalMessageNotification(
  payload: InternalMessagePushPayload,
): Promise<void> {
  try {
    const devices = await fetchDeviceTokens(
      payload.accountId,
      new Set(payload.recipientUids),
      { requireUid: true },
    );
    if (devices.length === 0) {
      console.log(`[Notify] Interno sin dispositivos para ${payload.recipientUids.join(',')}, skip push`);
      return;
    }
    await deliverPush(
      payload.accountId,
      devices,
      {
        // El candado dice "esto no lo escribió el cliente" antes de leer más.
        title: `🔒 ${payload.authorName} · ${payload.contactName}`,
        body: truncate(payload.text.replace(/\s+/g, ' ').trim(), INTERNAL_PREVIEW_MAX),
        data: {
          accountId: payload.accountId,
          sessionPhone: payload.sessionPhone,
          chatId: payload.chatId,
          reason: 'internal_message',
        },
        // Tag propio: no reemplaza en el teléfono un aviso de "atención
        // humana" del mismo chat. Son dos pendientes distintos.
        collapseTag: `whathero:internal:${payload.accountId}:${payload.sessionPhone}:${payload.chatId}`,
      },
      `reason=internal_message, chat=${payload.chatId}`,
    );
  } catch (error) {
    console.error('[Notify] Error en push de mensaje interno:', error);
  }
}
