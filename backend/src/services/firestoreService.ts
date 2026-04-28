import admin from 'firebase-admin';
import { toNumber } from '@whiskeysockets/baileys';
import { SessionData } from '../types';
import { extractPhoneNumber } from '../utils/phone';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { extractMediaInfo, processMediaAsync } from './mediaService';

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
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(phoneNumber);

    // Check if document already exists to preserve alias
    const doc = await sessionDocRef.get();
    const existingData = doc.data();

    const sessionData: any = {
      phone_number: phoneNumber,
      status: 'connected',
      last_sync: admin.firestore.Timestamp.now(),
      connected_at: admin.firestore.FieldValue.serverTimestamp(),
      session_key: sessionKey,
    };

    // Only set default alias if it doesn't exist yet
    if (!existingData || !existingData.alias) {
      sessionData.alias = `Sucursal - ${phoneNumber}`;
    }

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
    if (remoteJid.includes('@lid')) {
      let resolved = false;

      // 1. Try to resolve via socket (Baileys store)
      if (sock) {
        const { resolveLIDViaSock } = await import('../utils/phone');
        const sockResolved = await resolveLIDViaSock(phoneNumber, sock);
        if (sockResolved) {
          phoneNumber = sockResolved;
          resolved = true;
          console.log(`[Firestore] Resolved LID via Sock: ${extractPhoneNumber(remoteJid)} → ${phoneNumber}`);
        }
      }

      // 2. If not resolved via socket, search in Firestore for an existing chat with this remoteJid
      if (!resolved) {
        try {
          const chatsSnapshot = await getDb()
            .collection(ACCOUNTS_COLLECTION)
            .doc(accountId)
            .collection('whatsapp_sessions')
            .doc(sessionId)
            .collection('chats')
            .where('remoteJid', '==', remoteJid)
            .limit(1)
            .get();

          if (!chatsSnapshot.empty) {
            const existingChat = chatsSnapshot.docs[0];
            phoneNumber = existingChat.id; // Use the existing phone number document ID
            resolved = true;
            console.log(`[Firestore] Resolved LID via DB lookup: ${remoteJid} → ${phoneNumber}`);
            
            // Also store in memory for future use during this session
            const { storeLIDMapping } = await import('../utils/phone');
            storeLIDMapping(extractPhoneNumber(remoteJid), phoneNumber);
          }
        } catch (dbError) {
          console.error('[Firestore] Error looking up LID in DB:', dbError);
        }
      }
      
      if (!resolved) {
        console.warn(`[Firestore] Could not resolve LID ${remoteJid}, will use LID as chat ID (might create duplicate)`);
      }
    }

    const messageText = message.message?.conversation ||
                        message.message?.extendedTextMessage?.text ||
                        message.message?.imageMessage?.caption ||
                        message.message?.videoMessage?.caption ||
                        message.message?.documentMessage?.caption ||
                        message.message?.documentWithCaptionMessage?.message?.documentMessage?.caption ||
                        '';

    // ============================================
    // Pipeline de medios genérico (Fase 3a):
    // extractMediaInfo() devuelve los campos a persistir si el mensaje contiene
    // image / sticker / document. processMediaAsync() corre fire-and-forget
    // para descargar + subir a Storage + escribir mediaUrl al doc.
    // ============================================
    const mediaInfo = extractMediaInfo(message);
    const mediaFields = mediaInfo?.firestoreFields ?? {};

    // Preview que ve el operador en la lista de chats con un icono por tipo.
    const lastMessagePreview = (() => {
      if (!mediaInfo) return messageText;
      const isPtt = !!mediaInfo.firestoreFields?.mediaIsPtt;
      const isGif = !!mediaInfo.firestoreFields?.mediaIsGif;
      const labels: Record<string, { icon: string; label: string }> = {
        image: { icon: '📷', label: 'Imagen' },
        sticker: { icon: '🏷️', label: 'Sticker' },
        document: { icon: '📄', label: mediaInfo.fileName ?? 'Documento' },
        audio: { icon: '🎤', label: isPtt ? 'Nota de voz' : 'Audio' },
        video: { icon: '🎥', label: isGif ? 'GIF' : 'Video' },
      };
      const { icon, label } = labels[mediaInfo.type];
      return messageText ? `${icon} ${messageText}` : `${icon} ${label}`;
    })();

    // Use toNumber() to handle potential Long type from protobuf
    const messageTimestamp = message.messageTimestamp ? toNumber(message.messageTimestamp) * 1000 : Date.now();
    const messageId = message.key.id;

    // New path: accounts/{accountId}/whatsapp_sessions/{sessionId}/chats/{chatId}/messages
    const chatDocRef = getDb()
      .collection(ACCOUNTS_COLLECTION)
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
      isMedia: !!mediaInfo,
      ...mediaFields,
    }, { merge: true });

    // Update the chat document with lastMessage (for efficient list display)
    // IMPORTANT: Store the remoteJid so we can use the correct format when replying
    // (e.g., if it's @lid format, we need to use that exact format to send messages)
    await chatDocRef.set({
      phoneNumber,
      remoteJid, // Store the full JID to preserve @lid or other formats
      lastMessage: lastMessagePreview.substring(0, 100),
      lastMessageTimestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      lastMessageId: messageId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // Also update the session document with the latest lastMessage info
    const sessionDocRef = getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId);

    await sessionDocRef.update({
      last_message: lastMessagePreview.substring(0, 100),
      last_message_timestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      last_chat_id: phoneNumber,
      last_sync: admin.firestore.Timestamp.now(),
    });

    console.log(`Message saved for ${phoneNumber} (Account: ${accountId}, Session: ${sessionId})`);

    // Fase 2/3a: dispara descarga + upload del archivo completo en segundo plano.
    // El mensaje ya quedó visible para el operador (con thumbnail si aplica);
    // el full-res aparece apenas termine el upload (vía Firestore stream).
    if (mediaInfo && sock) {
      processMediaAsync(message, mediaInfo, sock, accountId, sessionId, phoneNumber, messageId)
        .catch(err => console.error(`[Media] Error en upload de ${mediaInfo.type} ${messageId}:`, err));
    }
  } catch (error) {
    console.error('Error saving message to Firestore:', error);
  }
}

export async function updateContactInFirestore(contact: any, sessionKey: string, accountId: string, sessions: Map<string, SessionData>) {
  try {
    const session = sessions.get(sessionKey);
    if (!session?.phoneNumber) return;

    const sessionId = session.phoneNumber;

    // In Baileys v7, if contact.id is a LID, contact.phoneNumber contains the real PN JID
    const rawJid = (contact.phoneNumber ?? contact.id) as string;
    if (!rawJid || rawJid.endsWith('@g.us')) return; // Skip groups

    const phoneNumber = extractPhoneNumber(rawJid);
    if (!phoneNumber) return;

    // We only care about 'name' (agenda name).
    // We ignore 'notify' (pushName) as per requirements.
    if (!contact.name) return;

    const chatDocRef = getDb()
      .collection(ACCOUNTS_COLLECTION)
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
      .collection(ACCOUNTS_COLLECTION)
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
      .collection(ACCOUNTS_COLLECTION)
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

// Incrementa el contador de mensajes pendientes de respuesta humana en un chat.
// Se llama cuando la IA NO va a responder (IA off, fuera de horario, discriminador→humano, etc).
export async function incrementUnrespondedCount(
  accountId: string,
  sessionId: string,
  contactPhone: string,
  by: number = 1
) {
  try {
    await getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(contactPhone)
      .set(
        { unresponded_count: admin.firestore.FieldValue.increment(by) },
        { merge: true }
      );
  } catch (error) {
    console.error(`[Unresponded] Error incrementing count for ${contactPhone}:`, error);
  }
}

// Resetea el contador a 0. Se llama cuando el humano responde (CRM o celular físico)
// o cuando la IA termina de responder exitosamente.
export async function resetUnrespondedCount(
  accountId: string,
  sessionId: string,
  contactPhone: string
) {
  try {
    await getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(contactPhone)
      .set({ unresponded_count: 0 }, { merge: true });
  } catch (error) {
    console.error(`[Unresponded] Error resetting count for ${contactPhone}:`, error);
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
      .collection(ACCOUNTS_COLLECTION).doc(accountId)
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
