import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  PresenceRegistry,
  parsePresenceSet,
  roomFor,
  takeToken,
  BUCKET_CAPACITY,
  type PresenceEntry,
} from './presenceRegistry';

const ACC = 'acc1';
const S1 = '5215500000001';
const S2 = '5215500000002';
const CHAT = '5215511111111';

function entry(over: Partial<PresenceEntry> = {}): PresenceEntry {
  return {
    socketId: 'sock-ana',
    clientId: 'anaclient0001',
    uid: 'uid-ana',
    name: 'Ana',
    accountId: ACC,
    sessionPhone: S1,
    chatId: CHAT,
    composing: false,
    ...over,
  };
}

describe('parsePresenceSet', () => {
  test('acepta el estado completo', () => {
    assert.deepEqual(
      parsePresenceSet({ clientId: 'abc12345', sessionPhone: S1, chatId: CHAT, composing: true }),
      { clientId: 'abc12345', sessionPhone: S1, chatId: CHAT, composing: true },
    );
  });

  test('sin sesión = salir de todo', () => {
    assert.deepEqual(parsePresenceSet({ clientId: 'abc12345', sessionPhone: null, chatId: null }), {
      clientId: 'abc12345',
      sessionPhone: null,
      chatId: null,
      composing: false,
    });
  });

  test('composing sólo dentro de un chat', () => {
    assert.equal(
      parsePresenceSet({ clientId: 'abc12345', sessionPhone: S1, chatId: null, composing: true })?.composing,
      false,
    );
  });

  test('rechaza lo que no encaja', () => {
    const bad: unknown[] = [
      null,
      'hola',
      { clientId: 'ABC12345', sessionPhone: S1 }, // mayúsculas
      { clientId: 'abc', sessionPhone: S1 }, // corto
      { clientId: 'abc12345', sessionPhone: 'tp:otra:cuenta' },
      { clientId: 'abc12345', sessionPhone: S1, chatId: '123@s.whatsapp.net' },
      { clientId: 'abc12345', sessionPhone: null, chatId: CHAT }, // chat sin sesión
      { clientId: 'abc12345', sessionPhone: 5215500000001 },
    ];
    for (const raw of bad) assert.equal(parsePresenceSet(raw), null, JSON.stringify(raw));
  });
});

describe('PresenceRegistry', () => {
  test('el payload trae sólo a quienes están dentro de un chat', () => {
    const r = new PresenceRegistry();
    r.set(entry());
    r.set(entry({ socketId: 'sock-luis', clientId: 'luisclient01', uid: 'uid-luis', name: 'Luis', chatId: null }));
    const payload = r.payloadFor(roomFor(ACC, S1));
    assert.equal(payload?.sessionPhone, S1);
    assert.deepEqual(payload?.viewers.map((v) => v.name), ['Ana']);
    assert.equal('socketId' in (payload?.viewers[0] ?? {}), false, 'no se filtran socket ids');
  });

  test('repetir el mismo estado no pide rebroadcast', () => {
    const r = new PresenceRegistry();
    r.set(entry());
    assert.equal(r.set(entry()).changedRooms.size, 0);
  });

  test('cambiar de sesión avisa a ambas salas', () => {
    const r = new PresenceRegistry();
    r.set(entry());
    const { changedRooms } = r.set(entry({ sessionPhone: S2 }));
    assert.deepEqual([...changedRooms].sort(), [roomFor(ACC, S1), roomFor(ACC, S2)].sort());
    assert.equal(r.payloadFor(roomFor(ACC, S1)), null);
    assert.equal(r.payloadFor(roomFor(ACC, S2))?.viewers.length, 1);
  });

  test('reconexión: el socket nuevo retira al fantasma de la misma pestaña', () => {
    const r = new PresenceRegistry();
    r.set(entry({ socketId: 'viejo' }));
    const { ghosts } = r.set(entry({ socketId: 'nuevo' }));
    assert.deepEqual(ghosts, ['viejo']);
    assert.equal(r.payloadFor(roomFor(ACC, S1))?.viewers.length, 1);

    // El viejo muere tarde: no puede llevarse puesto al nuevo.
    r.remove('viejo');
    assert.equal(r.payloadFor(roomFor(ACC, S1))?.viewers.length, 1);
    r.set(entry({ socketId: 'otro-mas' }));
    assert.equal(r.size, 1);
  });

  test('otra pestaña del mismo usuario NO es un fantasma', () => {
    const r = new PresenceRegistry();
    r.set(entry({ socketId: 's1', clientId: 'pestanauno01' }));
    const { ghosts } = r.set(entry({ socketId: 's2', clientId: 'pestanados02' }));
    assert.deepEqual(ghosts, []);
    assert.equal(r.payloadFor(roomFor(ACC, S1))?.viewers.length, 2);
  });

  test('el mismo clientId en otra cuenta no se confunde', () => {
    const r = new PresenceRegistry();
    r.set(entry({ socketId: 's1' }));
    const { ghosts } = r.set(entry({ socketId: 's2', accountId: 'acc2' }));
    assert.deepEqual(ghosts, []);
  });

  test('desconectar vacía la sala', () => {
    const r = new PresenceRegistry();
    r.set(entry());
    assert.deepEqual([...r.remove('sock-ana')], [roomFor(ACC, S1)]);
    assert.equal(r.payloadFor(roomFor(ACC, S1)), null);
    assert.equal(r.size, 0);
    assert.equal(r.remove('sock-ana').size, 0);
  });

  test('isComposingIn: sólo misma cuenta, sesión y chat con texto', () => {
    const r = new PresenceRegistry();
    r.set(entry({ composing: true }));
    assert.equal(r.isComposingIn(ACC, S1, CHAT), true);
    assert.equal(r.isComposingIn(ACC, S1, '5215599999999'), false);
    assert.equal(r.isComposingIn(ACC, S2, CHAT), false);
    assert.equal(r.isComposingIn('acc2', S1, CHAT), false);

    r.set(entry({ composing: false }));
    assert.equal(r.isComposingIn(ACC, S1, CHAT), false, 'borró el texto');
    r.set(entry({ composing: true }));
    r.remove('sock-ana');
    assert.equal(r.isComposingIn(ACC, S1, CHAT), false, 'se desconectó');
  });

  test('isComposingIn: el fantasma reemplazado ya no cuenta', () => {
    const r = new PresenceRegistry();
    r.set(entry({ socketId: 'viejo', composing: true }));
    r.set(entry({ socketId: 'nuevo', composing: false }));
    assert.equal(r.isComposingIn(ACC, S1, CHAT), false);
  });

  test('entriesForAccount no mezcla cuentas', () => {
    const r = new PresenceRegistry();
    r.set(entry());
    r.set(entry({ socketId: 'x', accountId: 'acc2', clientId: 'otracuenta1' }));
    assert.deepEqual(r.entriesForAccount(ACC).map((e) => e.socketId), ['sock-ana']);
  });
});

describe('takeToken', () => {
  test('ráfaga hasta la capacidad y luego frena', () => {
    let bucket;
    for (let i = 0; i < BUCKET_CAPACITY; i++) {
      const res = takeToken(bucket, 1000);
      assert.equal(res.ok, true);
      bucket = res.bucket;
    }
    assert.equal(takeToken(bucket, 1000).ok, false);
  });

  test('se recarga con el tiempo', () => {
    let bucket;
    for (let i = 0; i < BUCKET_CAPACITY; i++) bucket = takeToken(bucket, 1000).bucket;
    assert.equal(takeToken(bucket, 1000 + 250).ok, true); // 5/s → 1 ficha en 200 ms
  });
});
