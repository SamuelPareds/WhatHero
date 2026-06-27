import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { Server } from 'socket.io';
import makeWASocket, {
  DisconnectReason,
  useMultiFileAuthState,
  fetchLatestBaileysVersion,
  type ConnectionState
} from '@whiskeysockets/baileys';
import { pino } from 'pino';
import admin from 'firebase-admin';
import { rmSync, existsSync, readdirSync, writeFileSync, readFileSync, mkdirSync } from 'fs';
import { randomUUID } from 'crypto';
import cron from 'node-cron';
import { SessionData, MessageBuffer } from './src/types';
import { extractPhoneNumber, storeLIDMapping, resolveLIDViaSock, isConversationalJid } from './src/utils/phone';
import { unwrapMessageContent } from './src/utils/message';
import { initializeSession, saveMessageToFirestore, getAIConfig, cacheContactName, applyContactUpdate, reconcileContactNames, consolidateLIDChat, incrementUnrespondedCount, resetUnrespondedCount, writeMediaIndexEntry, isIndexableMedia, writeMessageIndexEntry } from './src/services/firestoreService';
import { isWithinActiveHours, generateAIResponse, normalizeHistory, processMessageBuffer, emitAiState, getSessionTimezone, AiError } from './src/services/aiService';

// Mapeo de códigos de AiError → HTTP para el endpoint manual (copiloto). El
// frontend usa el `code` para mostrar un mensaje claro con acción "Reintentar".
const AI_ERROR_HTTP: Record<string, number> = {
  timeout: 504,
  rate_limit: 429,
  auth: 502,
  provider_down: 502,
  provider_error: 502,
  safety_block: 422,
  empty_response: 502,
  empty_history: 422,
};
import { extractMediaInfo, classifyIncomingMedia } from './src/services/mediaService';
import { ReminderService } from './src/services/reminderService';
import { FollowupService } from './src/services/followupService';
import { sendHumanAttentionNotification } from './src/services/notificationService';
import { ACCOUNTS_COLLECTION, IS_PRODUCTION } from './src/config/env';
import { verifyHttpAuth, verifySocketAuth, invalidateMembershipCache } from './src/middleware/auth';
import { generateTempPassword } from './src/utils/password';
import { resolveHumanSender, BOT_SENDER, invalidateHumanNameCache } from './src/services/senderResolver';

// Ensure auth_info directory exists
const authInfoDir = 'auth_info';
if (!existsSync(authInfoDir)) {
  mkdirSync(authInfoDir, { recursive: true });
  console.log(`Created ${authInfoDir} directory`);
}

// Initialize Firebase Admin from environment variable or file
let firebaseCredential: admin.ServiceAccount;

if (process.env.FIREBASE_CONFIG) {
  try {
    firebaseCredential = JSON.parse(process.env.FIREBASE_CONFIG);
    console.log('Firebase initialized from FIREBASE_CONFIG environment variable');
  } catch (error) {
    console.error('Failed to parse FIREBASE_CONFIG environment variable:', error);
    process.exit(1);
  }
} else if (existsSync('./serviceAccountKey.json')) {
  try {
    firebaseCredential = JSON.parse(readFileSync('./serviceAccountKey.json', 'utf-8'));
    console.log('Firebase initialized from serviceAccountKey.json file');
  } catch (error) {
    console.error('Failed to read serviceAccountKey.json:', error);
    process.exit(1);
  }
} else {
  console.error('Firebase configuration not found. Set FIREBASE_CONFIG environment variable or provide serviceAccountKey.json');
  process.exit(1);
}

// Bucket de Firebase Storage. Hardcoded por proyecto único; sobreescribible
// vía env si en algún momento desplegamos a otro proyecto Firebase.
const storageBucket = process.env.FIREBASE_STORAGE_BUCKET || 'whathero-73605.firebasestorage.app';

admin.initializeApp({
  credential: admin.credential.cert(firebaseCredential),
  storageBucket,
});

const app = express();

// Enable CORS for Express (web requests)
app.use(cors({
  origin: "*",
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  credentials: true
}));

const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

const db = admin.firestore();
const logger = pino({ level: 'info' }, pino.destination({ sync: false }));

const sessions = new Map<string, SessionData>();

// Message buffers per chat: key = `${sessionKey}:${contactPhone}`
const messageBuffers = new Map<string, MessageBuffer>();

// Cooldown anti-loop para keyword rules con trigger 'outgoing' o 'both'.
// Key = `${sessionKey}::${contactPhone}::${keywordLower}`, valor = timestamp ms del último disparo.
// Necesario porque la respuesta canned saliente vuelve a entrar como `fromMe` en
// `messages.upsert`; si su contenido contuviera la misma keyword se generaría
// un loop infinito. También evita spam si el operador manda varios mensajes
// seguidos con la palabra clave.
const botRuleCooldowns = new Map<string, number>();
const BOT_RULE_COOLDOWN_MS = 30_000;

// Limpieza periódica del Map de cooldowns para que no crezca indefinidamente.
setInterval(() => {
  const now = Date.now();
  for (const [key, ts] of botRuleCooldowns.entries()) {
    if (now - ts > BOT_RULE_COOLDOWN_MS) botRuleCooldowns.delete(key);
  }
}, 10 * 60 * 1000);

// Descarga una URL (Storage o externa) a Buffer para enviarla por Baileys.
async function fetchToBuffer(url: string, label: string): Promise<Buffer> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to fetch ${label}: ${res.statusText}`);
  return Buffer.from(await res.arrayBuffer());
}

// Borra (best-effort) el objeto temporal que el composer subió a nuestro bucket
// para transportar un adjunto. Sólo actúa sobre URLs de firebasestorage de
// NUESTRO bucket: el path lo derivamos de la propia URL, nunca lo pasa el
// cliente (evita que se pueda pedir el borrado de rutas arbitrarias). El eco
// de `messages.upsert` ya re-guarda la copia canónica en la carpeta `media/`,
// así que este temporal es desechable una vez enviado. No bloquea el envío.
async function deleteTempStorageObject(url: string): Promise<void> {
  try {
    const prefix = 'https://firebasestorage.googleapis.com/v0/b/';
    if (!url.startsWith(prefix)) return;
    // .../o/<encodedPath>?alt=media&token=...  →  extraemos <encodedPath>.
    const afterO = url.split('/o/')[1];
    if (!afterO) return;
    const encodedPath = afterO.split('?')[0];
    const path = decodeURIComponent(encodedPath);
    // Sólo limpiamos lo que sube el composer (carpeta `outgoing/`); nunca la
    // copia canónica `media/` ni las plantillas de quick responses.
    if (!path.includes('/outgoing/')) return;
    await admin.storage().bucket().file(path).delete();
    console.log(`[deleteTempStorageObject] Temporal eliminado: ${path}`);
  } catch (error) {
    console.warn(`[deleteTempStorageObject] No se pudo borrar temporal:`, (error as any)?.message);
  }
}

// Construye el contenido Baileys de una respuesta automática (keyword rule).
// Prioridad de adjunto: documento > imagen > solo texto. La regla lleva como
// máximo un adjunto (lo garantiza el editor del cliente). El `response` viaja
// como caption del adjunto o como texto suelto. Devuelve null si no hay nada
// que enviar. Las descargas pueden lanzar; el caller decide el fallback.
async function buildRuleMessageContent(rule: any): Promise<any | null> {
  if (rule.documentUrl) {
    const buffer = await fetchToBuffer(rule.documentUrl, 'document');
    return {
      document: buffer,
      mimetype: 'application/pdf',
      fileName: rule.documentName || 'documento.pdf',
      caption: rule.response || undefined,
    };
  }
  if (rule.imageUrl) {
    const buffer = await fetchToBuffer(rule.imageUrl, 'image');
    return { image: buffer, caption: rule.response || undefined };
  }
  if (rule.response) return { text: rule.response };
  return null;
}

// Make io available to aiService via global variable for lazy evaluation
(global as any).__WhatHeroIO = io;

async function startSession(sessionKey: string, accountId: string) {
  const { state, saveCreds } = await useMultiFileAuthState(`auth_info/${sessionKey}`);
  const { version } = await fetchLatestBaileysVersion();

  // Write metadata file so startExistingSessions() can recover this session on reboot
  writeFileSync(`auth_info/${sessionKey}/meta.json`, JSON.stringify({ accountId }));

  // Initialize session data
  const existingSession = sessions.get(sessionKey);
  sessions.set(sessionKey, {
    sock: null,
    isReady: false,
    currentQR: undefined,
    phoneNumber: existingSession?.phoneNumber || undefined,
    isReconnecting: false,
    reconnectCount: existingSession?.reconnectCount || 0,
    accountId,
    // Preservamos el cache de nombres si la sesión se está reconectando.
    contactNames: existingSession?.contactNames ?? new Map<string, string>(),
    // Mismo criterio para el Map de senders pendientes: si la sesión vuelve
    // tras un reconnect, los envíos en vuelo conservan su intención.
    pendingSenders: existingSession?.pendingSenders ?? new Map(),
    ...(existingSession?.aiConfig && { aiConfig: existingSession.aiConfig }),
  });

  const sock = makeWASocket({
    version,
    auth: state,
    logger: logger.child({ class: 'baileys' }),
    browser: ['WhatHero', 'Chrome', '121.0.0'],
    generateHighQualityLinkPreview: true,
    syncFullHistory: false,
    markOnlineOnConnect: true,
    printQRInTerminal: false,
    retryRequestDelayMs: 250,
    defaultQueryTimeoutMs: 20000,
    getMessage: async () => undefined,
  });

  sock.ev.on('creds.update', saveCreds);

  // contacts.upsert llega masivamente al conectar (toda la agenda).
  // Solo cacheamos en memoria — no escribimos Firestore por contacto.
  // Tras 3s de silencio disparamos reconcileContactNames() que sólo escribe
  // en los chats que ya existen.
  sock.ev.on('contacts.upsert', (contacts) => {
    for (const contact of contacts) {
      cacheContactName(contact, sessionKey, sessions);
    }
    const session = sessions.get(sessionKey);
    if (!session) return;
    if (session.reconcileTimer) clearTimeout(session.reconcileTimer);
    session.reconcileTimer = setTimeout(() => {
      reconcileContactNames(sessionKey, accountId, sessions)
        .catch(err => console.error('[Reconcile] Error:', err));
    }, 3000);
  });

  // contacts.update son deltas (renombre en agenda, etc).
  // Cacheamos + actualizamos el chat doc si ya existe (si no, queda en cache).
  sock.ev.on('contacts.update', (updates) => {
    for (const update of updates) {
      applyContactUpdate(update, sessionKey, accountId, sessions);
    }
  });

  // Listen for LID-to-Phone mappings (Baileys v7.0+)
  // Payload is now typed as { lid, pn } instead of Record<string, string>
  // These are emitted both during initial history sync and whenever a new mapping is discovered
  sock.ev.on('lid-mapping.update', async ({ lid, pn }) => {
    const lidNum = extractPhoneNumber(lid);
    const pnNum = extractPhoneNumber(pn);
    console.log(`[startSession] LID-Mapping update: ${lidNum} → ${pnNum}`);
    storeLIDMapping(lidNum, pnNum);

    // Consolidate any duplicate chats created under the LID identifier
    const session = sessions.get(sessionKey);
    if (session?.phoneNumber) {
      await consolidateLIDChat(accountId, session.phoneNumber, lidNum, pnNum);
    }
  });

  sock.ev.on('connection.update', async (update: Partial<ConnectionState>) => {
    const { connection, lastDisconnect, qr } = update;
    const session = sessions.get(sessionKey);
    if (!session) return;

    if (qr) {
      console.log('[startSession] QR Code recibido para sessionKey:', sessionKey);
      console.log('[startSession] accountId:', session.accountId);
      session.currentQR = qr;
      session.isReady = false;
      console.log('[startSession] Emitiendo QR a io.to("' + session.accountId + '").emit("qr", ...)');
      io.to(session.accountId).emit('qr', { qr, sessionKey });
      console.log('[startSession] QR emitido exitosamente');
    }

    if (connection === 'close') {
      session.isReady = false;
      const statusCode = (lastDisconnect?.error as any)?.output?.statusCode;
      const errorMessage = (lastDisconnect?.error as any)?.message;

      // Mark session as disconnected in Firestore if we have a phone number
      if (session.phoneNumber) {
        try {
          const sessionDocRef = db
            .collection(ACCOUNTS_COLLECTION)
            .doc(session.accountId)
            .collection('whatsapp_sessions')
            .doc(session.phoneNumber);

          await sessionDocRef.update({
            status: 'disconnected',
            last_sync: admin.firestore.Timestamp.now(),
          });
        } catch (error) {
          console.error('Error updating session status:', error);
        }
      }

      // CHECK: If session was removed from the map, don't attempt reconnect
      if (!sessions.has(sessionKey)) {
        console.log(`[startSession] Session ${sessionKey} was explicitly cancelled. Stopping reconnect loop.`);
        return;
      }

      if (statusCode === DisconnectReason.loggedOut || statusCode === 401) {
        const reasonMsg = statusCode === 401 ? 'SESIÓN INVÁLIDA O NO AUTORIZADA' : 'LOGOUT DESDE EL TELÉFONO';
        console.log(`[ALERTA] WhatsApp cerró la sesión (${sessionKey}). Motivo: ${reasonMsg}. Limpiando credenciales locales.`);

        // Clear auth folder for this session
        try {
          rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
          console.log(`[startSession] Carpeta auth_info/${sessionKey} eliminada.`);
        } catch (error) {
          console.error('Error clearing auth folder:', error);
        }

        session.currentQR = undefined;
        session.phoneNumber = undefined;
        sessions.delete(sessionKey);

        // Notify frontend
        io.to(session.accountId).emit('status_update', { 
          status: 'logged_out', 
          sessionKey,
          phoneNumber: session.phoneNumber 
        });
      } else if (statusCode === 409) {
        console.log(`[ALERTA] Conflicto multidispositivo para ${sessionKey}. Se ha iniciado sesión en otro lugar. Limpiando para re-vincular.`);
        
        try {
          rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
        } catch (e) {}
        
        sessions.delete(sessionKey);
        io.to(session.accountId).emit('status_update', { status: 'logged_out', sessionKey });
      } else if (statusCode === 408 && !session.phoneNumber) {
        // QR Timeout on a session that was never connected
        console.log(`[startSession] QR Timeout for new session ${sessionKey}. Cleaning up instead of reconnecting.`);
        
        // Clean up memory and files to prevent leaks
        try {
          rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
        } catch (e) {}
        sessions.delete(sessionKey);
        
        io.to(session.accountId).emit('status_update', { status: 'qr_timeout', sessionKey });
      } else {
        // Regular disconnection - attempt reconnect with exponential backoff
        const MAX_RECONNECT_ATTEMPTS = 10;
        const BASE_DELAY_MS = 3000;

        session.reconnectCount = (session.reconnectCount || 0) + 1;

        console.log(`[Reconexión] Intento ${session.reconnectCount}/${MAX_RECONNECT_ATTEMPTS} para ${sessionKey} (code: ${statusCode})`);

        if (session.reconnectCount > MAX_RECONNECT_ATTEMPTS) {
          // Reached max reconnect attempts - mark as failed
          console.log(`[ALERTA] Sesión ${sessionKey} alcanzó máximo de intentos de reconexión (${MAX_RECONNECT_ATTEMPTS}). Marcando como fallida.`);
          session.isReady = false;
          sessions.delete(sessionKey);

          if (session.phoneNumber) {
            try {
              const sessionDocRef = db
                .collection(ACCOUNTS_COLLECTION)
                .doc(session.accountId)
                .collection('whatsapp_sessions')
                .doc(session.phoneNumber);
              await sessionDocRef.update({
                status: 'reconnect_failed',
                last_sync: admin.firestore.Timestamp.now(),
              });
            } catch (e) {}
          }

          io.to(session.accountId).emit('status_update', {
            status: 'reconnect_failed',
            sessionKey,
            phoneNumber: session.phoneNumber
          });
          return;
        }

        // Exponential backoff: 3s, 6s, 12s, 24s, 48s, 96s, 192s, 384s, 768s, 1200s (max)
        const delay = Math.min(BASE_DELAY_MS * Math.pow(2, session.reconnectCount - 1), 300000);

        console.log(`[Reconexión] Esperando ${delay}ms antes de reintento...`);

        // Notify frontend that we're reconnecting
        io.to(session.accountId).emit('status_update', {
          status: 'reconnecting',
          sessionKey,
          attempt: session.reconnectCount,
          maxAttempts: MAX_RECONNECT_ATTEMPTS,
          phoneNumber: session.phoneNumber,
        });

        // Update Firestore
        if (session.phoneNumber) {
          try {
            const sessionDocRef = db
              .collection(ACCOUNTS_COLLECTION)
              .doc(session.accountId)
              .collection('whatsapp_sessions')
              .doc(session.phoneNumber);
            await sessionDocRef.update({
              status: 'reconnecting',
              last_sync: admin.firestore.Timestamp.now(),
            });
          } catch (e) {}
        }

        if (!session.isReconnecting) {
          session.isReconnecting = true;
          setTimeout(() => {
            if (sessions.has(sessionKey)) {
              startSession(sessionKey, session.accountId);
            }
            session.isReconnecting = false;
          }, delay);
        }
      }
    } else if (connection === 'open') {
      console.log('[startSession] Conexión abierta para sessionKey:', sessionKey);
      session.isReady = true;
      session.currentQR = undefined;
      session.reconnectCount = 0; // Reset counter on successful connection

      // Extract and store the connected phone number
      if (sock.user?.id) {
        const phoneNumber = extractPhoneNumber(sock.user.id);
        session.phoneNumber = phoneNumber;
        console.log(`[startSession] WhatsApp conectado como: ${phoneNumber} (session: ${sessionKey})`);

        // Initialize session document in Firestore
        await initializeSession(phoneNumber, sessionKey, session.accountId);
      }

      console.log('[startSession] Emitiendo READY a io.to("' + session.accountId + '")');
      io.to(session.accountId).emit('ready', { phoneNumber: session.phoneNumber, sessionKey });
      console.log('[startSession] READY emitido exitosamente');
    }
  });

  // Listen for incoming and outgoing messages
  sock.ev.on('messages.upsert', async (m) => {
    const rawMessage = m.messages?.[0];
    if (!rawMessage) return;

    // Desempaquetar sobres (ephemeral / viewOnce) una sola vez al entrar.
    // Así TODO el handler (detección de metadata, extracción de texto entrante,
    // keyword rules outgoing y flujo de IA) ve el contenido real. El desempaque
    // dentro de saveMessageToFirestore queda como no-op idempotente.
    const message = unwrapMessageContent(rawMessage);

    // Filtro temprano: descartamos Estados/Stories, listas de difusión y canales
    // antes de tocar Firestore, IA, recordatorios o contadores. Son ruido para el CRM.
    if (!isConversationalJid(message.key.remoteJid)) {
      console.log(`[Filter] JID no conversacional ignorado en upsert: ${message.key.remoteJid}`);
      return;
    }

    // Eventos de metadata, NO conversación nueva. Cortamos acá para que no
    // disparen IA, buffers, keyword rules ni contadores de pendientes:
    //   - reactionMessage           → emoji sobre un mensaje existente
    //   - protocolMessage type 0/14 → revoke / edit (se mergean en el target)
    //   - cualquier otro protocolMessage (3=ephemeral setting, 4=sync, etc.) →
    //     metadata de configuración del chat; saveMessageToFirestore lo descarta
    //     sin escribir. Sin este corte, en chats con mensajes temporales el
    //     setting efímero entrante llegaría al flujo de IA y bumpearía el
    //     contador "tu turno" con un mensaje fantasma.
    const isMetadataEvent =
      !!message.message?.reactionMessage ||
      !!message.message?.protocolMessage;
    if (isMetadataEvent) {
      await saveMessageToFirestore(message, sessionKey, accountId, sessions, sock.user?.id, sock);
      return;
    }

    await saveMessageToFirestore(message, sessionKey, accountId, sessions, sock.user?.id, sock);

    // AI auto-response: only for incoming messages (not from self)
    if (message.key.fromMe) {
      // El dueño respondió (CRM web o celular físico): cancelar buffer + resetear contador
      const remoteJidForCancel = message.key.remoteJid;
      if (remoteJidForCancel && !remoteJidForCancel.endsWith('@g.us')) {
        let contactPhoneForCancel = extractPhoneNumber(remoteJidForCancel);
        if (contactPhoneForCancel) {
          // Resolver LID al phone number real para apuntar al chat doc correcto
          if (remoteJidForCancel.includes('@lid')) {
            const resolved = await resolveLIDViaSock(contactPhoneForCancel, sock);
            if (resolved) contactPhoneForCancel = resolved;
          }

          const bufferKey = `${sessionKey}:${contactPhoneForCancel}`;
          const buffer = messageBuffers.get(bufferKey);
          if (buffer?.timeout) {
            clearTimeout(buffer.timeout);
            messageBuffers.delete(bufferKey);
            console.log(`[Buffer] CANCELLED: Human response detected for ${contactPhoneForCancel}`);
            // El humano tomó el control: liberamos el indicador en el frontend
            emitAiState(accountId, sessionKey, contactPhoneForCancel, 'idle');
          }

          // Reset contador: el humano (o IA via CRM) acaba de responder
          const sessionForReset = sessions.get(sessionKey);
          if (sessionForReset?.phoneNumber) {
            await resetUnrespondedCount(accountId, sessionForReset.phoneNumber, contactPhoneForCancel);
          }

          // --- BOT KEYWORD RULES (trigger 'outgoing' / 'both') ---
          // Si el operador (vía WhatHero, WA Web o celular) escribió algo que
          // matchea una regla con trigger outgoing/both, enviamos el canned
          // como mensaje aparte tras el suyo. El cooldown anti-loop protege
          // contra que la propia respuesta canned reactive la regla.
          try {
            const outgoingText = message.message?.conversation
              || message.message?.extendedTextMessage?.text
              || message.message?.imageMessage?.caption
              || '';
            if (outgoingText.trim() && sessionForReset?.phoneNumber) {
              const aiConfig = await getAIConfig(sessionForReset, accountId);
              for (const rule of aiConfig.keywordRules) {
                const trigger = rule.trigger ?? 'incoming';
                if (trigger !== 'outgoing' && trigger !== 'both') continue;
                if (!outgoingText.toLowerCase().includes(rule.keyword.toLowerCase())) continue;

                const cooldownKey = `${sessionKey}::${contactPhoneForCancel}::${rule.keyword.toLowerCase()}`;
                const lastFired = botRuleCooldowns.get(cooldownKey) ?? 0;
                const now = Date.now();
                if (now - lastFired < BOT_RULE_COOLDOWN_MS) {
                  console.log(`[BotRule] Cooldown activo para "${rule.keyword}" en ${contactPhoneForCancel}, omitiendo`);
                  break;
                }
                botRuleCooldowns.set(cooldownKey, now);

                console.log(`[BotRule] OUTGOING match: "${rule.keyword}" → enviando respuesta canned a ${contactPhoneForCancel}`);
                const delayMs = aiConfig.responseDelayMs > 2000 ? 2000 : aiConfig.responseDelayMs;
                await new Promise(r => setTimeout(r, delayMs));

                try {
                  const content = await buildRuleMessageContent(rule);
                  if (content) {
                    const sentBotMsg = await sessionForReset.sock.sendMessage(remoteJidForCancel, content);
                    // Etiqueta 'bot': es una respuesta automática por keyword rule.
                    if (sentBotMsg?.key?.id) {
                      sessionForReset.pendingSenders.set(sentBotMsg.key.id, BOT_SENDER);
                    }
                  }
                } catch (sendErr) {
                  console.error('[BotRule] Error enviando canned outgoing:', sendErr);
                }

                break; // Primera regla que matchea gana, igual que el flujo incoming.
              }
            }
          } catch (botRuleErr) {
            console.error('[BotRule] Error procesando keyword rules outgoing:', botRuleErr);
          }
        }
      }
      return;
    }
    const remoteJid = message.key.remoteJid;
    if (!remoteJid || remoteJid.endsWith('@g.us')) return; // skip group messages

    // Extract contact phone number
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) return;

    // Resolvemos contactPhone temprano: lo necesitamos para incrementar el contador
    // de pendientes en cualquier rama donde la IA NO vaya a responder.
    let contactPhone = extractPhoneNumber(remoteJid);
    if (!contactPhone) return;
    if (remoteJid.includes('@lid')) {
      console.log(`[AI] Message from LID format: ${remoteJid}, attempting to resolve...`);
      const resolved = await resolveLIDViaSock(contactPhone, sock);
      if (resolved) {
        contactPhone = resolved;
        console.log(`[AI] Successfully resolved LID to ${contactPhone}`);
      } else {
        console.warn(`[AI] Could not resolve LID ${contactPhone}, will use LID as contact identifier`);
      }
    }

    // Helper local: marca este mensaje como pendiente de respuesta humana
    const markUnresponded = (by: number = 1) =>
      incrementUnrespondedCount(accountId, session.phoneNumber!, contactPhone, by);

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text || '';
    const mediaInfo = extractMediaInfo(message);

    // Caso degenerado: ni texto ni media (mensaje desconocido). Lo contamos
    // como pendiente y salimos para no romper flujo posterior con campos vacíos.
    if (!messageText.trim() && !mediaInfo) {
      await markUnresponded();
      return;
    }

    // --- KEYWORD TRIGGER FOR REMINDERS (sólo texto exacto, comando del operador) ---
    const lowerMsg = messageText.toLowerCase();
    if (lowerMsg === 'enviar_recordatorios' || lowerMsg === 'enviar recordatorios') {
      console.log(`[Reminders] Manual trigger detected from ${message.key.remoteJid}`);
      // Run in background
      ReminderService.processReminders(accountId, session.phoneNumber, sessionKey, sessions)
        .then(result => {
          console.log(`[Reminders] Manual trigger completed for ${session.phoneNumber}`, result);
        })
        .catch(err => {
          console.error(`[Reminders] Manual trigger failed for ${session.phoneNumber}`, err);
        });
      return; // Comando interno, no cuenta como pendiente
    }

    const aiConfig = await getAIConfig(session, accountId);
    const mediaClass = classifyIncomingMedia(mediaInfo, aiConfig.mediaAllowlist);

    // ============================================
    // ELEGIBILIDAD DE LA IA (precondición del media gate)
    // El gate sólo dispara handoff cuando la IA realmente iba a responder.
    // Si la IA no es elegible, la media bloqueada igual cuenta como pendiente
    // por el flujo normal de markUnresponded más abajo.
    // ============================================
    const provider: 'gemini' | 'openai' | 'deepseek' = (aiConfig.provider || 'gemini') as 'gemini' | 'openai' | 'deepseek';
    const hasValidApiKey = provider === 'openai'
      ? aiConfig.openaiApiKey
      : provider === 'deepseek'
      ? aiConfig.deepseekApiKey
      : aiConfig.apiKey;
    const baseEligible = !!aiConfig.enabled && !!hasValidApiKey && isWithinActiveHours(aiConfig);

    let aiAutoResponseEnabled = true; // Default: IA habilitada para este chat
    // -1 marca "no leído todavía" — el push coalescido de ai_off lo lee bajo demanda.
    let prevUnrespondedCount = -1;
    if (baseEligible) {
      try {
        const chatDoc = await db
          .collection(ACCOUNTS_COLLECTION)
          .doc(accountId)
          .collection('whatsapp_sessions')
          .doc(session.phoneNumber)
          .collection('chats')
          .doc(contactPhone)
          .get();
        const chatData = chatDoc.data();
        aiAutoResponseEnabled = (chatData?.ai_auto_response as boolean) ?? true;
        prevUnrespondedCount = (chatData?.unresponded_count as number) ?? 0;
      } catch (error) {
        console.warn(`[AI] Error checking ai_auto_response for ${contactPhone}:`, error);
      }
    }
    const aiEligible = baseEligible && aiAutoResponseEnabled;

    // ============================================
    // MEDIA GATE: filtro pre-IA universal (NO depende del discriminador).
    // Si la IA iba a responder pero llegó media que no puede leer, cancelamos
    // el buffer en curso y derivamos a humano. Stickers y GIFs son decorativos
    // (mediaClass='decorative') y no rompen este flujo.
    // ============================================
    if (aiEligible && mediaClass === 'blocked') {
      const bufferKey = `${sessionKey}:${contactPhone}`;
      const existingBuffer = messageBuffers.get(bufferKey);
      const pendingTexts = existingBuffer?.messages.length ?? 0;

      if (existingBuffer?.timeout) {
        clearTimeout(existingBuffer.timeout);
      }
      messageBuffers.delete(bufferKey);

      // Media bloqueada cortó el ciclo de IA: idle para liberar el spinner
      emitAiState(accountId, sessionKey, contactPhone, 'idle');

      // +1 por el mensaje multimedia que disparó el gate
      await incrementUnrespondedCount(accountId, session.phoneNumber, contactPhone, pendingTexts + 1);

      try {
        await db
          .collection(ACCOUNTS_COLLECTION)
          .doc(accountId)
          .collection('whatsapp_sessions')
          .doc(session.phoneNumber)
          .collection('chats')
          .doc(contactPhone)
          .set(
            { human_attention_at: admin.firestore.FieldValue.serverTimestamp() },
            { merge: true }
          );
      } catch (error) {
        console.error('[MediaGate] Error stamping human_attention_at:', error);
      }

      io.to(accountId).emit('human_attention_required', {
        sessionKey,
        chatId: contactPhone,
        phoneNumber: session.phoneNumber,
        timestamp: new Date().toISOString(),
        reason: 'blocked_media',
        mediaType: mediaInfo?.type,
      });

      // Push FCM para media bloqueada. No bloqueamos el flujo principal.
      sendHumanAttentionNotification({
        accountId,
        sessionPhone: session.phoneNumber,
        sessionKey,
        chatId: contactPhone,
        reason: 'blocked_media',
        mediaType: mediaInfo?.type,
      }).catch((err) => console.error('[Notify] blocked_media push falló:', err));

      console.log(
        `[MediaGate] Handoff humano: media bloqueada (${mediaInfo?.type}) para ${contactPhone} ` +
        `(canceló buffer con ${pendingTexts} texto(s))`
      );
      return;
    }

    // --- KEYWORD RULES (respuesta canned inmediata, sólo si hay texto) ---
    if (messageText.trim()) {
      for (const rule of aiConfig.keywordRules) {
        if (messageText.toLowerCase().includes(rule.keyword.toLowerCase())) {
          console.log(`[AI] Keyword rule matched: "${rule.keyword}", sending canned response`);
          await new Promise(r => setTimeout(r, aiConfig.responseDelayMs > 2000 ? 2000 : aiConfig.responseDelayMs));

          let sentBotMsg: any;
          try {
            const content = await buildRuleMessageContent(rule);
            if (content) {
              sentBotMsg = await session.sock.sendMessage(remoteJid, content);
            }
          } catch (error) {
            console.error(`[AI] Error sending media for keyword rule:`, error);
            // Fallback a solo-texto si la descarga del adjunto falló.
            if (rule.response) {
              sentBotMsg = await session.sock.sendMessage(remoteJid, { text: rule.response });
            }
          }

          // Etiqueta 'bot': respuesta automática disparada por keyword del cliente.
          if (sentBotMsg?.key?.id) {
            session.pendingSenders.set(sentBotMsg.key.id, BOT_SENDER);
          }

          return; // IA-canned respondió, no incrementar
        }
      }
    }

    // Si la IA no es elegible (apagada, sin API key, fuera de horario o
    // ai_auto_response off para este chat) → contamos pendiente y salimos.
    if (!aiEligible) {
      console.log(`[AI] No elegible para ${contactPhone} (enabled=${aiConfig.enabled}, hasKey=${!!hasValidApiKey}, inHours=${isWithinActiveHours(aiConfig)}, chatAuto=${aiAutoResponseEnabled})`);

      // ===========================================================
      // PUSH COALESCIDO ai_off
      // Disparamos sólo cuando el usuario apagó la IA explícitamente
      // (sesión o chat). NO empujamos por config (out-of-hours / sin
      // API key) porque eso es silencio intencional o problema admin.
      // Coalescing: notificamos únicamente en la transición 0 → 1 del
      // unresponded_count, así una racha de mensajes seguidos genera
      // un solo aviso. Cuando el humano responde, el contador se
      // resetea a 0 y el siguiente mensaje vuelve a notificar.
      // ===========================================================
      const aiTurnedOff = !aiConfig.enabled || (baseEligible && !aiAutoResponseEnabled);
      if (aiTurnedOff) {
        let prevCount = prevUnrespondedCount;
        // Si arriba no leímos el doc (sesión apagada → baseEligible false),
        // hacemos la lectura ahora — sólo pagamos el read en chats con IA off.
        if (prevCount < 0) {
          try {
            const snap = await db
              .collection(ACCOUNTS_COLLECTION)
              .doc(accountId)
              .collection('whatsapp_sessions')
              .doc(session.phoneNumber)
              .collection('chats')
              .doc(contactPhone)
              .get();
            prevCount = (snap.data()?.unresponded_count as number) ?? 0;
          } catch (err) {
            console.warn('[Notify] No se pudo leer unresponded_count para ai_off:', err);
            prevCount = -1; // negativo → no empujamos (fallamos cerrado)
          }
        }
        if (prevCount === 0) {
          sendHumanAttentionNotification({
            accountId,
            sessionPhone: session.phoneNumber,
            sessionKey,
            chatId: contactPhone,
            reason: 'ai_off',
            messagePreview: messageText.trim() || undefined,
            mediaType: mediaInfo?.type,
          }).catch((err) => console.error('[Notify] ai_off push falló:', err));
        }
      }

      await markUnresponded();
      return;
    }

    // IA elegible y sin media bloqueada. Si todavía no hay texto (sticker o
    // GIF solo, o media 'allowed' sin caption) la IA no tiene qué responder.
    if (!messageText.trim()) {
      await markUnresponded();
      return;
    }

    // ============================================
    // MESSAGE BUFFERING: Wait for more messages before processing
    // ============================================
    const bufferKey = `${sessionKey}:${contactPhone}`;
    let buffer = messageBuffers.get(bufferKey);

    // If no existing buffer, create one
    if (!buffer) {
      buffer = {
        contactPhone,
        messages: [messageText],
        timeout: null,
        responded: false,
      };
      messageBuffers.set(bufferKey, buffer);
      console.log(`[Buffer] Created new buffer for ${contactPhone}: message 1`);
    } else {
      // Add to existing buffer
      buffer.messages.push(messageText);
      console.log(`[Buffer] Added message to buffer for ${contactPhone}: now ${buffer.messages.length} messages`);

      // If already responded, don't reset timeout - create new buffer for this message
      if (buffer.responded) {
        buffer = {
          contactPhone,
          messages: [messageText],
          timeout: null,
          responded: false,
        };
        messageBuffers.set(bufferKey, buffer);
        console.log(`[Buffer] Buffer was responded, created new buffer for ${contactPhone}`);
      }
    }

    // Clear existing timeout if any
    if (buffer.timeout) {
      clearTimeout(buffer.timeout);
      console.log(`[Buffer] Cleared existing timeout for ${contactPhone}`);
    }

    // Notificamos al frontend: estamos esperando más mensajes del cliente.
    // expectedRespondAt permite pintar un mini-countdown si quisiéramos.
    const expectedRespondAt = Date.now() + aiConfig.responseDelayMs;
    emitAiState(accountId, sessionKey, contactPhone, 'buffering', expectedRespondAt);

    // Set new timeout to process buffer after delay
    buffer.timeout = setTimeout(async () => {
      console.log(`[Buffer] Timeout expired for ${contactPhone}, processing ${buffer.messages.length} message(s)`);

      // Mark buffer as responded BEFORE processing to prevent race conditions
      buffer.responded = true;

      // Process the buffered messages (emite 'thinking', 'responding' e 'idle' internamente)
      await processMessageBuffer(
        sessionKey,
        accountId,
        session,
        remoteJid,
        contactPhone,
        aiConfig,
        buffer.messages
      );

      // Clear the buffer from map
      messageBuffers.delete(bufferKey);
      console.log(`[Buffer] Cleared buffer for ${contactPhone}`);
    }, aiConfig.responseDelayMs);
  });

  // Store socket reference in session
  const session = sessions.get(sessionKey);
  if (session) session.sock = sock;

  return sock;
}

async function cancelSession(sessionKey: string) {
  const session = sessions.get(sessionKey);
  if (!session) {
    console.log(`[cancelSession] Session not found: ${sessionKey}`);
    return false;
  }

  console.log(`[cancelSession] Cancelando sesión: ${sessionKey}`);

  // Close the Baileys socket
  if (session.sock) {
    try {
      await session.sock.ws?.close();
      console.log(`[cancelSession] Socket cerrado para ${sessionKey}`);
    } catch (error) {
      console.error(`[cancelSession] Error cerrando socket:`, error);
    }
  }

  // Clean up auth directory
  try {
    rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
    console.log(`[cancelSession] Auth directory eliminado: auth_info/${sessionKey}`);
  } catch (error) {
    console.error(`[cancelSession] Error limpiando auth:`, error);
  }

  // Remove from sessions map
  sessions.delete(sessionKey);
  console.log(`[cancelSession] Sesión eliminada del mapa`);

  // Notify frontend
  io.to(session.accountId).emit('session_cancelled', { sessionKey });

  return true;
}

/**
 * Common logic to send a message via Baileys, reused by HTTP and Socket handlers.
 *
 * `senderUid` debe venir del middleware/handshake (req.auth.uid o
 * socket.data.uid). Lo usamos para resolver el primer nombre del operador
 * que respondió (etiqueta visible en cada mensaje saliente).
 */
async function performSendMessage(
  { to, text, imageUrl, documentUrl, documentName, videoUrl, audioUrl, mimetype, isPtt, cleanupAfterSend, sessionKey, accountId, quotedMessageId, quotedText, quotedFromMe }: any,
  senderUid: string,
) {
  const session = sessions.get(sessionKey);
  if (!session?.isReady || !session?.phoneNumber) {
    throw new Error('Session not ready');
  }

  // Try to get the stored remoteJid from the chat document
  let jid = to.includes('@') ? to : `${to}@s.whatsapp.net`;

  try {
    const chatDocRef = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(session.phoneNumber)
      .collection('chats')
      .doc(to);

    const chatDoc = await chatDocRef.get();
    if (chatDoc.exists && chatDoc.data()?.remoteJid) {
      jid = chatDoc.data()!.remoteJid;
    }
  } catch (error) {
    console.warn(`[performSendMessage] Error retrieving chat document:`, error);
  }

  // Reply: si el frontend mandó un quotedMessageId, construimos el stub
  // mínimo que Baileys necesita para que WhatsApp renderice la cita.
  // No necesitamos el mensaje original completo — alcanza con el stanzaId
  // y un placeholder de texto (WhatsApp resuelve el contenido por id en
  // el dispositivo del cliente).
  const sendOptions: any = {};
  if (quotedMessageId) {
    sendOptions.quoted = {
      key: {
        remoteJid: jid,
        id: quotedMessageId,
        fromMe: !!quotedFromMe,
      },
      message: { conversation: typeof quotedText === 'string' ? quotedText : '' },
    };
  }

  // Armamos el contenido Baileys según qué adjunto llegó. Prioridad:
  // documento > video > audio > imagen > texto (un mensaje lleva un solo
  // adjunto; el composer lo garantiza). El `text` viaja como caption del
  // adjunto (excepto audio, que en WhatsApp no lleva caption). `tempMediaUrl`
  // guarda la URL del temporal subido por el composer para limpiarla al final.
  const caption = text || undefined;
  let content: any;
  let tempMediaUrl: string | null = null;

  if (documentUrl) {
    content = {
      document: await fetchToBuffer(documentUrl, 'document'),
      mimetype: mimetype || 'application/octet-stream',
      fileName: documentName || 'documento',
      caption,
    };
    tempMediaUrl = documentUrl;
  } else if (videoUrl) {
    content = {
      video: await fetchToBuffer(videoUrl, 'video'),
      mimetype: mimetype || 'video/mp4',
      caption,
    };
    tempMediaUrl = videoUrl;
  } else if (audioUrl) {
    content = {
      audio: await fetchToBuffer(audioUrl, 'audio'),
      mimetype: mimetype || 'audio/mp4',
      ptt: !!isPtt,
    };
    tempMediaUrl = audioUrl;
  } else if (imageUrl) {
    content = {
      image: await fetchToBuffer(imageUrl, 'image'),
      caption,
    };
    tempMediaUrl = imageUrl;
  } else {
    content = { text };
  }

  const message = await session.sock.sendMessage(jid, content, sendOptions);

  // Limpieza del temporal sólo si el cliente lo pidió (envíos one-off del
  // composer). Las quick responses NO pasan el flag: sus imágenes son
  // plantillas reutilizables que deben persistir. Best-effort, no bloquea.
  if (cleanupAfterSend && tempMediaUrl) {
    void deleteTempStorageObject(tempMediaUrl);
  }

  // Etiquetamos al humano que envió este mensaje. El handler de
  // messages.upsert consume esta entry al guardar el doc en Firestore.
  if (message?.key?.id) {
    const senderInfo = await resolveHumanSender(senderUid);
    session.pendingSenders.set(message.key.id, senderInfo);
  }

  return {
    success: true,
    messageId: message.key.id,
    timestamp: new Date().toISOString(),
  };
}

// REST API endpoint to start a new session
app.post('/start-session', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { accountId } = req.body;
    console.log('[/start-session] POST recibido con accountId:', accountId);

    if (!accountId) {
      console.error('[/start-session] Error: Missing accountId');
      return res.status(400).json({ error: 'Missing accountId in request body' });
    }

    const sessionKey = randomUUID();
    console.log('[/start-session] Nuevo sessionKey generado:', sessionKey);
    console.log('[/start-session] Llamando a startSession...');

    await startSession(sessionKey, accountId);

    console.log('[/start-session] startSession completado, enviando sessionKey al cliente');
    res.json({ sessionKey });
  } catch (error) {
    console.error('[/start-session] Error:', error);
    res.status(500).json({ error: 'Failed to start session' });
  }
});

// REST API endpoint to cancel a session
app.post('/cancel-session', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { accountId, sessionKey } = req.body;
    console.log('[/cancel-session] POST recibido con sessionKey:', sessionKey);

    if (!sessionKey || !accountId) {
      return res.status(400).json({ error: 'Missing sessionKey or accountId' });
    }

    const session = sessions.get(sessionKey);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.accountId !== accountId) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    const success = await cancelSession(sessionKey);
    res.json({ success });
  } catch (error) {
    console.error('[/cancel-session] Error:', error);
    res.status(500).json({ error: 'Failed to cancel session' });
  }
});

// REST API endpoint to send messages (now uses common logic)
app.post('/send-message', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const result = await performSendMessage(req.body, req.auth!.uid);
    res.json(result);
  } catch (error) {
    console.error('Error sending message (HTTP):', error);
    res.status(500).json({
      error: 'Failed to send message',
      details: (error as any).message,
    });
  }
});

// REST API endpoint to generate AI response (bypass discriminator)
// Used when operator wants AI to generate a response for approval before sending
app.post('/generate-ai-response', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { chatPhone, sessionKey, accountId } = req.body;

    if (!chatPhone || !sessionKey || !accountId) {
      return res.status(400).json({ error: 'Missing chatPhone, sessionKey, or accountId' });
    }

    // Instrucción puntual opcional del operador (modo copiloto). Vacío =
    // comportamiento clásico. Cap defensivo de longitud para no inflar el prompt.
    const operatorInstruction = String(req.body.operatorInstruction || '').trim().slice(0, 500);

    // Find active session
    const sessionData = sessions.get(sessionKey);
    if (!sessionData) {
      return res.status(404).json({ error: 'Session not found' });
    }

    const phoneNumber = sessionData.phoneNumber!;

    // Load AI config
    const aiConfig = await getAIConfig(sessionData, accountId);
    const provider: 'gemini' | 'openai' | 'deepseek' = (aiConfig.provider || 'gemini') as 'gemini' | 'openai' | 'deepseek';
    const hasValidApiKey = provider === 'openai'
      ? aiConfig.openaiApiKey
      : provider === 'deepseek'
      ? aiConfig.deepseekApiKey
      : aiConfig.apiKey;
    // Generación manual = modo copiloto: el operador autenticado pide una
    // sugerencia. NO depende de `ai_enabled` (master switch del auto-responder).
    // Solo exigimos credenciales del provider activo, porque sin ellas no hay
    // a quién pedirle la respuesta.
    if (!hasValidApiKey) {
      return res.status(400).json({ error: 'AI credentials not configured for this session' });
    }

    // Fetch last 20 messages from chat
    const messagesRef = db
      .collection(ACCOUNTS_COLLECTION).doc(accountId)
      .collection('whatsapp_sessions').doc(phoneNumber)
      .collection('chats').doc(chatPhone)
      .collection('messages')
      .orderBy('timestamp', 'desc')
      .limit(20);

    const snapshot = await messagesRef.get();
    const rawDocs = snapshot.docs.reverse().map(d => d.data());
    const timezone = getSessionTimezone(aiConfig);
    const history = normalizeHistory(rawDocs, timezone);

    // El history ya incluye el último mensaje del cliente al final; no
    // hace falta extraerlo aparte. `generateAIResponse` lo trata como el
    // turn user actual y responde como model.
    //
    // throwOnError + timeoutMs: SOLO el modo manual (copiloto). Así el operador
    // recibe un error tipado si algo falla, sin afectar al auto-responder.
    const startedAt = Date.now();
    const suggestedText = await generateAIResponse(
      aiConfig.apiKey,
      aiConfig.systemPrompt,
      history,
      aiConfig.model,
      provider,
      aiConfig.openaiApiKey,
      aiConfig.deepseekApiKey,
      timezone,
      operatorInstruction,
      { throwOnError: true, timeoutMs: 25000 }
    );
    console.log(
      `[/generate-ai-response] provider=${provider} model=${aiConfig.model} historyLen=${history.length} latencyMs=${Date.now() - startedAt}`
    );

    res.json({ suggestedText });
  } catch (error) {
    // AiError tipado → status + code para que el frontend muestre el mensaje
    // correcto. Cualquier otro error cae al 500 genérico.
    if (error instanceof AiError) {
      const status = AI_ERROR_HTTP[error.code] ?? 502;
      console.warn(`[/generate-ai-response] AiError code=${error.code} status=${status} msg=${error.message}`);
      return res.status(status).json({ error: error.message, code: error.code });
    }
    console.error('Error generating AI response:', error);
    res.status(500).json({
      error: 'Failed to generate response',
      details: (error as any).message,
    });
  }
});

// REST API endpoint to edit a message
app.post('/edit-message', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { messageId, chatPhone, newText, sessionKey, accountId } = req.body;

    if (!messageId || !chatPhone || !newText || !sessionKey || !accountId) {
      return res.status(400).json({ error: 'Missing required fields: messageId, chatPhone, newText, sessionKey, accountId' });
    }

    const session = sessions.get(sessionKey);
    if (!session?.isReady || !session?.phoneNumber) {
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Get the remoteJid from the chat document
    let jid = chatPhone.includes('@') ? chatPhone : `${chatPhone}@s.whatsapp.net`;
    try {
      const chatDocRef = db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber)
        .collection('chats')
        .doc(chatPhone);

      const chatDoc = await chatDocRef.get();
      if (chatDoc.exists && chatDoc.data()?.remoteJid) {
        jid = chatDoc.data()!.remoteJid;
        console.log(`[/edit-message] Using stored remoteJid: ${jid}`);
      }
    } catch (error) {
      console.warn(`[/edit-message] Error retrieving chat document:`, error);
    }

    // Construct messageKey for Baileys
    const messageKey = {
      remoteJid: jid,
      id: messageId,
      fromMe: true
    };

    console.log(`[/edit-message] Editing message ${messageId} in chat ${chatPhone} with new text: ${newText}`);

    // Edit the message via Baileys
    await session.sock.sendMessage(jid, {
      text: newText,
      edit: messageKey
    });

    console.log(`[/edit-message] Message ${messageId} edited successfully`);

    res.json({
      success: true,
      messageId: messageId,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error('[/edit-message] Error:', error);
    res.status(500).json({
      error: 'Failed to edit message',
      details: (error as any).message,
    });
  }
});

// REST API endpoint to delete a message
app.post('/delete-message', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { messageId, chatPhone, sessionKey, accountId } = req.body;

    if (!messageId || !chatPhone || !sessionKey || !accountId) {
      return res.status(400).json({ error: 'Missing required fields: messageId, chatPhone, sessionKey, accountId' });
    }

    const session = sessions.get(sessionKey);
    if (!session?.isReady || !session?.phoneNumber) {
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Get the remoteJid from the chat document
    let jid = chatPhone.includes('@') ? chatPhone : `${chatPhone}@s.whatsapp.net`;
    try {
      const chatDocRef = db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber)
        .collection('chats')
        .doc(chatPhone);

      const chatDoc = await chatDocRef.get();
      if (chatDoc.exists && chatDoc.data()?.remoteJid) {
        jid = chatDoc.data()!.remoteJid;
        console.log(`[/delete-message] Using stored remoteJid: ${jid}`);
      }
    } catch (error) {
      console.warn(`[/delete-message] Error retrieving chat document:`, error);
    }

    // Construct messageKey for Baileys
    const messageKey = {
      remoteJid: jid,
      id: messageId,
      fromMe: true
    };

    console.log(`[/delete-message] Deleting message ${messageId} from chat ${chatPhone}`);

    // Delete the message via Baileys (for everyone)
    await session.sock.sendMessage(jid, {
      delete: messageKey
    });

    console.log(`[/delete-message] Message ${messageId} deleted successfully`);

    res.json({
      success: true,
      messageId: messageId,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error('[/delete-message] Error:', error);
    res.status(500).json({
      error: 'Failed to delete message',
      details: (error as any).message,
    });
  }
});

// Reaccionar a un mensaje (emoji nativo de WhatsApp). Soporta mensajes
// salientes (fromMe=true) y entrantes (fromMe=false). Pasar text='' quita
// la reacción. El backend NO escribe en Firestore acá: el `messages.upsert`
// del propio Baileys nos llegará como reactionMessage y el handler en
// firestoreService se encarga de mergear el campo `reactions` en el target.
app.post('/send-reaction', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { messageId, chatPhone, sessionKey, accountId, emoji, fromMe } = req.body;

    if (!messageId || !chatPhone || !sessionKey || !accountId || typeof fromMe !== 'boolean') {
      return res.status(400).json({ error: 'Missing required fields: messageId, chatPhone, sessionKey, accountId, fromMe' });
    }

    const session = sessions.get(sessionKey);
    if (!session?.isReady || !session?.phoneNumber) {
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Resolver remoteJid almacenado (igual que en delete/edit) — soporta LIDs.
    let jid = chatPhone.includes('@') ? chatPhone : `${chatPhone}@s.whatsapp.net`;
    try {
      const chatDocRef = db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber)
        .collection('chats')
        .doc(chatPhone);
      const chatDoc = await chatDocRef.get();
      if (chatDoc.exists && chatDoc.data()?.remoteJid) {
        jid = chatDoc.data()!.remoteJid;
      }
    } catch (error) {
      console.warn(`[/send-reaction] Error retrieving chat document:`, error);
    }

    // El key identifica el mensaje al que reacciono — fromMe del MENSAJE,
    // no del que reacciona. Si era saliente, fromMe=true; si era entrante, false.
    const messageKey = { remoteJid: jid, id: messageId, fromMe };

    const reactionText = typeof emoji === 'string' ? emoji : '';
    console.log(`[/send-reaction] ${reactionText ? `'${reactionText}'` : '(remove)'} -> ${messageId} (fromMe=${fromMe}) en chat ${chatPhone}`);

    await session.sock.sendMessage(jid, {
      react: { text: reactionText, key: messageKey },
    });

    res.json({ success: true, messageId, emoji: reactionText, timestamp: new Date().toISOString() });
  } catch (error) {
    console.error('[/send-reaction] Error:', error);
    res.status(500).json({ error: 'Failed to send reaction', details: (error as any).message });
  }
});

// Borrado completo de un chat: Storage + mensajes + chat doc.
// Hard-delete irreversible. La UI exige doble confirmación antes de invocar este endpoint.
app.post('/delete-chat', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { phoneNumber, sessionKey, sessionId, accountId } = req.body;

    if (!phoneNumber || !sessionKey || !sessionId || !accountId) {
      return res.status(400).json({ error: 'Missing required fields' });
    }

    const session = sessions.get(sessionKey);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.accountId !== accountId) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    // Paso 1: Storage primero. Si esto falla, preferimos quedarnos con el chat
    // doc visible (recuperable desde la UI) en vez de archivos huérfanos sin doc.
    const storagePrefix = `${ACCOUNTS_COLLECTION}/${accountId}/whatsapp_sessions/${sessionId}/chats/${phoneNumber}/`;
    let deletedFiles = 0;
    try {
      const bucket = admin.storage().bucket();
      const [files] = await bucket.getFiles({ prefix: storagePrefix });
      deletedFiles = files.length;
      if (deletedFiles > 0) {
        await bucket.deleteFiles({ prefix: storagePrefix });
      }
    } catch (storageError) {
      console.error(`[/delete-chat] Storage cleanup falló para ${phoneNumber}:`, storageError);
      return res.status(500).json({
        error: 'Failed to delete chat media',
        details: (storageError as any).message,
      });
    }

    // Paso 2: Mensajes en lotes de 500 (límite de batch de Firestore).
    const chatRef = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

    const messagesRef = chatRef.collection('messages');
    let deletedMessages = 0;
    while (true) {
      const snap = await messagesRef.limit(500).get();
      if (snap.empty) break;
      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      deletedMessages += snap.size;
      if (snap.size < 500) break;
    }

    // Paso 3: Chat doc.
    await chatRef.delete();

    console.log(`[/delete-chat] ${phoneNumber} eliminado (Account: ${accountId}, Session: ${sessionId}) — ${deletedMessages} mensajes, ${deletedFiles} archivos`);

    res.json({
      success: true,
      deletedMessages,
      deletedFiles,
    });
  } catch (error) {
    console.error('[/delete-chat] Error:', error);
    res.status(500).json({
      error: 'Failed to delete chat',
      details: (error as any).message,
    });
  }
});

// Endpoint que el cliente llama tras login (o tras ser agregado a una nueva
// cuenta) para refrescar custom claims. Las claims se embeben en el ID Token
// y son usadas por las Storage Rules (que no pueden hacer get() a Firestore).
// El propio cliente debe luego ejecutar `currentUser.getIdToken(true)` para
// que las claims tomen efecto en su token activo.
app.post('/auth/refresh-claims', express.json(), verifyHttpAuth({ requireAccountId: false }), async (req, res) => {
  try {
    const uid = req.auth!.uid;
    // Releemos Firestore (no usamos cache) para asegurar valor fresco.
    const snap = await db.collection('users').doc(uid).get();
    const memberOfAccounts: string[] =
      (snap.exists && (snap.data()?.memberOfAccounts as string[])) || [];
    await admin.auth().setCustomUserClaims(uid, { memberOf: memberOfAccounts });
    invalidateMembershipCache(uid);
    console.log(`[/auth/refresh-claims] uid=${uid} → memberOf=${memberOfAccounts.length} cuentas`);
    res.json({ success: true, memberOfAccounts });
  } catch (error) {
    console.error('[/auth/refresh-claims] Error:', error);
    res.status(500).json({ error: 'Failed to refresh claims' });
  }
});

// Crear sub-usuario para una cuenta. Solo el owner puede invitar a su
// propia cuenta. El owner sigue logueado: la creación corre 100% con
// Admin SDK, sin tocar el FirebaseAuth del cliente.
//
// Flujo:
// 1. Validar que requester sea owner Y dueño del accountId solicitado.
// 2. Generar password temporal CSPRNG.
// 3. admin.auth().createUser → nuevo Firebase Auth user.
// 4. setCustomUserClaims con memberOf = [accountId] (Storage Rules listas
//    desde el primer login).
// 5. Crear users/{newUid} con role 'member' y mustChangePassword true.
// 6. Crear accounts/{accountId}/members/{newUid} (mirror para listar).
// 7. Devolver email + tempPassword al owner una sola vez.
app.post('/accounts/members', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const requesterUid = req.auth!.uid;
    const { accountId, email, displayName } = req.body as {
      accountId: string;
      email?: string;
      displayName?: string;
    };

    const cleanEmail = (email || '').trim().toLowerCase();
    if (!cleanEmail || !cleanEmail.includes('@')) {
      return res.status(400).json({ error: 'Email inválido' });
    }
    // El nombre es obligatorio: lo usamos como etiqueta del autor en cada
    // mensaje saliente (etiqueta visible arriba de cada bubble). Sin nombre
    // los chats del CRM no muestran quién respondió.
    const cleanDisplayName = (displayName || '').trim();
    if (!cleanDisplayName) {
      return res.status(400).json({ error: 'El nombre es obligatorio' });
    }

    // Solo owners pueden invitar. Y solo a la cuenta de la que son owner.
    // Por ahora ownedAccountId == requesterUid (no soportamos owners de
    // múltiples cuentas todavía), así que esa es la única invariante.
    const requesterDoc = await db.collection('users').doc(requesterUid).get();
    if (!requesterDoc.exists) {
      return res.status(403).json({ error: 'Requester sin doc users/' });
    }
    const requesterData = requesterDoc.data()!;
    if (requesterData.role !== 'owner') {
      return res.status(403).json({ error: 'Solo el owner puede invitar miembros' });
    }
    if (requesterData.ownedAccountId !== accountId) {
      return res.status(403).json({ error: 'No puedes invitar a una cuenta que no es tuya' });
    }

    // Verificar email no exista (Firebase tira error feo si existe).
    try {
      await admin.auth().getUserByEmail(cleanEmail);
      return res.status(409).json({ error: 'Ese email ya está registrado' });
    } catch (e: any) {
      if (e?.code !== 'auth/user-not-found') {
        console.error('[/accounts/members] getUserByEmail error inesperado:', e);
        return res.status(500).json({ error: 'Error verificando email' });
      }
      // OK: no existe, podemos crearlo.
    }

    const tempPassword = generateTempPassword();

    // 1. Crear user en Firebase Auth.
    const newUser = await admin.auth().createUser({
      email: cleanEmail,
      password: tempPassword,
      displayName: cleanDisplayName,
      emailVerified: false,
    });

    // 2. Custom claims (memberOf) inmediatamente, así su primer login ya
    //    puede acceder a Storage sin esperar a /auth/refresh-claims.
    await admin.auth().setCustomUserClaims(newUser.uid, {
      memberOf: [accountId],
    });

    // 3. Doc users/{newUid} (sub-user). ownedAccountId apunta al owner.
    await db.collection('users').doc(newUser.uid).set({
      email: cleanEmail,
      displayName: cleanDisplayName,
      ownedAccountId: accountId,
      memberOfAccounts: [accountId],
      role: 'member',
      mustChangePassword: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: requesterUid,
    });

    // 4. Mirror en subcollection accounts/{accountId}/members.
    await db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('members')
      .doc(newUser.uid)
      .set({
        email: cleanEmail,
        displayName: cleanDisplayName,
        role: 'member',
        addedAt: admin.firestore.FieldValue.serverTimestamp(),
        addedBy: requesterUid,
      });

    // 5. Cache: si hubiera un cache stale para el owner, da igual; lo del
    //    sub-user ya quedó listo en Firestore + claims.
    invalidateMembershipCache(newUser.uid);

    console.log(
      `[/accounts/members] uid=${requesterUid} creó miembro ${newUser.uid} (${cleanEmail}) en cuenta ${accountId}`,
    );

    res.json({
      uid: newUser.uid,
      email: cleanEmail,
      tempPassword,
    });
  } catch (error) {
    console.error('[/accounts/members] Error:', error);
    res.status(500).json({
      error: 'Failed to create member',
      details: (error as any).message,
    });
  }
});

// Editar el displayName de un miembro (incluido el propio owner).
//
// Permisos:
// - Cualquier usuario puede editar SU PROPIO displayName (uid == requester).
// - Sólo el owner del accountId puede editar el displayName de otros miembros.
//
// Side effects: actualiza Firebase Auth + users/{uid} + mirror en
// accounts/{aid}/members/{uid} (si existe). Invalida el cache del
// senderResolver para que el siguiente mensaje muestre el nombre nuevo.
app.patch('/accounts/members/:uid', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const requesterUid = req.auth!.uid;
    const targetUid = req.params.uid;
    const { accountId, displayName } = req.body as {
      accountId: string;
      displayName?: string;
    };

    const cleanDisplayName = (displayName || '').trim();
    if (!cleanDisplayName) {
      return res.status(400).json({ error: 'El nombre es obligatorio' });
    }

    const editingSelf = requesterUid === targetUid;

    // Para edición de terceros exigimos rol owner sobre la cuenta y que el
    // target sea efectivamente miembro de esa cuenta. Para auto-edición
    // basta con la validación del middleware.
    if (!editingSelf) {
      const requesterDoc = await db.collection('users').doc(requesterUid).get();
      if (!requesterDoc.exists) {
        return res.status(403).json({ error: 'Requester sin doc users/' });
      }
      const requesterData = requesterDoc.data()!;
      if (requesterData.role !== 'owner' || requesterData.ownedAccountId !== accountId) {
        return res.status(403).json({ error: 'Solo el owner puede editar a otros miembros' });
      }

      const targetDoc = await db.collection('users').doc(targetUid).get();
      if (!targetDoc.exists) {
        return res.status(404).json({ error: 'Miembro no encontrado' });
      }
      const targetMemberOf = (targetDoc.data()?.memberOfAccounts as string[]) || [];
      if (!targetMemberOf.includes(accountId)) {
        return res.status(403).json({ error: 'El miembro no pertenece a esta cuenta' });
      }
    }

    // 1. Firebase Auth profile
    await admin.auth().updateUser(targetUid, { displayName: cleanDisplayName });

    // 2. users/{uid}: fuente de verdad para resolveHumanSender
    await db.collection('users').doc(targetUid).set(
      {
        displayName: cleanDisplayName,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    // 3. Mirror en accounts/{aid}/members/{uid} (sólo existe para sub-users;
    // el owner no tiene mirror). update() falla con NOT_FOUND si no existe,
    // lo cual es esperado para el owner — lo ignoramos silenciosamente.
    try {
      await db
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('members')
        .doc(targetUid)
        .update({
          displayName: cleanDisplayName,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (e: any) {
      if (e?.code !== 5) throw e; // 5 = NOT_FOUND (owner sin mirror)
    }

    // 4. Cache: el próximo mensaje del operador sale con el nuevo nombre.
    invalidateHumanNameCache(targetUid);

    console.log(
      `[PATCH /accounts/members] uid=${requesterUid} editó nombre de ${targetUid} → "${cleanDisplayName}"`,
    );

    res.json({ success: true, uid: targetUid, displayName: cleanDisplayName });
  } catch (error) {
    console.error('[PATCH /accounts/members] Error:', error);
    res.status(500).json({
      error: 'Failed to update member',
      details: (error as any).message,
    });
  }
});

// Backfill del media_index para una sesión existente.
// Recorre chats → messages y popula `media_index` con todo el histórico
// que sea indexable (image/video/document, sin GIFs). Idempotente: usa
// `set(merge:true)` en el helper. Pensado para correrse una sola vez por
// sesión tras desplegar la feature.
//
// Body: { accountId, sessionId }
// Respuesta: { success, scannedChats, indexedCount, skippedCount }
app.post('/backfill-media-index', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { accountId, sessionId } = req.body as {
      accountId?: string;
      sessionId?: string;
    };
    if (!accountId || !sessionId) {
      return res.status(400).json({ error: 'Missing accountId or sessionId' });
    }
    // verifyHttpAuth ya validó que el requester es miembro de accountId.

    const db = admin.firestore();
    const sessionRef = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId);

    const chatsSnap = await sessionRef.collection('chats').get();
    let scannedChats = 0;
    let indexedCount = 0;
    let skippedCount = 0;

    for (const chatDoc of chatsSnap.docs) {
      scannedChats++;
      const chatId = chatDoc.id;
      const chatData = chatDoc.data();
      const contactName: string | null = chatData?.contactName ?? null;

      // Paginamos los mensajes de a 500 para no cargar todo en memoria si
      // el chat es enorme. Avanzamos por `timestamp` desc + startAfter.
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      while (true) {
        let q: FirebaseFirestore.Query = chatDoc.ref
          .collection('messages')
          .where('isMedia', '==', true)
          .orderBy('timestamp', 'desc')
          .limit(500);
        if (cursor) q = q.startAfter(cursor);
        const page = await q.get();
        if (page.empty) break;

        for (const msgDoc of page.docs) {
          const m = msgDoc.data();
          const mediaFields = {
            mediaType: m.mediaType,
            mediaMime: m.mediaMime,
            mediaIsGif: m.mediaIsGif,
            mediaThumbBase64: m.mediaThumbBase64,
            mediaUrl: m.mediaUrl,
            mediaStatus: m.mediaStatus,
            mediaWidth: m.mediaWidth,
            mediaHeight: m.mediaHeight,
            mediaFileName: m.mediaFileName,
            mediaSize: m.mediaSize,
            mediaDuration: m.mediaDuration,
          };
          if (!isIndexableMedia(mediaFields)) {
            skippedCount++;
            continue;
          }
          await writeMediaIndexEntry({
            accountId,
            sessionId,
            messageId: msgDoc.id,
            chatId,
            contactName,
            timestamp: m.timestamp,
            fromMe: !!m.fromMe,
            senderType: m.senderType,
            senderName: m.senderName,
            mediaFields,
          });
          indexedCount++;
        }

        cursor = page.docs[page.docs.length - 1];
        if (page.size < 500) break;
      }
    }

    console.log(`[Backfill] media_index para ${accountId}/${sessionId}: chats=${scannedChats}, indexed=${indexedCount}, skipped=${skippedCount}`);
    res.json({ success: true, scannedChats, indexedCount, skippedCount });
  } catch (error) {
    console.error('[Backfill] Error:', error);
    res.status(500).json({
      error: 'Failed to backfill media_index',
      details: (error as any).message,
    });
  }
});

// Backfill del message_index para una sesión: recorre todos los chats y crea la
// entrada de búsqueda de cada mensaje con texto. Necesario una vez para indexar
// el histórico previo a esta feature (los mensajes nuevos se indexan al vuelo).
// Idempotente: re-ejecutarlo solo sobreescribe con merge. Mismo patrón paginado
// que /backfill-media-index.
app.post('/backfill-message-index', express.json(), verifyHttpAuth(), async (req, res) => {
  try {
    const { accountId, sessionId } = req.body as {
      accountId?: string;
      sessionId?: string;
    };
    if (!accountId || !sessionId) {
      return res.status(400).json({ error: 'Missing accountId or sessionId' });
    }
    // verifyHttpAuth ya validó que el requester es miembro de accountId.

    const db = admin.firestore();
    const sessionRef = db
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId);

    const chatsSnap = await sessionRef.collection('chats').get();
    let scannedChats = 0;
    let indexedCount = 0;
    let skippedCount = 0;

    for (const chatDoc of chatsSnap.docs) {
      scannedChats++;
      const chatId = chatDoc.id;
      const chatData = chatDoc.data();
      const contactName: string | null = chatData?.contactName ?? null;

      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      while (true) {
        let q: FirebaseFirestore.Query = chatDoc.ref
          .collection('messages')
          .orderBy('timestamp', 'desc')
          .limit(500);
        if (cursor) q = q.startAfter(cursor);
        const page = await q.get();
        if (page.empty) break;

        for (const msgDoc of page.docs) {
          const m = msgDoc.data();
          const text: string = m.text ?? '';
          // writeMessageIndexEntry hace no-op si el texto no tiene tokens
          // (media sin caption), pero contamos el skip para reportar.
          if (!text.trim()) {
            skippedCount++;
            continue;
          }
          await writeMessageIndexEntry({
            accountId,
            sessionId,
            messageId: msgDoc.id,
            chatId,
            text,
            contactName,
            timestamp: m.timestamp,
            fromMe: !!m.fromMe,
            senderName: m.senderName,
          });
          indexedCount++;
        }

        cursor = page.docs[page.docs.length - 1];
        if (page.size < 500) break;
      }
    }

    // Marcamos la sesión como ya indexada: a partir de aquí los mensajes nuevos
    // se indexan solos al guardarse, así que el frontend puede ocultar el botón
    // de backfill (no tiene sentido re-correrlo el histórico completo).
    await sessionRef.set(
      { message_index_backfilled_at: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true },
    );

    console.log(`[Backfill] message_index para ${accountId}/${sessionId}: chats=${scannedChats}, indexed=${indexedCount}, skipped=${skippedCount}`);
    res.json({ success: true, scannedChats, indexedCount, skippedCount });
  } catch (error) {
    console.error('[Backfill] Error:', error);
    res.status(500).json({
      error: 'Failed to backfill message_index',
      details: (error as any).message,
    });
  }
});

// REST API endpoint to send reminders manually
// NOTA: Este endpoint NO usa verifyHttpAuth porque es invocado por cron
// interno (sin Firebase user). Si en el futuro se expone al cliente, debe
// pasar por el middleware de auth para validar membresía.
app.post('/send-reminders', express.json(), async (req, res) => {
  try {
    const { sessionKey, accountId, sessionId } = req.body;

    if (!sessionKey || !accountId || !sessionId) {
      return res.status(400).json({ error: 'Missing sessionKey, accountId, or sessionId' });
    }

    const result = await ReminderService.processReminders(accountId, sessionId, sessionKey, sessions);
    res.json(result);
  } catch (error) {
    console.error('Error sending reminders (HTTP):', error);
    res.status(500).json({
      error: 'Failed to send reminders',
      details: (error as any).message,
    });
  }
});

// Disparo manual del agente de seguimiento (Fase 1: arma la cola, NO envía).
// Mismo patrón que /send-reminders: sin verifyHttpAuth porque lo invoca el cron
// interno. Útil para probar el clasificador y los borradores a demanda.
app.post('/run-followups', express.json(), async (req, res) => {
  try {
    const { sessionKey, accountId, sessionId } = req.body;

    if (!sessionKey || !accountId || !sessionId) {
      return res.status(400).json({ error: 'Missing sessionKey, accountId, or sessionId' });
    }

    const result = await FollowupService.buildFollowupQueue(accountId, sessionId, sessionKey, sessions);
    res.json(result);
  } catch (error) {
    console.error('Error running followups (HTTP):', error);
    res.status(500).json({
      error: 'Failed to run followups',
      details: (error as any).message,
    });
  }
});

// Handshake auth: rechazamos sockets sin idToken válido o sin membresía
// en el accountId solicitado. Esto cierra el hueco previo donde cualquier
// cliente podía unirse a la sala de cualquier cuenta tipeando un accountId.
io.use(verifySocketAuth);

io.on('connection', (socket) => {
  const accountId = socket.handshake.auth.accountId as string;
  const uid = socket.data.uid as string;
  console.log('[Socket.io] Cliente conectado: socket.id=' + socket.id + ', uid=' + uid + ', accountId=' + accountId);

  // Join this socket to a room named by accountId (for broadcasting to all their sessions)
  console.log('[Socket.io] Uniéndose a la sala: ' + accountId);
  socket.join(accountId);
  console.log('[Socket.io] Socket ' + socket.id + ' unido a la sala: ' + accountId);

  // Replay only this user's session states
  console.log('[Socket.io] Buscando sesiones existentes para accountId: ' + accountId);
  let sessionCount = 0;
  for (const [key, session] of sessions) {
    if (session.accountId !== accountId) continue;
    sessionCount++;

    if (session.isReady && session.phoneNumber) {
      console.log('[Socket.io] Reenviando READY para sessionKey: ' + key);
      socket.emit('ready', { phoneNumber: session.phoneNumber, sessionKey: key });
    } else if (session.currentQR) {
      console.log('[Socket.io] Reenviando QR para sessionKey: ' + key);
      socket.emit('qr', { qr: session.currentQR, sessionKey: key });
    }
  }
  console.log('[Socket.io] Total de sesiones encontradas para ' + accountId + ': ' + sessionCount);

  socket.on('cancel_session', async (data) => {
    const { sessionKey } = data;
    console.log('[Socket.io] cancel_session recibido para:', sessionKey);

    const session = sessions.get(sessionKey);
    if (!session) {
      socket.emit('error', { message: 'Session not found' });
      return;
    }

    if (session.accountId !== accountId) {
      socket.emit('error', { message: 'Unauthorized' });
      return;
    }

    const success = await cancelSession(sessionKey);
    socket.emit('session_cancelled', { sessionKey, success });
  });

  // Handle message sending via WebSocket
  socket.on('send_message_socket', async (data) => {
    const { to, text, imageUrl, sessionKey, accountId: msgAccountId } = data;
    console.log(`[Socket.io] Enviar mensaje solicitado para: ${to}`);

    try {
      // Security check: ensure accountId matches socket auth
      if (msgAccountId !== accountId) {
        throw new Error('Unauthorized accountId');
      }

      const result = await performSendMessage(data, uid);

      // Emit success back to the specific client
      socket.emit('message_sent_success', {
        to,
        messageId: result.messageId,
        tempId: data.tempId // We'll add this in Flutter for optimistic UI
      });
    } catch (error) {
      console.error('[Socket.io] Error enviando mensaje:', error);
      socket.emit('message_sent_error', { 
        to, 
        error: (error as any).message 
      });
    }
  });

  // 📌 Cancel pending buffer when user disables AI for a specific contact
  socket.on('cancel_ai_buffer', (data) => {
    const { sessionKey, contactPhone } = data;
    console.log('[Socket.io] cancel_ai_buffer recibido para:', contactPhone, 'en sesión:', sessionKey);

    const session = sessions.get(sessionKey);
    if (!session || session.accountId !== accountId) {
      console.warn('[Socket.io] Unauthorized or session not found for cancel_ai_buffer');
      socket.emit('ai_toggle_result', { success: false, message: 'Unauthorized' });
      return;
    }

    const bufferKey = `${sessionKey}:${contactPhone}`;
    const buffer = messageBuffers.get(bufferKey);

    if (buffer && buffer.timeout) {
      clearTimeout(buffer.timeout);
      messageBuffers.delete(bufferKey);
      console.log(`[Buffer] CANCELLED via Socket.io: User disabled AI for ${contactPhone}`);
      socket.emit('ai_toggle_result', { success: true, message: 'IA desactivada', contactPhone });
    } else {
      console.log(`[Buffer] No pending buffer found for ${contactPhone}`);
      socket.emit('ai_toggle_result', { success: true, message: 'IA desactivada', contactPhone });
    }
    // Cualquiera de los dos caminos: el frontend ya no debe ver indicador de IA
    emitAiState(accountId, sessionKey, contactPhone, 'idle');
  });
});

async function startExistingSessions() {
  // --- HEALTH CHECK: Synchronize Firestore status with local auth_info ---
  try {
    console.log('[HealthCheck] Sincronizando estados fantasma con Firestore...');
    
    // Get all account documents first to avoid collectionGroup index requirement
    const accountsSnapshot = await db.collection(ACCOUNTS_COLLECTION).get();
    let cleanedCount = 0;

    for (const accountDoc of accountsSnapshot.docs) {
      const sessionsSnapshot = await accountDoc.ref
        .collection('whatsapp_sessions')
        .where('status', '==', 'connected')
        .get();

      for (const sessionDoc of sessionsSnapshot.docs) {
        const data = sessionDoc.data();
        const sessionKey = data.session_key;
        
        // If no sessionKey is stored or the local auth directory/creds don't exist
        if (!sessionKey || !existsSync(`auth_info/${sessionKey}/creds.json`)) {
          console.log(`[HealthCheck] Marcando sesión huérfana como desconectada: ${sessionDoc.id} (Account: ${accountDoc.id})`);
          await sessionDoc.ref.update({
            status: 'disconnected',
            disconnect_reason: 'health_check_cleanup',
            last_sync: admin.firestore.Timestamp.now(),
          });
          cleanedCount++;
        }
      }
    }

    if (cleanedCount > 0) {
      console.log(`[HealthCheck] ✅ Sincronización completada. Limpiadas ${cleanedCount} sesiones fantasma.`);
    } else {
      console.log('[HealthCheck] ✅ Todo en orden. No hay sesiones fantasma.');
    }
  } catch (error) {
    console.error('[HealthCheck] Error durante la sincronización:', error);
  }

  if (!existsSync('auth_info')) {
    console.log('No existing auth_info directory');
    return;
  }

  const entries = readdirSync('auth_info', { withFileTypes: true });
  const subdirs = entries
    .filter(e => e.isDirectory() && existsSync(`auth_info/${e.name}/creds.json`))
    .map(e => e.name);

  if (subdirs.length === 0) {
    console.log('No existing sessions to reconnect');
    return;
  }

  console.log(`Auto-reconnecting ${subdirs.length} existing session(s)...`);
  for (const sessionKey of subdirs) {
    const metaPath = `auth_info/${sessionKey}/meta.json`;
    if (!existsSync(metaPath)) {
      console.warn(`Skipping session ${sessionKey}: no meta.json (pre-migration session?)`);
      continue;
    }

    try {
      const meta = JSON.parse(readFileSync(metaPath, 'utf-8'));
      const accountId = meta.accountId as string;
      if (!accountId) {
        console.warn(`Skipping session ${sessionKey}: meta.json has no accountId`);
        continue;
      }

      await startSession(sessionKey, accountId);
    } catch (error) {
      console.error(`Error reading meta.json for ${sessionKey}:`, error);
    }
  }
}

const PORT = parseInt(process.env.PORT || '3000', 10);
httpServer.listen(PORT, async () => {
  const envLabel = IS_PRODUCTION ? 'PRODUCTION 🚀' : 'DEVELOPMENT 🛠️';
  console.log(`Server running on port ${PORT}`);
  console.log(`[Env] ${envLabel} | NODE_ENV=${process.env.NODE_ENV ?? 'undefined'} | Firestore collection: "${ACCOUNTS_COLLECTION}"`);
  await startExistingSessions();

  // Setup cron for reminders (checks every minute)
  cron.schedule('* * * * *', () => {
    ReminderService.checkAndRunScheduledReminders(sessions);
    // Agente de seguimiento: mismo tick. Cada uno arma su cola a su hora configurada.
    FollowupService.checkAndRunScheduledFollowups(sessions);
  });
});
