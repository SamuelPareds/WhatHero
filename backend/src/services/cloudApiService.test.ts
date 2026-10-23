import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import {
  initCloudApiService,
  getMetaWebhookVerifyToken,
  handleMetaWebhookPayload,
  resolveCanonicalChatPhone,
  verifyMetaSignature,
  verifyCloudApiCredentials,
  appSecretProof,
  subscribeAppToWaba,
  isDeliveryStatusAdvance,
  decideCloudApiTarget,
  loadCloudApiSessionsOnBoot,
  listMetaTemplates,
  createMetaTemplate,
  deleteMetaTemplate,
  CloudApiTargetFacts,
} from './cloudApiService';
import { validateTemplateDraft } from './metaTemplates';
import { clearSessionGone, initSessionSupervisor, markSessionGone } from './sessionSupervisor';
import { SessionData } from '../types';

function makeFakeDb(existingChatIds: string[] = []) {
  const existingSet = new Set(existingChatIds);
  const updatedDocs = new Map<string, Record<string, any>>();

  const db: any = {
    updatedDocs,
    collection: (_colName: string) => ({
      doc: (_accId: string) => ({
        collection: (subName: string) => ({
          where: () => ({
            get: async () => ({ docs: [] }),
          }),
          doc: (_sessionId: string) => ({
            collection: (nestedName: string) => ({
              doc: (chatId: string) => ({
                id: chatId,
                exists: existingSet.has(chatId),
                collection: (msgCol: string) => ({
                  doc: (msgId: string) => {
                    const path = `${subName}/${nestedName}/${chatId}/${msgCol}/${msgId}`;
                    return {
                      get: async () => ({ exists: true, get: (field: string) => updatedDocs.get(path)?.[field] }),
                      update: async (patch: Record<string, any>) => {
                        updatedDocs.set(path, { ...updatedDocs.get(path), ...patch });
                      },
                    };
                  },
                }),
              }),
            }),
          }),
        }),
      }),
      get: async () => ({ docs: [] }),
    }),
    getAll: async (...refs: Array<{ id: string; exists: boolean }>) =>
      refs.map((r) => ({ id: r.id, exists: r.exists })),
    runTransaction: async (fn: (tx: any) => Promise<void>) =>
      fn({ get: (ref: any) => ref.get(), update: (ref: any, patch: Record<string, any>) => ref.update(patch) }),
  };

  return db;
}

function makeCloudSession(accountId: string, sessionId: string, phoneNumberId: string): SessionData {
  return {
    sock: { isCloudApi: true },
    currentQR: undefined,
    isReady: true,
    sessionId,
    linkedPhone: sessionId,
    role: 'primary',
    reconnectCount: 0,
    accountId,
    provider: 'cloud_api',
    cloudApi: {
      phoneNumberId,
      wabaId: 'waba_test_123',
      accessToken: 'EAATestToken123456',
      verifiedName: 'Meta Test Number',
    },
    generation: 1,
    socketStartedAt: Date.now(),
    lastConnectedAt: Date.now(),
    lastWrittenStatus: 'connected',
    contactNames: new Map(),
    pendingSenders: new Map(),
    unreadKeys: new Map(),
  };
}

// Firestore mínimo para la hidratación: cuentas por `listDocuments`, sesiones
// Cloud API por `where('provider')`, secretos por id, y el `update` del status.
function makeHydrationDb(
  accounts: Record<string, { sessions: Record<string, any>; secrets?: Record<string, any> }>,
) {
  const calls = { listDocuments: 0, updates: [] as Array<{ path: string; patch: Record<string, any> }> };
  const accountRef = (accountId: string) => ({
    id: accountId,
    collection: (name: string) => {
      if (name === 'whatsapp_sessions') {
        return {
          where: (_field: string, _op: string, value: string) => ({
            get: async () => ({
              docs: Object.entries(accounts[accountId]?.sessions ?? {})
                .filter(([, data]) => data.provider === value)
                .map(([id, data]) => ({ id, data: () => data })),
            }),
          }),
          doc: (sessionId: string) => ({
            update: async (patch: Record<string, any>) => {
              calls.updates.push({ path: `${accountId}/${sessionId}`, patch });
            },
          }),
        };
      }
      return {
        doc: (sessionId: string) => ({
          get: async () => ({ data: () => accounts[accountId]?.secrets?.[sessionId] }),
        }),
      };
    },
  });
  const db: any = {
    calls,
    collection: (_root: string) => ({
      listDocuments: async () => {
        calls.listDocuments++;
        return Object.keys(accounts).map(accountRef);
      },
      doc: (accountId: string) => accountRef(accountId),
    }),
  };
  return db;
}

function initWithHydrationDb(db: any, sessions: Map<string, SessionData>, configsLoaded: string[] = []) {
  initSessionSupervisor({ sessions, db, io: {} as any, startSession: async () => {} });
  initCloudApiService({
    db,
    sessions,
    onUpsertedMessage: async () => {},
    loadAllSessionConfigs: async (sessionKey) => {
      configsLoaded.push(sessionKey);
    },
  });
}

const cloudSecret = (phoneNumberId: string) => ({ phoneNumberId, wabaId: 'waba_1', accessToken: 'EAA-secreto-de-prueba' });

function webhookFor(phoneNumberId: string) {
  return {
    object: 'whatsapp_business_account',
    entry: [{ changes: [{ value: { messaging_product: 'whatsapp', metadata: { phone_number_id: phoneNumberId } } }] }],
  };
}

function facts(overrides: Partial<CloudApiTargetFacts> = {}): CloudApiTargetFacts {
  return {
    accountId: 'acc1',
    digits: '15552041012',
    ownDoc: { exists: false },
    adoptedBy: [],
    phoneNumberIdOwners: [],
    ...overrides,
  };
}

describe('cloudApiService', () => {
  it('devuelve un verify token por defecto estable para configurar el webhook en Meta', () => {
    const token = getMetaWebhookVerifyToken();
    assert.equal(typeof token, 'string');
    assert.ok(token.length >= 10);
  });

  it('resolveCanonicalChatPhone unifica variantes de México (521 vs 52) cuando ya existe el chat hermano', async () => {
    const fakeDb = makeFakeDb(['525512345678']);
    const sessions = new Map<string, SessionData>();

    initCloudApiService({
      db: fakeDb,
      sessions,
      onUpsertedMessage: async () => {},
      loadAllSessionConfigs: async () => {},
    });

    // El webhook de Meta puede entregar `5215512345678` aunque el chat se haya abierto como `525512345678`.
    const resolved = await resolveCanonicalChatPhone('acc1', '15550001111', '5215512345678');
    assert.equal(resolved, '525512345678');
  });

  it('handleMetaWebhookPayload transforma mensajes entrantes, deduplica por wamid y cachea el nombre del contacto', async () => {
    const fakeDb = makeFakeDb();
    const sessions = new Map<string, SessionData>();
    const sessionKey = 'acc1_15551234567';
    const session = makeCloudSession('acc1', '15551234567', 'phone_id_999');
    sessions.set(sessionKey, session);

    const receivedUpserts: any[] = [];
    initCloudApiService({
      db: fakeDb,
      sessions,
      onUpsertedMessage: async (_sKey, _accId, _sock, rawMsg) => {
        receivedUpserts.push(rawMsg);
      },
      loadAllSessionConfigs: async () => {},
    });

    const payload = {
      object: 'whatsapp_business_account',
      entry: [
        {
          id: 'waba_test_123',
          changes: [
            {
              field: 'messages',
              value: {
                messaging_product: 'whatsapp',
                metadata: {
                  display_phone_number: '15551234567',
                  phone_number_id: 'phone_id_999',
                },
                contacts: [
                  {
                    profile: { name: 'Cliente Prueba' },
                    wa_id: '5215599887766',
                  },
                ],
                messages: [
                  {
                    from: '5215599887766',
                    id: 'wamid.test_unique_001',
                    timestamp: '1729500000',
                    type: 'text',
                    text: { body: 'Hola desde el número de prueba' },
                  },
                ],
              },
            },
          ],
        },
      ],
    };

    await handleMetaWebhookPayload(payload);
    // Segundo disparo con el mismo wamid (reintento de Meta) debe ignorarse.
    await handleMetaWebhookPayload(payload);

    assert.equal(receivedUpserts.length, 1);
    assert.equal(receivedUpserts[0].key.id, 'wamid.test_unique_001');
    assert.equal(receivedUpserts[0].key.fromMe, false);
    assert.equal(receivedUpserts[0].key.remoteJid, '5215599887766@s.whatsapp.net');
    assert.equal(receivedUpserts[0].message.conversation, 'Hola desde el número de prueba');
    assert.equal(session.contactNames.get('5215599887766'), 'Cliente Prueba');
  });

  it('handleMetaWebhookPayload procesa estados de entrega y registra errores de entrega de Meta', async () => {
    const fakeDb = makeFakeDb();
    const sessions = new Map<string, SessionData>();
    const sessionKey = 'acc1_15551234567';
    sessions.set(sessionKey, makeCloudSession('acc1', '15551234567', 'phone_id_999'));

    initCloudApiService({
      db: fakeDb,
      sessions,
      onUpsertedMessage: async () => {},
      loadAllSessionConfigs: async () => {},
    });

    await handleMetaWebhookPayload({
      object: 'whatsapp_business_account',
      entry: [
        {
          changes: [
            {
              value: {
                messaging_product: 'whatsapp',
                metadata: { phone_number_id: 'phone_id_999' },
                statuses: [
                  {
                    id: 'wamid.out_123',
                    status: 'failed',
                    recipient_id: '5215599887766',
                    errors: [
                      {
                        code: 131047,
                        title: 'Re-engagement message',
                        error_data: {
                          details: 'More than 24 hours have passed since the customer last replied.',
                        },
                      },
                    ],
                  },
                ],
              },
            },
          ],
        },
      ],
    });

    const patch = fakeDb.updatedDocs.get('whatsapp_sessions/chats/5215599887766/messages/wamid.out_123');
    assert.ok(patch);
    assert.equal(patch.deliveryStatus, 'failed');
    assert.match(patch.deliveryError, /131047/);
  });
});

describe('firma del webhook de Meta', () => {
  const secret = 'clave-secreta-de-la-app';
  const body = Buffer.from(JSON.stringify(webhookFor('phone_id_999')));
  const sign = (buf: Buffer, key = secret) => `sha256=${createHmac('sha256', key).update(buf).digest('hex')}`;

  it('acepta la firma de Meta sobre el cuerpo crudo', () => {
    assert.equal(verifyMetaSignature(body, sign(body), secret), true);
  });

  it('rechaza un cuerpo alterado, otra clave, sin header o con header mal formado', () => {
    const tampered = Buffer.from(body.toString().replace('phone_id_999', 'phone_id_000'));
    assert.equal(verifyMetaSignature(tampered, sign(body), secret), false);
    assert.equal(verifyMetaSignature(body, sign(body, 'otra-clave'), secret), false);
    assert.equal(verifyMetaSignature(body, undefined, secret), false);
    assert.equal(verifyMetaSignature(body, sign(body).replace('sha256=', 'sha1='), secret), false);
    assert.equal(verifyMetaSignature(body, sign(body).slice(0, -2), secret), false);
    assert.equal(verifyMetaSignature(undefined, sign(body), secret), false);
    assert.equal(verifyMetaSignature(body, sign(body), ''), false);
  });

});

// Un mensaje de texto entrante para el `phone_number_id` dado. Los wamid tienen
// que ser únicos entre tests: el dedupe del webhook vive en el módulo.
function textChange(phoneNumberId: string, wamid: string) {
  return {
    value: {
      messaging_product: 'whatsapp',
      metadata: { phone_number_id: phoneNumberId },
      messages: [{ from: '5215599887766', id: wamid, timestamp: '1729500000', type: 'text', text: { body: 'hola' } }],
    },
  };
}

function signedWebhook(changes: any[], secret?: string) {
  const rawBody = Buffer.from(JSON.stringify({ object: 'whatsapp_business_account', entry: [{ changes }] }));
  const signature = secret ? `sha256=${createHmac('sha256', secret).update(rawBody).digest('hex')}` : undefined;
  return { body: JSON.parse(rawBody.toString()), auth: { rawBody, signature } };
}

function initWithSessions(list: SessionData[]) {
  const sessions = new Map<string, SessionData>();
  for (const s of list) sessions.set(`${s.accountId}_${s.sessionId}`, s);
  const received: Array<{ sessionKey: string; raw: any }> = [];
  initCloudApiService({
    db: makeFakeDb(),
    sessions,
    onUpsertedMessage: async (sessionKey, _acc, _sock, raw) => {
      received.push({ sessionKey, raw });
    },
    loadAllSessionConfigs: async () => {},
  });
  return received;
}

function withAppSecret(session: SessionData, appSecret: string): SessionData {
  session.cloudApi = { ...session.cloudApi!, appSecret };
  return session;
}

describe('firma del webhook por sesión (cada cliente con su app)', () => {
  it('procesa lo firmado por la app de la sesión y descarta lo que no', async () => {
    const received = initWithSessions([withAppSecret(makeCloudSession('accA', '15550000001', 'pid_A'), 'secreto-A')]);

    const ok = signedWebhook([textChange('pid_A', 'wamid.firma_ok')], 'secreto-A');
    await handleMetaWebhookPayload(ok.body, ok.auth);
    const sinFirma = signedWebhook([textChange('pid_A', 'wamid.sin_firma')]);
    await handleMetaWebhookPayload(sinFirma.body, sinFirma.auth);
    const otraClave = signedWebhook([textChange('pid_A', 'wamid.otra_clave')], 'secreto-B');
    await handleMetaWebhookPayload(otraClave.body, otraClave.auth);

    assert.deepEqual(received.map((r) => r.raw.key.id), ['wamid.firma_ok']);
  });

  it('un cliente no puede firmar cambios para el número de otro con su propia clave', async () => {
    const received = initWithSessions([
      withAppSecret(makeCloudSession('accA', '15550000001', 'pid_A'), 'secreto-A'),
      withAppSecret(makeCloudSession('accB', '15550000002', 'pid_B'), 'secreto-B'),
    ]);

    const mixed = signedWebhook(
      [textChange('pid_A', 'wamid.mezcla_A'), textChange('pid_B', 'wamid.mezcla_B')],
      'secreto-A',
    );
    await handleMetaWebhookPayload(mixed.body, mixed.auth);

    assert.deepEqual(received.map((r) => r.sessionKey), ['accA_15550000001']);
  });

  it('una sesión sin App Secret propio usa META_APP_SECRET; sin ninguno, en desarrollo acepta', async () => {
    const previous = process.env.META_APP_SECRET;
    try {
      process.env.META_APP_SECRET = 'secreto-whathero';
      let received = initWithSessions([makeCloudSession('accC', '15550000003', 'pid_C')]);
      const conGlobal = signedWebhook([textChange('pid_C', 'wamid.global_ok')], 'secreto-whathero');
      await handleMetaWebhookPayload(conGlobal.body, conGlobal.auth);
      const sinFirma = signedWebhook([textChange('pid_C', 'wamid.global_sin_firma')]);
      await handleMetaWebhookPayload(sinFirma.body, sinFirma.auth);
      assert.deepEqual(received.map((r) => r.raw.key.id), ['wamid.global_ok']);

      delete process.env.META_APP_SECRET;
      received = initWithSessions([makeCloudSession('accC', '15550000003', 'pid_C')]);
      const dev = signedWebhook([textChange('pid_C', 'wamid.dev_sin_clave')]);
      await handleMetaWebhookPayload(dev.body, dev.auth);
      assert.deepEqual(received.map((r) => r.raw.key.id), ['wamid.dev_sin_clave']);
    } finally {
      if (previous === undefined) delete process.env.META_APP_SECRET;
      else process.env.META_APP_SECRET = previous;
    }
  });
});

describe('verifyCloudApiCredentials con App Secret', () => {
  const realFetch = globalThis.fetch;

  it('manda el appsecret_proof del token con la clave de la app', async () => {
    let requested = '';
    globalThis.fetch = (async (url: string) => {
      requested = url;
      return new Response(JSON.stringify({ id: 'pid_1', display_phone_number: '+1 555-204-1012', verified_name: 'Test Number' }));
    }) as any;
    try {
      const result = await verifyCloudApiCredentials({
        phoneNumberId: 'pid_1',
        wabaId: 'waba_1',
        accessToken: 'EAA-token',
        appSecret: 'secreto-A',
      });
      assert.equal(result.sessionId, '15552041012');
      assert.equal(new URL(requested).searchParams.get('appsecret_proof'), appSecretProof('EAA-token', 'secreto-A'));
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('un App Secret que no es de la app del token se explica en español', async () => {
    globalThis.fetch = (async () =>
      new Response(
        JSON.stringify({ error: { message: 'Invalid appsecret_proof provided in the API argument', type: 'GraphMethodException', code: 100 } }),
        { status: 400 },
      )) as any;
    try {
      await assert.rejects(
        verifyCloudApiCredentials({ phoneNumberId: 'pid_1', wabaId: 'waba_1', accessToken: 'EAA-token', appSecret: 'mal' }),
        (err: any) => err.httpStatus === 400 && /App Secret no corresponde/.test(err.message),
      );
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});

describe('decideCloudApiTarget', () => {
  it('alta nueva y actualización de credenciales de la misma sesión Cloud API', () => {
    assert.deepEqual(decideCloudApiTarget(facts()), { kind: 'connect', sessionId: '15552041012', isNew: true });
    assert.deepEqual(
      decideCloudApiTarget(facts({
        intoSessionId: '15552041012',
        ownDoc: { exists: true, provider: 'cloud_api', phone: '15552041012' },
        adoptedBy: ['15552041012'],
        phoneNumberIdOwners: [{ accountId: 'acc1', sessionId: '15552041012' }],
      })),
      { kind: 'connect', sessionId: '15552041012', isNew: false },
    );
  });

  it('credenciales de otro número no cambian el número de la sesión que se edita', () => {
    assert.deepEqual(decideCloudApiTarget(facts({ intoSessionId: '5215511111111' })), { kind: 'reject', reason: 'wrong_number' });
  });

  it('no escribe sobre una lápida', () => {
    assert.deepEqual(
      decideCloudApiTarget(facts({ ownDoc: { exists: true, deleting: true, provider: 'cloud_api' } })),
      { kind: 'reject', reason: 'deleting' },
    );
  });

  it('el mismo phone_number_id no se conecta en otra cuenta ni en otra sesión', () => {
    assert.deepEqual(
      decideCloudApiTarget(facts({ phoneNumberIdOwners: [{ accountId: 'otra', sessionId: '15552041012' }] })),
      { kind: 'reject', reason: 'phone_number_id_in_use' },
    );
    assert.deepEqual(
      decideCloudApiTarget(facts({ phoneNumberIdOwners: [{ accountId: 'acc1', sessionId: '5215522222222' }] })),
      { kind: 'reject', reason: 'phone_number_id_in_use' },
    );
  });

  it('respeta los cambios de número: ni el número de otra sesión ni un id reemplazado', () => {
    assert.deepEqual(decideCloudApiTarget(facts({ adoptedBy: ['5215533333333'] })), { kind: 'reject', reason: 'in_use' });
    assert.deepEqual(
      decideCloudApiTarget(facts({ ownDoc: { exists: true, provider: 'cloud_api', phone: '5215544444444' } })),
      { kind: 'reject', reason: 'number_replaced' },
    );
  });

  it('no convierte en Cloud API una sesión QR del mismo número', () => {
    assert.deepEqual(
      decideCloudApiTarget(facts({ ownDoc: { exists: true, phone: '15552041012' } })),
      { kind: 'reject', reason: 'qr_session_exists' },
    );
  });
});

describe('hidratación de sesiones Cloud API', () => {
  it('salta lápidas y sesiones eliminadas, no recrea las que ya están en memoria y escribe el status con update', async () => {
    const db = makeHydrationDb({
      hidr1: {
        sessions: {
          '111111': { provider: 'cloud_api', cloud_api_verified_name: 'Viva' },
          '222222': { provider: 'cloud_api', deleting_at: new Date(), status: 'deleting' },
          '333333': { provider: 'cloud_api' },
          '444444': { provider: 'cloud_api' },
          '555555': { provider: 'cloud_api' },
          '666666': { status: 'connected' },
        },
        secrets: {
          '111111': cloudSecret('pid_1'),
          '222222': cloudSecret('pid_2'),
          '333333': cloudSecret('pid_3'),
          '444444': cloudSecret('pid_4'),
        },
      },
    });
    const sessions = new Map<string, SessionData>();
    const inMemory = makeCloudSession('hidr1', '444444', 'pid_4');
    inMemory.contactNames.set('5215599887766', 'Cliente');
    sessions.set('hidr1_444444', inMemory);
    const configsLoaded: string[] = [];
    initWithHydrationDb(db, sessions, configsLoaded);
    markSessionGone('hidr1', '333333');

    try {
      await loadCloudApiSessionsOnBoot();
    } finally {
      clearSessionGone('hidr1', '333333');
    }

    assert.deepEqual([...sessions.keys()].sort(), ['hidr1_111111', 'hidr1_444444']);
    assert.equal(sessions.get('hidr1_444444'), inMemory, 'la sesión viva conserva su estado en memoria');
    assert.equal(sessions.get('hidr1_111111')?.cloudApi?.phoneNumberId, 'pid_1');
    assert.deepEqual(configsLoaded, ['hidr1_111111']);
    assert.equal(db.calls.updates.length, 1);
    assert.equal(db.calls.updates[0].path, 'hidr1/111111');
    assert.equal(db.calls.updates[0].patch.status, 'connected');
    assert.equal(db.calls.updates[0].patch.session_key, 'hidr1_111111');
  });

  it('un phone_number_id desconocido recarga a lo sumo una vez cada 5 min', async () => {
    const db = makeHydrationDb({ hidr2: { sessions: {} } });
    initWithHydrationDb(db, new Map());

    await handleMetaWebhookPayload(webhookFor('pid_ajeno'));
    await handleMetaWebhookPayload(webhookFor('pid_ajeno'));
    await handleMetaWebhookPayload(webhookFor('otro_pid_ajeno'));

    assert.equal(db.calls.listDocuments, 1);
  });

  it('un webhook de una sesión que no alcanzó a hidratarse la encuentra al recargar', async () => {
    const db = makeHydrationDb({
      hidr3: { sessions: { '777777': { provider: 'cloud_api' } }, secrets: { '777777': cloudSecret('pid_7') } },
    });
    const sessions = new Map<string, SessionData>();
    initWithHydrationDb(db, sessions);

    await handleMetaWebhookPayload(webhookFor('pid_7'));

    assert.ok(sessions.has('hidr3_777777'));
    assert.equal(db.calls.listDocuments, 1);
  });

  it('el webhook ya no se resuelve por display_phone_number', async () => {
    const db = makeHydrationDb({ hidr4: { sessions: {} } });
    const sessions = new Map<string, SessionData>();
    sessions.set('hidr4_15551234567', makeCloudSession('hidr4', '15551234567', 'pid_real'));
    const received: any[] = [];
    initSessionSupervisor({ sessions, db, io: {} as any, startSession: async () => {} });
    initCloudApiService({
      db,
      sessions,
      onUpsertedMessage: async (_k, _a, _s, raw) => {
        received.push(raw);
      },
      loadAllSessionConfigs: async () => {},
    });

    await handleMetaWebhookPayload({
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          value: {
            messaging_product: 'whatsapp',
            metadata: { display_phone_number: '15551234567', phone_number_id: 'pid_falso' },
            messages: [{ id: 'wamid.forjado', from: '5215599887766', type: 'text', text: { body: 'hola' } }],
          },
        }],
      }],
    });

    assert.equal(received.length, 0);
  });
});

describe('subscribeAppToWaba (la app queda recibiendo los webhooks del número)', () => {
  const realFetch = globalThis.fetch;
  const params = { phoneNumberId: 'pid_1', wabaId: 'waba_1', accessToken: 'EAA-token', appSecret: 'secreto-A' };

  // Simula Graph: lista de números del WABA y respuesta del POST de suscripción.
  function stubGraph(opts: { numbers: string[]; subscribe?: Response }) {
    const calls: Array<{ method: string; url: URL }> = [];
    globalThis.fetch = (async (url: string, init?: RequestInit) => {
      const parsed = new URL(url);
      calls.push({ method: init?.method ?? 'GET', url: parsed });
      if (parsed.pathname.endsWith('/phone_numbers')) {
        return new Response(JSON.stringify({ data: opts.numbers.map((id) => ({ id })) }));
      }
      return opts.subscribe ?? new Response(JSON.stringify({ success: true }));
    }) as any;
    return calls;
  }

  it('comprueba que el número sea del WABA y suscribe la app, con appsecret_proof', async () => {
    const calls = stubGraph({ numbers: ['otro', 'pid_1'] });
    try {
      await subscribeAppToWaba(params);
      assert.deepEqual(calls.map((c) => `${c.method} ${c.url.pathname.replace(/^\/v[\d.]+/, '')}`), [
        'GET /waba_1/phone_numbers',
        'POST /waba_1/subscribed_apps',
      ]);
      const proof = appSecretProof('EAA-token', 'secreto-A');
      assert.ok(calls.every((c) => c.url.searchParams.get('appsecret_proof') === proof));
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('un Phone Number ID de otro WABA se rechaza sin suscribir nada', async () => {
    const calls = stubGraph({ numbers: ['otro'] });
    try {
      await assert.rejects(subscribeAppToWaba(params), (err: any) =>
        err.httpStatus === 400 && /no pertenece a ese WABA/.test(err.message),
      );
      assert.equal(calls.filter((c) => c.method === 'POST').length, 0);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('si Meta no deja suscribir, se explica en vez de dejar la sesión muda', async () => {
    stubGraph({
      numbers: ['pid_1'],
      subscribe: new Response(
        JSON.stringify({ error: { message: '(#200) Permissions error', type: 'OAuthException', code: 200 } }),
        { status: 403 },
      ),
    });
    try {
      await assert.rejects(subscribeAppToWaba(params), (err: any) =>
        err.httpStatus === 400 && /no dejó suscribir/.test(err.message) && /whatsapp_business_management/.test(err.message),
      );
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});

describe('estados de entrega (los acuses de Meta llegan desordenados)', () => {
  it('sólo avanzan: un delivered tardío no pisa un read', () => {
    assert.equal(isDeliveryStatusAdvance(undefined, 'sent'), true);
    assert.equal(isDeliveryStatusAdvance('sent', 'delivered'), true);
    assert.equal(isDeliveryStatusAdvance('delivered', 'read'), true);
    assert.equal(isDeliveryStatusAdvance('read', 'delivered'), false);
    assert.equal(isDeliveryStatusAdvance('delivered', 'sent'), false);
    assert.equal(isDeliveryStatusAdvance('sent', 'failed'), true);
    assert.equal(isDeliveryStatusAdvance('sent', 'estado_nuevo'), false);
  });

  it('el webhook aplica la regla sobre el doc del mensaje', async () => {
    const fakeDb = makeFakeDb();
    const sessions = new Map<string, SessionData>();
    sessions.set('acc1_15551234567', makeCloudSession('acc1', '15551234567', 'phone_id_999'));
    initCloudApiService({ db: fakeDb, sessions, onUpsertedMessage: async () => {}, loadAllSessionConfigs: async () => {} });

    const status = (s: string) => ({
      object: 'whatsapp_business_account',
      entry: [{ changes: [{ value: {
        messaging_product: 'whatsapp',
        metadata: { phone_number_id: 'phone_id_999' },
        statuses: [{ id: 'wamid.orden', status: s, recipient_id: '5215599887766' }],
      } }] }],
    });
    await handleMetaWebhookPayload(status('read'));
    await handleMetaWebhookPayload(status('delivered'));

    const doc = fakeDb.updatedDocs.get('whatsapp_sessions/chats/5215599887766/messages/wamid.orden');
    assert.equal(doc.deliveryStatus, 'read');
  });
});

describe('plantillas propias contra Graph', () => {
  const realFetch = globalThis.fetch;

  function setup() {
    const sessions = new Map<string, SessionData>();
    sessions.set('acc1_15551234567', makeCloudSession('acc1', '15551234567', 'phone_id_999'));
    initCloudApiService({ db: makeFakeDb(), sessions, onUpsertedMessage: async () => {}, loadAllSessionConfigs: async () => {} });
  }

  function stubGraph(handler: (url: URL, init?: RequestInit) => Response) {
    const calls: Array<{ method: string; url: URL; body?: any }> = [];
    globalThis.fetch = (async (url: string, init?: RequestInit) => {
      const parsed = new URL(url);
      calls.push({ method: init?.method ?? 'GET', url: parsed, body: init?.body ? JSON.parse(String(init.body)) : undefined });
      return handler(parsed, init);
    }) as any;
    return calls;
  }

  it('lee todas las páginas, no sólo las primeras 100', async () => {
    setup();
    const calls = stubGraph((url) => url.searchParams.get('after') === 'p2'
      ? new Response(JSON.stringify({ data: [{ id: '2', name: 'b', status: 'PENDING' }] }))
      : new Response(JSON.stringify({
        data: [{ id: '1', name: 'a', status: 'APPROVED' }],
        paging: { next: 'https://graph.facebook.com/v21.0/waba_test_123/message_templates?after=p2' },
      })));
    try {
      const list = await listMetaTemplates({ accountId: 'acc1', sessionId: '15551234567' });
      assert.deepEqual(list.map((t) => t.name), ['a', 'b']);
      assert.equal(calls.length, 2);
      assert.match(calls[0].url.searchParams.get('fields')!, /rejected_reason/);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('si Graph no reconoce un campo extra, lista igual con los básicos', async () => {
    setup();
    const calls = stubGraph((url) => /rejected_reason/.test(url.searchParams.get('fields') ?? '')
      ? new Response(JSON.stringify({ error: { code: 100, message: 'Tried accessing nonexisting field (rejected_reason)' } }), { status: 400 })
      : new Response(JSON.stringify({ data: [{ id: '1', name: 'a', status: 'APPROVED' }] })));
    try {
      const list = await listMetaTemplates({ accountId: 'acc1', sessionId: '15551234567' });
      assert.deepEqual(list.map((t) => t.name), ['a']);
      assert.equal(calls.length, 2);
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('crear manda el payload al WABA y devuelve la categoría que asignó Meta', async () => {
    setup();
    const calls = stubGraph(() => new Response(JSON.stringify({ id: '777', status: 'PENDING', category: 'MARKETING' })));
    try {
      const { draft } = validateTemplateDraft({
        name: 'aviso_pedido', language: 'es_MX', category: 'UTILITY',
        body: 'Hola {{nombre}}, tu pedido ya salió.', examples: { nombre: 'Ana' },
      });
      const created = await createMetaTemplate({ accountId: 'acc1', sessionId: '15551234567', draft: draft! });
      assert.deepEqual(created, { id: '777', status: 'PENDING', category: 'MARKETING' });
      assert.equal(calls[0].method, 'POST');
      assert.match(calls[0].url.pathname, /\/waba_test_123\/message_templates$/);
      assert.equal(calls[0].body.parameter_format, 'named');
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('eliminar borra sólo ese idioma: por hsm_id + name, nunca por name a secas', async () => {
    setup();
    const calls = stubGraph(() => new Response(JSON.stringify({ success: true })));
    try {
      await deleteMetaTemplate({ accountId: 'acc1', sessionId: '15551234567', templateId: '777', name: 'aviso_pedido' });
      assert.equal(calls[0].method, 'DELETE');
      assert.equal(calls[0].url.searchParams.get('hsm_id'), '777');
      assert.equal(calls[0].url.searchParams.get('name'), 'aviso_pedido');
    } finally {
      globalThis.fetch = realFetch;
    }
  });

  it('una sesión eliminada no administra plantillas', async () => {
    setup();
    markSessionGone('acc1', '15551234567');
    try {
      await assert.rejects(listMetaTemplates({ accountId: 'acc1', sessionId: '15551234567' }), (err: any) => err.httpStatus === 410);
    } finally {
      clearSessionGone('acc1', '15551234567');
    }
  });
});
