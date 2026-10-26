import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  IN_FLIGHT_WINDOW_MS,
  decideExisting,
  idempotencyDocId,
  parseCallbackData,
  parseSendInput,
  sendFingerprint,
} from './apiSends';
import { PUBLIC_API_ERRORS, PublicApiError, mapMetaSendError } from './publicApiErrors';

function body(overrides: Record<string, any> = {}) {
  return {
    from: '+52 1 55 0000 0000',
    to: '+52 55 1234 5678',
    template: 'seguimiento_onboarding',
    language: 'es_MX',
    variables: { nombre: 'Ana' },
    contactName: '  Ana   López ',
    idempotencyKey: 'agendacool:onboarding:uid1:2026-10-26',
    ...overrides,
  };
}

function rejection(fn: () => unknown): PublicApiError {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof PublicApiError);
    return error;
  }
  assert.fail('se esperaba un error');
}

describe('parseSendInput (la forma del request)', () => {
  it('limpia los números y el nombre', () => {
    const input = parseSendInput(body());
    assert.equal(input.from, '5215500000000');
    assert.equal(input.to, '525512345678');
    assert.equal(input.contactName, 'Ana López');
    assert.deepEqual(input.variables, { nombre: 'Ana' });
  });

  it('un request mal armado es stop y dice todo lo que falta', () => {
    const error = rejection(() => parseSendInput(body({ template: 'Seguimiento', language: 'es-MX', idempotencyKey: '' })));
    assert.equal(error.code, 'invalid_request');
    assert.equal(error.action, 'stop');
    assert.equal(error.extra.details?.length, 3);
    assert.equal(rejection(() => parseSendInput([])).code, 'invalid_request');
    assert.equal(rejection(() => parseSendInput(body({ variables: ['Ana'] }))).code, 'invalid_request');
    assert.equal(rejection(() => parseSendInput(body({ to: undefined }))).code, 'invalid_request');
    assert.equal(rejection(() => parseSendInput(body({ idempotencyKey: 'x'.repeat(201) }))).code, 'invalid_request');
  });

  it('un teléfono raro es del contacto: skip, no stop', () => {
    const error = rejection(() => parseSendInput(body({ to: '12345' })));
    assert.equal(error.code, 'invalid_phone');
    assert.equal(error.action, 'skip');
  });

  it('variables y nombre son opcionales', () => {
    const input = parseSendInput(body({ variables: undefined, contactName: null }));
    assert.deepEqual(input.variables, {});
    assert.equal(input.contactName, null);
  });
});

describe('idempotencia', () => {
  const input = parseSendInput(body());
  const fingerprint = sendFingerprint('5215500000000', input);
  const ts = (ms: number) => ({ toMillis: () => ms });

  it('el fingerprint no depende del orden de las variables ni del nombre, sí del contenido', () => {
    const reordered = parseSendInput(body({ variables: { b: '2', a: '1' }, contactName: 'Otro' }));
    const same = parseSendInput(body({ variables: { a: '1', b: '2' } }));
    assert.equal(sendFingerprint('s', reordered), sendFingerprint('s', same));
    assert.notEqual(sendFingerprint('s', same), sendFingerprint('s', parseSendInput(body({ variables: { a: '1', b: '3' } }))));
    assert.notEqual(sendFingerprint('s', same), sendFingerprint('otra', same));
  });

  it('el id del registro es estable y seguro para Firestore', () => {
    assert.equal(idempotencyDocId('a/b c'), idempotencyDocId('a/b c'));
    assert.match(idempotencyDocId('a/b c'), /^[0-9a-f]{64}$/);
    const id = idempotencyDocId('x');
    assert.equal(parseCallbackData(`whathero_api:${id}`), id);
    assert.equal(parseCallbackData(`otra_cosa:${id}`), null);
    assert.equal(parseCallbackData('whathero_api:../../x'), null);
  });

  it('lo que ya salió se contesta igual, con el acuse si ya llegó', () => {
    const decision = decideExisting(
      { fingerprint, status: 'sent', wamid: 'wamid.1', chat_phone: '5215512345678', delivery_status: 'read' },
      fingerprint,
      0,
    );
    assert.deepEqual(decision, {
      kind: 'replay',
      response: { id: 'wamid.1', status: 'accepted', to: '5215512345678', replayed: true, deliveryStatus: 'read' },
    });
  });

  it('misma llave con otro contenido es un error de quien llama', () => {
    const decision = decideExisting({ fingerprint: 'otro', status: 'sent' }, fingerprint, 0);
    assert.equal(decision.kind === 'error' && decision.error.code, 'idempotency_conflict');
  });

  it('lo que Meta rechazó no salió: se puede volver a intentar', () => {
    assert.deepEqual(decideExisting({ fingerprint, status: 'failed' }, fingerprint, 0), { kind: 'reclaim' });
  });

  it('en vuelo pide reintentar; un intento cortado nunca se reenvía', () => {
    const started = 1_000_000;
    const inFlight = decideExisting({ fingerprint, status: 'sending', attempt_started_at: ts(started) }, fingerprint, started + 5_000);
    assert.equal(inFlight.kind === 'error' && inFlight.error.code, 'in_progress');
    assert.equal(inFlight.kind === 'error' && inFlight.error.action, 'retry');

    const stale = decideExisting(
      { fingerprint, status: 'sending', attempt_started_at: ts(started) },
      fingerprint,
      started + IN_FLIGHT_WINDOW_MS,
    );
    assert.equal(stale.kind === 'error' && stale.error.code, 'send_in_doubt');
    assert.equal(stale.kind === 'error' && stale.error.action, 'skip');

    const doubt = decideExisting({ fingerprint, status: 'in_doubt' }, fingerprint, 0);
    assert.equal(doubt.kind === 'error' && doubt.error.code, 'send_in_doubt');
  });
});

describe('errores de Meta al enviar → contrato del API', () => {
  const code = (metaCode: number, httpStatus = 400) => {
    const error = mapMetaSendError({ code: metaCode, httpStatus });
    return [error.code, error.action];
  };

  it('cada familia dice si parar, saltar o reintentar', () => {
    assert.deepEqual(code(130429), ['meta_rate_limited', 'retry']);
    assert.deepEqual(code(131056), ['meta_rate_limited', 'retry']);
    assert.deepEqual(code(190, 401), ['session_credentials_invalid', 'stop']);
    assert.deepEqual(code(131042), ['account_restricted', 'stop']);
    assert.deepEqual(code(132015), ['template_paused', 'stop']);
    assert.deepEqual(code(132016), ['template_not_approved', 'stop']);
    assert.deepEqual(code(132000), ['template_rejected_by_meta', 'stop']);
    assert.deepEqual(code(131050), ['recipient_opted_out', 'skip']);
    assert.deepEqual(code(131049), ['recipient_marketing_limited', 'skip']);
    assert.deepEqual(code(131026), ['recipient_unreachable', 'skip']);
    assert.deepEqual(code(131000, 500), ['meta_unavailable', 'retry']);
    assert.deepEqual(code(999999), ['meta_rejected', 'stop']);
  });

  it('el código de Meta viaja para diagnosticar', () => {
    assert.equal(mapMetaSendError({ code: 131042, httpStatus: 400 }).toJSON().error.metaCode, 131042);
    assert.equal(mapMetaSendError({ httpStatus: 503 }).code, 'meta_unavailable');
  });

  it('todo código del catálogo tiene HTTP de error y una acción válida', () => {
    for (const [name, { http, action }] of Object.entries(PUBLIC_API_ERRORS)) {
      assert.ok(http >= 400 && http < 600, name);
      assert.ok(['stop', 'skip', 'retry'].includes(action), name);
    }
  });
});
