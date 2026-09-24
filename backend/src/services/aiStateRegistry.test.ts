import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AiStateRegistry, aiStateKey, type AiStatePayload } from './aiStateRegistry';

const p = (state: AiStatePayload['state'], contactPhone = '5215511111111'): AiStatePayload => ({
  sessionKey: 'sk',
  contactPhone,
  state,
});
const KEY = aiStateKey('sk', '5215511111111');

test('el seq sigue creciendo aunque la entrada se borre y se recree', () => {
  const r = new AiStateRegistry();
  const thinkingA = r.apply('acc', p('thinking'));
  r.apply('acc', p('idle')); // el humano apagó
  const bufferingB = r.apply('acc', p('buffering')); // buffer nuevo
  assert.ok(bufferingB > thinkingA);
  // El finally del ciclo viejo no puede apagarle el indicador al buffer nuevo.
  assert.equal(r.isOwner(KEY, thinkingA), false);
  assert.equal(r.isOwner(KEY, bufferingB), true);
});

test('cualquier emisión posterior (incluido idle) quita la propiedad', () => {
  const r = new AiStateRegistry();
  const seq = r.apply('acc', p('responding'));
  r.apply('acc', p('idle'));
  assert.equal(r.isOwner(KEY, seq), false);
  assert.equal(r.has(KEY), false);
});

test('la foto es por cuenta', () => {
  const r = new AiStateRegistry();
  r.apply('acc', p('thinking'));
  r.apply('otra', { sessionKey: 'sk2', contactPhone: '5215522222222', state: 'buffering' });
  assert.deepEqual(r.snapshotFor('acc').map((s) => s.state), ['thinking']);
});

test('el barrido re-emite los vivos sin cambiar de dueño y borra los muertos', () => {
  const r = new AiStateRegistry();
  const vivo = r.apply('acc', p('thinking'));
  r.apply('acc', p('buffering', '5215599999999'));
  const { reemit, dead } = r.sweep((key) => key === KEY);
  assert.deepEqual(reemit.map((e) => e.payload.state), ['thinking']);
  assert.deepEqual(dead.map((e) => e.payload.contactPhone), ['5215599999999']);
  assert.equal(r.isOwner(KEY, vivo), true, 're-emitir no le quita el indicador a su dueño');
  assert.equal(r.size, 1);
});

test('idle sobre un chat desconocido no rompe nada', () => {
  const r = new AiStateRegistry();
  r.apply('acc', p('idle'));
  assert.equal(r.size, 0);
});
