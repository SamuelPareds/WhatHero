// ============================================
// Mensajes internos: el equipo se habla DENTRO de la conversación con un
// cliente sin que el cliente lo vea ("dile que sí a la promo", "¿me ayudas
// con este chat?").
//
// Viven en una colección plana de la sesión, NO en `chats/{id}/messages`:
//     whatsapp_sessions/{sid}/internal_messages/{id}   { chatId, ... }
// - Fuera de `messages/` porque todo lo que lee ahí le habla al cliente o
//   habla de él: el historial de la IA, el discriminador, el agente de
//   seguimiento, el preview y el ✓ de la lista, los pendientes, el buscador,
//   la guarda de choque. Un interno ahí adentro sería una fuga esperando su
//   turno (la IA repitiéndole al cliente "dile que no, es muy insistente").
// - Plana (gemela de media_index) para que la bandeja "Para ti" sea UNA
//   consulta (`recipientUids array-contains`) y no una por chat.
//
// El backend es el único que escribe: fija el autor (no se le cree al
// cliente), sólo avisa a quien ve la sesión y manda el push.
// ============================================
import admin from 'firebase-admin';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { sessionTeam } from './memberAccess';
import { resolveHumanSender } from './senderResolver';
import { sendInternalMessageNotification } from './notificationService';

export const INTERNAL_TEXT_MAX = 2000;
const RECIPIENTS_MAX = 20;
// El id lo genera la app (autoId de Firestore). Si reintenta porque no le
// llegó la respuesta, el segundo intento choca con el primero en vez de
// duplicar el mensaje y el aviso.
const ID_RE = /^[A-Za-z0-9]{20}$/;
// Termina en `.doc(...)`: una `/` metería el mensaje en otra ruta.
const SEGMENT_RE = /^[^/]{1,128}$/;
const ALREADY_EXISTS = 6; // código gRPC de Firestore

export interface Teammate {
  uid: string;
  name: string;
}

export interface InternalMessageInput {
  sessionId: string;
  chatId: string;
  id: string;
  text: string;
  recipientUids: string[];
}

export type ParseResult =
  | { ok: true; value: InternalMessageInput }
  | { ok: false; error: string };

// Valida el body de POST /internal-messages. Puro: se testea sin Firestore.
export function parseInternalMessageInput(body: unknown): ParseResult {
  const b = (body ?? {}) as Record<string, unknown>;
  const { sessionId, chatId, id } = b;
  if (typeof sessionId !== 'string' || !SEGMENT_RE.test(sessionId)) {
    return { ok: false, error: 'sessionId inválido' };
  }
  if (typeof chatId !== 'string' || !SEGMENT_RE.test(chatId)) {
    return { ok: false, error: 'chatId inválido' };
  }
  if (typeof id !== 'string' || !ID_RE.test(id)) {
    return { ok: false, error: 'id inválido' };
  }
  const text = typeof b.text === 'string' ? b.text.trim() : '';
  if (!text) return { ok: false, error: 'El mensaje está vacío' };
  if (text.length > INTERNAL_TEXT_MAX) {
    return { ok: false, error: `Máximo ${INTERNAL_TEXT_MAX} caracteres` };
  }
  const requested = Array.isArray(b.recipientUids) ? b.recipientUids : [];
  const recipientUids = [
    ...new Set(requested.filter((u): u is string => typeof u === 'string' && SEGMENT_RE.test(u))),
  ].slice(0, RECIPIENTS_MAX);
  return { ok: true, value: { sessionId, chatId, id, text, recipientUids } };
}

// A quién se le avisa de verdad: nunca al autor, y sólo a quien ve la sesión.
// Un push lleva el nombre del cliente y el texto: no puede llegarle a un
// miembro restringido a otra sesión aunque la app lo pida.
export function pickRecipients(requested: string[], team: readonly string[], authorUid: string): string[] {
  const allowed = new Set(team);
  return requested.filter((uid) => uid !== authorUid && allowed.has(uid));
}

function sessionRef(accountId: string, sessionId: string) {
  return admin
    .firestore()
    .collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('whatsapp_sessions')
    .doc(sessionId);
}

async function withNames(uids: string[]): Promise<Teammate[]> {
  const senders = await Promise.all(uids.map((uid) => resolveHumanSender(uid)));
  return senders.map((s, i) => ({ uid: uids[i], name: s.name }));
}

// Con quién puedo hablar en esta sesión, sin contarme. null = no se pudo leer.
export async function listTeammates(
  accountId: string,
  sessionId: string,
  requesterUid: string,
): Promise<Teammate[] | null> {
  const team = await sessionTeam(accountId, sessionId);
  if (!team) return null;
  return withNames(team.filter((uid) => uid !== requesterUid));
}

export type CreateResult = 'created' | 'duplicate' | 'team_unavailable';

export async function createInternalMessage(
  accountId: string,
  authorUid: string,
  input: InternalMessageInput,
): Promise<CreateResult> {
  // Sin saber quién ve la sesión no sabemos a quién avisar. Mejor que la app
  // muestre "no se envió" que guardar un aviso que no le llega a nadie.
  const team = await sessionTeam(accountId, input.sessionId);
  if (!team) return 'team_unavailable';

  const recipientUids = pickRecipients(input.recipientUids, team, authorUid);
  const session = sessionRef(accountId, input.sessionId);
  const chatRef = session.collection('chats').doc(input.chatId);
  const [[author, ...recipients], chatSnap] = await Promise.all([
    withNames([authorUid, ...recipientUids]),
    chatRef.get(),
  ]);
  const contactName = ((chatSnap.data()?.contactName as string | undefined) ?? '').trim();

  try {
    await session.collection('internal_messages').doc(input.id).create({
      chatId: input.chatId,
      // Copia para la bandeja "Para ti": así lista sin leer cada chat.
      contactName,
      text: input.text,
      authorUid,
      authorName: author.name,
      recipients, // lo que se pinta
      recipientUids, // lo que consulta la bandeja (array-contains)
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    if ((error as { code?: number }).code === ALREADY_EXISTS) return 'duplicate';
    throw error;
  }

  console.log(
    `[Interno] ${author.name} → ${recipients.map((r) => r.name).join(', ') || '(sin aviso)'} en ${input.chatId}`,
  );
  if (recipientUids.length === 0) return 'created';

  if (chatSnap.exists) await bumpUnread(chatRef, recipientUids);
  void sendInternalMessageNotification({
    accountId,
    sessionPhone: input.sessionId,
    chatId: input.chatId,
    contactName: contactName || input.chatId,
    authorName: author.name,
    text: input.text,
    recipientUids,
  });
  return 'created';
}

// El badge violeta: un contador por destinatario que su app borra al abrir
// el chat. Sólo si el chat existe: uno abierto con "Nuevo chat" no tiene doc
// hasta el primer mensaje, no hay tile donde pintarlo, y un `set` crearía un
// doc fantasma sin `lastMessageTimestamp`.
async function bumpUnread(chatRef: admin.firestore.DocumentReference, uids: string[]): Promise<void> {
  const inc = admin.firestore.FieldValue.increment(1);
  // FieldPath y no 'internal_unread.' + uid: un punto en el uid partiría el campo.
  const [first, ...rest] = uids.map((uid) => new admin.firestore.FieldPath('internal_unread', uid));
  try {
    await chatRef.update(first, inc, ...rest.flatMap((path) => [path, inc]));
  } catch (error) {
    // El mensaje ya quedó y el push sale igual: sin badge no se pierde nada.
    console.warn('[Interno] No se pudo sumar el badge:', error);
  }
}
