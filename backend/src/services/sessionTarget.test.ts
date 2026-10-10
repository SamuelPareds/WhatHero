import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildNumberChangePatch,
  decideSessionTarget,
  defaultSessionAlias,
  lastNumberChangeMs,
  type LinkIntent,
  type TargetFacts,
} from './sessionTarget';

const A = '5215500000001'; // número anterior
const B = '5215500000002'; // número nuevo
const C = '5215500000003';

const absent = { exists: false };

function facts(partial: Partial<TargetFacts>): TargetFacts {
  return { linked: B, ownDoc: absent, adoptedBy: [], ...partial };
}

function intent(partial: Partial<LinkIntent> = {}): LinkIntent {
  return { intoSessionId: A, allowNumberChange: true, keepPrevious: false, expectedPhone: A, ...partial };
}

// --- Reconexión ---

test('una reconexión escribe al doc fijado, sin mirar nada más', () => {
  const d = decideSessionTarget(facts({ pinnedSessionId: A, ownDoc: { exists: true, phone: B } }));
  assert.deepEqual(d, { kind: 'relink', sessionId: A });
});

// --- Vinculación normal (sin intent) ---

test('un número nunca visto abre su propio doc', () => {
  assert.deepEqual(decideSessionTarget(facts({})), { kind: 'new', sessionId: B });
});

test('re-vincular un número que ya tiene su doc vuelve a él', () => {
  const d = decideSessionTarget(facts({ ownDoc: { exists: true, phone: B } }));
  assert.deepEqual(d, { kind: 'relink', sessionId: B });
});

test('doc legacy sin phone_number cuenta como propio', () => {
  const d = decideSessionTarget(facts({ ownDoc: { exists: true } }));
  assert.deepEqual(d, { kind: 'relink', sessionId: B });
});

test('el número nuevo de una sesión migrada vuelve a esa sesión, no abre una vacía', () => {
  const d = decideSessionTarget(facts({ adoptedBy: [A] }));
  assert.deepEqual(d, { kind: 'relink', sessionId: A });
});

test('un número reemplazado no vuelve como línea aparte (su id está ocupado)', () => {
  const d = decideSessionTarget(facts({ linked: A, ownDoc: { exists: true, phone: B } }));
  assert.deepEqual(d, { kind: 'reject', reason: 'number_replaced', sessionId: A });
});

// --- Con intent ---

test('intent con el mismo número es un relink normal', () => {
  const d = decideSessionTarget(facts({
    linked: A,
    intent: intent({ allowNumberChange: false }),
    intoDoc: { exists: true, phone: A },
    ownDoc: { exists: true, phone: A },
  }));
  assert.deepEqual(d, { kind: 'relink', sessionId: A });
});

test('intent a un doc que ya no existe se rechaza', () => {
  const d = decideSessionTarget(facts({ intent: intent(), intoDoc: absent }));
  assert.deepEqual(d, { kind: 'reject', reason: 'not_found', sessionId: A });
});

test('escanear otro número sin pedir el cambio se rechaza: un QR equivocado no secuestra la sesión', () => {
  const d = decideSessionTarget(facts({
    intent: intent({ allowNumberChange: false }),
    intoDoc: { exists: true, phone: A },
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'wrong_number', sessionId: A });
});

test('cambio de número pedido a un número sin doc: se adopta el doc anterior', () => {
  const d = decideSessionTarget(facts({ intent: intent(), intoDoc: { exists: true, phone: A } }));
  assert.deepEqual(d, { kind: 'number_change', sessionId: A, fromPhone: A, dropEmptyDocOf: null });
});

test('el doc vacío del número nuevo se marca para borrarse', () => {
  const d = decideSessionTarget(facts({
    intent: intent(),
    intoDoc: { exists: true, phone: A },
    ownDoc: { exists: true, phone: B, hasChats: false },
  }));
  assert.deepEqual(d, { kind: 'number_change', sessionId: A, fromPhone: A, dropEmptyDocOf: B });
});

test('si el número nuevo ya trabajó por su cuenta no se mezclan historiales', () => {
  const d = decideSessionTarget(facts({
    intent: intent(),
    intoDoc: { exists: true, phone: A },
    ownDoc: { exists: true, phone: B, hasChats: true },
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'has_history', sessionId: A });
});

test('si el número de la sesión cambió mientras se escaneaba, se rechaza', () => {
  const d = decideSessionTarget(facts({
    linked: C,
    intent: intent({ expectedPhone: A }),
    intoDoc: { exists: true, phone: B },
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'stale', sessionId: A });
});

test('un número que ya es el de otra sesión migrada no puede adoptar una segunda', () => {
  const d = decideSessionTarget(facts({
    intent: intent(),
    intoDoc: { exists: true, phone: A },
    adoptedBy: [C],
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'in_use', sessionId: A });
});

test('volver al número anterior: el doc conserva su id y no se borra nada', () => {
  // Sesión A que hoy usa B; el operador recupera A y lo vuelve a poner.
  const d = decideSessionTarget(facts({
    linked: A,
    intent: intent({ expectedPhone: B }),
    intoDoc: { exists: true, phone: B },
    ownDoc: { exists: true, phone: B }, // el doc {A} es la propia sesión
  }));
  assert.deepEqual(d, { kind: 'number_change', sessionId: A, fromPhone: B, dropEmptyDocOf: null });
});

// --- Sesión que se está eliminando ---

test('volver a vincular el número de una sesión que se está eliminando se rechaza', () => {
  const d = decideSessionTarget(facts({ ownDoc: { exists: true, phone: B }, deleting: [B] }));
  assert.deepEqual(d, { kind: 'reject', reason: 'deleting', sessionId: B });
});

test('el número nuevo de una sesión migrada que se está eliminando no vuelve a ella', () => {
  const d = decideSessionTarget(facts({ adoptedBy: [A], deleting: [A] }));
  assert.deepEqual(d, { kind: 'reject', reason: 'deleting', sessionId: A });
});

test('re-vincular una tarjeta que se está eliminando se rechaza aunque sea el mismo número', () => {
  const d = decideSessionTarget(facts({
    linked: A,
    intent: intent({ allowNumberChange: false }),
    intoDoc: { exists: true, phone: A },
    ownDoc: { exists: true, phone: A },
    deleting: [A],
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'deleting', sessionId: A });
});

test('cambiar de número hacia uno cuya sesión se está eliminando gana sobre has_history e in_use', () => {
  const d = decideSessionTarget(facts({
    intent: intent(),
    intoDoc: { exists: true, phone: A },
    ownDoc: { exists: true, phone: B, hasChats: true },
    adoptedBy: [C],
    deleting: [B],
  }));
  assert.deepEqual(d, { kind: 'reject', reason: 'deleting', sessionId: B });
});

test('una reconexión no mira lápidas: no lee nada', () => {
  const d = decideSessionTarget(facts({ pinnedSessionId: A, deleting: [A] }));
  assert.deepEqual(d, { kind: 'relink', sessionId: A });
});

// --- Parche del cambio ---

test('el parche apunta al número nuevo y agrega el anterior a la historia', () => {
  const { patch } = buildNumberChangePatch({ number_history: [{ phone: C, until: 't0' }] }, A, B, 't1', false);
  assert.equal(patch.phone_number, B);
  assert.deepEqual(patch.number_history, [
    { phone: C, until: 't0' },
    { phone: A, until: 't1' },
  ]);
  assert.deepEqual(patch.number_change, { from: A, to: B, at: 't1', pausedAutomations: [] });
});

test('se pausan sólo los automáticos que estaban encendidos', () => {
  const { patch, pausedAutomations } = buildNumberChangePatch(
    { followup_enabled: true, reminder_enabled: false },
    A, B, 't', false,
  );
  assert.deepEqual(pausedAutomations, ['followups']);
  assert.equal(patch.followup_enabled, false);
  assert.equal('reminder_enabled' in patch, false);
});

test('el alias por defecto se actualiza; uno puesto por el operador se respeta', () => {
  assert.equal(
    buildNumberChangePatch({ alias: defaultSessionAlias(A) }, A, B, 't', false).patch.alias,
    defaultSessionAlias(B),
  );
  assert.equal('alias' in buildNumberChangePatch({ alias: 'Ventas' }, A, B, 't', false).patch, false);
});

test('la línea anterior que se queda recibiendo entra a previous_lines', () => {
  const { patch } = buildNumberChangePatch({}, A, B, 't', true);
  assert.deepEqual(patch.previous_lines, { [A]: { status: 'connected', since: 't', last_sync: 't' } });
});

test('si el número nuevo era una línea anterior, deja de serlo', () => {
  const { patch } = buildNumberChangePatch(
    { previous_lines: { [A]: { status: 'connected' }, [C]: { status: 'disconnected' } } },
    B, A, 't', false,
  );
  assert.deepEqual(patch.previous_lines, { [C]: { status: 'disconnected' } });
});

test('lastNumberChangeMs toma el until más reciente', () => {
  const at = (ms: number) => ({ toMillis: () => ms });
  assert.equal(lastNumberChangeMs({ number_history: [{ until: at(10) }, { until: at(30) }, { until: at(20) }] }), 30);
  assert.equal(lastNumberChangeMs({}), undefined);
  assert.equal(lastNumberChangeMs(undefined), undefined);
});
