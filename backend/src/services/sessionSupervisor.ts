import admin from 'firebase-admin';
import { existsSync, rmSync } from 'fs';
import type { Server } from 'socket.io';
import type { SessionData, SessionStatus } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';

/**
 * Supervisión de la conexión de cada sesión de WhatsApp.
 *
 * POR QUÉ EXISTE ESTE ARCHIVO
 * El 03-sep-2026 una sesión de producción pasó 26 horas mostrando
 * "Reconectando…" sin que nadie la estuviera reconectando. El log lo dejó
 * clarísimo:
 *
 *   17:39:34  [Reconexión] Intento 1/10 para d34a3443 (code: 428)
 *   17:39:37  [startSession] d34a3443 → handshake con WA Web 2.3000.1046734560
 *             ...silencio absoluto durante 26 horas
 *
 * El socket de ese reintento se quedó colgado en CONNECTING. Baileys sólo emite
 * `connection.update {connection:'close'}` desde su `end()`, y `end()` se
 * dispara únicamente desde los handlers del WebSocket (`open`, `close`,
 * `error`, `CB:*`). Si el connect TCP se traga los paquetes —un SYN sin
 * respuesta, un blackhole en el NAT de salida— no ocurre ninguno de esos
 * eventos y `end()` no corre jamás. El `handshakeTimeout` de la librería `ws`
 * tampoco cubre ese caso: mide el upgrade HTTP, ya con TCP+TLS establecidos.
 *
 * Pero el bug de fondo no era de Baileys, era nuestro: el reintento N+1 lo
 * disparaba EXCLUSIVAMENTE el evento `close` del intento N. Una cadena de un
 * solo eslabón que apostaba toda la recuperación a que una librería de terceros
 * avisara siempre que falla. El día que no avisó no había timer, ni watchdog, ni
 * segunda opinión — ni un log que lo delatara.
 *
 * QUÉ HACE ESTE MÓDULO
 * Invierte la responsabilidad: el supervisor decide cuándo (re)arrancar un
 * socket; Baileys sólo aporta información (el statusCode del cierre). Tres
 * capas independientes, redundantes a propósito:
 *
 *   1. Deadline de arranque — un socket que no da señales de vida en
 *      CONNECT_DEADLINE_MS se da por muerto sin esperar a Baileys.
 *   2. Scheduler propio — el próximo intento se programa desde aquí y nunca se
 *      queda sin timer: si `startSession` explota, se reprograma solo.
 *   3. Watchdog periódico — barre el Map buscando sesiones que NO estén
 *      conectadas y NO tengan ningún reintento en marcha. Ese es exactamente el
 *      estado en el que murió AgendaCool, y ninguna capa anterior podía verlo.
 *
 * Y como el `status` de Firestore se escribía sólo desde `connection.update`,
 * quedó congelado en "reconnecting" para siempre, con la UI escondiendo justo
 * ahí el botón de re-vincular. Por eso aquí el status pasa a ser una PROYECCIÓN
 * del estado en memoria (`projectStatus`), recalculada en cada barrido: no
 * puede desincronizarse, porque se vuelve a derivar de la verdad cada 2 min.
 */

// Un socket sano llega a `connected to WA` en ~400ms. 60s es holgadísimo y a la
// vez muy por debajo de las horas que puede tardar el kernel en rendirse con un
// connect TCP colgado. No aplica al flujo de QR: el primer `qr` recibido cuenta
// como señal de vida y desarma el deadline (a partir de ahí supervisa Baileys
// con su propio `qrTimeout`).
const CONNECT_DEADLINE_MS = 60_000;

const RECONNECT_BASE_MS = 3_000;
const RECONNECT_MAX_MS = 300_000; // 5 min

// A partir de aquí el doc pasa a `reconnect_failed` para que la UI deje de
// prometer una reconexión inminente y ofrezca re-vincular. El backend NO deja
// de intentar: una caída de red puede durar horas y exigirle al cliente que
// escanee un QR por eso sería un producto peor. Reintentar es gratis; mentir no.
const RECONNECT_ALERT_MS = 10 * 60_000;

// Cada cuánto se recalcula la proyección del estado y se buscan huérfanas.
const SWEEP_INTERVAL_MS = 2 * 60_000;

// El barrido de fantasmas sí paga reads en Firestore, así que va más espaciado.
// Cubre el caso que la proyección no puede ver: docs que apuntan a sesiones que
// ya no existen en memoria.
const GHOST_SWEEP_INTERVAL_MS = 15 * 60_000;

// Estados que afirman que hay una sesión viva detrás. Si el `session_key` del
// doc no está en el Map, cualquiera de estos es mentira.
const LIVE_STATUSES: SessionStatus[] = ['connected', 'reconnecting', 'reconnect_failed'];

interface SupervisorDeps {
  sessions: Map<string, SessionData>;
  db: admin.firestore.Firestore;
  io: Server;
  /** `startSession` de index.ts. Se inyecta para no crear un ciclo de imports. */
  startSession: (sessionKey: string, accountId: string) => Promise<unknown>;
}

let deps: SupervisorDeps | null = null;

export function initSessionSupervisor(d: SupervisorDeps): void {
  deps = d;
}

function requireDeps(): SupervisorDeps {
  if (!deps) throw new Error('[Supervisor] initSessionSupervisor() no fue llamado');
  return deps;
}

// ---------------------------------------------------------------------------
// Ciclo de vida del socket
// ---------------------------------------------------------------------------

/**
 * Mata un socket de Baileys sin que sus eventos nos alcancen.
 *
 * El orden importa: primero se sueltan TODOS los listeners y después se cierra.
 * `sock.end()` emite un último `connection.update` y, sin este orden, ese evento
 * entraría por el handler y programaría una reconexión del socket que acabamos
 * de reemplazar. Antes de esto no se hacía teardown en ningún lado: cada
 * reconexión apilaba un socket zombi más, con sus listeners intactos, escribiendo
 * sobre el estado del socket sano.
 */
export function teardownSocket(sock: any): void {
  if (!sock) return;
  try { sock.ev?.removeAllListeners(); } catch { /* ya estaba muerto */ }
  try { sock.end?.(new Error('reemplazado por WhatHero')); } catch { /* idem */ }
  try { sock.ws?.close(); } catch { /* idem */ }
}

/** Desarma los dos timers de una sesión. Idempotente. */
export function clearSessionTimers(session: SessionData): void {
  if (session.connectDeadline) clearTimeout(session.connectDeadline);
  if (session.reconnectTimer) clearTimeout(session.reconnectTimer);
  session.connectDeadline = undefined;
  session.reconnectTimer = undefined;
}

/**
 * Arma el deadline de arranque. Se llama justo después de crear el socket.
 *
 * `generation` se compara al vencer porque el timer sobrevive al socket que lo
 * armó: si mientras tanto arrancó un reemplazo, este deadline ya no opina.
 */
export function armConnectDeadline(sessionKey: string, session: SessionData, generation: number): void {
  if (session.connectDeadline) clearTimeout(session.connectDeadline);
  session.connectDeadline = setTimeout(() => {
    const current = requireDeps().sessions.get(sessionKey);
    if (!current || current.generation !== generation) return;
    current.connectDeadline = undefined;
    console.warn(
      `[Supervisor] ⏱️ El socket de ${sessionKey} no dio señales de vida en ${CONNECT_DEADLINE_MS / 1000}s. ` +
      `Baileys no emitió nada: lo damos por muerto y reintentamos.`
    );
    teardownSocket(current.sock);
    current.sock = null;
    scheduleReconnect(sessionKey, current, 'connect_timeout');
  }, CONNECT_DEADLINE_MS);
}

/**
 * El socket habló (llegó un `qr` o un `open`): está vivo, el deadline sobra.
 * A partir de aquí supervisan Baileys (qrTimeout, keep-alive) y el watchdog.
 */
export function noteSignOfLife(session: SessionData): void {
  if (!session.connectDeadline) return;
  clearTimeout(session.connectDeadline);
  session.connectDeadline = undefined;
}

// ---------------------------------------------------------------------------
// Reconexión
// ---------------------------------------------------------------------------

/**
 * Programa el próximo intento. Único punto donde nace una reconexión: el
 * handler de `close`, el deadline de arranque y el watchdog pasan todos por acá.
 */
export function scheduleReconnect(sessionKey: string, session: SessionData, reason: string): void {
  const { io } = requireDeps();

  if (session.reconnectTimer) clearTimeout(session.reconnectTimer);
  session.isReady = false;
  session.reconnectCount += 1;

  const delay = Math.min(RECONNECT_BASE_MS * 2 ** (session.reconnectCount - 1), RECONNECT_MAX_MS);
  console.log(
    `[Supervisor] Reintento #${session.reconnectCount} para ${sessionKey} en ${Math.round(delay / 1000)}s (motivo: ${reason})`
  );

  session.reconnectTimer = setTimeout(() => {
    session.reconnectTimer = undefined;
    void restartSession(sessionKey, session.accountId, reason);
  }, delay);

  void syncSessionStatus(sessionKey, session);
  io.to(session.accountId).emit('status_update', {
    status: 'reconnecting',
    sessionKey,
    attempt: session.reconnectCount,
    phoneNumber: session.phoneNumber,
    reason,
  });
}

/**
 * Arranca (o rearranca) el socket de una sesión.
 *
 * El `catch` es la garantía de que la cadena nunca se corta: antes, el
 * `startSession(...)` del setTimeout iba sin `await` ni `.catch()`, así que una
 * excepción ahí era una unhandled rejection — que en Node 20 tumba el proceso
 * entero — y en el mejor caso dejaba la sesión sin ningún intento programado.
 */
export async function restartSession(sessionKey: string, accountId: string, reason: string): Promise<void> {
  const { sessions, startSession } = requireDeps();
  const session = sessions.get(sessionKey);
  if (!session) return; // cancelada mientras esperábamos el timer

  // Sin credenciales no hay nada que reconectar: reintentar sólo generaría QRs
  // que nadie va a escanear. Se retira y el estado queda honesto.
  if (!existsSync(`auth_info/${sessionKey}/creds.json`)) {
    console.warn(`[Supervisor] ${sessionKey} ya no tiene credenciales en disco. Se retira en vez de reintentar.`);
    await retireSession(sessionKey, 'credentials_gone', { wipeAuth: true });
    return;
  }

  try {
    await startSession(sessionKey, accountId);
  } catch (error) {
    console.error(`[Supervisor] startSession falló para ${sessionKey} (motivo previo: ${reason}):`, error);
    const current = sessions.get(sessionKey);
    if (current) scheduleReconnect(sessionKey, current, 'start_failed');
  }
}

/**
 * Saca una sesión de circulación: mata el socket, desarma los timers, la borra
 * del Map y deja el doc de Firestore diciendo la verdad.
 *
 * `wipeAuth` borra también las credenciales en disco. Va en true cuando la
 * sesión ya no sirve para nada (logout, conflicto, reemplazo): si se dejaran,
 * `startExistingSessions()` la resucitaría en cada arranque, para siempre.
 */
export async function retireSession(
  sessionKey: string,
  reason: string,
  { wipeAuth = false, status = 'disconnected' as SessionStatus } = {},
): Promise<void> {
  const { sessions } = requireDeps();
  const session = sessions.get(sessionKey);
  if (!session) return;

  console.log(`[Supervisor] Retirando sesión ${sessionKey} (motivo: ${reason}, wipeAuth: ${wipeAuth})`);
  clearSessionTimers(session);
  teardownSocket(session.sock);
  session.sock = null;
  session.isReady = false;
  sessions.delete(sessionKey);

  if (wipeAuth) {
    try {
      rmSync(`auth_info/${sessionKey}`, { recursive: true, force: true });
    } catch (error) {
      console.error(`[Supervisor] No se pudo borrar auth_info/${sessionKey}:`, error);
    }
  }

  await writeSessionStatus(session, status, { disconnect_reason: reason });
}

/**
 * Cuando una sesión conecta, retira cualquier OTRA sesión del mismo número.
 *
 * Re-vincular una cuenta genera un `sessionKey` nuevo, pero la vieja se quedaba
 * viva en el Map y con su carpeta `auth_info` intacta: peleaba por la misma
 * cuenta de WhatsApp (de ahí buena parte de los cierres 428/409 que se veían en
 * el log) y volvía a resucitar en cada arranque. Un número, una sesión.
 */
export async function retireDuplicateSessions(liveKey: string, live: SessionData): Promise<void> {
  const { sessions } = requireDeps();
  if (!live.phoneNumber) return;

  const stale = [...sessions.entries()].filter(
    ([key, s]) => key !== liveKey && s.accountId === live.accountId && s.phoneNumber === live.phoneNumber,
  );

  for (const [key] of stale) {
    console.log(`[Supervisor] ${live.phoneNumber} reconectó con ${liveKey}; retirando duplicada ${key}.`);
    // `status` se omite a propósito: el doc es el mismo y la sesión viva ya lo
    // dejó en `connected`. Escribir `disconnected` acá lo pisaría con mentira.
    const session = sessions.get(key);
    if (!session) continue;
    clearSessionTimers(session);
    teardownSocket(session.sock);
    sessions.delete(key);
    try {
      rmSync(`auth_info/${key}`, { recursive: true, force: true });
    } catch (error) {
      console.error(`[Supervisor] No se pudo borrar auth_info/${key}:`, error);
    }
  }
}

// ---------------------------------------------------------------------------
// Proyección del estado a Firestore
// ---------------------------------------------------------------------------

/**
 * El estado que le corresponde a una sesión AHORA, derivado sólo de memoria.
 *
 * Esta función es la razón por la que el estado ya no puede quedar congelado:
 * el status de Firestore dejó de ser un log de eventos (que se pierde si el
 * evento no llega) para ser una proyección que se recalcula cada barrido.
 */
export function projectStatus(session: SessionData, now = Date.now()): SessionStatus {
  if (session.isReady) return 'connected';
  const downSince = session.lastConnectedAt ?? session.socketStartedAt;
  return now - downSince > RECONNECT_ALERT_MS ? 'reconnect_failed' : 'reconnecting';
}

/**
 * Escribe el status en el doc de sesión. Único escritor de ese campo.
 *
 * Sin `phoneNumber` no hay doc que direccionar — pasaba en cada arranque en
 * frío, porque el número sólo se conocía tras el primer `open`. Ahora
 * `startSession` lo hidrata desde `meta.json`, así que este caso es residual
 * (sesión nueva que nunca llegó a vincularse) y no hay nada que corregir.
 */
export async function writeSessionStatus(
  session: SessionData,
  status: SessionStatus,
  extra: Record<string, unknown> = {},
): Promise<void> {
  const { db } = requireDeps();
  if (!session.phoneNumber) return;

  try {
    await db
      .collection(ACCOUNTS_COLLECTION)
      .doc(session.accountId)
      .collection('whatsapp_sessions')
      .doc(session.phoneNumber)
      .set(
        { status, last_sync: admin.firestore.Timestamp.now(), ...extra },
        { merge: true },
      );
    session.lastWrittenStatus = status;
  } catch (error) {
    console.error(`[Supervisor] No se pudo escribir status=${status} para ${session.phoneNumber}:`, error);
  }
}

/** Proyecta y escribe sólo si algo cambió. */
async function syncSessionStatus(sessionKey: string, session: SessionData): Promise<void> {
  const expected = projectStatus(session);
  if (expected === session.lastWrittenStatus) return;
  await writeSessionStatus(session, expected);
}

// ---------------------------------------------------------------------------
// Watchdog
// ---------------------------------------------------------------------------

/**
 * Barrido en memoria: sin reads a Firestore. Hace dos cosas.
 *
 * 1. Mantiene el doc sincronizado con la realidad. Mientras el estado es
 *    `reconnecting` refresca `last_sync` aunque no cambie nada: ese heartbeat
 *    es lo que le permite a la app distinguir "el backend sigue intentando" de
 *    "el doc lleva horas congelado porque nadie lo mira". Late sólo en esa
 *    ventana —a los 10 min el estado pasa a `reconnect_failed`, donde la UI ya
 *    ofrece re-vincular— para que una sesión muerta durante días no cueste una
 *    escritura cada dos minutos para siempre.
 * 2. Resucita huérfanas: sesión no conectada y SIN ningún timer armado. Nadie
 *    tiene un plan para reconectarla. Es la firma exacta del incidente del
 *    03-sep y la última red antes de que un cliente se quede mudo sin que nos
 *    enteremos. Se exceptúa la sesión que está mostrando un QR: esa no está
 *    huérfana, está esperando a que un humano lo escanee — reiniciarla le
 *    cambiaría el código en la cara al cliente cada dos minutos.
 */
export function sweepSessions(): void {
  const { sessions } = requireDeps();
  const now = Date.now();

  for (const [sessionKey, session] of sessions) {
    const expected = projectStatus(session, now);

    if (expected === 'reconnecting') {
      void writeSessionStatus(session, expected); // heartbeat
    } else if (expected !== session.lastWrittenStatus) {
      void writeSessionStatus(session, expected);
    }

    const esperandoEscaneo = session.currentQR !== undefined;
    if (!session.isReady && !esperandoEscaneo && !session.reconnectTimer && !session.connectDeadline) {
      const downFor = Math.round((now - (session.lastConnectedAt ?? session.socketStartedAt)) / 1000);
      console.warn(
        `[Watchdog] ${sessionKey} lleva ${downFor}s sin conectar y NADIE tiene un reintento programado. Forzando arranque.`
      );
      scheduleReconnect(sessionKey, session, 'watchdog_orphan');
    }
  }
}

/**
 * Barrido en Firestore: busca docs que afirman tener una sesión viva detrás
 * cuando en memoria no existe ninguna. Es lo único que la proyección no puede
 * ver, porque parte del Map.
 *
 * Reemplaza al HealthCheck de arranque, que sólo miraba `status == 'connected'`
 * y sólo corría al bootear — por eso un doc atascado en `reconnecting` le era
 * invisible.
 */
export async function sweepFirestoreGhosts(): Promise<number> {
  const { db, sessions } = requireDeps();
  const liveKeys = new Set(sessions.keys());
  let cleaned = 0;

  try {
    const accounts = await db.collection(ACCOUNTS_COLLECTION).get();

    for (const account of accounts.docs) {
      const docs = await account.ref
        .collection('whatsapp_sessions')
        .where('status', 'in', LIVE_STATUSES)
        .get();

      for (const doc of docs.docs) {
        const sessionKey = doc.data().session_key;
        if (sessionKey && liveKeys.has(sessionKey)) continue;

        console.log(`[GhostSweep] ${doc.id} (cuenta ${account.id}) dice "${doc.data().status}" sin sesión viva. Corrigiendo.`);
        await doc.ref.set(
          {
            status: 'disconnected',
            disconnect_reason: sessionKey ? 'ghost_no_session_in_memory' : 'ghost_no_session_key',
            last_sync: admin.firestore.Timestamp.now(),
          },
          { merge: true },
        );
        cleaned++;
      }
    }

    console.log(cleaned > 0 ? `[GhostSweep] ✅ ${cleaned} sesión(es) fantasma corregidas.` : '[GhostSweep] ✅ Sin fantasmas.');
  } catch (error) {
    console.error('[GhostSweep] Error durante el barrido:', error);
  }

  return cleaned;
}

/** Arranca los dos barridos periódicos. Se llama una vez, al levantar el server. */
export function startSupervisorLoops(): void {
  requireDeps();
  setInterval(() => {
    try {
      sweepSessions();
    } catch (error) {
      console.error('[Watchdog] Error en el barrido:', error);
    }
  }, SWEEP_INTERVAL_MS);

  setInterval(() => {
    void sweepFirestoreGhosts();
  }, GHOST_SWEEP_INTERVAL_MS);

  console.log(
    `[Supervisor] Activo. Barrido cada ${SWEEP_INTERVAL_MS / 1000}s, fantasmas cada ${GHOST_SWEEP_INTERVAL_MS / 60000}min.`
  );
}
