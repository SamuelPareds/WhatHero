import 'dotenv/config';
import express from 'express';
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

admin.initializeApp({
  credential: admin.credential.cert(firebaseCredential),
});

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

const db = admin.firestore();
const logger = pino({ level: 'info' }, pino.destination({ sync: false }));

interface SessionData {
  sock: any;
  isReady: boolean;
  currentQR: string | undefined;
  phoneNumber: string | undefined;
  isReconnecting: boolean;
  accountId: string;
}

const sessions = new Map<string, SessionData>();

// Helper function to extract and clean phone number from Baileys JID
// Handles format: "5215561642726:50@s.whatsapp.net" -> "5215561642726"
function extractPhoneNumber(jid: string | undefined): string {
  if (!jid) return '';

  // Remove WhatsApp domain suffixes
  let cleaned = jid.replace('@s.whatsapp.net', '').replace('@g.us', '');

  // Remove device suffix (e.g., ":50")
  const phoneOnly = cleaned.split(':')[0];

  return phoneOnly || '';
}

// Initialize/update session document in Firestore
async function initializeSession(phoneNumber: string, sessionKey: string, accountId: string) {
  try {
    const sessionDocRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(phoneNumber);

    const sessionData = {
      phone_number: phoneNumber,
      alias: `Sucursal - ${phoneNumber}`,
      status: 'connected',
      last_sync: admin.firestore.Timestamp.now(),
      connected_at: admin.firestore.FieldValue.serverTimestamp(),
      session_key: sessionKey,
    };

    await sessionDocRef.set(sessionData, { merge: true });
    console.log(`Session initialized for phone: ${phoneNumber} with key: ${sessionKey}`);
  } catch (error) {
    console.error('Error initializing session:', error);
  }
}

async function saveMessageToFirestore(message: any, sessionKey: string, accountId: string, botJid?: string) {
  try {
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) {
      console.warn('Session phone number not set, cannot save message');
      return;
    }

    const sessionId = session.phoneNumber;

    // Extract clean phone number from the message's remote JID
    const remoteJid = message.key.remoteJid;
    if (!remoteJid) return;

    const phoneNumber = extractPhoneNumber(remoteJid);
    if (!phoneNumber) return;

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text ||
                        message.message?.imageMessage?.caption ||
                        '';

    const messageTimestamp = message.messageTimestamp ? message.messageTimestamp * 1000 : Date.now();
    const messageId = message.key.id;

    // New path: accounts/{accountId}/whatsapp_sessions/{sessionId}/chats/{chatId}/messages
    const chatDocRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

    const messagesSubCollectionRef = chatDocRef.collection('messages');

    // Save message to messages subcollection
    await messagesSubCollectionRef.doc(messageId).set({
      id: messageId,
      text: messageText,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      from: message.key.fromMe ? (botJid || 'bot') : phoneNumber,
      fromMe: message.key.fromMe,
      isMedia: !!message.message?.imageMessage || !!message.message?.documentMessage || !!message.message?.audioMessage,
    }, { merge: true });

    // Update the chat document with lastMessage (for efficient list display)
    await chatDocRef.set({
      phoneNumber,
      lastMessage: messageText.substring(0, 100),
      lastMessageTimestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      lastMessageId: messageId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // Also update the session document with the latest lastMessage info
    const sessionDocRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId);

    await sessionDocRef.update({
      last_message: messageText.substring(0, 100),
      last_message_timestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      last_chat_id: phoneNumber,
      last_sync: admin.firestore.Timestamp.now(),
    });

    console.log(`Message saved for ${phoneNumber} (Account: ${accountId}, Session: ${sessionId})`);
  } catch (error) {
    console.error('Error saving message to Firestore:', error);
  }
}

async function startSession(sessionKey: string, accountId: string) {
  const { state, saveCreds } = await useMultiFileAuthState(`auth_info/${sessionKey}`);
  const { version } = await fetchLatestBaileysVersion();

  // Write metadata file so startExistingSessions() can recover this session on reboot
  writeFileSync(`auth_info/${sessionKey}/meta.json`, JSON.stringify({ accountId }));

  // Initialize session data
  sessions.set(sessionKey, {
    sock: null,
    isReady: false,
    currentQR: undefined,
    phoneNumber: undefined,
    isReconnecting: false,
    accountId,
  });

  const sock = makeWASocket({
    version,
    auth: state,
    logger: logger.child({ class: 'baileys' }),
    printQRInTerminal: true
  });

  sock.ev.on('creds.update', saveCreds);

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

      // Mark session as disconnected
      if (session.phoneNumber) {
        try {
          const sessionDocRef = db
            .collection('accounts')
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

      if (statusCode === DisconnectReason.loggedOut) {
        console.log(`WhatsApp logged out from device (${sessionKey}). Clearing auth.`);

        // Clear auth folder for this session
        try {
          rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
          console.log(`auth_info/${sessionKey} cleared`);
        } catch (error) {
          console.error('Error clearing auth folder:', error);
        }

        session.currentQR = undefined;
        session.phoneNumber = undefined;
        sessions.delete(sessionKey);

        // Notify frontend
        io.to(session.accountId).emit('status_update', { status: 'logged_out', sessionKey });
      } else {
        // Regular disconnection - attempt normal reconnect
        console.log('connection closed due to ', lastDisconnect?.error, ', attempting reconnect');
        if (!session.isReconnecting) {
          session.isReconnecting = true;
          setTimeout(() => {
            startSession(sessionKey, session.accountId);
            session.isReconnecting = false;
          }, 3000);
        }
      }
    } else if (connection === 'open') {
      console.log('[startSession] Conexión abierta para sessionKey:', sessionKey);
      session.isReady = true;
      session.currentQR = undefined;

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
    const message = m.messages?.[0];
    if (message) {
      await saveMessageToFirestore(message, sessionKey, accountId, sock.user?.id);
    }
  });

  // Store socket reference in session
  const session = sessions.get(sessionKey);
  if (session) session.sock = sock;

  return sock;
}

// REST API endpoint to start a new session
app.post('/start-session', express.json(), async (req, res) => {
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

// REST API endpoint to send messages
app.post('/send-message', express.json(), async (req, res) => {
  try {
    const { to, text, sessionKey } = req.body;

    if (!to || !text || !sessionKey) {
      return res.status(400).json({ error: 'Missing "to", "text", or "sessionKey" field' });
    }

    const session = sessions.get(sessionKey);
    if (!session?.isReady) {
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Format the phone number for WhatsApp
    const jid = to.includes('@') ? to : `${to}@s.whatsapp.net`;

    // Send the message via Baileys
    const message = await session.sock.sendMessage(jid, { text });

    console.log(`Message sent to ${to}:`, text);

    res.json({
      success: true,
      messageId: message.key.id,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error('Error sending message:', error);
    res.status(500).json({
      error: 'Failed to send message',
      details: (error as any).message,
    });
  }
});

io.on('connection', (socket) => {
  const accountId = socket.handshake.auth.accountId as string | undefined;
  console.log('[Socket.io] Cliente conectado: socket.id=' + socket.id + ', accountId=' + accountId);

  if (!accountId) {
    console.warn('[Socket.io] Socket ' + socket.id + ' conectado sin accountId, desconectando');
    socket.disconnect();
    return;
  }

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
});

async function startExistingSessions() {
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
  console.log(`Server running on port ${PORT}`);
  await startExistingSessions();
});
