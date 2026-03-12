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
import { rmSync, existsSync, readdirSync, writeFileSync, readFileSync } from 'fs';
import { randomUUID } from 'crypto';
import serviceAccount from './serviceAccountKey.json' with { type: 'json' };

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

// Initialize Firebase Admin
admin.initializeApp({
  credential: admin.credential.cert(serviceAccount as admin.ServiceAccount),
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
      console.warn(`[${sessionKey}] Session phone number not set, cannot save message`);
      return;
    }

    const sessionId = session.phoneNumber;
    console.log(`[${sessionKey}] Saving message for account: ${accountId}, session: ${sessionId}`);

    // Extract clean phone number from the message's remote JID
    const remoteJid = message.key.remoteJid;
    if (!remoteJid) {
      console.warn(`[${sessionKey}] No remoteJid in message, skipping`);
      return;
    }

    const phoneNumber = extractPhoneNumber(remoteJid);
    if (!phoneNumber) {
      console.warn(`[${sessionKey}] Could not extract phone number from: ${remoteJid}`);
      return;
    }

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text ||
                        message.message?.imageMessage?.caption ||
                        '';

    if (!messageText) {
      console.warn(`[${sessionKey}] Message has no text content`);
    }

    const messageTimestamp = message.messageTimestamp ? message.messageTimestamp * 1000 : Date.now();
    const messageId = message.key.id;

    console.log(`[${sessionKey}] Extracted message: ID=${messageId}, phone=${phoneNumber}, text="${messageText.substring(0, 50)}..."`);


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

    console.log(`[${sessionKey}] ✅ Message saved successfully for ${phoneNumber} (Account: ${accountId}, Session: ${sessionId}, MessageID: ${messageId})`);
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
      console.log('QR Code received for session:', sessionKey);
      session.currentQR = qr;
      session.isReady = false;
      io.to(session.accountId).emit('qr', { qr, sessionKey });
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
      console.log('opened connection for session:', sessionKey);
      session.isReady = true;
      session.currentQR = undefined;

      // Extract and store the connected phone number
      if (sock.user?.id) {
        const phoneNumber = extractPhoneNumber(sock.user.id);
        session.phoneNumber = phoneNumber;
        console.log(`WhatsApp connected as: ${phoneNumber} (session: ${sessionKey})`);

        // Initialize session document in Firestore
        await initializeSession(phoneNumber, sessionKey, session.accountId);
      }

      io.to(session.accountId).emit('ready', { phoneNumber: session.phoneNumber, sessionKey });
    }
  });

  // Listen for incoming and outgoing messages
  sock.ev.on('messages.upsert', async (m) => {
    console.log(`[${sessionKey}] messages.upsert event received, message count: ${m.messages?.length}`);
    const message = m.messages?.[0];
    if (message) {
      console.log(`[${sessionKey}] Processing message:`, {
        id: message.key.id,
        from: message.key.remoteJid,
        fromMe: message.key.fromMe,
        hasText: !!message.message?.conversation,
        hasExtendedText: !!message.message?.extendedTextMessage,
      });
      await saveMessageToFirestore(message, sessionKey, accountId, sock.user?.id);
    } else {
      console.warn(`[${sessionKey}] No message found in upsert event`);
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
    if (!accountId) {
      return res.status(400).json({ error: 'Missing accountId in request body' });
    }

    const sessionKey = randomUUID();
    await startSession(sessionKey, accountId);
    res.json({ sessionKey });
  } catch (error) {
    console.error('Error starting session:', error);
    res.status(500).json({ error: 'Failed to start session' });
  }
});

// REST API endpoint to send messages
app.post('/send-message', express.json(), async (req, res) => {
  try {
    const { to, text, sessionKey } = req.body;

    console.log(`[/send-message] Request: to=${to}, text="${text}", sessionKey=${sessionKey}`);

    if (!to || !text || !sessionKey) {
      console.warn(`[/send-message] Missing fields: to=${to}, text=${text}, sessionKey=${sessionKey}`);
      return res.status(400).json({ error: 'Missing "to", "text", or "sessionKey" field' });
    }

    const session = sessions.get(sessionKey);
    if (!session) {
      console.error(`[/send-message] Session not found: ${sessionKey}`);
      return res.status(503).json({ error: 'Session not found' });
    }

    if (!session.isReady) {
      console.error(`[/send-message] Session not ready: ${sessionKey}`);
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Validate phone number format
    let cleanPhone = to.replace(/\D/g, ''); // Remove non-digits
    if (cleanPhone.length < 10) {
      console.error(`[/send-message] Invalid phone number: ${to}`);
      return res.status(400).json({ error: 'Invalid phone number format' });
    }

    // Format the phone number for WhatsApp
    const jid = to.includes('@') ? to : `${cleanPhone}@s.whatsapp.net`;

    console.log(`[/send-message] Sending message from ${session.phoneNumber} to ${jid}`);

    // Send the message via Baileys
    const message = await session.sock.sendMessage(jid, { text });

    console.log(`[/send-message] Message sent successfully. ID=${message.key.id}, to=${jid}, text="${text.substring(0, 50)}..."`);

    res.json({
      success: true,
      messageId: message.key.id,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error('[/send-message] Error:', error);
    res.status(500).json({
      error: 'Failed to send message',
      details: (error as any).message,
    });
  }
});

// Diagnostic endpoint to check messages saved in Firestore
app.get('/debug/messages/:accountId/:sessionId/:phoneNumber', async (req, res) => {
  try {
    const { accountId, sessionId, phoneNumber } = req.params;
    console.log(`[/debug/messages] Query: account=${accountId}, session=${sessionId}, phone=${phoneNumber}`);

    const messagesRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber)
      .collection('messages');

    const snapshot = await messagesRef.orderBy('timestamp', 'desc').limit(20).get();
    const messages = snapshot.docs.map(doc => ({
      id: doc.id,
      ...doc.data(),
    }));

    res.json({
      accountId,
      sessionId,
      phoneNumber,
      messageCount: messages.length,
      messages: messages,
    });
  } catch (error) {
    console.error('[/debug/messages] Error:', error);
    res.status(500).json({
      error: 'Failed to fetch messages',
      details: (error as any).message,
    });
  }
});

io.on('connection', (socket) => {
  const accountId = socket.handshake.auth.accountId as string | undefined;
  console.log(`Socket.io client connected: ${socket.id}, accountId: ${accountId}`);

  if (!accountId) {
    console.warn(`Socket ${socket.id} connected without accountId, disconnecting`);
    socket.disconnect();
    return;
  }

  // Join this socket to a room named by accountId (for broadcasting to all their sessions)
  socket.join(accountId);

  // Replay only this user's session states
  for (const [key, session] of sessions) {
    if (session.accountId !== accountId) continue;

    if (session.isReady && session.phoneNumber) {
      socket.emit('ready', { phoneNumber: session.phoneNumber, sessionKey: key });
    } else if (session.currentQR) {
      socket.emit('qr', { qr: session.currentQR, sessionKey: key });
    }
  }
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

httpServer.listen(3000, async () => {
  console.log('Server running on port 3000');
  await startExistingSessions();
});
