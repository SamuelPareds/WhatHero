import { test } from 'node:test';
import assert from 'node:assert/strict';
import { memberHasSessionAccess } from './memberAccess';

const S1 = '5215500000001';
const S2 = '5215500000002';

test('miembro legacy (sin access) ve todo', () => {
  assert.equal(memberHasSessionAccess(undefined, S1), true);
});

test('allSessions ve todo', () => {
  assert.equal(memberHasSessionAccess({ allSessions: true }, S2), true);
});

test('restringido: sólo las sesiones concedidas', () => {
  const access = { allSessions: false, sessions: { [S1]: { allChats: true } } };
  assert.equal(memberHasSessionAccess(access, S1), true);
  assert.equal(memberHasSessionAccess(access, S2), false);
});

test('restringido sin sesiones no ve nada', () => {
  assert.equal(memberHasSessionAccess({ allSessions: false }, S1), false);
  assert.equal(memberHasSessionAccess({ allSessions: false, sessions: {} }, S1), false);
});

test('propiedades heredadas no cuentan como concesión', () => {
  assert.equal(memberHasSessionAccess({ allSessions: false, sessions: {} }, 'constructor'), false);
});
