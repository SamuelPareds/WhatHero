import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DELETION_GRACE_MS,
  graceRemainingMs,
  grantsToRevoke,
  keyBelongsTo,
  storagePrefix,
} from './sessionDeletion';

const ACC = 'owner-uid';
const SID = '5215500000001';

// --- Qué llaves son de la sesión ---

test('el principal y la línea anterior comparten doc: las dos son de la sesión', () => {
  assert.equal(keyBelongsTo({ accountId: ACC, sessionId: SID }, ACC, SID), true);
});

test('un QR abierto para re-vincularla también es de la sesión, aunque no tenga doc todavía', () => {
  assert.equal(keyBelongsTo({ accountId: ACC, intoSessionId: SID }, ACC, SID), true);
});

test('un QR de "Agregar número" no apunta a ninguna sesión: no se toca', () => {
  assert.equal(keyBelongsTo({ accountId: ACC }, ACC, SID), false);
});

test('otra sesión u otra cuenta con el mismo número no son de la sesión', () => {
  assert.equal(keyBelongsTo({ accountId: ACC, sessionId: '5215500000002' }, ACC, SID), false);
  assert.equal(keyBelongsTo({ accountId: 'otra-cuenta', sessionId: SID }, ACC, SID), false);
  assert.equal(keyBelongsTo(null, ACC, SID), false);
});

// --- Storage ---

test('el prefijo de Storage termina en "/" y no abarca a un número que empieza igual', () => {
  const prefix = storagePrefix('accounts', ACC, '52155');
  assert.equal(prefix, `accounts/${ACC}/whatsapp_sessions/52155/`);
  assert.equal(`accounts/${ACC}/whatsapp_sessions/521551234/chats/x/media/y.jpg`.startsWith(prefix), false);
  assert.equal(`accounts/${ACC}/whatsapp_sessions/52155/chats/x/media/y.jpg`.startsWith(prefix), true);
});

// --- Gracia ---

test('la gracia cuenta desde que se pidió el borrado, y un borrado viejo no espera', () => {
  assert.equal(graceRemainingMs(1_000, 1_000), DELETION_GRACE_MS);
  assert.equal(graceRemainingMs(1_000, 1_000 + 30_000), DELETION_GRACE_MS - 30_000);
  assert.equal(graceRemainingMs(1_000, 1_000 + DELETION_GRACE_MS * 10), 0);
});

// --- Permisos del equipo ---

test('se revoca sólo a quien tiene un permiso explícito a esa sesión', () => {
  const members = [
    { id: 'con-permiso', data: { access: { allSessions: false, sessions: { [SID]: { allChats: true } } } } },
    { id: 'otra-sesion', data: { access: { allSessions: false, sessions: { '5215500000002': { allChats: true } } } } },
    { id: 'acceso-total', data: { access: { allSessions: true, sessions: {} } } },
    { id: 'legacy-sin-access', data: { email: 'x@y.com' } },
    { id: 'sin-datos', data: undefined },
  ];
  assert.deepEqual(grantsToRevoke(members, SID), ['con-permiso']);
});

test('un id que coincide con una propiedad heredada de Object no cuenta como permiso', () => {
  const members = [{ id: 'm', data: { access: { sessions: {} } } }];
  assert.deepEqual(grantsToRevoke(members, 'constructor'), []);
});
