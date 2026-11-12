import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  FollowupOutbox,
  OutboxDeps,
  SendResult,
  DAILY_CAP,
  MAX_CONSECUTIVE_FAILURES,
  MIN_GAP_MS,
  MAX_GAP_MS,
  sendWindow,
  msUntilNextOpening,
  nextGapMs,
  gapRange,
} from './followupOutbox';

const MX = 'America/Mexico_City';
// 11-nov-2026 10:00 en CDMX (16:00 UTC).
const TEN_AM = Date.parse('2026-11-11T16:00:00Z');

// Reloj y timers falsos: `advance` dispara lo que venza, en orden.
function harness(results: SendResult[], opts: { online?: boolean; paused?: boolean; start?: number } = {}) {
  let now = opts.start ?? TEN_AM;
  let seq = 0;
  const timers = new Map<number, { at: number; fn: () => void }>();
  const sends: number[] = [];
  const saved: unknown[] = [];
  let online = opts.online ?? true;
  const paused: string[] = [];

  const deps: OutboxDeps = {
    now: () => now,
    random: () => 0.5,
    setTimer: (fn, ms) => {
      const id = ++seq;
      timers.set(id, { at: now + ms, fn });
      return id;
    },
    clearTimer: (h) => timers.delete(h as number),
    timezone: async () => MX,
    isOnline: () => online,
    loadState: async () => ({ paused: opts.paused ?? false, pausedReason: null, day: null, sentToday: 0 }),
    saveState: async (_k, s) => {
      saved.push(s);
    },
    sendNext: async () => {
      sends.push(now);
      return results.shift() ?? 'none';
    },
    onPaused: (_k, reason) => paused.push(reason),
  };
  const outbox = new FollowupOutbox(deps);

  const flush = () => new Promise((r) => setImmediate(r));
  async function advance(ms: number) {
    const until = now + ms;
    for (;;) {
      const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      now = due[1].at;
      due[1].fn();
      for (let i = 0; i < 10; i++) await flush();
    }
    now = until;
  }

  return {
    outbox, sends, saved, paused, advance,
    get now() { return now; },
    setOnline: (v: boolean) => { online = v; },
    pendingTimers: () => timers.size,
  };
}

describe('ventana de envío', () => {
  test('de 9:00 a 20:00 en la zona de la sesión', () => {
    assert.deepEqual(sendWindow(new Date(TEN_AM), MX), { open: true });
    const night = new Date('2026-11-12T03:00:00Z'); // 21:00 CDMX
    const w = sendWindow(night, MX);
    assert.equal(w.open, false);
    assert.equal((w as { waitMs: number }).waitMs, 12 * 3_600_000); // hasta las 9 de mañana
  });

  test('de madrugada espera a las 9 del mismo día', () => {
    const dawn = new Date('2026-11-11T13:30:00Z'); // 7:30 CDMX
    assert.equal(msUntilNextOpening(dawn, MX), 90 * 60_000);
  });

  test('el ritmo cae entre 60 y 150 s, y sólo se acorta fuera de producción', () => {
    assert.equal(nextGapMs(() => 0), MIN_GAP_MS);
    assert.equal(nextGapMs(() => 1), MAX_GAP_MS);
    assert.deepEqual(gapRange({ NODE_ENV: 'production', FOLLOWUP_GAP_MS: '1000' }), { min: MIN_GAP_MS, max: MAX_GAP_MS });
    assert.deepEqual(gapRange({ NODE_ENV: 'development', FOLLOWUP_GAP_MS: '1000' }), { min: 1000, max: 1000 });
  });
});

describe('FollowupOutbox', () => {
  test('envía uno a la vez, espaciados, y se detiene cuando no queda nada', async () => {
    const h = harness(['sent', 'sent', 'sent']);
    h.outbox.kick('s1');
    await h.advance(10 * 60_000);
    assert.equal(h.sends.length, 4); // 3 enviados + la consulta que dice "no queda"
    for (let i = 1; i < 3; i++) {
      const gap = h.sends[i] - h.sends[i - 1];
      assert.ok(gap >= MIN_GAP_MS && gap <= MAX_GAP_MS, `hueco de ${gap} ms`);
    }
    assert.equal(h.pendingTimers(), 0);
  });

  test('aprobar más mientras espera no adelanta el ritmo', async () => {
    const h = harness(['sent', 'sent']);
    h.outbox.kick('s1');
    await h.advance(6_000);
    assert.equal(h.sends.length, 1);
    h.outbox.kick('s1'); // el owner aprueba otro
    await h.advance(6_000);
    assert.equal(h.sends.length, 1, 'el segundo espera su hueco');
  });

  test(`${MAX_CONSECUTIVE_FAILURES} fallos seguidos pausan el goteo`, async () => {
    const h = harness(['failed', 'failed', 'failed', 'sent']);
    h.outbox.kick('s1');
    await h.advance(30 * 60_000);
    assert.equal(h.sends.length, MAX_CONSECUTIVE_FAILURES);
    assert.deepEqual(h.paused, ['failures']);
    assert.equal(h.outbox.status('s1')?.paused, true);
    assert.equal(h.pendingTimers(), 0);
  });

  test('un éxito entre fallos reinicia la cuenta', async () => {
    const h = harness(['failed', 'failed', 'sent', 'failed', 'failed', 'none']);
    h.outbox.kick('s1');
    await h.advance(30 * 60_000);
    assert.deepEqual(h.paused, []);
  });

  test('reanudar después de la pausa vuelve a enviar', async () => {
    const h = harness(['failed', 'failed', 'failed', 'sent']);
    h.outbox.kick('s1');
    await h.advance(30 * 60_000);
    await h.outbox.setPaused('s1', false);
    await h.advance(10_000);
    assert.equal(h.sends.length, 4);
  });

  test('pausado desde antes, kick no envía', async () => {
    const h = harness(['sent'], { paused: true });
    h.outbox.kick('s1');
    await h.advance(10 * 60_000);
    assert.equal(h.sends.length, 0);
  });

  test('fuera de horario espera a la apertura en vez de fallar', async () => {
    const h = harness(['sent'], { start: Date.parse('2026-11-12T03:00:00Z') }); // 21:00
    h.outbox.kick('s1');
    await h.advance(60_000);
    assert.equal(h.sends.length, 0);
    assert.equal(h.outbox.status('s1')?.waiting, 'hours');
    await h.advance(12 * 3_600_000 + 6 * 60_000);
    assert.equal(h.sends.length >= 1, true);
  });

  test('sesión caída: espera a que vuelva', async () => {
    const h = harness(['sent'], { online: false });
    h.outbox.kick('s1');
    await h.advance(3 * 60_000);
    assert.equal(h.sends.length, 0);
    assert.equal(h.outbox.status('s1')?.waiting, 'offline');
    h.setOnline(true);
    await h.advance(2 * 60_000);
    assert.equal(h.sends.length >= 1, true);
  });

  test(`no pasa de ${DAILY_CAP} al día; lo demás sale mañana`, async () => {
    const results: SendResult[] = Array(DAILY_CAP + 5).fill('sent');
    const h = harness(results, { start: Date.parse('2026-11-11T15:00:00Z') }); // 9:00
    h.outbox.kick('s1');
    await h.advance(10.9 * 3_600_000); // hasta las 19:54
    assert.equal(h.sends.length, DAILY_CAP);
    assert.equal(h.outbox.status('s1')?.waiting, 'cap');
    await h.advance(14 * 3_600_000);
    assert.ok(h.sends.length > DAILY_CAP);
  });

  test('una espera fuera de horario no guarda estado cada minuto', async () => {
    const h = harness([], { online: false });
    h.outbox.kick('s1');
    await h.advance(30 * 60_000);
    assert.ok(h.saved.length <= 2, `${h.saved.length} escrituras`);
  });
});
