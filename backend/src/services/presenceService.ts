// ============================================
// Presencia del equipo: quién está en qué chat y quién está respondiendo.
//
// Todo efímero y en memoria: CERO lecturas/escrituras de Firestore por
// presencia (salvo el acceso a la sesión, cacheado en memberAccess.ts).
//   - La entrada de un socket muere con el socket. No hay heartbeat: el
//     ping/pong de Socket.io ya retira a los clientes muertos (≤45 s) y el
//     cliente reenvía su estado completo en cada conexión, así que un
//     reinicio o un redeploy se reconstruyen solos.
//   - Cada sesión de WhatsApp es una sala `tp:{accountId}:{sessionPhone}` a
//     la que sólo se entra con acceso a esa sesión. NO se usa la sala
//     `accountId` a propósito: esa llega a todos los miembros, incluidos los
//     restringidos a otras sesiones, y la presencia lleva ids de chats.
//   - Proceso único (Railway, sin Redis). Con réplicas, esto necesitaría el
//     adapter de Redis y un registro compartido.
//
// Protocolo (un evento de ida, uno de vuelta):
//   cliente → team_presence_set {clientId, sessionPhone|null, chatId|null, composing}
//   sala    ← team_presence     {sessionPhone, viewers:[{clientId,uid,name,chatId,composing}]}
// ============================================
import type { Server, Socket } from 'socket.io';
import { resolveHumanSender } from './senderResolver';
import { canAccessSession, invalidateMemberAccess } from './memberAccess';
import {
  PresenceRegistry,
  parsePresenceSet,
  roomFor,
  takeToken,
} from './presenceRegistry';

const registry = new PresenceRegistry();
let io: Server | null = null;

// Si el token bucket frena un set, el ÚLTIMO estado se aplica igual cuando
// haya ficha: tirarlo dejaría al equipo viendo un chat que ya no es.
const DEFER_MS = 250;

export function initPresence(server: Server): void {
  io = server;
}

function broadcast(rooms: Iterable<string>): void {
  if (!io) return;
  for (const room of rooms) {
    const payload = registry.payloadFor(room);
    if (payload) io.to(room).emit('team_presence', payload);
  }
}

function leavePresenceRooms(socket: Socket, keep?: string): void {
  for (const room of socket.rooms) {
    if (room.startsWith('tp:') && room !== keep) void socket.leave(room);
  }
}

export function registerPresenceHandlers(
  socket: Socket,
  accountId: string,
  uid: string,
): void {
  // Número de secuencia por socket: tras cada await se compara, y si llegó un
  // set más nuevo o el socket se cerró, el resultado viejo se descarta. Sin
  // esto un set lento (cache frío) podía pisar a uno rápido posterior, o
  // resucitar la entrada de un socket ya desconectado.
  socket.data.presenceSeq = 0;

  socket.on('team_presence_set', (raw: unknown) => onSet(socket, accountId, uid, raw));

  socket.on('disconnect', () => {
    socket.data.presenceSeq++;
    clearTimeout(socket.data.presenceDeferTimer);
    broadcast(registry.remove(socket.id));
  });
}

function onSet(socket: Socket, accountId: string, uid: string, raw: unknown): void {
  const { ok, bucket } = takeToken(socket.data.presenceBucket, Date.now());
  socket.data.presenceBucket = bucket;
  if (!ok) {
    socket.data.presenceDeferred = raw;
    if (!socket.data.presenceDeferTimer) {
      socket.data.presenceDeferTimer = setTimeout(() => {
        socket.data.presenceDeferTimer = undefined;
        const latest = socket.data.presenceDeferred;
        socket.data.presenceDeferred = undefined;
        if (latest !== undefined && socket.connected) onSet(socket, accountId, uid, latest);
      }, DEFER_MS);
    }
    return;
  }
  // Una promesa rechazada sin catch tumba el proceso en Node 20.
  void handleSet(socket, accountId, uid, raw).catch((error) => {
    console.error('[Presence] Error aplicando team_presence_set:', error);
  });
}

async function handleSet(
  socket: Socket,
  accountId: string,
  uid: string,
  raw: unknown,
): Promise<void> {
  const parsed = parsePresenceSet(raw);
  if (!parsed) return;
  const seq = ++socket.data.presenceSeq;

  if (parsed.sessionPhone === null) {
    leavePresenceRooms(socket);
    broadcast(registry.remove(socket.id));
    return;
  }

  const [allowed, sender] = await Promise.all([
    canAccessSession(accountId, uid, parsed.sessionPhone),
    resolveHumanSender(uid),
  ]);
  if (seq !== socket.data.presenceSeq || socket.disconnected) return;

  if (!allowed) {
    console.warn(`[Presence] uid=${uid} sin acceso a la sesión ${parsed.sessionPhone}`);
    leavePresenceRooms(socket);
    broadcast(registry.remove(socket.id));
    return;
  }

  const room = roomFor(accountId, parsed.sessionPhone);
  leavePresenceRooms(socket, room);
  void socket.join(room);

  const { changedRooms } = registry.set({
    socketId: socket.id,
    clientId: parsed.clientId,
    uid,
    name: sender.name,
    accountId,
    sessionPhone: parsed.sessionPhone,
    chatId: parsed.chatId,
    composing: parsed.composing,
  });
  broadcast(changedRooms);
}

// Al cambiar los permisos de un miembro: invalida el cache y saca en el acto
// de cada sala a quien ya no tenga acceso a esa sesión.
export async function revalidatePresenceAccess(accountId: string): Promise<void> {
  invalidateMemberAccess(accountId);
  if (!io) return;
  const changed = new Set<string>();
  for (const entry of registry.entriesForAccount(accountId)) {
    if (await canAccessSession(accountId, entry.uid, entry.sessionPhone)) continue;
    const socket = io.sockets.sockets.get(entry.socketId);
    if (socket) {
      // Invalida un set en vuelo que ya había pasado el chequeo viejo.
      socket.data.presenceSeq++;
      leavePresenceRooms(socket);
    }
    for (const room of registry.remove(entry.socketId)) changed.add(room);
  }
  broadcast(changed);
}
