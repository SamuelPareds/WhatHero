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
import { GoogleGenerativeAI } from '@google/generative-ai';

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

interface SessionData {
  sock: any;
  isReady: boolean;
  currentQR: string | undefined;
  phoneNumber: string | undefined;
  isReconnecting: boolean;
  accountId: string;
  aiConfig?: {
    enabled: boolean;
    apiKey: string;
    systemPrompt: string;
    responseDelayMs: number;
    model: string;
    activeHours?: {
      enabled: boolean;
      timezone: string;
      start: string;
      end: string;
    };
    optedOutContacts: string[];
    keywordRules: { keyword: string; response: string }[];
    discriminator?: {
      enabled: boolean;
      prompt: string;
    };
    loadedAt: number;
  };
}

const sessions = new Map<string, SessionData>();

// Message buffer interface for aggregating multiple messages before processing
interface MessageBuffer {
  contactPhone: string;
  messages: string[];
  timeout: NodeJS.Timeout | null;
  responded: boolean;
}

// Message buffers per chat: key = `${sessionKey}:${contactPhone}`
const messageBuffers = new Map<string, MessageBuffer>();

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

// AI config cache TTL: 60 seconds
const AI_CONFIG_TTL_MS = 60_000;

// Get AI config with in-memory caching
async function getAIConfig(session: SessionData, accountId: string) {
  const now = Date.now();
  if (session.aiConfig && (now - session.aiConfig.loadedAt) < AI_CONFIG_TTL_MS) {
    return session.aiConfig;
  }

  try {
    const sessionDocRef = db
      .collection('accounts').doc(accountId)
      .collection('whatsapp_sessions').doc(session.phoneNumber!);

    const doc = await sessionDocRef.get();
    const data = doc.data();

    session.aiConfig = {
      enabled: data?.ai_enabled ?? false,
      apiKey: data?.ai_api_key ?? '',
      systemPrompt: data?.ai_system_prompt ?? '',
      responseDelayMs: data?.ai_response_delay_ms ?? 1500,
      model: data?.ai_model ?? 'gemini-2.5-flash',
      activeHours: data?.ai_active_hours,
      optedOutContacts: data?.ai_opted_out_contacts ?? [],
      keywordRules: data?.ai_keyword_rules ?? [],
      discriminator: {
        enabled: data?.ai_discriminator_enabled ?? false,
        prompt: data?.ai_discriminator_prompt ?? '',
      },
      loadedAt: now,
    };

    return session.aiConfig;
  } catch (error) {
    console.error('[AI] Error fetching AI config:', error);
    return {
      enabled: false,
      apiKey: '',
      systemPrompt: '',
      responseDelayMs: 0,
      model: 'gemini-2.5-flash',
      optedOutContacts: [],
      keywordRules: [],
      discriminator: {
        enabled: false,
        prompt: '',
      },
      loadedAt: now,
    };
  }
}

// Check if current time is within active hours
function isWithinActiveHours(aiConfig: any): boolean {
  if (!aiConfig.activeHours?.enabled) {
    return true; // Active hours disabled = always within hours
  }

  try {
    const { timezone, start, end } = aiConfig.activeHours;
    if (!timezone || !start || !end) {
      return true; // Invalid config = allow
    }

    // Get current time in the specified timezone
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });

    const currentTimeStr = formatter.format(new Date());
    const [currentHour, currentMinute] = currentTimeStr.split(':').map(Number);
    const currentTime = currentHour * 60 + currentMinute; // Minutes since midnight

    // Parse start and end times
    const [startHour, startMinute] = start.split(':').map(Number);
    const [endHour, endMinute] = end.split(':').map(Number);

    const startTime = startHour * 60 + startMinute;
    const endTime = endHour * 60 + endMinute;

    // Check if current time is within range
    if (startTime <= endTime) {
      // Normal case: 09:00 - 18:00
      return currentTime >= startTime && currentTime < endTime;
    } else {
      // Overnight case: 22:00 - 06:00
      return currentTime >= startTime || currentTime < endTime;
    }
  } catch (error) {
    console.error('[AI] Error checking active hours:', error);
    return true; // On error, allow response
  }
}

// Generate AI response using Gemini with conversation history
async function generateAIResponse(
  apiKey: string,
  systemPrompt: string,
  userMessage: string,
  history?: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash'
): Promise<string | null> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    // If we have history, use multi-turn chat with system prompt prepended to the first user message
    if (history && history.length > 0) {
      // Inject system prompt at the beginning of the history by prepending to first user message
      const enhancedHistory = [...history];
      if (enhancedHistory.length > 0 && enhancedHistory[0].role === 'user') {
        enhancedHistory[0] = {
          role: 'user',
          parts: [{ text: `${systemPrompt}\n\n${enhancedHistory[0].parts[0]?.text || ''}` }],
        };
      }
      const chat = model.startChat({ history: enhancedHistory });
      const result = await chat.sendMessage(userMessage);
      return result.response.text();
    } else {
      // Single turn: include system prompt in the message
      const fullPrompt = `${systemPrompt}\n\n${userMessage}`;
      const result = await model.generateContent(fullPrompt);
      return result.response.text();
    }
  } catch (error) {
    console.error('[AI] Error calling Gemini:', error);
    return null;
  }
}

// Classify message intent using discriminator (TalkToAiAssistant or TalkToHuman)
//
// HOW IT WORKS:
// 1. User writes natural language rules (e.g., "Pass to human if client asks about availability")
// 2. The discriminator prompt is: {USER_RULES} + {CONVERSATION_HISTORY}
// 3. Gemini analyzes if the latest message matches the rules
// 4. Gemini responds with "Respuesta: SI" (AI can respond) or "Respuesta: NO" (needs human)
// 5. Backend parses the response and routes accordingly
//
// EXAMPLE PROMPT (what user writes):
// "Pass messages to a human if:
//  - Client asks about specific availability (dates, times)
//  - Client wants to book/reschedule an appointment
//  - Client asks about personal data or account balance
//
//  For anything else, you can respond directly."
async function classifyMessageIntent(
  apiKey: string,
  discriminatorPrompt: string,
  conversationHistory: string,
  modelName: string = 'gemini-2.5-flash'
): Promise<'TalkToAiAssistant' | 'TalkToHuman'> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    // Replace {HISTORY} placeholder with actual conversation
    let userPrompt = discriminatorPrompt.replace('{HISTORY}', conversationHistory);

    // Add instructions for clear response format
    userPrompt += '\n\n---\nResponde SOLO con una de estas dos opciones:\n- Respuesta: SI (si el asistente puede responder)\n- Respuesta: NO (si requiere intervención humana)';

    const result = await model.generateContent(userPrompt);
    const responseText = result.response.text().toUpperCase();

    console.log(`[Discriminator] Gemini response: ${responseText.substring(0, 100)}`);

    // Check response for simple YES/NO keywords
    // Look for "Respuesta: SI" or "Respuesta: NO"
    if (responseText.includes('RESPUESTA: NO') || responseText.includes('NO')) {
      // Check that it's actually saying NO, not just containing "NO" elsewhere
      if (responseText.includes('RESPUESTA: NO')) {
        return 'TalkToHuman';
      }
      // If only "NO" without context, treat as ambiguous and allow AI
    }

    // Default to AI response (SI or ambiguous)
    return 'TalkToAiAssistant';
  } catch (error) {
    console.error('[Discriminator] Error classifying intent:', error);
    // Default: allow AI response on error
    return 'TalkToAiAssistant';
  }
}

// Process buffered messages: fetch history, run discriminator, and send AI response
async function processMessageBuffer(
  sessionKey: string,
  accountId: string,
  session: SessionData,
  remoteJid: string,
  contactPhone: string,
  aiConfig: any,
  bufferedMessages: string[]
) {
  try {
    // Combine all buffered messages into one context
    const combinedMessage = bufferedMessages.join('\n');
    console.log(`[Buffer] Processing ${bufferedMessages.length} message(s) for ${contactPhone}: "${combinedMessage.substring(0, 50)}..."`);

    // Fetch last 10 messages for conversation history
    let history: { role: 'user' | 'model'; parts: { text: string }[] }[] = [];

    try {
      const historyDocs = await db
        .collection('accounts').doc(accountId)
        .collection('whatsapp_sessions').doc(session.phoneNumber!)
        .collection('chats').doc(contactPhone)
        .collection('messages')
        .orderBy('timestamp', 'desc')
        .limit(10)
        .get();

      const rawHistory = historyDocs.docs
        .reverse()
        .filter(d => d.data().text)
        .map(d => ({
          role: d.data().fromMe ? ('model' as const) : ('user' as const),
          parts: [{ text: d.data().text as string }],
        }));

      // Ensure history alternates correctly
      history = [];
      for (const msg of rawHistory) {
        if (history.length === 0) {
          if (msg.role === 'user') {
            history.push(msg);
          }
        } else {
          const lastRole = history[history.length - 1].role;
          if (lastRole === 'user' && msg.role === 'model') {
            history.push(msg);
          } else if (lastRole === 'model' && msg.role === 'user') {
            history.push(msg);
          }
        }
      }

      if (history.length > 0 && history[history.length - 1].role !== 'user') {
        history.pop();
      }
    } catch (error) {
      console.log('[Buffer] Could not fetch message history, continuing without context:', error);
    }

    // DISCRIMINATOR: Check if message should be handled by AI or human
    if (aiConfig.discriminator?.enabled && aiConfig.discriminator?.prompt) {
      const historyText = history
        .map((msg) => {
          const role = msg.role === 'user' ? 'Customer' : 'Assistant';
          return `${role}: ${msg.parts[0]?.text || ''}`;
        })
        .join('\n');

      const conversationContext = `${historyText}\nCustomer: ${combinedMessage}`;

      const classification = await classifyMessageIntent(
        aiConfig.apiKey,
        aiConfig.discriminator.prompt,
        conversationContext,
        aiConfig.model
      );

      if (classification === 'TalkToHuman') {
        try {
          const chatDocRef = db
            .collection('accounts')
            .doc(accountId)
            .collection('whatsapp_sessions')
            .doc(session.phoneNumber!)
            .collection('chats')
            .doc(contactPhone);

          await chatDocRef.update({
            needs_human: true,
            human_attention_at: admin.firestore.FieldValue.serverTimestamp(),
          });

          console.log(`[Buffer] Chat ${contactPhone} marked as needs_human=true`);
        } catch (error) {
          console.error('[Buffer] Error marking chat as needing human attention:', error);
        }

        io.to(accountId).emit('human_attention_required', {
          sessionKey,
          chatId: contactPhone,
          phoneNumber: session.phoneNumber,
          timestamp: new Date().toISOString(),
        });

        console.log(
          `[Buffer] Emitted human_attention_required for ${contactPhone} (Session: ${session.phoneNumber})`
        );
        return; // Skip AI response
      }

      console.log(`[Buffer] Discriminator classification: ${classification}, proceeding with AI response`);
    }

    // Generate and send AI response
    const aiResponse = await generateAIResponse(
      aiConfig.apiKey,
      aiConfig.systemPrompt || 'Eres un asistente útil.',
      combinedMessage,
      history,
      aiConfig.model
    );

    if (aiResponse) {
      await session.sock.sendMessage(remoteJid, { text: aiResponse });
      console.log(`[Buffer] Auto-responded to ${remoteJid} on session ${session.phoneNumber} with ${aiResponse.length} chars`);
    }
  } catch (error) {
    console.error('[Buffer] Error processing message buffer:', error);
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
    if (!message) return;

    await saveMessageToFirestore(message, sessionKey, accountId, sock.user?.id);

    // AI auto-response: only for incoming messages (not from self)
    if (message.key.fromMe) return;
    const remoteJid = message.key.remoteJid;
    if (!remoteJid || remoteJid.endsWith('@g.us')) return; // skip group messages

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text || '';
    if (!messageText.trim()) return; // skip media-only messages

    // Get AI config with caching
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) return;

    const aiConfig = await getAIConfig(session, accountId);
    if (!aiConfig.enabled || !aiConfig.apiKey) return;

    // Extract contact phone number
    const contactPhone = extractPhoneNumber(remoteJid);

    // Check if contact is opted out
    if (aiConfig.optedOutContacts?.includes(contactPhone)) {
      console.log(`[AI] Contact ${contactPhone} is opted out, skipping AI response`);
      return;
    }

    // Check if within active hours
    if (!isWithinActiveHours(aiConfig)) {
      console.log(`[AI] Outside active hours, skipping AI response`);
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
