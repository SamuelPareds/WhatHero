import { test, describe, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { AiBuffers, AI_COMPOSING_RECHECK_MS, type AiBufferContext } from './aiBuffer';

const ctx: AiBufferContext = { accountId: 'acc', sessionKey: 'sk', contactPhone: '5215511111111' };
const KEY = 'sk:5215511111111';
const DELAY = 1000;

// Deja correr lo que quedó pendiente en la cola de microtareas.
const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

describe('AiBuffers', () => {
  let states: string[];
  let composing: boolean;
  let buffers: AiBuffers;
  let fired: string[][];
  // Cada disparo queda "procesando" hasta que el test lo suelta.
  let releases: Array<() => void>;

  const fire = (messages: string[]) => {
    fired.push(messages);
    return new Promise<void>((resolve) => releases.push(resolve));
  };

  beforeEach(() => {
    mock.timers.enable({ apis: ['setTimeout'] });
    states = [];
    composing = false;
    fired = [];
    releases = [];
    buffers = new AiBuffers({
      emitAiState: (_a, _s, _c, state) => {
        states.push(state);
      },
      cancelCycle: () => false,
      hasState: () => states.length > 0 && states[states.length - 1] !== 'idle',
      isComposing: () => composing,
      now: () => 0,
    });
  });

  afterEach(() => mock.timers.reset());

  test('dispara UNA vez, tras el silencio, con toda la ráfaga', () => {
    buffers.push(ctx, 'hola', DELAY, fire);
    mock.timers.tick(500);
    buffers.push(ctx, '¿hay stock?', DELAY, fire);
    mock.timers.tick(DELAY - 1);
    assert.equal(fired.length, 0);
    mock.timers.tick(1);
    assert.deepEqual(fired, [['hola', '¿hay stock?']]);
    assert.deepEqual(states, ['buffering', 'buffering']);
  });

  test('el cierre del buffer viejo NO borra al nuevo (la IA contestaba después del humano)', async () => {
    buffers.push(ctx, 'm1', DELAY, fire);
    mock.timers.tick(DELAY); // A dispara y queda procesando
    buffers.push(ctx, 'm2', DELAY, fire); // el cliente escribe: buffer B
    releases[0](); // A termina
    await flush();

    assert.equal(buffers.has(KEY), true, 'B sigue en el mapa');
    // El humano responde: tiene que encontrar a B y apagarlo.
    assert.equal(buffers.yieldToHuman(ctx, 'test'), 1);
    mock.timers.tick(DELAY * 10);
    assert.equal(fired.length, 1, 'B no dispara después del humano');
  });

  test('un mensaje durante el procesamiento no se cuela en la ráfaga ya entregada', () => {
    buffers.push(ctx, 'm1', DELAY, fire);
    mock.timers.tick(DELAY);
    buffers.push(ctx, 'm2', DELAY, fire);
    assert.deepEqual(fired[0], ['m1']);
    mock.timers.tick(DELAY);
    assert.deepEqual(fired[1], ['m2'], 'm2 va sólo en su propia ráfaga: no se cuenta dos veces');
  });

  test('mientras alguien escribe, la IA espera; al soltar, dispara', () => {
    composing = true;
    buffers.push(ctx, 'm1', DELAY, fire);
    mock.timers.tick(DELAY);
    mock.timers.tick(AI_COMPOSING_RECHECK_MS * 5);
    assert.equal(fired.length, 0);
    assert.equal(buffers.has(KEY), true, 'la espera sigue viva');

    composing = false;
    mock.timers.tick(AI_COMPOSING_RECHECK_MS);
    assert.deepEqual(fired, [['m1']]);
  });

  test('un mensaje nuevo durante la espera por quien escribe reinicia el delay completo', () => {
    composing = true;
    buffers.push(ctx, 'm1', DELAY, fire);
    mock.timers.tick(DELAY);
    composing = false;
    buffers.push(ctx, 'm2', DELAY, fire);
    mock.timers.tick(DELAY - 1);
    assert.equal(fired.length, 0, 'el re-chequeo pendiente se canceló: no dispara antes');
    mock.timers.tick(1);
    assert.deepEqual(fired, [['m1', 'm2']]);
  });

  test('ceder tras una re-espera limpia el timer ACTUAL', () => {
    composing = true;
    buffers.push(ctx, 'm1', DELAY, fire);
    mock.timers.tick(DELAY + AI_COMPOSING_RECHECK_MS); // ya re-armó dos veces
    assert.equal(buffers.yieldToHuman(ctx, 'envío'), 1);
    composing = false;
    mock.timers.tick(DELAY * 10);
    assert.equal(fired.length, 0);
  });

  test('ceder sin nada activo no emite nada', () => {
    assert.equal(buffers.yieldToHuman(ctx, 'envío'), 0);
    assert.deepEqual(states, []);
  });

  test('ceder con una espera activa apaga el indicador', () => {
    buffers.push(ctx, 'm1', DELAY, fire);
    buffers.push(ctx, 'm2', DELAY, fire);
    assert.equal(buffers.yieldToHuman(ctx, 'envío'), 2);
    assert.equal(states.at(-1), 'idle');
    assert.equal(buffers.has(KEY), false);
  });

  test('si el disparo revienta, apaga el indicador y no escapa la rejection', async () => {
    buffers.push(ctx, 'm1', DELAY, () => Promise.reject(new Error('boom')));
    mock.timers.tick(DELAY);
    await flush();
    assert.equal(states.at(-1), 'idle');
    assert.equal(buffers.has(KEY), false);
  });
});
