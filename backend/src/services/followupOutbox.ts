// ============================================
// El goteo de seguimientos aprobados.
//
// Mandar decenas de mensajes en pocos minutos a gente que no tiene guardado
// el número es lo que WhatsApp castiga con un bloqueo, y en una sesión QR el
// número es del cliente. Por eso lo aprobado NO sale de golpe:
//
//   - Uno cada 60–150 s al azar (un ritmo fijo también es una firma).
//   - Sólo de 9:00 a 20:00 en la zona de la sesión. Fuera de horario espera.
//   - Tope de 80 por día y sesión. Lo que sobra sale mañana.
//   - 3 fallos seguidos pausan el goteo: puede ser un bloqueo, e insistir lo
//     empeora. Lo reanuda una persona.
//   - Sesión caída: espera a que vuelva, no falla.
//
// Cada envío pasa por `sendOne` (followupCampaignService.ts), que reclama la
// propuesta en una transacción, revisa que el chat siga igual que cuando se
// analizó y sólo entonces envía. Un envío sin respuesta queda `in_doubt` y no
// se reintenta nunca: pudo haber salido.
//
// Esta clase sólo decide CUÁNDO. No sabe de Firestore ni de WhatsApp: todo
// llega por `deps`, y así los tests fijan el ritmo sin esperar minutos.
// ============================================
import { localDate } from './followupCampaigns';

export const SEND_START_HOUR = 9;
export const SEND_END_HOUR = 20;
export const DAILY_CAP = 80;
export const MIN_GAP_MS = 60_000;
export const MAX_GAP_MS = 150_000;
export const MAX_CONSECUTIVE_FAILURES = 3;
// Cuánto se espera a que vuelva una sesión caída antes de volver a mirar.
export const OFFLINE_RETRY_MS = 60_000;
// El primer envío tras aprobar sale pronto: el owner quiere ver que arrancó.
export const FIRST_SEND_DELAY_MS = 5_000;
// Una propuesta que ya no se podía enviar no gasta el hueco del ritmo.
export const AFTER_SKIP_DELAY_MS = 2_000;

// Para pruebas en dev: `FOLLOWUP_GAP_MS=5000` acorta el ritmo. Nunca en prod.
export function gapRange(env: NodeJS.ProcessEnv = process.env): { min: number; max: number } {
  const forced = Number(env.FOLLOWUP_GAP_MS);
  if (env.NODE_ENV !== 'production' && Number.isFinite(forced) && forced > 0) {
    return { min: forced, max: forced };
  }
  return { min: MIN_GAP_MS, max: MAX_GAP_MS };
}

export function nextGapMs(random: () => number, range = gapRange()): number {
  return Math.round(range.min + random() * (range.max - range.min));
}

/**
 * ¿Se puede enviar ahora? Si no, cuánto falta para la próxima apertura (las
 * 9:00 de hoy o de mañana). Se calcula en minutos sobre la hora local para no
 * depender de la medianoche UTC.
 */
export function sendWindow(now: Date, timezone: string): { open: true } | { open: false; waitMs: number } {
  const seconds = secondsIntoDay(now, timezone);
  if (seconds >= SEND_START_HOUR * 3600 && seconds < SEND_END_HOUR * 3600) return { open: true };
  return { open: false, waitMs: msUntilNextOpening(now, timezone) };
}

function secondsIntoDay(now: Date, timezone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(now);
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0);
  return (get('hour') % 24) * 3600 + get('minute') * 60 + get('second');
}

/** Hasta las próximas 9:00 (hoy si todavía no son, si no mañana). */
export function msUntilNextOpening(now: Date, timezone: string): number {
  const seconds = secondsIntoDay(now, timezone);
  const startS = SEND_START_HOUR * 3600;
  const wait = seconds < startS ? startS - seconds : 86_400 - seconds + startS;
  return wait * 1000;
}

export type SendResult = 'sent' | 'skipped' | 'failed' | 'in_doubt' | 'none';

export type OutboxWaiting = 'hours' | 'cap' | 'offline' | null;

export interface OutboxStatus {
  paused: boolean;
  pausedReason: string | null;
  waiting: OutboxWaiting;
  nextAt: number | null;
  day: string;
  sentToday: number;
}

export interface OutboxDeps {
  now(): number;
  random(): number;
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
  timezone(key: string): Promise<string>;
  isOnline(key: string): boolean;
  // Estado guardado (pausa y conteo del día). Se lee una vez por clave.
  loadState(key: string): Promise<{ paused: boolean; pausedReason: string | null; day: string | null; sentToday: number }>;
  saveState(key: string, status: OutboxStatus): Promise<void>;
  // Envía la siguiente propuesta aprobada. 'none' = no queda ninguna.
  sendNext(key: string, today: string): Promise<SendResult>;
  onPaused?(key: string, reason: string): void;
}

interface Lane {
  timer: unknown | null;
  running: boolean;
  loaded: boolean;
  paused: boolean;
  pausedReason: string | null;
  day: string | null;
  sentToday: number;
  failures: number;
  waiting: OutboxWaiting;
  nextAt: number | null;
  // Lo último que se guardó. Sesión caída o fuera de horario re-mira cada
  // minuto: sin esto serían 1 440 escrituras al día por nada.
  persisted: string | null;
}

export class FollowupOutbox {
  private lanes = new Map<string, Lane>();

  constructor(private deps: OutboxDeps) {}

  private lane(key: string): Lane {
    let lane = this.lanes.get(key);
    if (!lane) {
      lane = {
        timer: null, running: false, loaded: false, paused: false, pausedReason: null,
        day: null, sentToday: 0, failures: 0, waiting: null, nextAt: null, persisted: null,
      };
      this.lanes.set(key, lane);
    }
    return lane;
  }

  /** Hay algo nuevo que enviar (se aprobó, volvió la sesión, arrancó el proceso). */
  kick(key: string, delayMs = FIRST_SEND_DELAY_MS): void {
    const lane = this.lane(key);
    if (lane.running) return;
    // Un timer ya armado se respeta: aprobar más no adelanta el ritmo ni el
    // horario. La única espera que un kick acorta es la de una sesión caída
    // (el kick llega justo cuando vuelve).
    if (lane.timer !== null) {
      if (lane.waiting !== 'offline') return;
      this.deps.clearTimer(lane.timer);
      lane.timer = null;
    }
    this.arm(key, lane, delayMs, null);
  }

  async setPaused(key: string, paused: boolean, reason: string | null = null): Promise<void> {
    const lane = this.lane(key);
    await this.ensureLoaded(key, lane);
    lane.paused = paused;
    lane.pausedReason = paused ? reason : null;
    if (!paused) lane.failures = 0;
    if (paused && lane.timer !== null) {
      this.deps.clearTimer(lane.timer);
      lane.timer = null;
      lane.nextAt = null;
    }
    await this.persist(key, lane);
    if (!paused) this.kick(key);
  }

  status(key: string): OutboxStatus | null {
    const lane = this.lanes.get(key);
    if (!lane || !lane.loaded) return null;
    return this.snapshot(lane);
  }

  /** La sesión se eliminó: no queda nada que enviar. */
  forget(key: string): void {
    const lane = this.lanes.get(key);
    if (lane?.timer != null) this.deps.clearTimer(lane.timer);
    this.lanes.delete(key);
  }

  private snapshot(lane: Lane): OutboxStatus {
    return {
      paused: lane.paused,
      pausedReason: lane.pausedReason,
      waiting: lane.waiting,
      nextAt: lane.nextAt,
      day: lane.day ?? '',
      sentToday: lane.sentToday,
    };
  }

  private arm(key: string, lane: Lane, ms: number, waiting: OutboxWaiting): void {
    lane.waiting = waiting;
    lane.nextAt = this.deps.now() + ms;
    lane.timer = this.deps.setTimer(() => {
      lane.timer = null;
      void this.run(key);
    }, ms);
  }

  private async ensureLoaded(key: string, lane: Lane): Promise<void> {
    if (lane.loaded) return;
    const saved = await this.deps.loadState(key);
    lane.paused = saved.paused;
    lane.pausedReason = saved.pausedReason;
    lane.day = saved.day;
    lane.sentToday = saved.sentToday;
    lane.loaded = true;
  }

  private async persist(key: string, lane: Lane): Promise<void> {
    const status = this.snapshot(lane);
    // `nextAt` sólo importa mientras se está enviando ("siguiente en ~1 min").
    // Esperando, basta con saber qué se espera.
    const fingerprint = JSON.stringify({ ...status, nextAt: status.waiting === null ? status.nextAt : status.waiting });
    if (fingerprint === lane.persisted) return;
    lane.persisted = fingerprint;
    try {
      await this.deps.saveState(key, status);
    } catch (error) {
      console.warn(`[Seguimiento] No se pudo guardar el estado del goteo de ${key}:`, error);
    }
  }

  private async run(key: string): Promise<void> {
    const lane = this.lane(key);
    if (lane.running) return;
    lane.running = true;
    let next: { ms: number; waiting: OutboxWaiting } | null = null;
    try {
      await this.ensureLoaded(key, lane);
      if (lane.paused) {
        lane.waiting = null;
        lane.nextAt = null;
        return;
      }
      if (!this.deps.isOnline(key)) {
        next = { ms: OFFLINE_RETRY_MS, waiting: 'offline' };
        return;
      }
      const tz = await this.deps.timezone(key);
      const now = new Date(this.deps.now());
      const window = sendWindow(now, tz);
      if (!window.open) {
        // Unos minutos al azar después de la apertura: no todas las sesiones a las 9:00:00.
        next = { ms: window.waitMs + Math.round(this.deps.random() * 5 * 60_000), waiting: 'hours' };
        return;
      }
      const today = localDate(now, tz);
      if (lane.day !== today) {
        lane.day = today;
        lane.sentToday = 0;
      }
      if (lane.sentToday >= DAILY_CAP) {
        next = { ms: msUntilNextOpening(now, tz) + Math.round(this.deps.random() * 5 * 60_000), waiting: 'cap' };
        return;
      }

      const result = await this.deps.sendNext(key, today);
      switch (result) {
        case 'none':
          lane.failures = 0;
          lane.waiting = null;
          lane.nextAt = null;
          return;
        case 'skipped':
          next = { ms: AFTER_SKIP_DELAY_MS, waiting: null };
          return;
        case 'sent':
          lane.sentToday++;
          lane.failures = 0;
          next = { ms: nextGapMs(this.deps.random), waiting: null };
          return;
        case 'failed':
        case 'in_doubt':
          // Un `in_doubt` pudo haber salido: cuenta para el tope.
          if (result === 'in_doubt') lane.sentToday++;
          lane.failures++;
          if (lane.failures >= MAX_CONSECUTIVE_FAILURES) {
            lane.paused = true;
            lane.pausedReason = 'failures';
            lane.waiting = null;
            lane.nextAt = null;
            this.deps.onPaused?.(key, 'failures');
            return;
          }
          next = { ms: nextGapMs(this.deps.random), waiting: null };
          return;
      }
    } catch (error) {
      console.error(`[Seguimiento] El goteo de ${key} falló; reintenta en 1 min:`, error);
      next = { ms: OFFLINE_RETRY_MS, waiting: null };
    } finally {
      lane.running = false;
      if (next && !lane.paused) this.arm(key, lane, next.ms, next.waiting);
      await this.persist(key, lane);
    }
  }
}
