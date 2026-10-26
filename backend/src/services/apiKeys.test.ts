import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { TokenBucket, apiKeyAllowsSession, generateApiKey, hashSecret, keyHint, parseApiKey, secretMatches } from './apiKeys';

describe('llaves del API (formato y hash)', () => {
  it('una llave generada se reconoce, y sólo su secreto coincide con el hash guardado', () => {
    const generated = generateApiKey();
    assert.match(generated.key, /^whk_[0-9a-f]{16}_[A-Za-z0-9_-]{43}$/);
    const parsed = parseApiKey(generated.key);
    assert.equal(parsed?.keyId, generated.keyId);
    assert.equal(secretMatches(parsed!.secret, generated.secretHash), true);
    assert.equal(secretMatches(generateApiKey().key.slice(-43), generated.secretHash), false);
    // Lo guardado es el hash, nunca el secreto.
    assert.equal(generated.secretHash, hashSecret(parsed!.secret));
    assert.ok(!generated.secretHash.includes(parsed!.secret));
  });

  it('dos llaves nunca se repiten', () => {
    const keys = new Set(Array.from({ length: 200 }, () => generateApiKey().key));
    assert.equal(keys.size, 200);
  });

  it('lo que no tiene la forma exacta no es una llave (y no cuesta una lectura)', () => {
    const { key } = generateApiKey();
    assert.ok(parseApiKey(`  ${key}  `), 'los espacios al copiar no la rompen');
    for (const bad of [undefined, 123, '', 'Bearer x', key.slice(0, -1), key.replace('whk_', 'wh_'), `${key}x`]) {
      assert.equal(parseApiKey(bad), null, String(bad));
    }
    assert.equal(secretMatches('x', 'no-es-hex'), false);
  });

  it('la pista muestra el inicio del id y el final del secreto, nada más', () => {
    assert.equal(keyHint('0123456789abcdef', 'A'.repeat(39) + 'wxyz'), 'whk_012345…wxyz');
  });

  it('alcance: todas las sesiones, o sólo las elegidas', () => {
    const base = { keyId: 'k', accountId: 'a', name: 'AgendaCool' };
    assert.equal(apiKeyAllowsSession({ ...base, allSessions: true, sessionIds: [] }, '5215500000000'), true);
    assert.equal(apiKeyAllowsSession({ ...base, allSessions: false, sessionIds: ['5215500000000'] }, '5215500000000'), true);
    assert.equal(apiKeyAllowsSession({ ...base, allSessions: false, sessionIds: ['5215500000000'] }, '5215511111111'), false);
    assert.equal(apiKeyAllowsSession({ ...base, allSessions: false, sessionIds: [] }, '5215500000000'), false);
  });
});

describe('TokenBucket (límite por llave)', () => {
  it('deja pasar la ráfaga, frena con Retry-After y se recarga con el tiempo', () => {
    let now = 0;
    const bucket = new TokenBucket(3, 1, () => now);
    assert.ok(bucket.take('k').ok);
    assert.ok(bucket.take('k').ok);
    assert.ok(bucket.take('k').ok);
    const limited = bucket.take('k');
    assert.equal(limited.ok, false);
    assert.equal(!limited.ok && limited.retryAfterSeconds, 1);
    // Cada llave tiene su propio cubo.
    assert.ok(bucket.take('otra').ok);

    now = 1_000;
    assert.ok(bucket.take('k').ok);
    assert.equal(bucket.take('k').ok, false);
  });

  it('waitSeconds mira sin gastar', () => {
    let now = 0;
    const bucket = new TokenBucket(1, 0.5, () => now);
    assert.equal(bucket.waitSeconds('ip'), 0);
    assert.equal(bucket.waitSeconds('ip'), 0);
    bucket.take('ip');
    assert.equal(bucket.waitSeconds('ip'), 2);
    now = 2_000;
    assert.equal(bucket.waitSeconds('ip'), 0);
  });
});
