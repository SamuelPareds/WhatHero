// Reglas de firestore.rules contra el emulador. Ver CLAUDE.md, "🔐 Listar sesiones".
//
// Para el owner casi todo pasa (`isOwner` corta los OR), así que una consulta
// mal armada sólo revienta con un miembro restringido. Aquí se prueba con los
// cinco tipos de usuario, y todo corre para `accounts` y `accounts_dev`: las
// reglas están duplicadas y no deben separarse.

import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  setLogLevel,
  updateDoc,
  where,
} from 'firebase/firestore';

// Cada assertFails hace que el SDK loguee su PERMISSION_DENIED como warning:
// sin esto, un fallo de verdad se pierde entre decenas de rechazos esperados.
setLogLevel('error');

const OWNER = 'owner';
const RESTRICTED = 'restringido'; // sólo S1
const FULL = 'total'; // access.allSessions
const LEGACY = 'legacy'; // miembro sin campo `access` → acceso total
const OUTSIDER = 'ajeno'; // miembro de otra cuenta

const S1 = '5215511111111';
const S2 = '5215522222222';
const TOMB = '5215533333333'; // lápida: se está eliminando

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-whathero',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});

after(() => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users', OWNER), {
      role: 'owner', ownedAccountId: OWNER, memberOfAccounts: [OWNER],
    });
    for (const uid of [RESTRICTED, FULL, LEGACY]) {
      await setDoc(doc(db, 'users', uid), {
        role: 'member', ownedAccountId: OWNER, memberOfAccounts: [OWNER],
      });
    }
    await setDoc(doc(db, 'users', OUTSIDER), {
      role: 'member', ownedAccountId: 'otra', memberOfAccounts: ['otra'],
    });

    for (const root of ['accounts', 'accounts_dev']) {
      const account = [root, OWNER];
      await setDoc(doc(db, ...account, 'members', RESTRICTED), {
        access: { allSessions: false, sessions: { [S1]: { allChats: true } } },
      });
      await setDoc(doc(db, ...account, 'members', FULL), {
        access: { allSessions: true, sessions: {} },
      });
      await setDoc(doc(db, ...account, 'members', LEGACY), { displayName: 'Legacy' });

      await setDoc(doc(db, ...account, 'whatsapp_sessions', S1), {
        status: 'connected', session_key: 'k1', allowedUids: [RESTRICTED],
      });
      await setDoc(doc(db, ...account, 'whatsapp_sessions', S2), {
        status: 'connected', session_key: 'k2', allowedUids: [],
      });
      await setDoc(doc(db, ...account, 'whatsapp_sessions', TOMB), {
        status: 'deleting', deleting_at: new Date(), allowedUids: [],
      });
      for (const sid of [S1, S2, TOMB]) {
        await setDoc(doc(db, ...account, 'whatsapp_sessions', sid, 'chats', 'c1'), { name: 'Cliente' });
      }
      await setDoc(doc(db, ...account, 'cloud_api_secrets', S1), { accessToken: 'EAA-secreto' });
    }
  });
});

const dbAs = (uid) => env.authenticatedContext(uid).firestore();

for (const root of ['accounts', 'accounts_dev']) {
  const sessions = (db) => collection(db, root, OWNER, 'whatsapp_sessions');
  const session = (db, sid) => doc(db, root, OWNER, 'whatsapp_sessions', sid);
  const chat = (db, sid, id = 'c1') => doc(db, root, OWNER, 'whatsapp_sessions', sid, 'chats', id);

  describe(`${root}: listar sesiones (las reglas no son filtros)`, () => {
    it('el restringido NO puede listar con un filtro que no sea allowedUids', async () => {
      // La consulta del SessionDispatcher que lo mandaba a la bienvenida.
      await assertFails(getDocs(query(sessions(dbAs(RESTRICTED)), where('status', '==', 'connected'))));
      await assertFails(getDocs(sessions(dbAs(RESTRICTED))));
    });

    it('el restringido lista con allowedUids array-contains y sólo ve las suyas', async () => {
      const snap = await assertSucceeds(
        getDocs(query(sessions(dbAs(RESTRICTED)), where('allowedUids', 'array-contains', RESTRICTED))),
      );
      assert.deepEqual(snap.docs.map((d) => d.id), [S1]);
    });

    it('owner, acceso total y legacy listan sin filtro', async () => {
      for (const uid of [OWNER, FULL, LEGACY]) {
        await assertSucceeds(getDocs(sessions(dbAs(uid))));
      }
    });

    it('alguien de otra cuenta no lista nada', async () => {
      await assertFails(getDocs(query(sessions(dbAs(OUTSIDER)), where('allowedUids', 'array-contains', OUTSIDER))));
      await assertFails(getDocs(sessions(dbAs(OUTSIDER))));
    });
  });

  describe(`${root}: acceso por sesión`, () => {
    it('el restringido lee su sesión y su subárbol, no los de otra', async () => {
      const db = dbAs(RESTRICTED);
      await assertSucceeds(getDoc(session(db, S1)));
      await assertSucceeds(getDoc(chat(db, S1)));
      await assertFails(getDoc(session(db, S2)));
      await assertFails(getDoc(chat(db, S2)));
    });

    it('el restringido escribe en su sesión, no en otra', async () => {
      const db = dbAs(RESTRICTED);
      await assertSucceeds(setDoc(chat(db, S1), { note: 'ok' }, { merge: true }));
      await assertFails(setDoc(chat(db, S2), { note: 'no' }, { merge: true }));
    });
  });

  describe(`${root}: eliminar una sesión (sólo el backend crea y borra)`, () => {
    it('nadie crea ni borra el doc de sesión desde el cliente', async () => {
      for (const uid of [OWNER, FULL]) {
        const db = dbAs(uid);
        await assertFails(deleteDoc(session(db, S1)));
        await assertFails(setDoc(session(db, '5215599999999'), { status: 'connected' }));
      }
    });

    it('se edita una sesión viva, pero nadie planta deleting_at', async () => {
      const db = dbAs(OWNER);
      await assertSucceeds(updateDoc(session(db, S1), { alias: 'Sucursal Centro' }));
      await assertFails(updateDoc(session(db, S1), { deleting_at: new Date() }));
    });

    it('una lápida no se edita ni se escribe su subárbol, pero se lee', async () => {
      const db = dbAs(OWNER);
      await assertFails(updateDoc(session(db, TOMB), { alias: 'x' }));
      await assertFails(setDoc(chat(db, TOMB, 'c2'), { name: 'Huérfano' }));
      await assertSucceeds(getDoc(chat(db, TOMB)));
    });
  });

  describe(`${root}: secretos de Cloud API (sólo el backend)`, () => {
    // El access token de Meta manda mensajes en nombre de la empresa: ningún
    // cliente lo lee, ni el owner. La app sólo ve `cloud_api_token_hint`.
    it('nadie lee, lista ni escribe cloud_api_secrets desde el cliente', async () => {
      for (const uid of [OWNER, RESTRICTED, FULL, LEGACY, OUTSIDER]) {
        const db = dbAs(uid);
        const secret = doc(db, root, OWNER, 'cloud_api_secrets', S1);
        await assertFails(getDoc(secret));
        await assertFails(getDocs(collection(db, root, OWNER, 'cloud_api_secrets')));
        await assertFails(setDoc(secret, { accessToken: 'robado' }));
      }
    });
  });

  describe(`${root}: miembros`, () => {
    it('un miembro lee la lista, pero no se puede dar permisos', async () => {
      const db = dbAs(RESTRICTED);
      await assertSucceeds(getDoc(doc(db, root, OWNER, 'members', FULL)));
      await assertFails(setDoc(doc(db, root, OWNER, 'members', RESTRICTED), {
        access: { allSessions: true, sessions: {} },
      }));
    });
  });
}

describe('users/{uid}', () => {
  it('cada quien lee sólo el suyo', async () => {
    const db = dbAs(RESTRICTED);
    await assertSucceeds(getDoc(doc(db, 'users', RESTRICTED)));
    await assertFails(getDoc(doc(db, 'users', OWNER)));
  });

  it('nadie edita su membresía desde el cliente', async () => {
    await assertFails(updateDoc(doc(dbAs(OUTSIDER), 'users', OUTSIDER), { memberOfAccounts: [OWNER] }));
  });

  it('el auto-bootstrap crea un owner de su propia cuenta y nada más', async () => {
    const owner = (uid) => ({
      role: 'owner', ownedAccountId: uid, memberOfAccounts: [uid], mustChangePassword: false,
    });
    await assertSucceeds(setDoc(doc(dbAs('nuevo'), 'users', 'nuevo'), owner('nuevo')));
    await assertFails(setDoc(doc(dbAs('intruso'), 'users', 'intruso'), {
      ...owner('intruso'), memberOfAccounts: [OWNER],
    }));
  });
});
