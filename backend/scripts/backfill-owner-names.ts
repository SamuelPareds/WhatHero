// Recupera el nombre de los owners que se registraron con el registro roto
// (04-may al 12-nov-2026). Ver CLAUDE.md, "🆕 Registro".
//
//   npx tsx scripts/backfill-owner-names.ts          → sólo lista a quién le falta (no escribe)
//   npx tsx scripts/backfill-owner-names.ts --apply  → copia el nombre del perfil de Auth
//
// Sin `displayName` en users/{uid}, el owner aparece "Sin nombre" en Miembros y
// sus mensajes salen firmados como "Usuario". La pantalla de registro guardaba
// el nombre en el perfil de Auth antes de fallar, así que de ahí se recupera.
//
// `users` es una sola colección para dev y prod (mismo proyecto Firebase):
// basta con correrlo una vez, con las credenciales de FIREBASE_CONFIG.

import 'dotenv/config';
import admin from 'firebase-admin';

const apply = process.argv.includes('--apply');

if (!process.env.FIREBASE_CONFIG) {
  console.error('Falta FIREBASE_CONFIG (el JSON de la cuenta de servicio).');
  process.exit(1);
}
admin.initializeApp({ credential: admin.credential.cert(JSON.parse(process.env.FIREBASE_CONFIG)) });

async function authName(uid: string): Promise<string | null> {
  try {
    return (await admin.auth().getUser(uid)).displayName?.trim() || null;
  } catch {
    return null; // usuario borrado de Auth
  }
}

async function main() {
  const owners = await admin.firestore().collection('users').where('role', '==', 'owner').get();
  const missing = owners.docs.filter((d) => !String(d.get('displayName') ?? '').trim());
  console.log(`${owners.size} owners, ${missing.length} sin nombre en users/{uid}.\n`);

  let fixed = 0;
  for (const d of missing) {
    const name = await authName(d.id);
    const created = d.get('createdAt')?.toDate?.().toISOString().slice(0, 10) ?? '¿?';
    console.log(`${d.id}  ${d.get('email') ?? ''}  (${created})  →  ${name ?? 'Auth tampoco tiene nombre'}`);
    if (!apply || !name) continue;
    // Precondición: si alguien lo cambió desde que lo leímos, no se pisa.
    await d.ref.update({ displayName: name }, { lastUpdateTime: d.updateTime });
    fixed++;
  }

  console.log(apply
    ? `\n✅ ${fixed} nombres recuperados.`
    : '\nNo se escribió nada. Corre con --apply para guardar los nombres.');
}

main().then(() => process.exit(0), (e) => {
  console.error(e);
  process.exit(1);
});
