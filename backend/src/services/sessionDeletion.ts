// ============================================
// Eliminar una sesión de WhatsApp con todo lo suyo. Sólo el owner.
//
// Borrar es lo fácil: todo vive bajo un doc (`whatsapp_sessions/{sid}` y sus
// subcolecciones) y un prefijo de Storage. Lo difícil es que NO RESUCITE. Hay
// sockets reintentando, reintentos a mitad de `startSession`, carpetas de
// credenciales que el arranque restaura, media subiendo, ciclos de IA, lotes de
// seguimiento y vistas abiertas en otros dispositivos: todos escriben con
// `set(merge)`, y cualquiera recreaba el doc o dejaba huérfanos que reaparecían
// enteros si el número se volvía a vincular (el id del doc es el número).
//
// Por eso el doc es la LÁPIDA, y se borra al final:
//   1. Se marca (`deleting_at`, ver markSessionDeleting). Sobrevive a un
//      reinicio, todo el equipo ve "Eliminando…" y las guardas saben que no
//      deben escribir: initializeSession, sessionTarget, reglas de Firestore.
//   2. Se corta todo lo que escribe: ciclos de IA, sockets (con logout ante
//      WhatsApp), QRs pendientes para re-vincularla y carpetas en disco.
//   3. Tras una gracia para que lo que estaba en vuelo termine, se purga
//      Storage y cada subcolección, se verifica que no quede nada (hasta tres
//      pasadas), se revocan los permisos del equipo y RECIÉN AHÍ se borra el
//      doc. `recursiveDelete(doc)` no sirve para esto: borra el padre aunque
//      fallen los descendientes, y se llevaría la marca que permite reanudar.
//   4. Si algo falla, la lápida se queda y el barrido periódico lo retoma.
//
// Ver CLAUDE.md, "🗑️ Eliminar una sesión".
// ============================================
import admin from 'firebase-admin';
import { existsSync, readdirSync, rmSync } from 'fs';
import type { Server } from 'socket.io';
import type { SessionData } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';
import {
  forgetKey,
  logoutAndForget,
  markSessionDeleting,
  markSessionGone,
} from './sessionSupervisor';
import { cancelAiCyclesForSession } from './aiService';
import { invalidateMemberAccess } from './memberAccess';
import { revalidatePresenceAccess } from './presenceService';
import { removeSessionFromApiKeys } from './apiKeys';
import { purgeApiSendsForSession } from './apiSends';

// Lo que estaba en vuelo al cortar (una media que reintenta, la última llamada
// al LLM de un lote de seguimiento) termina en segundos. Dos minutos es
// holgadísimo, y la verificación de abajo cubre igual lo que llegue tarde.
export const DELETION_GRACE_MS = 2 * 60_000;
const MAX_PURGE_PASSES = 3;

/** De meta.json: a qué cuenta y doc pertenece una llave. */
export interface KeyOwner {
  accountId: string;
  sessionId?: string;
  // QR pendiente para re-vincular o cambiarle el número a la sesión.
  intoSessionId?: string;
}

/**
 * ¿Esta llave es de la sesión? El principal y la línea anterior comparten el
 * doc (`sessionId`); un QR abierto para re-vincularla todavía no tiene doc pero
 * apunta a ella. Un QR de "Agregar número" no apunta a nada: si escanea este
 * mismo número lo rechaza sessionTarget (`deleting`).
 */
export function keyBelongsTo(owner: KeyOwner | null, accountId: string, sessionId: string): boolean {
  if (!owner || owner.accountId !== accountId) return false;
  return owner.sessionId === sessionId || owner.intoSessionId === sessionId;
}

/**
 * Prefijo de Storage de la sesión. La barra final no es estética: sin ella el
 * prefijo de `52155` también abarca a `521551234…`, y borraríamos los archivos
 * de otra sesión.
 */
export function storagePrefix(root: string, accountId: string, sessionId: string): string {
  return `${root}/${accountId}/whatsapp_sessions/${sessionId}/`;
}

export function graceRemainingMs(deletingAtMs: number, now: number, graceMs = DELETION_GRACE_MS): number {
  return Math.max(0, deletingAtMs + graceMs - now);
}

/** Miembros con un permiso explícito a la sesión (`access.sessions.{sid}`). */
export function grantsToRevoke(
  members: { id: string; data: Record<string, any> | undefined }[],
  sessionId: string,
): string[] {
  return members
    .filter(({ data }) => {
      const sessions = data?.access?.sessions;
      return !!sessions && typeof sessions === 'object' && Object.prototype.hasOwnProperty.call(sessions, sessionId);
    })
    .map(({ id }) => id);
}

// ---------------------------------------------------------------------------

interface Deps {
  sessions: Map<string, SessionData>;
  db: admin.firestore.Firestore;
  io: Server;
  /** `readSessionMeta` de index.ts (ya normaliza los meta.json legacy). */
  readKeyOwner: (sessionKey: string) => KeyOwner | null;
}

let deps: Deps | null = null;

export function initSessionDeletion(d: Deps): void {
  deps = d;
}

function requireDeps(): Deps {
  if (!deps) throw new Error('[Eliminar] initSessionDeletion() no fue llamado');
  return deps;
}

function sessionRef(accountId: string, sessionId: string) {
  return requireDeps()
    .db.collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('whatsapp_sessions')
    .doc(sessionId);
}

const running = new Map<string, Promise<void>>();

/**
 * Lo que dispara el endpoint. Devuelve `missing` si el doc no existe; si no,
 * si el logout salió hacia WhatsApp. Pedirlo dos veces no hace daño: la
 * segunda vuelve a cortar (idempotente) y el job no se duplica.
 */
export async function requestSessionDeletion(
  accountId: string,
  sessionId: string,
  byUid: string,
): Promise<'missing' | { loggedOut: boolean; already: boolean }> {
  const marked = await markSessionDeleting(accountId, sessionId, byUid);
  if (marked === 'missing') return 'missing';

  markSessionGone(accountId, sessionId);
  const { loggedOut } = await stopSessionActivity(accountId, sessionId);
  scheduleJob(accountId, sessionId, Date.now());

  console.log(
    `[Eliminar] ${sessionId} (cuenta ${accountId}) marcada por ${byUid}. ` +
    `Logout ante WhatsApp: ${loggedOut ? 'confirmado' : 'no se pudo (sin socket abierto)'}.`,
  );
  return { loggedOut, already: marked === 'already' };
}

/**
 * Corta todo lo que puede escribir en la sesión. Idempotente: el job la vuelve
 * a correr antes de cada pasada por si algo arrancó entre medio.
 *
 * `loggedOut` es honesto: sólo es true si había al menos un socket vinculado y
 * todos llegaron a mandar el logout. Si no, el teléfono puede seguir mostrando
 * "WhatHero" en Dispositivos vinculados y la app se lo dice al owner.
 */
export async function stopSessionActivity(accountId: string, sessionId: string): Promise<{ loggedOut: boolean }> {
  const { sessions, io, readKeyOwner } = requireDeps();

  const ours = [...sessions.entries()].filter(([key, s]) =>
    keyBelongsTo(
      { accountId: s.accountId, sessionId: s.sessionId, intoSessionId: readKeyOwner(key)?.intoSessionId },
      accountId,
      sessionId,
    ),
  );

  // La IA primero: un ciclo que se queda sin socket falla al enviar y escala a
  // humano, o sea, escribe el chat y manda un push. Uno cancelado no escala.
  for (const [key] of ours) cancelAiCyclesForSession(key);

  const results = await Promise.all(
    ours.map(async ([key, s]) => {
      const linked = !!s.sessionId;
      if (!linked) {
        // QR abierto para re-vincularla: la pantalla del QR ya sabe mostrar un rechazo.
        io.to(accountId).emit('link_rejected', { sessionKey: key, reason: 'deleting', sessionId });
      }
      const confirmed = await logoutAndForget(key, 'session_deleted');
      return { linked, confirmed };
    }),
  );

  // Carpetas en disco que no están en memoria (una restauración que falló al
  // bootear, por ejemplo): el próximo arranque las resucitaría.
  if (existsSync('auth_info')) {
    for (const entry of readdirSync('auth_info', { withFileTypes: true })) {
      if (!entry.isDirectory() || sessions.has(entry.name)) continue;
      if (!keyBelongsTo(readKeyOwner(entry.name), accountId, sessionId)) continue;
      forgetKey(entry.name);
      try {
        rmSync(`auth_info/${entry.name}`, { recursive: true, force: true });
        console.log(`[Eliminar] Carpeta auth_info/${entry.name} de ${sessionId} borrada.`);
      } catch (error) {
        console.error(`[Eliminar] No se pudo borrar auth_info/${entry.name}:`, error);
      }
    }
  }

  const linked = results.filter((r) => r.linked);
  return { loggedOut: linked.length > 0 && linked.every((r) => r.confirmed) };
}

function scheduleJob(accountId: string, sessionId: string, deletingAtMs: number): void {
  const id = `${accountId}/${sessionId}`;
  if (running.has(id)) return;
  const job = runDeletionJob(accountId, sessionId, deletingAtMs)
    .catch((error) => {
      console.error(`[Eliminar] ${sessionId}: el borrado falló; la lápida queda y se reintenta en el próximo barrido.`, error);
    })
    .finally(() => running.delete(id));
  running.set(id, job);
}

async function runDeletionJob(accountId: string, sessionId: string, deletingAtMs: number): Promise<void> {
  const wait = graceRemainingMs(deletingAtMs, Date.now());
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  const ref = sessionRef(accountId, sessionId);
  const prefix = storagePrefix(ACCOUNTS_COLLECTION, accountId, sessionId);
  const bucket = admin.storage().bucket();

  for (let pass = 1; ; pass++) {
    // Nunca purgar una sesión viva: si la lápida ya no está, alguien la quitó
    // (o el borrado ya terminó). No hay nada que hacer.
    const snap = await ref.get();
    if (!snap.exists || !snap.data()?.deleting_at) {
      console.warn(`[Eliminar] ${sessionId}: ya no es lápida; se aborta la purga.`);
      return;
    }

    await stopSessionActivity(accountId, sessionId);

    // Storage primero: si después fallara Firestore, la lápida sigue y se
    // reintenta entero; al revés quedarían archivos sin nada que los nombre.
    // `force` sigue con el resto aunque falle uno y rechaza al final.
    await bucket.deleteFiles({ prefix, force: true }).catch((errors) => {
      console.warn(`[Eliminar] ${sessionId}: Storage dejó errores en la pasada ${pass}:`, errors);
    });
    // Cada subcolección por separado, nunca el doc (ver el encabezado).
    // `listCollections` también ve las que sólo tienen huérfanos adentro.
    for (const collection of await ref.listCollections()) {
      await requireDeps().db.recursiveDelete(collection).catch((error) => {
        console.warn(`[Eliminar] ${sessionId}: ${collection.id} dejó errores en la pasada ${pass}:`, error);
      });
    }

    const [[leftFiles], leftCollections] = await Promise.all([
      bucket.getFiles({ prefix, maxResults: 1, autoPaginate: false }),
      ref.listCollections(),
    ]);
    if (leftFiles.length === 0 && leftCollections.length === 0) break;
    if (pass >= MAX_PURGE_PASSES) {
      throw new Error(
        `quedan restos tras ${pass} pasadas (Storage: ${leftFiles.length > 0}, subcolecciones: ${leftCollections.map((c) => c.id).join(', ') || 'ninguna'})`,
      );
    }
  }

  await revokeMemberGrants(accountId, sessionId);
  // Lo del API pública vive fuera del doc de la sesión: los registros de envío
  // (números y nombres de sus contactos) y las llaves restringidas a ella.
  await purgeApiSendsForSession(accountId, sessionId);
  await removeSessionFromApiKeys(accountId, sessionId);
  // Limpiar también el secreto de Cloud API (si existía) guardado fuera de whatsapp_sessions.
  await requireDeps()
    .db.collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('cloud_api_secrets')
    .doc(sessionId)
    .delete()
    .catch((err) => {
      console.warn(`[Eliminar] ${sessionId}: no se pudo borrar cloud_api_secrets:`, err);
    });
  await ref.delete();

  console.log(`[Eliminar] ✅ ${sessionId} (cuenta ${accountId}) eliminada por completo.`);
}

/**
 * Un permiso colgado no es inofensivo: el id del doc es el número, así que si
 * se vuelve a vincular, el miembro heredaría en silencio acceso a la sesión
 * nueva (las reglas leen `access.sessions`).
 */
async function revokeMemberGrants(accountId: string, sessionId: string): Promise<void> {
  const { db } = requireDeps();
  const members = await db.collection(ACCOUNTS_COLLECTION).doc(accountId).collection('members').get();
  const uids = grantsToRevoke(members.docs.map((d) => ({ id: d.id, data: d.data() })), sessionId);
  // FieldPath y no 'access.sessions.123': así el id nunca se lee como ruta.
  const field = new admin.firestore.FieldPath('access', 'sessions', sessionId);
  await Promise.all(
    uids.map((uid) => members.docs.find((d) => d.id === uid)!.ref.update(field, admin.firestore.FieldValue.delete())),
  );

  invalidateMemberAccess(accountId);
  void revalidatePresenceAccess(accountId).catch((error) => {
    console.error('[Eliminar] Error revalidando presencia:', error);
  });
  if (uids.length > 0) console.log(`[Eliminar] ${sessionId}: permiso revocado a ${uids.length} miembro(s).`);
}

// ---------------------------------------------------------------------------
// Retomar tras un reinicio
// ---------------------------------------------------------------------------

export interface Tombstone {
  accountId: string;
  sessionId: string;
  deletingAtMs: number;
}

async function findTombstones(): Promise<Tombstone[]> {
  const { db } = requireDeps();
  const found: Tombstone[] = [];
  // `listDocuments`: incluye cuentas sin doc propio (owners antiguos).
  for (const account of await db.collection(ACCOUNTS_COLLECTION).listDocuments()) {
    try {
      const snap = await account.collection('whatsapp_sessions').where('deleting_at', '!=', null).get();
      for (const doc of snap.docs) {
        found.push({
          accountId: account.id,
          sessionId: doc.id,
          deletingAtMs: doc.data().deleting_at?.toMillis?.() ?? Date.now(),
        });
      }
    } catch (error) {
      console.error(`[Eliminar] No se pudieron buscar lápidas en la cuenta ${account.id}:`, error);
    }
  }
  return found;
}

/**
 * Al bootear, ANTES de restaurar sesiones: marca las lápidas para que
 * `startExistingSessions` no resucite sus carpetas.
 */
export async function loadTombstones(): Promise<Tombstone[]> {
  const tombstones = await findTombstones();
  for (const t of tombstones) markSessionGone(t.accountId, t.sessionId);
  if (tombstones.length > 0) {
    console.log(`[Eliminar] ${tombstones.length} eliminación(es) pendiente(s): ${tombstones.map((t) => t.sessionId).join(', ')}`);
  }
  return tombstones;
}

/** Retoma los borrados pendientes. Al bootear y en cada barrido de fantasmas. */
export async function resumeSessionDeletions(known?: Tombstone[]): Promise<void> {
  const tombstones = known ?? (await findTombstones());
  for (const t of tombstones) {
    markSessionGone(t.accountId, t.sessionId);
    scheduleJob(t.accountId, t.sessionId, t.deletingAtMs);
  }
}
