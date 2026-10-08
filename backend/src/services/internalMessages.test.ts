import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseInternalMessageInput,
  parseInternalDeleteInput,
  pickRecipients,
  unreadAfterDelete,
  INTERNAL_TEXT_MAX,
} from './internalMessages';

const ID = 'AbCdEfGhIjKlMnOpQrSt'; // autoId de Firestore: 20 alfanuméricos
const BASE = {
  sessionId: '5215500000001',
  chatId: '5215511111111',
  id: ID,
  text: 'Dile que sí a la promo',
};

function errorOf(body: unknown): string | null {
  const r = parseInternalMessageInput(body);
  return r.ok ? null : r.error;
}

describe('parseInternalMessageInput', () => {
  test('acepta un mensaje válido y le quita los espacios de los extremos', () => {
    const r = parseInternalMessageInput({ ...BASE, text: '  ¿Me ayudas con este chat?  \n', recipientUids: ['uid-mayra'] });
    assert.deepEqual(r, {
      ok: true,
      value: { ...BASE, text: '¿Me ayudas con este chat?', recipientUids: ['uid-mayra'] },
    });
  });

  test('sin destinatarios es válido: queda escrito en el chat sin avisar', () => {
    const r = parseInternalMessageInput(BASE);
    assert.ok(r.ok);
    assert.deepEqual(r.value.recipientUids, []);
  });

  test('rechaza un mensaje vacío o de sólo espacios', () => {
    assert.notEqual(errorOf({ ...BASE, text: '' }), null);
    assert.notEqual(errorOf({ ...BASE, text: '   \n ' }), null);
    assert.notEqual(errorOf({ ...BASE, text: 42 }), null);
  });

  test(`rechaza más de ${INTERNAL_TEXT_MAX} caracteres`, () => {
    assert.equal(errorOf({ ...BASE, text: 'a'.repeat(INTERNAL_TEXT_MAX) }), null);
    assert.notEqual(errorOf({ ...BASE, text: 'a'.repeat(INTERNAL_TEXT_MAX + 1) }), null);
  });

  test('rechaza un id que no es autoId de Firestore (el reintento depende de él)', () => {
    assert.notEqual(errorOf({ ...BASE, id: 'abc' }), null);
    assert.notEqual(errorOf({ ...BASE, id: 'AbCdEfGhIj/lMnOpQrSt' }), null);
    assert.notEqual(errorOf({ ...BASE, id: undefined }), null);
  });

  test('rechaza una / en chatId o sessionId: cambiaría la ruta del doc', () => {
    assert.notEqual(errorOf({ ...BASE, chatId: '521/messages/x' }), null);
    assert.notEqual(errorOf({ ...BASE, sessionId: 'a/b' }), null);
    assert.notEqual(errorOf({ ...BASE, chatId: '' }), null);
  });

  test('destinatarios: quita duplicados y descarta lo que no es un uid', () => {
    const r = parseInternalMessageInput({
      ...BASE,
      recipientUids: ['uid-ana', 'uid-ana', 7, null, 'a/b', 'uid-luis'],
    });
    assert.ok(r.ok);
    assert.deepEqual(r.value.recipientUids, ['uid-ana', 'uid-luis']);
  });

  test('un body que no es objeto no revienta', () => {
    assert.notEqual(errorOf(undefined), null);
    assert.notEqual(errorOf('hola'), null);
  });
});

describe('pickRecipients', () => {
  const TEAM = ['uid-owner', 'uid-mayra', 'uid-ana'];

  test('nunca me avisa a mí mismo', () => {
    assert.deepEqual(pickRecipients(['uid-owner', 'uid-mayra'], TEAM, 'uid-owner'), ['uid-mayra']);
  });

  test('descarta a quien no ve la sesión, aunque la app lo pida', () => {
    assert.deepEqual(pickRecipients(['uid-mayra', 'uid-de-otra-sesion'], TEAM, 'uid-owner'), ['uid-mayra']);
  });
});

describe('parseInternalDeleteInput', () => {
  test('acepta sesión e id válidos', () => {
    assert.deepEqual(parseInternalDeleteInput({ sessionId: BASE.sessionId, id: ID }), {
      ok: true,
      sessionId: BASE.sessionId,
      id: ID,
    });
  });

  test('rechaza un id raro o una / en la sesión', () => {
    assert.equal(parseInternalDeleteInput({ sessionId: BASE.sessionId, id: 'x' }).ok, false);
    assert.equal(parseInternalDeleteInput({ sessionId: 'a/b', id: ID }).ok, false);
  });
});

describe('unreadAfterDelete', () => {
  const SENT = 1_000;

  test('a quien no lo vio se le descuenta', () => {
    const next = unreadAfterDelete({ 'uid-mayra': 2 }, {}, ['uid-mayra'], SENT);
    assert.deepEqual([...next], [['uid-mayra', 1]]);
  });

  test('si era el único pendiente, el badge se apaga (0 = borrar el campo)', () => {
    const next = unreadAfterDelete({ 'uid-mayra': 1 }, { 'uid-mayra': SENT - 10 }, ['uid-mayra'], SENT);
    assert.deepEqual([...next], [['uid-mayra', 0]]);
  });

  test('a quien ya lo vio no se le toca, aunque tenga otro interno pendiente', () => {
    // Lo vio (abrió el chat después de que llegó) y luego le llegó otro: ese
    // otro es su 1 pendiente, y borrar éste no se lo puede comer.
    const next = unreadAfterDelete({ 'uid-mayra': 1 }, { 'uid-mayra': SENT + 10 }, ['uid-mayra'], SENT);
    assert.equal(next.size, 0);
  });

  test('sin contador no hay nada que descontar (nunca baja de 0)', () => {
    const next = unreadAfterDelete({}, {}, ['uid-mayra', 'uid-ana'], SENT);
    assert.equal(next.size, 0);
  });

  test('cada destinatario por su lado', () => {
    const next = unreadAfterDelete(
      { 'uid-mayra': 3, 'uid-ana': 1 },
      { 'uid-ana': SENT + 5 },
      ['uid-mayra', 'uid-ana'],
      SENT,
    );
    assert.deepEqual([...next], [['uid-mayra', 2]]);
  });
});
