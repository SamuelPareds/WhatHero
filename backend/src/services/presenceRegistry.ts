// Presencia del equipo: estado puro en memoria, sin io ni Firestore, para que
// se pueda testear entero. El cableado con Socket.io vive en presenceService.ts.
//
// Una entrada por socket: cada pestaña de la app ve una sola sesión y, como
// mucho, un chat a la vez. La entrada muere con el socket; no hay heartbeat.

export interface PresenceSet {
  clientId: string;
  sessionPhone: string | null;
  chatId: string | null;
  composing: boolean;
}

export interface PresenceEntry {
  socketId: string;
  clientId: string;
  uid: string;
  name: string;
  accountId: string;
  sessionPhone: string;
  chatId: string | null;
  composing: boolean;
}

export interface PresenceViewer {
  clientId: string;
  uid: string;
  name: string;
  chatId: string;
  composing: boolean;
}

export interface PresencePayload {
  sessionPhone: string;
  viewers: PresenceViewer[];
}

// Formatos estrictos: esto entra por un socket y termina en claves de Map y
// nombres de sala. Todo lo que no encaje se descarta sin tocar el estado.
const CLIENT_ID_RE = /^[a-z0-9]{8,32}$/;
const SESSION_PHONE_RE = /^\d{6,20}$/;
// Los chats con un LID sin resolver usan el LID como id: también son dígitos.
const CHAT_ID_RE = /^\d{3,32}$/;

export function parsePresenceSet(raw: unknown): PresenceSet | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.clientId !== 'string' || !CLIENT_ID_RE.test(r.clientId)) return null;

  const sessionPhone = r.sessionPhone ?? null;
  if (sessionPhone !== null && (typeof sessionPhone !== 'string' || !SESSION_PHONE_RE.test(sessionPhone))) {
    return null;
  }
  const chatId = r.chatId ?? null;
  if (chatId !== null && (typeof chatId !== 'string' || !CHAT_ID_RE.test(chatId))) return null;
  // Sin sesión no se puede estar en un chat.
  if (sessionPhone === null && chatId !== null) return null;

  return {
    clientId: r.clientId,
    sessionPhone: sessionPhone as string | null,
    chatId: chatId as string | null,
    // Sólo se responde dentro de un chat.
    composing: chatId !== null && r.composing === true,
  };
}

export function roomFor(accountId: string, sessionPhone: string): string {
  return `tp:${accountId}:${sessionPhone}`;
}

export class PresenceRegistry {
  private bySocket = new Map<string, PresenceEntry>();
  private byRoom = new Map<string, Set<string>>();
  // Una pestaña (cuenta + uid + clientId) tiene un solo socket vivo. Al
  // reconectar llega con socket nuevo antes de que el viejo muera (hasta 45 s
  // de ping timeout): sin este índice se vería a sí misma como fantasma.
  private byClient = new Map<string, string>();

  /**
   * Aplica el estado de un socket. Devuelve las salas a rebroadcastear
   * (vacío si nada cambió) y los sockets fantasma que se retiraron.
   */
  set(entry: PresenceEntry): { changedRooms: Set<string>; ghosts: string[] } {
    const changedRooms = new Set<string>();
    const ghosts: string[] = [];

    const clientKey = `${entry.accountId}|${entry.uid}|${entry.clientId}`;
    const previousSocket = this.byClient.get(clientKey);
    if (previousSocket && previousSocket !== entry.socketId) {
      for (const room of this.remove(previousSocket)) changedRooms.add(room);
      ghosts.push(previousSocket);
    }

    const prev = this.bySocket.get(entry.socketId);
    if (prev && sameEntry(prev, entry)) return { changedRooms, ghosts };

    if (prev) {
      const prevClientKey = `${prev.accountId}|${prev.uid}|${prev.clientId}`;
      if (prevClientKey !== clientKey && this.byClient.get(prevClientKey) === entry.socketId) {
        this.byClient.delete(prevClientKey);
      }
      const prevRoom = roomFor(prev.accountId, prev.sessionPhone);
      this.byRoom.get(prevRoom)?.delete(entry.socketId);
      if (this.byRoom.get(prevRoom)?.size === 0) this.byRoom.delete(prevRoom);
      changedRooms.add(prevRoom);
    }

    const room = roomFor(entry.accountId, entry.sessionPhone);
    this.bySocket.set(entry.socketId, entry);
    this.byClient.set(clientKey, entry.socketId);
    let members = this.byRoom.get(room);
    if (!members) {
      members = new Set();
      this.byRoom.set(room, members);
    }
    members.add(entry.socketId);
    changedRooms.add(room);
    return { changedRooms, ghosts };
  }

  /** Quita el socket. Devuelve la sala afectada, si la había. */
  remove(socketId: string): Set<string> {
    const entry = this.bySocket.get(socketId);
    if (!entry) return new Set();
    this.bySocket.delete(socketId);

    const clientKey = `${entry.accountId}|${entry.uid}|${entry.clientId}`;
    // Sólo si sigue apuntando a este socket: el fantasma que muere tarde no
    // puede borrar el índice de su reemplazo.
    if (this.byClient.get(clientKey) === socketId) this.byClient.delete(clientKey);

    const room = roomFor(entry.accountId, entry.sessionPhone);
    const members = this.byRoom.get(room);
    members?.delete(socketId);
    if (members?.size === 0) this.byRoom.delete(room);
    return new Set([room]);
  }

  /**
   * Estado completo de una sala. Sólo cuentan quienes están DENTRO de un chat:
   * mirar la lista no es presencia. null si la sala quedó vacía (no queda
   * nadie que lo reciba).
   */
  payloadFor(room: string): PresencePayload | null {
    const members = this.byRoom.get(room);
    if (!members || members.size === 0) return null;
    let sessionPhone = '';
    const viewers: PresenceViewer[] = [];
    for (const socketId of members) {
      const e = this.bySocket.get(socketId);
      if (!e) continue;
      sessionPhone = e.sessionPhone;
      if (e.chatId === null) continue;
      viewers.push({
        clientId: e.clientId,
        uid: e.uid,
        name: e.name,
        chatId: e.chatId,
        composing: e.composing,
      });
    }
    return { sessionPhone, viewers };
  }

  entriesForAccount(accountId: string): PresenceEntry[] {
    return [...this.bySocket.values()].filter((e) => e.accountId === accountId);
  }

  get size(): number {
    return this.bySocket.size;
  }
}

function sameEntry(a: PresenceEntry, b: PresenceEntry): boolean {
  return (
    a.accountId === b.accountId &&
    a.sessionPhone === b.sessionPhone &&
    a.chatId === b.chatId &&
    a.composing === b.composing &&
    a.name === b.name &&
    a.uid === b.uid &&
    a.clientId === b.clientId
  );
}

// Token bucket por socket: un cliente sano manda un par de eventos por
// navegación; esto sólo frena a uno roto o malicioso inundando el socket.
export const BUCKET_CAPACITY = 20;
export const BUCKET_REFILL_PER_SEC = 5;

export interface TokenBucket {
  tokens: number;
  updatedAt: number;
}

export function takeToken(
  bucket: TokenBucket | undefined,
  now: number,
): { ok: boolean; bucket: TokenBucket } {
  const current = bucket ?? { tokens: BUCKET_CAPACITY, updatedAt: now };
  const refilled = Math.min(
    BUCKET_CAPACITY,
    current.tokens + ((now - current.updatedAt) / 1000) * BUCKET_REFILL_PER_SEC,
  );
  if (refilled < 1) return { ok: false, bucket: { tokens: refilled, updatedAt: now } };
  return { ok: true, bucket: { tokens: refilled - 1, updatedAt: now } };
}
