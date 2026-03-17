import admin from 'firebase-admin';
import { SessionData } from '../types';
import { extractPhoneNumber } from '../utils/phone';

// Lazy evaluation: getDb() is called only after Firebase is initialized
function getDb() {
  return admin.firestore();
}

// AI config cache TTL: 60 seconds
export const AI_CONFIG_TTL_MS = 60_000;

// Initialize/update session document in Firestore
export async function initializeSession(phoneNumber: string, sessionKey: string, accountId: string) {
  try {
    const sessionDocRef = getDb()
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

export async function saveMessageToFirestore(message: any, sessionKey: string, accountId: string, sessions: Map<string, SessionData>, botJid?: string) {
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
    const chatDocRef = getDb()
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
    // IMPORTANT: Store the remoteJid so we can use the correct format when replying
    // (e.g., if it's @lid format, we need to use that exact format to send messages)
    await chatDocRef.set({
      phoneNumber,
      remoteJid, // Store the full JID to preserve @lid or other formats
      lastMessage: messageText.substring(0, 100),
      lastMessageTimestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      lastMessageId: messageId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // Also update the session document with the latest lastMessage info
    const sessionDocRef = getDb()
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

// Get AI config with in-memory caching
export async function getAIConfig(session: SessionData, accountId: string) {
  const now = Date.now();
  if (session.aiConfig && (now - session.aiConfig.loadedAt) < AI_CONFIG_TTL_MS) {
    return session.aiConfig;
  }

  try {
    const sessionDocRef = getDb()
      .collection('accounts').doc(accountId)
      .collection('whatsapp_sessions').doc(session.phoneNumber!);

    const doc = await sessionDocRef.get();
    const data = doc.data();

    session.aiConfig = {
      enabled: data?.ai_enabled ?? false,
      apiKey: data?.ai_api_key ?? '',
      provider: data?.ai_provider ?? 'gemini',
      openaiApiKey: data?.ai_openai_api_key ?? '',
      systemPrompt: data?.ai_system_prompt ?? '',
      responseDelayMs: data?.ai_response_delay_ms ?? 1500,
      model: data?.ai_model ?? 'gemini-2.5-flash',
      activeHours: data?.ai_active_hours,
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
      provider: 'gemini',
      openaiApiKey: '',
      systemPrompt: '',
      responseDelayMs: 0,
      model: 'gemini-2.5-flash',
      keywordRules: [],
      discriminator: {
        enabled: false,
        prompt: '',
      },
      loadedAt: now,
    };
  }
}
