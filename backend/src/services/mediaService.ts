// Pipeline de medios (Fase 2): descifra el archivo de WhatsApp, lo sube
// a Firebase Storage y actualiza el doc del mensaje con la URL final.
//
// Se ejecuta fire-and-forget: el mensaje ya quedó visible en el CRM con
// su thumbnail (Fase 1). Esta función agrega la imagen full-res "encima".

import admin from 'firebase-admin';
import { downloadMediaMessage } from '@whiskeysockets/baileys';
import { pino } from 'pino';
import { randomUUID } from 'crypto';
import { ACCOUNTS_COLLECTION } from '../config/env';

const mediaLogger = pino({ level: 'warn' }).child({ module: 'media' });

const MAX_RETRIES = 3;
const RETRY_BASE_DELAY_MS = 2000;

function extFromMime(mime: string): string {
  if (mime.includes('png')) return 'png';
  if (mime.includes('webp')) return 'webp';
  if (mime.includes('gif')) return 'gif';
  return 'jpg';
}

export async function processImageMediaAsync(
  message: any,
  sock: any,
  accountId: string,
  sessionId: string,
  contactPhone: string,
  messageId: string
): Promise<void> {
  const imageMessage = message.message?.imageMessage;
  if (!imageMessage) return;

  const mime = imageMessage.mimetype || 'image/jpeg';
  const ext = extFromMime(mime);
  const path = `${ACCOUNTS_COLLECTION}/${accountId}/whatsapp_sessions/${sessionId}/chats/${contactPhone}/media/${messageId}.${ext}`;

  const messageRef = admin.firestore()
    .collection(ACCOUNTS_COLLECTION).doc(accountId)
    .collection('whatsapp_sessions').doc(sessionId)
    .collection('chats').doc(contactPhone)
    .collection('messages').doc(messageId);

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      // 'buffer' devuelve los bytes ya descifrados con la mediaKey del mensaje.
      // reuploadRequest permite a Baileys pedir re-upload al sender si la URL
      // del CDN de WA expiró (mensajes viejos).
      const buffer = (await downloadMediaMessage(
        message,
        'buffer',
        {},
        {
          logger: mediaLogger,
          reuploadRequest: sock?.updateMediaMessage,
        }
      )) as Buffer;

      if (!buffer || buffer.length === 0) {
        throw new Error('Empty buffer from downloadMediaMessage');
      }

      const bucket = admin.storage().bucket();
      const file = bucket.file(path);

      // Token de descarga estilo Firebase: el cliente puede usar la URL
      // directamente con Image.network sin necesitar el SDK de Storage.
      const downloadToken = randomUUID();

      await file.save(buffer, {
        contentType: mime,
        metadata: {
          metadata: { firebaseStorageDownloadTokens: downloadToken },
        },
        resumable: false,
      });

      const encodedPath = encodeURIComponent(path);
      const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media&token=${downloadToken}`;

      await messageRef.set({
        mediaUrl: url,
        mediaSize: buffer.length,
        mediaStatus: 'ready',
      }, { merge: true });

      console.log(`[Media] Imagen subida: ${messageId} (${buffer.length} bytes) → ${path}`);
      return;
    } catch (error: any) {
      const errMsg = error?.message ?? String(error);
      console.warn(`[Media] Intento ${attempt}/${MAX_RETRIES} falló para ${messageId}: ${errMsg}`);

      if (attempt === MAX_RETRIES) {
        try {
          await messageRef.set({ mediaStatus: 'failed' }, { merge: true });
        } catch (_) { /* noop */ }
        console.error(`[Media] Imagen marcada como FAILED: ${messageId}`);
      } else {
        // Backoff lineal: 2s, 4s
        await new Promise(r => setTimeout(r, attempt * RETRY_BASE_DELAY_MS));
      }
    }
  }
}
