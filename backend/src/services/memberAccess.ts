// Quién puede ver qué sesión de WhatsApp. Un solo lugar decide el acceso,
// para que las notificaciones y la presencia del equipo no puedan discrepar.
//
// Modelo (accounts/{accountId}/members/{uid}.access):
//   { allSessions: bool, sessions: { "<phone>": { allChats: true } } }
// El owner (uid == accountId) no tiene doc en members/ y ve todo.
import admin from 'firebase-admin';
import { ACCOUNTS_COLLECTION } from '../config/env';

export interface MemberAccess {
  allSessions?: boolean;
  sessions?: Record<string, unknown>;
}

// Un miembro SIN campo `access` es legacy y ve todo: la restricción sólo
// existe cuando el owner la configura (PATCH /accounts/members/:uid/access).
export function memberHasSessionAccess(
  access: MemberAccess | undefined,
  sessionPhone: string,
): boolean {
  if (!access) return true;
  if (access.allSessions === true) return true;
  return (
    !!access.sessions &&
    Object.prototype.hasOwnProperty.call(access.sessions, sessionPhone)
  );
}

// Lectura de members/ por cuenta, cacheada. La presencia consulta el acceso
// en cada cambio de chat de cada operador: sin cache sería una lectura de toda
// la colección por clic. Quitarle acceso a alguien invalida el cache en el
// acto (ver invalidateMemberAccess), así que los 60 s sólo cubren cambios
// hechos por fuera de nuestra API.
const CACHE_TTL_MS = 60_000;

type MembersSnapshot = Map<string, MemberAccess | undefined>;

const cache = new Map<string, { members: MembersSnapshot; loadedAt: number }>();
// Una invalidación en medio de una lectura no debe dejar cacheado lo viejo.
const epochs = new Map<string, number>();

async function loadMembers(accountId: string): Promise<MembersSnapshot> {
  const snap = await admin
    .firestore()
    .collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('members')
    .get();
  const members: MembersSnapshot = new Map();
  snap.forEach((doc) => members.set(doc.id, doc.data()?.access as MemberAccess | undefined));
  return members;
}

async function getMembers(accountId: string): Promise<MembersSnapshot | null> {
  const cached = cache.get(accountId);
  if (cached && Date.now() - cached.loadedAt < CACHE_TTL_MS) return cached.members;

  const epoch = epochs.get(accountId) ?? 0;
  try {
    const members = await loadMembers(accountId);
    if ((epochs.get(accountId) ?? 0) === epoch) {
      cache.set(accountId, { members, loadedAt: Date.now() });
    }
    return members;
  } catch (error) {
    // Firestore caído: mejor el último dato conocido que dejar al equipo
    // ciego. Sin ningún dato, denegamos (el llamador decide qué significa).
    console.warn(`[memberAccess] No se pudo leer members de ${accountId}:`, error);
    return cached?.members ?? null;
  }
}

// ¿`uid` puede ver la sesión `sessionPhone` de la cuenta? Falla cerrado.
export async function canAccessSession(
  accountId: string,
  uid: string,
  sessionPhone: string,
): Promise<boolean> {
  if (uid === accountId) return true; // owner: nunca paga lectura
  const members = await getMembers(accountId);
  if (!members || !members.has(uid)) return false;
  return memberHasSessionAccess(members.get(uid), sessionPhone);
}

export function invalidateMemberAccess(accountId: string): void {
  cache.delete(accountId);
  epochs.set(accountId, (epochs.get(accountId) ?? 0) + 1);
}
