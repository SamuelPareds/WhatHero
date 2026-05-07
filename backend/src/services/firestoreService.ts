import admin from 'firebase-admin';
import { toNumber } from '@whiskeysockets/baileys';
import { SessionData, SenderInfo } from '../types';
import { extractPhoneNumber, isConversationalJid } from '../utils/phone';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { extractMediaInfo, processMediaAsync } from './mediaService';
import { WHATSAPP_SENDER } from './senderResolver';

// Lazy evaluation: getDb() is called only after Firebase is initialized
function getDb() {
  return admin.firestore();
}

// AI config cache TTL: 60 seconds
export const AI_CONFIG_TTL_MS = 60_000;

// ============================================
// Reply / quote support.
//
// Cuando el cliente (o nosotros) responde un mensaje específico, Baileys
// expone el contexto en `contextInfo` dentro del envoltorio del mensaje:
//   - extendedTextMessage.contextInfo (texto)
//   - imageMessage.contextInfo / videoMessage.contextInfo / audioMessage.contextInfo
//   - documentMessage.contextInfo / stickerMessage.contextInfo
// Campos relevantes:
//   contextInfo.stanzaId       → id del mensaje citado (= key.id del original)
//   contextInfo.participant    → JID de quien envió el original
//   contextInfo.quotedMessage  → contenido del mensaje citado
//
// Persistimos un snapshot mínimo (id + texto preview + fromMe) en el doc del
// mensaje que responde. NO denormalizamos el mensaje completo — alcanza para
// renderizar la cita y sobrevive si el original se borra/edita después.
// ============================================

const QUOTE_HOST_KEYS = [
  'extendedTextMessage',
  'imageMessage',
  'videoMessage',
  'audioMessage',
  'documentMessage',
  'documentWithCaptionMessage',
  'stickerMessage',
] as const;

// Texto preview de un mensaje citado. Reusa la misma lógica de iconografía
// que `lastMessagePreview` (📷 Imagen, 🎤 Nota de voz, etc.) para que la
// cita se vea consistente entre la lista de chats y el bubble.
function previewFromQuotedMessage(quotedMessage: any): string {
  if (!quotedMessage) return '';

  const text = quotedMessage.conversation
    || quotedMessage.extendedTextMessage?.text
    || quotedMessage.imageMessage?.caption
    || quotedMessage.videoMessage?.caption
    || quotedMessage.documentMessage?.caption
    || quotedMessage.documentWithCaptionMessage?.message?.documentMessage?.caption
    || '';

  if (quotedMessage.imageMessage) {
    return text ? `📷 ${text}` : '📷 Imagen';
  }
  if (quotedMessage.videoMessage) {
    const isGif = !!quotedMessage.videoMessage.gifPlayback;
    if (isGif) return text ? `🎥 ${text}` : '🎥 GIF';
    return text ? `🎥 ${text}` : '🎥 Video';
  }
  if (quotedMessage.audioMessage) {
    const isPtt = !!quotedMessage.audioMessage.ptt;
    return isPtt ? '🎤 Nota de voz' : '🎤 Audio';
  }
  if (quotedMessage.stickerMessage) return '🏷️ Sticker';
  if (quotedMessage.documentMessage) {
    const fileName = quotedMessage.documentMessage.fileName || 'Documento';
    return `📄 ${fileName}`;
  }
  if (quotedMessage.documentWithCaptionMessage) {
    const inner = quotedMessage.documentWithCaptionMessage.message?.documentMessage;
    const fileName = inner?.fileName || 'Documento';
    return text ? `📄 ${fileName}: ${text}` : `📄 ${fileName}`;
  }

  return text;
}

// Devuelve los campos a persistir si el mensaje contiene una cita, o null si
// no es una respuesta. `selfJid` se usa para inferir `quotedFromMe` cuando el
// `participant` del contextInfo coincide con el JID del operador.
export function extractQuoteInfo(message: any, selfJid?: string): {
  quotedMessageId: string;
  quotedText: string;
  quotedFromMe: boolean;
} | null {
  if (!message?.message) return null;

  let contextInfo: any = null;
  for (const hostKey of QUOTE_HOST_KEYS) {
    const host = message.message[hostKey];
    if (host?.contextInfo?.stanzaId) {
      contextInfo = host.contextInfo;
      break;
    }
  }
  if (!contextInfo) return null;

  const stanzaId: string = contextInfo.stanzaId;
  const quotedText = previewFromQuotedMessage(contextInfo.quotedMessage).substring(0, 200);

  // Inferir si el mensaje citado lo envió el operador. WhatsApp pone el JID
  // del autor original en `participant`. Si coincide con el JID propio del
  // socket, fue nuestro. Fallback: si no hay participant, asumimos del cliente
  // (caso típico cuando el cliente cita a un mensaje recién enviado por él).
  const participant: string | undefined = contextInfo.participant;
  let quotedFromMe = false;
  if (participant && selfJid) {
    const normalize = (jid: string) => jid.split(':')[0].split('@')[0];
    quotedFromMe = normalize(participant) === normalize(selfJid);
  }

  return { quotedMessageId: stanzaId, quotedText, quotedFromMe };
}

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

// Tras un hard-delete de un mensaje, si era el último del chat hay que
// recalcular `lastMessage` / `lastMessageTimestamp` / `lastMessageId` para que
// la UI de chats_screen no quede mostrando un preview fantasma.
//
// Si el mensaje borrado NO era el último (deletedMessageId !== lastMessageId
// del chat doc), no hace falta tocar nada — simplemente desaparece de la
// subcolección y los demás siguen siendo correctos.
//
// Cuando no quedan mensajes en absoluto, limpiamos los campos con
// FieldValue.delete() en vez de set('') para no dejar basura en el doc.
export async function recalcChatLastMessage(
  accountId: string,
  sessionId: string,
  phoneNumber: string,
  deletedMessageId: string,
) {
  const chatRef = getDb()
    .collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('whatsapp_sessions')
    .doc(sessionId)
    .collection('chats')
    .doc(phoneNumber);

  const chatSnap = await chatRef.get();
  if (!chatSnap.exists) return;

  const data = chatSnap.data() ?? {};
  if (data.lastMessageId !== deletedMessageId) return;

  const remaining = await chatRef
    .collection('messages')
    .orderBy('timestamp', 'desc')
    .limit(1)
    .get();

  if (remaining.empty) {
    await chatRef.update({
      lastMessage: admin.firestore.FieldValue.delete(),
      lastMessageTimestamp: admin.firestore.FieldValue.delete(),
      lastMessageId: admin.firestore.FieldValue.delete(),
    });
    console.log(`[recalcChatLastMessage] chat ${phoneNumber} sin mensajes restantes, campos limpiados`);
    return;
  }

  const newest = remaining.docs[0];
  const newestData = newest.data();
  await chatRef.update({
    lastMessage: (newestData.text as string | undefined)?.substring(0, 100) ?? '',
    lastMessageTimestamp: newestData.timestamp ?? admin.firestore.FieldValue.delete(),
    lastMessageId: newest.id,
  });
  console.log(`[recalcChatLastMessage] chat ${phoneNumber} → último ahora ${newest.id}`);
}

export async function saveMessageToFirestore(
  message: any,
  sessionKey: string,
  accountId: string,
  sessions: Map<string, SessionData>,
  botJid?: string,
  sock?: any,
  // Override explícito (lo usan los recordatorios). Si no se pasa, el sender
  // se resuelve consultando session.pendingSenders por messageId. Un upsert
  // de mensaje fromMe sin entry → enviado desde el WhatsApp del teléfono.
  explicitSenderInfo?: SenderInfo,
) {
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

    // Filtro: ignorar Estados/Stories, listas de difusión y canales.
    // No son conversaciones 1:1 y no deben crear chats en Firestore.
    if (!isConversationalJid(remoteJid)) {
      console.log(`[Filter] JID no conversacional ignorado en saveMessage: ${remoteJid}`);
      return;
    }

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

    // ============================================
    // Reacciones nativas de WhatsApp (emoji sobre un mensaje).
    // Llegan vía messages.upsert con message.message.reactionMessage en lugar
    // de texto/media. NO son un mensaje propio: son metadata del mensaje
    // original. Las guardamos como un map "reactions" en el doc del mensaje
    // target, sin crear un documento nuevo.
    //
    //   reactionMessage.key.id → id del mensaje al que reaccionan
    //   reactionMessage.text   → emoji ('' = reacción removida)
    //   message.key.fromMe     → quién reacciona (operador vs contacto)
    //
    // En chats 1:1 sólo hay dos reactores posibles, así que usamos las claves
    // 'me' / 'them' — el render en Flutter no necesita resolver JIDs.
    // ============================================
    const reactionMessage = message.message?.reactionMessage;
    if (reactionMessage) {
      const targetMessageId = reactionMessage.key?.id;
      if (!targetMessageId) {
        console.warn(`[Reaction] Sin targetMessageId, ignorando reacción en chat ${phoneNumber}`);
        return;
      }

      const reactorKey = message.key.fromMe ? 'me' : 'them';
      const emoji = reactionMessage.text ?? '';
      const reactionTs = message.messageTimestamp
        ? toNumber(message.messageTimestamp) * 1000
        : Date.now();

      const targetMessageRef = getDb()
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(sessionId)
        .collection('chats')
        .doc(phoneNumber)
        .collection('messages')
        .doc(targetMessageId);

      // Emoji vacío = el usuario removió su reacción → borramos sólo esa entry
      // del map. set+merge sobre objeto anidado conserva las reacciones del
      // otro reactor. Si el doc target aún no existe (race: reacción antes
      // que el mensaje original), set+merge crea un doc parcial que se
      // completará cuando llegue el mensaje real.
      const reactionsPayload = emoji
        ? { [reactorKey]: { emoji, timestamp: admin.firestore.Timestamp.fromDate(new Date(reactionTs)) } }
        : { [reactorKey]: admin.firestore.FieldValue.delete() };

      await targetMessageRef.set({ reactions: reactionsPayload }, { merge: true });

      console.log(
        `[Reaction] ${reactorKey} reaccionó "${emoji || '(removida)'}" sobre ${targetMessageId} en chat ${phoneNumber}`,
      );
      return;
    }

    // ============================================
    // protocolMessage: metadata sobre un mensaje existente.
    // Tipos relevantes (proto.Message.ProtocolMessage.Type):
    //   0  = REVOKE         (eliminar para todos)
    //   14 = MESSAGE_EDIT   (editar mensaje)
    //
    // Política WhatHero: ambos casos se mergean en el doc target; NO
    // borramos el mensaje original. Para revokes preservamos el texto como
    // evidencia (el operador decide manualmente si purgar). Para edits
    // sobreescribimos el texto y marcamos `edited: true`. Otros tipos de
    // protocolMessage (ephemeral settings, etc) los dejamos pasar — caen
    // al flujo normal y aparecen como burbujas vacías = canary.
    // ============================================
    const protocolMessage = message.message?.protocolMessage;
    if (protocolMessage && (protocolMessage.type === 0 || protocolMessage.type === 14)) {
      const targetMessageId = protocolMessage.key?.id;
      if (!targetMessageId) {
        console.warn(`[Protocol] type=${protocolMessage.type} sin targetMessageId en chat ${phoneNumber}, ignorando`);
        return;
      }

      const protocolTs = message.messageTimestamp
        ? toNumber(message.messageTimestamp) * 1000
        : Date.now();
      const actor = message.key.fromMe ? 'me' : 'them';

      const targetMessageRef = getDb()
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(sessionId)
        .collection('chats')
        .doc(phoneNumber)
        .collection('messages')
        .doc(targetMessageId);

      if (protocolMessage.type === 14) {
        // MESSAGE_EDIT: extraemos texto nuevo del payload anidado.
        const editedMessage = protocolMessage.editedMessage;
        const newText = editedMessage?.conversation
          ?? editedMessage?.extendedTextMessage?.text
          ?? '';

        if (!newText) {
          console.warn(`[Edit] ${actor} editó ${targetMessageId} pero el payload no trae texto extraible, ignorando`);
          return;
        }

        await targetMessageRef.set({
          text: newText,
          edited: true,
          editedAt: admin.firestore.Timestamp.fromDate(new Date(protocolTs)),
        }, { merge: true });

        console.log(`[Edit] ${actor} editó ${targetMessageId} en chat ${phoneNumber}: "${newText}"`);
        return;
      }

      // REVOKE (type 0): comportamiento depende de quién lo originó.
      //   actor='me'   → fui yo (operador) usando "Eliminar para todos"
      //                  desde WhatHero o desde mi propio WhatsApp. El intento
      //                  era purgarlo, no marcarlo como evidencia → hard-delete.
      //   actor='them' → el cliente lo eliminó en su WhatsApp. Preservamos el
      //                  contenido + banner ámbar (evidencia para el operador).
      if (actor === 'me') {
        await targetMessageRef.delete();
        await recalcChatLastMessage(accountId, sessionId, phoneNumber, targetMessageId);
        console.log(`[Revoke] me eliminó ${targetMessageId} en chat ${phoneNumber} → hard-delete`);
      } else {
        await targetMessageRef.set({
          revoked: true,
          revokedAt: admin.firestore.Timestamp.fromDate(new Date(protocolTs)),
        }, { merge: true });
        console.log(`[Revoke] them eliminó ${targetMessageId} en chat ${phoneNumber} (preservado como evidencia)`);
      }
      return;
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

    // Resolver senderInfo SOLO para mensajes salientes (fromMe).
    // Los entrantes no llevan campos sender (es el cliente del otro lado).
    let senderFields: Record<string, any> = {};
    if (message.key.fromMe) {
      let senderInfo: SenderInfo | undefined = explicitSenderInfo;
      if (!senderInfo) {
        // Buscar la intención registrada por el entry point que envió.
        // Pequeño retry para mitigar race con el await sendMessage del entry
        // point (en la práctica el primer get acierta; este loop es defensa).
        for (let i = 0; i < 3; i++) {
          senderInfo = session.pendingSenders.get(messageId);
          if (senderInfo) break;
          if (i < 2) await new Promise(r => setTimeout(r, 30));
        }
        if (senderInfo) {
          session.pendingSenders.delete(messageId);
        } else {
          // No registrado → enviado desde la app oficial de WhatsApp.
          senderInfo = WHATSAPP_SENDER;
        }
      }
      senderFields = {
        senderType: senderInfo.type,
        senderName: senderInfo.name,
        ...(senderInfo.uid && { senderUid: senderInfo.uid }),
      };
    }

    // Si el mensaje es una respuesta a otro, snapshot del id + texto preview
    // del mensaje citado. Mensajes sin cita no escriben estos campos (todos
    // los reads en Flutter usan `as String?` → legacy intacto).
    const quoteInfo = extractQuoteInfo(message, botJid);
    const quoteFields = quoteInfo
      ? {
          quotedMessageId: quoteInfo.quotedMessageId,
          quotedText: quoteInfo.quotedText,
          quotedFromMe: quoteInfo.quotedFromMe,
        }
      : {};

    // Save message to messages subcollection
    await messagesSubCollectionRef.doc(messageId).set({
      id: messageId,
      text: messageText,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      from: message.key.fromMe ? (botJid || 'bot') : phoneNumber,
      fromMe: message.key.fromMe,
      isMedia: !!mediaInfo,
      ...senderFields,
      ...mediaFields,
      ...quoteFields,
    }, { merge: true });

    // Update the chat document with lastMessage (for efficient list display)
    // IMPORTANT: Store the remoteJid so we can use the correct format when replying
    // (e.g., if it's @lid format, we need to use that exact format to send messages)
    // Si tenemos el nombre de agenda en el cache de la sesión, lo incluimos en el
    // mismo write (cero writes adicionales sobre el flujo normal).
    const cachedName = session.contactNames?.get(phoneNumber);
    const chatDocPayload: Record<string, any> = {
      phoneNumber,
      remoteJid,
      lastMessage: lastMessagePreview.substring(0, 100),
      lastMessageTimestamp: admin.firestore.Timestamp.fromDate(new Date(messageTimestamp)),
      lastMessageId: messageId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (cachedName) {
      chatDocPayload.contactName = cachedName;
    }
    await chatDocRef.set(chatDocPayload, { merge: true });

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

// Extrae phoneNumber + name del payload de un evento de contacts.
// Devuelve null si no es un contacto procesable (grupo, sin name, etc).
function extractContactInfo(contact: any): { phoneNumber: string; name: string } | null {
  // En Baileys v7, si contact.id es un LID, contact.phoneNumber trae el JID real.
  const rawJid = (contact.phoneNumber ?? contact.id) as string;
  if (!rawJid || rawJid.endsWith('@g.us')) return null;

  const phoneNumber = extractPhoneNumber(rawJid);
  if (!phoneNumber) return null;

  // Solo nos importa 'name' (nombre de agenda).
  // Ignoramos 'notify' (pushName) por decisión de producto.
  if (!contact.name) return null;

  return { phoneNumber, name: contact.name };
}

// Cachea el nombre de agenda en memoria sin tocar Firestore.
// Usado por contacts.upsert (que llega masivamente al conectar).
export function cacheContactName(contact: any, sessionKey: string, sessions: Map<string, SessionData>) {
  const session = sessions.get(sessionKey);
  if (!session) return;

  const info = extractContactInfo(contact);
  if (!info) return;

  session.contactNames.set(info.phoneNumber, info.name);
}

// Aplica un cambio de nombre: cachea + actualiza el chat doc SI existe.
// Usado por contacts.update (deltas reales: renombre en agenda, etc).
// Si el chat no existe, sólo queda en memoria — se persistirá cuando llegue
// un mensaje de ese contacto o en la próxima reconciliación.
export async function applyContactUpdate(contact: any, sessionKey: string, accountId: string, sessions: Map<string, SessionData>) {
  const session = sessions.get(sessionKey);
  if (!session?.phoneNumber) return;

  const info = extractContactInfo(contact);
  if (!info) return;

  session.contactNames.set(info.phoneNumber, info.name);

  // Intentamos actualizar el chat doc. Si no existe, update() falla con
  // NOT_FOUND (gRPC code 5) — lo silenciamos porque ese es el caso esperado
  // para contactos que aún no tienen chat real.
  try {
    const chatDocRef = getDb()
      .collection(ACCOUNTS_COLLECTION)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(session.phoneNumber)
      .collection('chats')
      .doc(info.phoneNumber);

    await chatDocRef.update({
      contactName: info.name,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`[ContactUpdate] Nombre actualizado en chat existente: ${info.phoneNumber} → ${info.name}`);
  } catch (error: any) {
    // code 5 = NOT_FOUND. Ignorar: el chat no existe, no hay nada que actualizar.
    if (error?.code === 5) return;
    console.error('[ContactUpdate] Error actualizando contact:', error);
  }
}

// Reconciliación post-connect: pagina sobre los chats existentes y escribe
// contactName en aquellos que tienen entrada en el cache pero el doc aún no
// la tiene (o difiere). O(chatsReales) en lugar de O(agendaCompleta).
export async function reconcileContactNames(sessionKey: string, accountId: string, sessions: Map<string, SessionData>) {
  const session = sessions.get(sessionKey);
  if (!session?.phoneNumber) return;
  if (session.contactNames.size === 0) return;

  const sessionId = session.phoneNumber;
  const chatsRef = getDb()
    .collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('whatsapp_sessions')
    .doc(sessionId)
    .collection('chats');

  let updated = 0;
  let scanned = 0;
  let lastDoc: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  const PAGE_SIZE = 200;

  while (true) {
    let query = chatsRef.orderBy('__name__').limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);

    const snap = await query.get();
    if (snap.empty) break;

    const batch = getDb().batch();
    let writesInBatch = 0;

    for (const doc of snap.docs) {
      scanned++;
      const cachedName = session.contactNames.get(doc.id);
      if (!cachedName) continue;
      const currentName = doc.get('contactName');
      if (currentName === cachedName) continue;
      batch.set(doc.ref, {
        contactName: cachedName,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      writesInBatch++;
      updated++;
    }

    if (writesInBatch > 0) await batch.commit();

    if (snap.size < PAGE_SIZE) break;
    lastDoc = snap.docs[snap.docs.length - 1];
  }

  console.log(`[Reconcile] Sesión ${sessionId}: ${scanned} chats escaneados, ${updated} nombres actualizados.`);
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

    const rawAllowlist = (data?.ai_media_allowlist ?? {}) as Record<string, unknown>;

    session.aiConfig = {
      enabled: data?.ai_enabled ?? false,
      apiKey: data?.ai_api_key ?? '',
      provider: data?.ai_provider ?? 'gemini',
      openaiApiKey: data?.ai_openai_api_key ?? '',
      systemPrompt: data?.ai_system_prompt ?? '',
      responseDelayMs: data?.ai_response_delay_ms ?? 1500,
      model: data?.ai_model ?? 'gemini-2.5-flash',
      activeHours: data?.ai_active_hours,
      // Back-compat: leer del nuevo nombre (`bot_keyword_rules`) y caer al
      // viejo (`ai_keyword_rules`) si todavía no existe el doc migrado.
      // La UI siempre escribe en el nuevo, así que tras el primer guardado
      // del usuario el viejo deja de usarse.
      keywordRules: data?.bot_keyword_rules ?? data?.ai_keyword_rules ?? [],
      discriminator: {
        enabled: data?.ai_discriminator_enabled ?? false,
        prompt: data?.ai_discriminator_prompt ?? '',
      },
      mediaAllowlist: {
        image:    rawAllowlist.image    === true,
        audio:    rawAllowlist.audio    === true,
        video:    rawAllowlist.video    === true,
        document: rawAllowlist.document === true,
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
      mediaAllowlist: {
        image: false,
        audio: false,
        video: false,
        document: false,
      },
      loadedAt: now,
    };
  }
}
