// Pipeline de medios: extracción + descarga + upload + URL.
//
// Ejecutado fire-and-forget desde firestoreService.ts. El operador ve la
// burbuja del mensaje al instante (con thumbnail si aplica); el archivo
// completo aparece cuando este job termina vía Firestore stream.

import admin from 'firebase-admin';
import { downloadMediaMessage } from '@whiskeysockets/baileys';
import { pino } from 'pino';
import { randomUUID } from 'crypto';
import { ACCOUNTS_COLLECTION } from '../config/env';

const mediaLogger = pino({ level: 'warn' }).child({ module: 'media' });

const MAX_RETRIES = 3;
const RETRY_BASE_DELAY_MS = 2000;

export type MediaType = 'image' | 'sticker' | 'document' | 'audio' | 'video';

export interface MediaInfo {
  type: MediaType;
  mime: string;
  ext: string;
  fileName?: string;
  // Campos a persistir en el doc de Firestore al guardar el mensaje (Fase 1).
  // El job de upload completará luego mediaUrl + mediaSize + mediaStatus='ready'.
  firestoreFields: Record<string, any>;
}

function extFromMime(mime: string): string {
  if (mime.includes('png')) return 'png';
  if (mime.includes('webp')) return 'webp';
  if (mime.includes('gif')) return 'gif';
  return 'jpg';
}

function extFromFileName(fileName: string, fallbackMime: string): string {
  const dot = fileName.lastIndexOf('.');
  if (dot > 0 && dot < fileName.length - 1) {
    return fileName.substring(dot + 1).toLowerCase();
  }
  if (fallbackMime.includes('pdf')) return 'pdf';
  if (fallbackMime.includes('msword') || fallbackMime.includes('wordprocessingml')) return 'docx';
  if (fallbackMime.includes('spreadsheet') || fallbackMime.includes('excel')) return 'xlsx';
  return 'bin';
}

function extFromAudioMime(mime: string): string {
  // Las notas de voz de WhatsApp casi siempre son OGG/Opus.
  // Audios adjuntos pueden venir en MP3, M4A, etc.
  if (mime.includes('ogg')) return 'ogg';
  if (mime.includes('mpeg') || mime.includes('mp3')) return 'mp3';
  if (mime.includes('mp4') || mime.includes('m4a') || mime.includes('aac')) return 'm4a';
  if (mime.includes('webm')) return 'webm';
  if (mime.includes('wav')) return 'wav';
  return 'ogg';
}

// Detecta el tipo de media en un mensaje WhatsApp. Si no hay media soportada
// en este mensaje, retorna null (texto plano u otro tipo aún no soportado).
export function extractMediaInfo(message: any): MediaInfo | null {
  const m = message?.message;
  if (!m) return null;

  if (m.imageMessage) {
    const img = m.imageMessage;
    const mime = img.mimetype || 'image/jpeg';
    const thumb = img.jpegThumbnail;
    return {
      type: 'image',
      mime,
      ext: extFromMime(mime),
      firestoreFields: {
        mediaType: 'image',
        mediaMime: mime,
        mediaWidth: img.width || null,
        mediaHeight: img.height || null,
        mediaThumbBase64: thumb ? Buffer.from(thumb).toString('base64') : null,
        mediaStatus: 'thumb_only',
      },
    };
  }

  // Video y "GIF" (en WhatsApp un GIF es un mp4 mute con loop, marcado por
  // gifPlayback). Mismo pipeline que imagen: jpegThumbnail como poster
  // instantáneo + descarga del mp4 completo en segundo plano.
  if (m.videoMessage) {
    const vd = m.videoMessage;
    const mime = vd.mimetype || 'video/mp4';
    const thumb = vd.jpegThumbnail;
    return {
      type: 'video',
      mime,
      ext: 'mp4',
      firestoreFields: {
        mediaType: 'video',
        mediaMime: mime,
        mediaWidth: vd.width || null,
        mediaHeight: vd.height || null,
        mediaDuration: vd.seconds || null,
        mediaThumbBase64: thumb ? Buffer.from(thumb).toString('base64') : null,
        mediaIsGif: !!vd.gifPlayback,
        mediaStatus: thumb ? 'thumb_only' : 'pending',
      },
    };
  }

  if (m.stickerMessage) {
    const st = m.stickerMessage;
    const mime = st.mimetype || 'image/webp';
    return {
      type: 'sticker',
      mime,
      ext: 'webp',
      firestoreFields: {
        mediaType: 'sticker',
        mediaMime: mime,
        mediaWidth: st.width || null,
        mediaHeight: st.height || null,
        // Stickers no traen jpegThumbnail; vamos directo al full-res (~30-50KB).
        mediaStatus: 'pending',
      },
    };
  }

  // Audio: notas de voz (ptt=true) y adjuntos de audio (ptt=false).
  // Mismo pipeline para ambos; el campo mediaIsPtt distingue en el frontend
  // para el icono y la duración compacta.
  if (m.audioMessage) {
    const au = m.audioMessage;
    const mime = au.mimetype || 'audio/ogg';
    const isPtt = !!au.ptt;
    return {
      type: 'audio',
      mime,
      ext: extFromAudioMime(mime),
      firestoreFields: {
        mediaType: 'audio',
        mediaMime: mime,
        mediaIsPtt: isPtt,
        mediaDuration: au.seconds || null,
        mediaStatus: 'pending',
      },
    };
  }

  // Documentos pueden venir como documentMessage o como documentWithCaptionMessage
  // (wrapper que WhatsApp introdujo cuando agregó captions a documentos).
  const doc = m.documentMessage
    || m.documentWithCaptionMessage?.message?.documentMessage
    || null;
  if (doc) {
    const mime = doc.mimetype || 'application/octet-stream';
    const fileName = doc.fileName || `archivo-${Date.now()}`;
    return {
      type: 'document',
      mime,
      ext: extFromFileName(fileName, mime),
      fileName,
      firestoreFields: {
        mediaType: 'document',
        mediaMime: mime,
        mediaFileName: fileName,
        mediaSize: doc.fileLength ? Number(doc.fileLength) : null,
        mediaStatus: 'pending',
      },
    };
  }

  return null;
}

export async function processMediaAsync(
  message: any,
  info: MediaInfo,
  sock: any,
  accountId: string,
  sessionId: string,
  contactPhone: string,
  messageId: string
): Promise<void> {
  const path = `${ACCOUNTS_COLLECTION}/${accountId}/whatsapp_sessions/${sessionId}/chats/${contactPhone}/media/${messageId}.${info.ext}`;

  const messageRef = admin.firestore()
    .collection(ACCOUNTS_COLLECTION).doc(accountId)
    .collection('whatsapp_sessions').doc(sessionId)
    .collection('chats').doc(contactPhone)
    .collection('messages').doc(messageId);

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
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
      const downloadToken = randomUUID();

      await file.save(buffer, {
        contentType: info.mime,
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

      console.log(`[Media] ${info.type} subido: ${messageId} (${buffer.length} bytes) → ${path}`);
      return;
    } catch (error: any) {
      const errMsg = error?.message ?? String(error);
      console.warn(`[Media] Intento ${attempt}/${MAX_RETRIES} falló para ${info.type} ${messageId}: ${errMsg}`);

      if (attempt === MAX_RETRIES) {
        try {
          await messageRef.set({ mediaStatus: 'failed' }, { merge: true });
        } catch (_) { /* noop */ }
        console.error(`[Media] ${info.type} marcado como FAILED: ${messageId}`);
      } else {
        await new Promise(r => setTimeout(r, attempt * RETRY_BASE_DELAY_MS));
      }
    }
  }
}
