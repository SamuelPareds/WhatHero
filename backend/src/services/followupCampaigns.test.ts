import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  resolvePeriod,
  zonedMidnightUtc,
  localDate,
  daysBetween,
  renderCampaignMessage,
  renderDateVariables,
  fillName,
  firstName,
  daysLeftPhrase,
  messageProblems,
  unknownVariables,
  normalizePlan,
  parseCandidateJson,
  extractJsonObject,
  verifyEvidence,
  adaptedKeepsOffer,
  structuralSkip,
  proposalLastDay,
  RECENT_ACTIVITY_MS,
  RECENT_FOLLOWUP_MS,
  MAX_PERIOD_DAYS,
  checkSendable,
  chatFollowupStatus,
} from './followupCampaigns';

const MX = 'America/Mexico_City'; // UTC−6 todo el año desde 2022
const NY = 'America/New_York';    // con horario de verano

// 11-nov-2026, 10:30 en Ciudad de México.
const NOW = new Date('2026-11-11T16:30:00Z');

describe('resolvePeriod', () => {
  test('últimos 7 días: desde las 00:00 de hace 7 días hasta ahora', () => {
    const p = resolvePeriod({ kind: 'last_days', days: 7 }, NOW, MX);
    assert.equal(p.fromDate, '2026-11-04');
    assert.equal(p.toDate, '2026-11-11');
    assert.equal(p.start.toISOString(), '2026-11-04T06:00:00.000Z');
    assert.equal(p.end.toISOString(), NOW.toISOString());
    assert.equal(p.clamped, false);
  });

  test('el mes pasado cruza el año', () => {
    const jan = new Date('2027-01-05T18:00:00Z');
    const p = resolvePeriod({ kind: 'last_month' }, jan, MX);
    assert.equal(p.fromDate, '2026-12-01');
    assert.equal(p.toDate, '2026-12-31');
    assert.equal(p.start.toISOString(), '2026-12-01T06:00:00.000Z');
    assert.equal(p.end.toISOString(), '2027-01-01T06:00:00.000Z');
  });

  test('este mes empieza el día 1', () => {
    const p = resolvePeriod({ kind: 'this_month' }, NOW, MX);
    assert.equal(p.fromDate, '2026-11-01');
    assert.equal(p.end.toISOString(), NOW.toISOString());
  });

  test('a las 23:30 de México ya es otro día en UTC, pero "hoy" es el de México', () => {
    const late = new Date('2026-11-12T05:30:00Z'); // 11-nov 23:30 en CDMX
    const p = resolvePeriod({ kind: 'last_days', days: 1 }, late, MX);
    assert.equal(p.toDate, '2026-11-11');
    assert.equal(p.fromDate, '2026-11-10');
  });

  test('un rango al revés se voltea y uno que termina en el futuro se corta en ahora', () => {
    const p = resolvePeriod({ kind: 'range', from: '2026-12-01', to: '2026-11-01' }, NOW, MX);
    assert.equal(p.fromDate, '2026-11-01');
    assert.equal(p.toDate, '2026-11-11');
    assert.equal(p.end.toISOString(), NOW.toISOString());
  });

  test(`nunca más de ${MAX_PERIOD_DAYS} días hacia atrás`, () => {
    const p = resolvePeriod({ kind: 'last_days', days: 400 }, NOW, MX);
    assert.equal(daysBetween(p.fromDate, p.toDate), MAX_PERIOD_DAYS);
    assert.equal(p.clamped, true);
    const r = resolvePeriod({ kind: 'range', from: '2025-01-01', to: '2025-02-01' }, NOW, MX);
    assert.equal(r.clamped, true);
  });

  test('la medianoche respeta el horario de verano', () => {
    // 8-mar-2026 empieza el horario de verano en Nueva York (a las 2:00).
    assert.equal(zonedMidnightUtc('2026-03-08', NY).toISOString(), '2026-03-08T05:00:00.000Z');
    assert.equal(zonedMidnightUtc('2026-03-09', NY).toISOString(), '2026-03-09T04:00:00.000Z');
    // 1-nov-2026 termina.
    assert.equal(zonedMidnightUtc('2026-11-01', NY).toISOString(), '2026-11-01T04:00:00.000Z');
    assert.equal(zonedMidnightUtc('2026-11-02', NY).toISOString(), '2026-11-02T05:00:00.000Z');
  });

  test('localDate usa la zona, no UTC', () => {
    assert.equal(localDate(new Date('2026-11-12T05:30:00Z'), MX), '2026-11-11');
  });
});

describe('el mensaje', () => {
  const promo = 'Hola {nombre}, {faltan_dias} para el fin de esta promo. Aparta tu cita hoy con $200.';

  test('cuenta los días que faltan al momento de enviar', () => {
    assert.equal(
      renderCampaignMessage(promo, { contactName: 'ana lópez', deadline: '2026-11-14', today: '2026-11-11' }),
      'Hola Ana, faltan 3 días para el fin de esta promo. Aparta tu cita hoy con $200.',
    );
    assert.equal(
      renderCampaignMessage(promo, { contactName: 'Ana', deadline: '2026-11-14', today: '2026-11-13' }),
      'Hola Ana, falta 1 día para el fin de esta promo. Aparta tu cita hoy con $200.',
    );
  });

  test('al inicio de frase va con mayúscula, y el último día se dice así', () => {
    assert.equal(renderDateVariables('{faltan_dias} de la promo.', '2026-11-14', '2026-11-14'), 'Hoy es el último día de la promo.');
    assert.equal(renderDateVariables('¡Corre! {faltan_dias}.', '2026-11-20', '2026-11-11'), '¡Corre! Faltan 9 días.');
  });

  test('con la fecha límite vencida no hay mensaje que enviar', () => {
    assert.equal(renderCampaignMessage(promo, { contactName: 'Ana', deadline: '2026-11-10', today: '2026-11-11' }), null);
    assert.equal(daysLeftPhrase('2026-11-10', '2026-11-11'), null);
  });

  test('cuenta días sin fecha límite: no se puede enviar', () => {
    assert.equal(renderDateVariables('{faltan_dias}', null, '2026-11-11'), null);
  });

  test('un texto sin variables de fecha sale igual con o sin fecha límite', () => {
    assert.equal(renderDateVariables('Hola, ¿sigues interesada?', null, '2026-11-11'), 'Hola, ¿sigues interesada?');
  });

  test('{fecha_limite} se escribe como lo diría una persona', () => {
    assert.equal(renderDateVariables('Termina el {fecha_limite}.', '2026-12-01', '2026-11-11'), 'Termina el 1 de diciembre.');
  });

  test('sin nombre usable, {nombre} se quita sin dejar huecos', () => {
    assert.equal(fillName('Hola {nombre}, ¿cómo estás?', '+52 55 1234 5678'), 'Hola, ¿cómo estás?');
    assert.equal(fillName('{nombre}, faltan pocos días', null), 'Faltan pocos días');
    assert.equal(fillName('¡Hola {nombre}!', '🌸🌸'), '¡Hola!');
  });

  test('el primer nombre se limpia de emojis y mayúsculas raras', () => {
    assert.equal(firstName('Anita 🌸'), 'Anita');
    assert.equal(firstName('MARÍA JOSÉ'), 'María');
    assert.equal(firstName('ana@correo.com'), null);
    assert.equal(firstName('5512345678'), null);
    assert.equal(firstName('J'), null);
  });

  test('una variable que no conocemos saldría literal: se rechaza', () => {
    assert.deepEqual(unknownVariables('Hola {cliente}, {nombre}'), ['cliente']);
    assert.match(messageProblems('Hola {cliente}', null).join(' '), /\{cliente\}/);
  });

  test('contar días exige fecha límite', () => {
    assert.match(messageProblems('{faltan_dias} de promo', null).join(' '), /fecha/);
    assert.deepEqual(messageProblems('{faltan_dias} de promo', '2026-11-20'), []);
  });

  test('una propuesta vive hasta la fecha límite, o 7 días sin ella', () => {
    assert.equal(proposalLastDay(null, '2026-11-11'), '2026-11-18');
    assert.equal(proposalLastDay('2026-11-14', '2026-11-11'), '2026-11-14');
  });
});

describe('normalizePlan', () => {
  const today = '2026-11-11';

  test('un plan completo pasa sin faltantes', () => {
    const r = normalizePlan({
      period: { kind: 'last_days', days: 7 },
      audience: 'Preguntaron por microblading',
      exclusions: 'Ya agendaron',
      message: 'Hola { Nombre }, {faltan_dias} para el fin de la promo',
      deadline: '2026-11-15',
      adapt: false,
    }, today);
    assert.deepEqual(r.missing, []);
    assert.deepEqual(r.problems, []);
    assert.equal(r.plan.message, 'Hola {nombre}, {faltan_dias} para el fin de la promo');
  });

  test('pide lo que falta en vez de inventarlo', () => {
    const r = normalizePlan({ message: '{faltan_dias} para el fin de la promo' }, today);
    assert.deepEqual(r.missing.sort(), ['audience', 'deadline', 'period']);
  });

  test('una fecha límite pasada no se acepta', () => {
    const r = normalizePlan({
      period: { kind: 'this_month' }, audience: 'x', message: 'Hola', deadline: '2026-11-01',
    }, today);
    assert.equal(r.plan.deadline, null);
    assert.match(r.problems.join(' '), /ya pasó/);
  });

  test('un periodo mal formado cuenta como faltante', () => {
    const r = normalizePlan({ period: { kind: 'range', from: '2026-02-30', to: 'ayer' }, audience: 'x', message: 'Hola' }, today);
    assert.deepEqual(r.missing, ['period']);
  });
});

describe('lo que devuelve la IA falla cerrado', () => {
  test('JSON dentro de un bloque de código', () => {
    const d = parseCandidateJson('```json\n{"match": true, "reason": "Preguntó precio", "quote": "cuánto cuesta"}\n```');
    assert.deepEqual(d, { match: true, reason: 'Preguntó precio', quote: 'cuánto cuesta' });
  });

  test('ilegible = no entra a la campaña', () => {
    assert.equal(parseCandidateJson('creo que sí, tal vez').match, false);
    assert.equal(parseCandidateJson('').match, false);
    assert.equal(extractJsonObject('{roto'), null);
  });

  test('"match": "true" como texto también vale', () => {
    assert.equal(parseCandidateJson('{"match": "true"}').match, true);
  });
});

describe('verifyEvidence', () => {
  const lines = [
    { text: 'Hola buenas tardes', at: 1 },
    { text: '¿Cuánto cuesta el MICROBLADING?', at: 2 },
  ];

  test('la cita existe en un mensaje del cliente (sin importar acentos ni mayúsculas)', () => {
    assert.deepEqual(verifyEvidence('cuanto cuesta el microblading', lines), { text: 'cuanto cuesta el microblading', at: 2 });
  });

  test('una cita inventada se descarta', () => {
    assert.equal(verifyEvidence('quiero agendar el sábado', lines), null);
    assert.equal(verifyEvidence(null, lines), null);
  });
});

describe('adaptedKeepsOffer', () => {
  const t = '{faltan_dias} para el fin de la promo. Aparta con $200 y liquida el día de tu cita.';

  test('conserva variables y cifras', () => {
    assert.equal(adaptedKeepsOffer(t, 'Hola, vi que preguntaste por las cejas. {faltan_dias} para el fin de la promo. Aparta con $200 y liquida el día de tu cita.'), true);
  });

  test('si pierde la cifra o la variable, no sirve', () => {
    assert.equal(adaptedKeepsOffer(t, 'Faltan pocos días para el fin de la promo. Aparta con $200.'), false);
    assert.equal(adaptedKeepsOffer(t, '{faltan_dias} para el fin de la promo. Aparta con $300.'), false);
    assert.equal(adaptedKeepsOffer(t, '{faltan_dias}, {precio}, $200'), false);
  });
});

describe('structuralSkip', () => {
  const now = Date.parse('2026-11-11T16:30:00Z');
  const old = { lastMessageTimestamp: now - 3 * 86_400_000 };

  test('un lead frío normal se revisa', () => {
    assert.equal(structuralSkip('5215512345678', old, null, 'c1', now), null);
  });

  test('un chat pendiente espera una respuesta, no un seguimiento', () => {
    assert.equal(structuralSkip('5215512345678', { ...old, unresponded_count: 2 }, null, 'c1', now), 'pending');
    assert.equal(structuralSkip('5215512345678', { ...old, marked_pending: true }, null, 'c1', now), 'pending');
  });

  test('opt-outs, grupos y conversaciones vivas', () => {
    assert.equal(structuralSkip('x', { ...old, followup_opt_out: true }, null, 'c1', now), 'opted_out');
    assert.equal(structuralSkip('x', { ...old, marketing_opt_out_at: { _seconds: 1 } }, null, 'c1', now), 'opted_out');
    assert.equal(structuralSkip('120363-1@g.us', old, null, 'c1', now), 'group');
    assert.equal(structuralSkip('x', { lastMessageTimestamp: now - RECENT_ACTIVITY_MS + 60_000 }, null, 'c1', now), 'recent_activity');
  });

  test('un seguimiento esta semana o uno ya programado lo saca', () => {
    assert.equal(structuralSkip('x', { ...old, followup_last_at: now - RECENT_FOLLOWUP_MS + 60_000 }, null, 'c1', now), 'recent_followup');
    assert.equal(structuralSkip('x', old, { status: 'approved', campaignId: 'c0' }, 'c1', now), 'already_scheduled');
    assert.equal(structuralSkip('x', old, { status: 'in_doubt' }, 'c1', now), 'already_scheduled');
  });

  test('una propuesta pendiente de otra campaña no se pisa; la del barrido diario sí', () => {
    assert.equal(structuralSkip('x', old, { status: 'pending', campaignId: 'c0' }, 'c1', now), 'in_other_campaign');
    assert.equal(structuralSkip('x', old, { status: 'pending', campaignId: null }, 'c1', now), null);
    assert.equal(structuralSkip('x', old, { status: 'pending', campaignId: 'c1' }, 'c1', now), null);
  });
});


describe('checkSendable', () => {
  const proposal = {
    status: 'approved',
    messageTemplate: 'Hola Ana, {faltan_dias} de la promo.',
    deadline: '2026-11-15',
    lastDay: '2026-11-15',
    chatLastMessageId: 'M1',
  };
  const chat = { lastMessageId: 'M1', unresponded_count: 0 };

  test('sin cambios sale con los días de HOY', () => {
    assert.deepEqual(checkSendable(proposal, chat, '2026-11-13'), { ok: true, text: 'Hola Ana, faltan 2 días de la promo.' });
  });

  test('si la conversación se movió, no sale', () => {
    assert.deepEqual(checkSendable(proposal, { ...chat, lastMessageId: 'M2' }, '2026-11-13'),
      { ok: false, status: 'stale', reason: 'conversation_moved' });
    assert.equal((checkSendable(proposal, { ...chat, unresponded_count: 1 }, '2026-11-13') as { reason: string }).reason, 'pending');
    assert.equal((checkSendable(proposal, null, '2026-11-13') as { reason: string }).reason, 'chat_deleted');
  });

  test('quien pidió no recibir mensajes no recibe', () => {
    assert.equal((checkSendable(proposal, { ...chat, marketing_opt_out_at: 1 }, '2026-11-13') as { reason: string }).reason, 'opted_out');
  });

  test('pasada la fecha límite vence', () => {
    assert.equal((checkSendable(proposal, chat, '2026-11-16') as { status: string }).status, 'expired');
  });

  test('un texto editado a mano sale tal cual', () => {
    assert.deepEqual(checkSendable({ ...proposal, editedText: '  Hola Ana, te esperamos  ' }, chat, '2026-11-13'),
      { ok: true, text: 'Hola Ana, te esperamos' });
  });

  test('el chat doc refleja la propuesta', () => {
    assert.equal(chatFollowupStatus('pending'), 'queued');
    assert.equal(chatFollowupStatus('approved'), 'scheduled');
    assert.equal(chatFollowupStatus('handled'), 'sent');
    assert.equal(chatFollowupStatus('rejected'), 'dismissed');
  });
});
