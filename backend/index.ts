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
import { rmSync } from 'fs';
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

let currentQR: string | undefined;
let isReady = false;
let waSocket: any = null; // Store socket reference for sending messages
let isReconnecting = false; // Prevent multiple reconnection attempts
let currentUserPhone: string | undefined; // Store the connected WhatsApp phone number
const userId = 'admin_1'; // Multi-tenant user ID (hardcoded for now)

// Helper function to extract and clean phone number from Baileys JID
function extractPhoneNumber(jid: string): string {
  return jid.replace('@s.whatsapp.net', '').replace('@g.us', '');
}

// Initialize/update session document in Firestore
async function initializeSession(phoneNumber: string) {
  try {
    const sessionDocRef = db
      .collection('accounts')
      .doc(userId)
      .collection('whatsapp_sessions')
      .doc(phoneNumber);

    const sessionData = {
      phone_number: phoneNumber,
      alias: `Sucursal - ${phoneNumber}`,
      status: 'connected',
      last_sync: admin.firestore.Timestamp.now(),
      connected_at: admin.firestore.FieldValue.serverTimestamp(),
    };

    await sessionDocRef.set(sessionData, { merge: true });
    console.log(`Session initialized for phone: ${phoneNumber}`);
  } catch (error) {
    console.error('Error initializing session:', error);
  }
}

async function saveMessageToFirestore(message: any, botJid?: string) {
  try {
    if (!currentUserPhone) {
      console.warn('Current user phone not set, cannot save message');
      return;
    }

    const sessionId = currentUserPhone;

    const phoneNumber = message.key.remoteJid?.replace('@s.whatsapp.net', '').replace('@g.us', '');
    if (!phoneNumber) return;

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text ||
                        message.message?.imageMessage?.caption ||
                        '';

    const messageTimestamp = message.messageTimestamp ? message.messageTimestamp * 1000 : Date.now();
    const messageId = message.key.id;

    // New path: accounts/{userId}/whatsapp_sessions/{sessionId}/chats/{chatId}/messages
    const chatDocRef = db
      .collection('accounts')
      .doc(userId)
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
      .doc(userId)
      .collection('whatsapp_sessions')
      .doc(sessionId);

    await sessionDocRef.update({
      last_message: messageText.substring(0, 100),
      last_message_timestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      last_chat_id: phoneNumber,
      last_sync: admin.firestore.Timestamp.now(),
    });

    console.log(`Message saved for ${phoneNumber} (Account: ${userId}, Session: ${sessionId})`);
  } catch (error) {
    console.error('Error saving message to Firestore:', error);
  }
}

async function connectToWhatsApp() {
  const { state, saveCreds } = await useMultiFileAuthState('auth_info');
  const { version } = await fetchLatestBaileysVersion();

  const sock = makeWASocket({
    version,
    auth: state,
    logger: logger.child({ class: 'baileys' }),
    printQRInTerminal: true
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', async (update: Partial<ConnectionState>) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      console.log('QR Code received');
      currentQR = qr;
      isReady = false;
      io.emit('qr', qr);
    }

    if (connection === 'close') {
      isReady = false;
      const statusCode = (lastDisconnect?.error as any)?.output?.statusCode;

      // Mark session as disconnected
      if (currentUserPhone) {
        try {
          const sessionDocRef = db
            .collection('accounts')
            .doc(userId)
            .collection('whatsapp_sessions')
            .doc(currentUserPhone);

          await sessionDocRef.update({
            status: 'disconnected',
            last_sync: admin.firestore.Timestamp.now(),
          });
        } catch (error) {
          console.error('Error updating session status:', error);
        }
      }

      if (statusCode === DisconnectReason.loggedOut) {
        console.log('WhatsApp logged out from device. Clearing auth and requesting new QR.');

        // Clear auth_info folder
        try {
          rmSync('auth_info', { recursive: true, force: true });
          console.log('auth_info cleared');
        } catch (error) {
          console.error('Error clearing auth_info:', error);
        }

        currentQR = undefined;
        currentUserPhone = undefined;
        isReconnecting = true;

        // Notify frontend
        io.emit('status_update', { status: 'logged_out' });

        // Regenerate QR
        setTimeout(() => {
          connectToWhatsApp();
          isReconnecting = false;
        }, 500);
      } else {
        // Regular disconnection - attempt normal reconnect
        console.log('connection closed due to ', lastDisconnect?.error, ', attempting reconnect');
        if (!isReconnecting) {
          isReconnecting = true;
          setTimeout(() => {
            connectToWhatsApp();
            isReconnecting = false;
          }, 3000);
        }
      }
    } else if (connection === 'open') {
      console.log('opened connection');
      isReady = true;
      currentQR = undefined;

      // Extract and store the connected phone number
      if (sock.user?.id) {
        currentUserPhone = extractPhoneNumber(sock.user.id);
        console.log(`WhatsApp connected as: ${currentUserPhone}`);

        // Initialize session document in Firestore
        await initializeSession(currentUserPhone);
      }

      io.emit('ready', true);
    }
  });

  // Listen for incoming and outgoing messages
  sock.ev.on('messages.upsert', async (m) => {
    const message = m.messages?.[0];
    if (message) {
      await saveMessageToFirestore(message, sock.user?.id);
    }
  });

  // Store socket reference globally for sending messages
  waSocket = sock;

  return sock;
}

// REST API endpoint to send messages
app.post('/send-message', express.json(), async (req, res) => {
  try {
    if (!isReady || !waSocket) {
      return res.status(503).json({ error: 'WhatsApp not connected' });
    }

    const { to, text } = req.body;

    if (!to || !text) {
      return res.status(400).json({ error: 'Missing "to" or "text" field' });
    }

    // Format the phone number for WhatsApp
    const jid = to.includes('@') ? to : `${to}@s.whatsapp.net`;

    // Send the message via Baileys
    const message = await waSocket.sendMessage(jid, { text });

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
  console.log('Socket.io client connected:', socket.id);
  console.log('Current status - isReady:', isReady, 'hasQR:', !!currentQR);

  if (isReady) {
    socket.emit('ready', true);
  } else if (currentQR) {
    socket.emit('qr', currentQR);
  }
});

httpServer.listen(3000, () => {
  console.log('Server running on port 3000');
  connectToWhatsApp();
});
