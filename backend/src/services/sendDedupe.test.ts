import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { SendDedupe, SEND_DEDUPE_TTL_MS, sendDedupeKey, validTempId } from './sendDedupe';

describe('SendDedupe', () => {
  let now: number;
  let dedupe: SendDedupe;
  let sends: number;

  const send = (messageId = 'WA1') => () => {
    sends++;
    return Promise.resolve({ messageId });
  };

  beforeEach(() => {
    now = 0;
    sends = 0;
    dedupe = new SendDedupe(() => now);
  });

  test('un reintento mientras el primero sigue en vuelo NO envía otra vez', async () => {
    let release!: (v: { messageId: string }) => void;
    const slow = () => {
      sends++;
      return new Promise<{ messageId: string }>((resolve) => (release = resolve));
    };
    const first = dedupe.run('u1:tmp-1', slow);
    const retry = dedupe.run('u1:tmp-1', slow);
    release({ messageId: 'WA1' });
    assert.deepEqual(await first, { messageId: 'WA1' });
    assert.deepEqual(await retry, { messageId: 'WA1' });
    assert.equal(sends, 1);
  });

  test('un reintento de algo que ya salió recibe el mismo resultado sin enviar (ack perdido)', async () => {
    await dedupe.run('u1:tmp-1', send('WA1'));
    now += SEND_DEDUPE_TTL_MS - 1;
    assert.deepEqual(await dedupe.run('u1:tmp-1', send('WA2')), { messageId: 'WA1' });
    assert.equal(sends, 1);
  });

  test('si el envío falló, el reintento sí reenvía', async () => {
    await assert.rejects(
      dedupe.run('u1:tmp-1', () => {
        sends++;
        return Promise.reject(new Error('Session not ready'));
      }),
    );
    assert.deepEqual(await dedupe.run('u1:tmp-1', send('WA2')), { messageId: 'WA2' });
    assert.equal(sends, 2);
  });

  test('sin clave no deduplica', async () => {
    await dedupe.run(null, send());
    await dedupe.run(null, send());
    assert.equal(sends, 2);
    assert.equal(dedupe.size, 0);
  });

  test('pasados 10 min la entrada vence y se poda', async () => {
    await dedupe.run('u1:tmp-1', send('WA1'));
    now += SEND_DEDUPE_TTL_MS;
    assert.deepEqual(await dedupe.run('u1:tmp-1', send('WA2')), { messageId: 'WA2' });
    assert.equal(sends, 2);
    assert.equal(dedupe.size, 1);
  });

  test('un envío en vuelo no vence aunque pase el TTL', async () => {
    let release!: (v: { messageId: string }) => void;
    const first = dedupe.run('u1:tmp-1', () => {
      sends++;
      return new Promise<{ messageId: string }>((resolve) => (release = resolve));
    });
    now += SEND_DEDUPE_TTL_MS * 2;
    const retry = dedupe.run('u1:tmp-1', send('WA2'));
    release({ messageId: 'WA1' });
    assert.deepEqual(await first, { messageId: 'WA1' });
    assert.deepEqual(await retry, { messageId: 'WA1' });
    assert.equal(sends, 1);
  });

  test('el mismo tempId de otro usuario no se mezcla', async () => {
    await dedupe.run(sendDedupeKey('u1', 'tmp-1'), send('WA1'));
    assert.deepEqual(await dedupe.run(sendDedupeKey('u2', 'tmp-1'), send('WA2')), { messageId: 'WA2' });
    assert.equal(sends, 2);
  });
});

describe('validTempId / sendDedupeKey', () => {
  test('acepta el formato de la app', () => {
    assert.equal(validTempId('tmp-1760000000000000-3'), 'tmp-1760000000000000-3');
    assert.equal(sendDedupeKey('u1', 'tmp-1'), 'u1:tmp-1');
  });

  test('ignora lo que no es un tempId razonable', () => {
    for (const bad of [undefined, null, '', 42, {}, 'x'.repeat(65)]) {
      assert.equal(validTempId(bad), null);
      assert.equal(sendDedupeKey('u1', bad), null);
    }
  });
});
