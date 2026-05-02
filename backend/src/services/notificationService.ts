import admin from 'firebase-admin';
import { ACCOUNTS_COLLECTION } from '../config/env';

// Acceso perezoso a Firestore — admin.firestore() solo es seguro tras initializeApp()
function getDb() {
  return admin.firestore();
}

export type HumanAttentionReason = 'discriminator' | 'blocked_media' | 'ai_off';

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
  return preview.length > PREVIEW_MAX
    ? `${preview.slice(0, PREVIEW_MAX - 1)}…`
    : preview;
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

// Lee tokens FCM activos del usuario. Devuelve también el deviceId para limpieza posterior.
async function fetchDeviceTokens(
  accountId: string,
): Promise<{ deviceId: string; token: string; platform: string }[]> {
  try {
    const snap = await getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('devices')
      .get();

    const result: { deviceId: string; token: string; platform: string }[] = [];
    snap.forEach((doc) => {
      const data = doc.data() as DeviceDoc;
      if (data?.fcm_token && typeof data.fcm_token === 'string') {
        result.push({
          deviceId: doc.id,
          token: data.fcm_token,
          platform: data.platform ?? 'unknown',
        });
      }
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

// Punto de entrada único: dispara push FCM a todos los dispositivos del usuario
// cuando un chat necesita atención humana. Idempotente y silencioso ante errores
// (no debe romper el flujo principal de mensajes si el push falla).
export async function sendHumanAttentionNotification(
  payload: HumanAttentionPayload,
): Promise<void> {
  const devices = await fetchDeviceTokens(payload.accountId);
  if (devices.length === 0) {
    console.log(`[Notify] Sin dispositivos registrados para ${payload.accountId}, skip push`);
    return;
  }

  const { sessionAlias, contactName } = await fetchTitleParts(
    payload.accountId,
    payload.sessionPhone,
    payload.chatId,
  );

  const title = `${sessionAlias} · ${contactName}`;
  const body = buildBody(payload);

  // collapse_key/tag por chat: si caen varias notifs antes de que el usuario abra,
  // el SO las colapsa en una sola en vez de spamear el shade.
  const collapseTag = `whathero:${payload.accountId}:${payload.sessionPhone}:${payload.chatId}`;

  const message: admin.messaging.MulticastMessage = {
    tokens: devices.map((d) => d.token),
    notification: { title, body },
    data: {
      accountId: payload.accountId,
      sessionPhone: payload.sessionPhone,
      sessionKey: payload.sessionKey,
      chatId: payload.chatId,
      reason: payload.reason,
      ...(payload.mediaType ? { mediaType: payload.mediaType } : {}),
    },
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
        'apns-collapse-id': collapseTag.slice(0, 64), // APNs limita a 64 chars
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
      `[Notify] FCM enviado a ${response.successCount}/${devices.length} dispositivos ` +
      `(reason=${payload.reason}, chat=${payload.chatId})`
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
      await pruneDeadTokens(payload.accountId, dead);
    }
  } catch (error) {
    console.error('[Notify] Error enviando multicast FCM:', error);
  }
}
