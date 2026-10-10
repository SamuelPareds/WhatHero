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
import { isSessionGone } from './sessionSupervisor';

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

// Valida el body de POST /internal-messages/delete.
export function parseInternalDeleteInput(
  body: unknown,
): { ok: true; sessionId: string; id: string } | { ok: false; error: string } {
  const b = (body ?? {}) as Record<string, unknown>;
  const { sessionId, id } = b;
  if (typeof sessionId !== 'string' || !SEGMENT_RE.test(sessionId)) {
    return { ok: false, error: 'sessionId inválido' };
  }
  if (typeof id !== 'string' || !ID_RE.test(id)) {
    return { ok: false, error: 'id inválido' };
  }
  return { ok: true, sessionId, id };
}

// Cómo queda el badge de cada destinatario al borrar un interno: uid → nuevo
// contador (0 = se borra el campo). Puro, para testearlo sin Firestore.
//
// Sólo se le descuenta a quien todavía NO lo vio. El contador cuenta los
// internos que llegaron después de la última vez que abrió el chat
// (`internal_seen_at`, lo escribe la app al apagar el badge). A quien ya lo vio
// no se le toca: descontarle se comería el badge de un interno más nuevo que
// sí tiene pendiente.
export function unreadAfterDelete(
  unread: Record<string, number>,
  seenAtMs: Record<string, number>,
  recipientUids: string[],
  sentAtMs: number,
): Map<string, number> {
  const next = new Map<string, number>();
  for (const uid of recipientUids) {
    const count = unread[uid] ?? 0;
    if (count <= 0) continue; // nada pendiente: ya lo vio o nunca se le contó
    const seen = seenAtMs[uid];
    if (seen !== undefined && seen >= sentAtMs) continue; // lo vio; lo pendiente es otro
    next.set(uid, count - 1);
  }
  return next;
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

export type CreateResult = 'created' | 'duplicate' | 'team_unavailable' | 'session_gone';

export async function createInternalMessage(
  accountId: string,
  authorUid: string,
  input: InternalMessageInput,
): Promise<CreateResult> {
  // La sesión se está eliminando: el `create` dejaría un huérfano y el push
  // avisaría al equipo de un chat que ya no existe.
  if (isSessionGone(accountId, input.sessionId)) return 'session_gone';

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

export type DeleteResult = 'deleted' | 'not_found' | 'forbidden';

// Borra un interno. Sólo su autor puede: ni el destinatario ni el owner (por
// ahora; los permisos finos vienen después). En una transacción con el doc del
// chat, para descontar el badge de quien todavía no lo vio sin pisar un
// interno que llegue al mismo tiempo.
//
// El push que ya salió no se puede retirar: si el destinatario no lo abrió,
// sigue en la bandeja de su teléfono con el texto.
export async function deleteInternalMessage(
  accountId: string,
  requesterUid: string,
  sessionId: string,
  id: string,
): Promise<DeleteResult> {
  const session = sessionRef(accountId, sessionId);
  const msgRef = session.collection('internal_messages').doc(id);

  return admin.firestore().runTransaction(async (tx) => {
    const msg = await tx.get(msgRef);
    if (!msg.exists) return 'not_found';
    const data = msg.data() ?? {};
    if (data.authorUid !== requesterUid) return 'forbidden';

    const recipientUids = Array.isArray(data.recipientUids) ? (data.recipientUids as string[]) : [];
    const chatId = typeof data.chatId === 'string' ? data.chatId : '';
    // Todas las lecturas antes de la primera escritura (regla de las transacciones).
    const chatRef = chatId && recipientUids.length > 0 ? session.collection('chats').doc(chatId) : null;
    const chat = chatRef ? await tx.get(chatRef) : null;

    if (chatRef && chat?.exists) {
      const chatData = chat.data() ?? {};
      const next = unreadAfterDelete(
        numbersIn(chatData.internal_unread),
        millisIn(chatData.internal_seen_at),
        recipientUids,
        (data.timestamp as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0,
      );
      const updates: unknown[] = [];
      for (const [uid, count] of next) {
        updates.push(
          new admin.firestore.FieldPath('internal_unread', uid),
          count > 0 ? count : admin.firestore.FieldValue.delete(),
        );
      }
      if (updates.length > 0) {
        const [field, value, ...rest] = updates;
        tx.update(chatRef, field as admin.firestore.FieldPath, value, ...rest);
      }
    }
    tx.delete(msgRef);
    return 'deleted';
  });
}

function numbersIn(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (raw && typeof raw === 'object') {
    for (const [k, v] of Object.entries(raw)) if (typeof v === 'number') out[k] = v;
  }
  return out;
}

function millisIn(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (raw && typeof raw === 'object') {
    for (const [k, v] of Object.entries(raw)) {
      if (v instanceof admin.firestore.Timestamp) out[k] = v.toMillis();
    }
  }
  return out;
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
