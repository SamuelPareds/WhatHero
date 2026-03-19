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
import { SessionData, MessageBuffer } from './src/types';
import { extractPhoneNumber, storeLIDMapping, resolveLIDFromContacts } from './src/utils/phone';
import { initializeSession, saveMessageToFirestore, getAIConfig, updateContactInFirestore, consolidateLIDChat } from './src/services/firestoreService';
import { isWithinActiveHours, generateAIResponse, normalizeHistory, processMessageBuffer } from './src/services/aiService';

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

// Enable CORS for Express (web requests)
app.use(cors({
  origin: "*",
  methods: ["GET", "POST", "OPTIONS"],
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

// Make io available to aiService via global variable for lazy evaluation
(global as any).__WhatHeroIO = io;

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

  // Listen for contact updates to capture agenda names
  sock.ev.on('contacts.upsert', (contacts) => {
    for (const contact of contacts) {
      updateContactInFirestore(contact, sessionKey, accountId, sessions);
    }
  });

  sock.ev.on('contacts.update', (updates) => {
    for (const update of updates) {
      updateContactInFirestore(update, sessionKey, accountId, sessions);
    }
  });

  // Listen for LID-to-Phone mappings (Baileys v6.6+)
  // This is crucial for resolving @lid format JIDs to real phone numbers
  (sock.ev.on as any)('lid-mapping.update', async (mappings: Record<string, string>) => {
    console.log(`[startSession] LID-Mapping update received with ${Object.keys(mappings).length} mappings`);
    const session = sessions.get(sessionKey);

    for (const [lid, phoneNumber] of Object.entries(mappings)) {
      storeLIDMapping(lid, phoneNumber);

      // Consolidate any duplicate chats created under the LID identifier
      if (session?.phoneNumber) {
        await consolidateLIDChat(accountId, session.phoneNumber, lid, phoneNumber);
      }
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
    if (!message) return;

    await saveMessageToFirestore(message, sessionKey, accountId, sessions, sock.user?.id, sock);

    // AI auto-response: only for incoming messages (not from self)
    if (message.key.fromMe) {
      // 📌 Cancel any pending buffer for this contact when human responds
      const remoteJidForCancel = message.key.remoteJid;
      if (remoteJidForCancel && !remoteJidForCancel.endsWith('@g.us')) {
        const contactPhoneForCancel = extractPhoneNumber(remoteJidForCancel);
        if (contactPhoneForCancel) {
          const bufferKey = `${sessionKey}:${contactPhoneForCancel}`;
          const buffer = messageBuffers.get(bufferKey);
          if (buffer?.timeout) {
            clearTimeout(buffer.timeout);
            messageBuffers.delete(bufferKey);
            console.log(`[Buffer] CANCELLED: Human response detected for ${contactPhoneForCancel}`);
          }
        }
      }
      return;
    }
    const remoteJid = message.key.remoteJid;
    if (!remoteJid || remoteJid.endsWith('@g.us')) return; // skip group messages

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text || '';
    if (!messageText.trim()) return; // skip media-only messages

    // Get AI config with caching
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) return;

    const aiConfig = await getAIConfig(session, accountId);
    const provider: 'gemini' | 'openai' = (aiConfig.provider || 'gemini') as 'gemini' | 'openai';
    const hasValidApiKey = provider === 'openai'
      ? aiConfig.openaiApiKey
      : aiConfig.apiKey;
    if (!aiConfig.enabled || !hasValidApiKey) return;

    // Extract contact phone number
    let contactPhone = extractPhoneNumber(remoteJid);
    if (!contactPhone) return; // Skip if we can't extract phone number

    // If we got a LID format, try to resolve it to a real phone number
    if (remoteJid.includes('@lid')) {
      console.log(`[AI] Message from LID format: ${remoteJid}, attempting to resolve...`);
      const resolved = await resolveLIDFromContacts(contactPhone, sock);
      if (resolved) {
        contactPhone = resolved;
        console.log(`[AI] Successfully resolved LID to ${contactPhone}`);
      } else {
        console.warn(`[AI] Could not resolve LID ${contactPhone}, will use LID as contact identifier`);
      }
    }

    // Check if within active hours
    if (!isWithinActiveHours(aiConfig)) {
      console.log(`[AI] Outside active hours, skipping AI response`);
      return;
    }

    // Check if AI auto-response is enabled for this specific contact
    let aiAutoResponseEnabled = true; // Default: IA enabled
    try {
      const chatDocRef = db
        .collection('accounts')
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber)
        .collection('chats')
        .doc(contactPhone);

      const chatDoc = await chatDocRef.get();
      aiAutoResponseEnabled = (chatDoc.data()?.ai_auto_response as boolean) ?? true;
    } catch (error) {
      console.warn(`[AI] Error checking ai_auto_response for ${contactPhone}:`, error);
    }

    if (!aiAutoResponseEnabled) {
      console.log(`[AI] Auto-response disabled for ${contactPhone}, skipping AI response`);
      return;
    }

    // Check keyword rules (fast-path, immediate response - not buffered)
    for (const rule of aiConfig.keywordRules) {
      if (messageText.toLowerCase().includes(rule.keyword.toLowerCase())) {
        console.log(`[AI] Keyword rule matched: "${rule.keyword}", sending canned response`);
        await new Promise(r => setTimeout(r, aiConfig.responseDelayMs));
        await session.sock.sendMessage(remoteJid, { text: rule.response });
        return;
      }
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

    // Set new timeout to process buffer after delay
    buffer.timeout = setTimeout(async () => {
      console.log(`[Buffer] Timeout expired for ${contactPhone}, processing ${buffer.messages.length} message(s)`);

      // Mark buffer as responded BEFORE processing to prevent race conditions
      buffer.responded = true;

      // Process the buffered messages
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

// REST API endpoint to cancel a session
app.post('/cancel-session', express.json(), async (req, res) => {
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

// REST API endpoint to send messages (text or media with optional caption)
app.post('/send-message', express.json(), async (req, res) => {
  try {
    const { to, text, imageUrl, sessionKey, accountId } = req.body;

    // text is optional if imageUrl is provided, but at least one must exist
    if (!to || !sessionKey || !accountId || (!text && !imageUrl)) {
      return res.status(400).json({ error: 'Missing required fields: to, sessionKey, accountId, and at least one of (text, imageUrl)' });
    }

    const session = sessions.get(sessionKey);
    if (!session?.isReady || !session?.phoneNumber) {
      return res.status(503).json({ error: 'Session not ready' });
    }

    // Try to get the stored remoteJid from the chat document
    // This is important for @lid format contacts - we need to use the exact JID format
    let jid = to.includes('@') ? to : `${to}@s.whatsapp.net`; // Default fallback

    try {
      const chatDocRef = db
        .collection('accounts')
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber)
        .collection('chats')
        .doc(to);

      const chatDoc = await chatDocRef.get();
      if (chatDoc.exists && chatDoc.data()?.remoteJid) {
        jid = chatDoc.data()!.remoteJid;
        console.log(`[/send-message] Using stored remoteJid: ${jid}`);
      } else {
        console.log(`[/send-message] No stored remoteJid found for ${to}, using default: ${jid}`);
      }
    } catch (error) {
      console.warn(`[/send-message] Error retrieving chat document:`, error);
      // Continue with default jid
    }

    console.log(`[/send-message] Sending message to JID: ${jid}`);

    // Send the message via Baileys (text or image with optional caption)
    let message;
    if (imageUrl) {
      // Send as image with optional caption
      // Baileys requires image as Buffer, not URL - download it first
      try {
        console.log(`[/send-message] Downloading image from URL: ${imageUrl}`);
        const imageResponse = await fetch(imageUrl).then(res => {
          if (!res.ok) throw new Error(`Failed to fetch image: ${res.statusText}`);
          return res.arrayBuffer();
        });
        const imageBuffer = Buffer.from(imageResponse);

        message = await session.sock.sendMessage(jid, {
          image: imageBuffer,
          caption: text || undefined,
        });
        console.log(`Image sent to ${to} with caption: ${text || '(no caption)'}`);
      } catch (imageError) {
        console.error(`[/send-message] Error downloading/sending image:`, imageError);
        throw new Error(`Failed to process image URL: ${(imageError as any).message}`);
      }
    } else {
      // Send as text
      message = await session.sock.sendMessage(jid, { text });
      console.log(`Text message sent to ${to}:`, text);
    }

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

// REST API endpoint to generate AI response (bypass discriminator)
// Used when operator wants AI to generate a response for approval before sending
app.post('/generate-ai-response', express.json(), async (req, res) => {
  try {
    const { chatPhone, sessionKey, accountId } = req.body;

    if (!chatPhone || !sessionKey || !accountId) {
      return res.status(400).json({ error: 'Missing chatPhone, sessionKey, or accountId' });
    }

    // Find active session
    const sessionData = sessions.get(sessionKey);
    if (!sessionData) {
      return res.status(404).json({ error: 'Session not found' });
    }

    const phoneNumber = sessionData.phoneNumber!;

    // Load AI config
    const aiConfig = await getAIConfig(sessionData, accountId);
    const provider: 'gemini' | 'openai' = (aiConfig.provider || 'gemini') as 'gemini' | 'openai';
    const hasValidApiKey = provider === 'openai'
      ? aiConfig.openaiApiKey
      : aiConfig.apiKey;
    if (!aiConfig.enabled || !hasValidApiKey) {
      return res.status(400).json({ error: 'AI not configured for this session' });
    }

    // Fetch last 20 messages from chat
    const messagesRef = db
      .collection('accounts').doc(accountId)
      .collection('whatsapp_sessions').doc(phoneNumber)
      .collection('chats').doc(chatPhone)
      .collection('messages')
      .orderBy('timestamp', 'desc')
      .limit(20);

    const snapshot = await messagesRef.get();
    const rawDocs = snapshot.docs.reverse().map(d => d.data());
    const history = normalizeHistory(rawDocs);

    // Get last user message for context
    const lastUserMsg = rawDocs.filter(m => !m.fromMe).at(-1)?.text ?? '';

    // Generate response directly (bypass discriminator)
    const suggestedText = await generateAIResponse(
      aiConfig.apiKey,
      aiConfig.systemPrompt,
      lastUserMsg,
      history,
      aiConfig.model,
      provider,
      aiConfig.openaiApiKey
    );

    if (!suggestedText) {
      return res.status(500).json({ error: 'AI failed to generate response' });
    }

    res.json({ suggestedText });
  } catch (error) {
    console.error('Error generating AI response:', error);
    res.status(500).json({
      error: 'Failed to generate response',
      details: (error as any).message,
    });
  }
});

// DEV ONLY: Delete chat history (triggered by "elimhis" command)
app.post('/delete-chat-history', express.json(), async (req, res) => {
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

    // Delete all messages in this chat
    const chatRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

    const messagesRef = chatRef.collection('messages');
    const messagesSnapshot = await messagesRef.get();

    // Batch delete all messages
    const batch = db.batch();
    messagesSnapshot.docs.forEach((doc) => {
      batch.delete(doc.ref);
    });
    await batch.commit();

    // Reset chat document (keep it but clear lastMessage)
    await chatRef.update({
      lastMessage: '',
      lastMessageTimestamp: null,
      lastMessageId: '',
    });

    console.log(`[DEV] Chat history deleted for ${phoneNumber} (Account: ${accountId}, Session: ${sessionId})`);

    res.json({
      success: true,
      message: 'Chat history deleted',
      deletedCount: messagesSnapshot.size,
    });
  } catch (error) {
    console.error('[DEV] Error deleting chat history:', error);
    res.status(500).json({
      error: 'Failed to delete chat history',
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
  });
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
