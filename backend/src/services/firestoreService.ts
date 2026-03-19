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

export async function saveMessageToFirestore(message: any, sessionKey: string, accountId: string, sessions: Map<string, SessionData>, botJid?: string, sock?: any) {
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

    let phoneNumber = extractPhoneNumber(remoteJid);
    if (!phoneNumber) return;

    // If we got a LID format and no mapping exists yet, try to resolve it
    if (remoteJid.includes('@lid') && sock) {
      const { resolveLIDFromContacts } = await import('../utils/phone');
      const resolved = await resolveLIDFromContacts(phoneNumber, sock);
      if (resolved) {
        phoneNumber = resolved;
        console.log(`[Firestore] Resolved LID ${extractPhoneNumber(remoteJid)} → ${phoneNumber}`);
      }
    }

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

export async function updateContactInFirestore(contact: any, sessionKey: string, accountId: string, sessions: Map<string, SessionData>) {
  try {
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) return;

    const sessionId = session.phoneNumber;
    const remoteJid = contact.id;
    if (!remoteJid || remoteJid.endsWith('@g.us')) return; // Skip groups

    const phoneNumber = extractPhoneNumber(remoteJid);
    if (!phoneNumber) return;

    // We only care about 'name' (agenda name). 
    // We ignore 'notify' (pushName) as per requirements.
    if (!contact.name) return;

    const chatDocRef = getDb()
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

    await chatDocRef.set({
      contactName: contact.name,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    console.log(`Contact name updated for ${phoneNumber}: ${contact.name}`);
  } catch (error) {
    console.error('Error updating contact in Firestore:', error);
  }
}

// Consolidate duplicate chats when LID-to-Phone mapping is discovered
// If a chat exists under a LID identifier, migrate it to the real phone number
export async function consolidateLIDChat(
  accountId: string,
  sessionId: string,
  lid: string,
  phoneNumber: string
) {
  try {
    const db = getDb();

    // Check if a chat exists under the LID
    const lidChatRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(lid);

    const lidChatDoc = await lidChatRef.get();
    if (!lidChatDoc.exists) {
      // No LID chat found, nothing to consolidate
      return;
    }

    const lidChatData = lidChatDoc.data();
    if (!lidChatData) {
      return;
    }
    console.log(`[Consolidate] Found LID chat for ${lid}, consolidating to ${phoneNumber}`);

    // Check if phone number chat already exists
    const phoneChatRef = db
      .collection('accounts')
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

    const phoneChatDoc = await phoneChatRef.get();

    if (phoneChatDoc.exists) {
      // Merge scenario: both chats exist
      console.log(`[Consolidate] Both LID and phone chats exist, merging messages...`);

      // Fetch all messages from LID chat
      const lidMessagesRef = lidChatRef.collection('messages');
      const lidMessagesSnapshot = await lidMessagesRef.get();

      // Move all messages from LID chat to phone chat
      const batch = db.batch();
      lidMessagesSnapshot.docs.forEach((doc) => {
        const messageRef = phoneChatRef.collection('messages').doc(doc.id);
        batch.set(messageRef, doc.data(), { merge: true });
      });
      await batch.commit();

      console.log(`[Consolidate] Migrated ${lidMessagesSnapshot.size} messages from LID ${lid} to ${phoneNumber}`);

      // Delete LID chat document
      await lidChatRef.delete();
      console.log(`[Consolidate] Deleted LID chat document for ${lid}`);
    } else {
      // Simple rename: only LID chat exists
      console.log(`[Consolidate] Phone chat doesn't exist, renaming LID chat to ${phoneNumber}`);

      // Copy all data from LID to phone number
      await phoneChatRef.set(lidChatData, { merge: true });

      // Fetch and copy all messages
      const lidMessagesRef = lidChatRef.collection('messages');
      const lidMessagesSnapshot = await lidMessagesRef.get();

      const batch = db.batch();
      lidMessagesSnapshot.docs.forEach((doc) => {
        const messageRef = phoneChatRef.collection('messages').doc(doc.id);
        batch.set(messageRef, doc.data());
      });
      await batch.commit();

      // Delete LID chat
      await lidChatRef.delete();
      console.log(`[Consolidate] Renamed LID chat ${lid} → ${phoneNumber}, migrated ${lidMessagesSnapshot.size} messages`);
    }
  } catch (error) {
    console.error(`[Consolidate] Error consolidating LID ${lid}:`, error);
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
