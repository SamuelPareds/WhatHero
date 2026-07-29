// Diagnóstico de la versión de WhatsApp Web.
//
//   npm run check:wa                  → qué versión resuelve hoy + prueba de conexión
//   npm run check:wa 2.3000.1044032412 → prueba una versión concreta antes de usarla
//
// La prueba de conexión es la única forma fiable de saber si WhatsApp acepta
// una versión: si genera QR, sirve; si da 405, está cortada.
// Ver WA_VERSION_GUIDE.md.

import makeWASocket, {
  useMultiFileAuthState,
  fetchLatestWaWebVersion,
  fetchLatestBaileysVersion,
  type WAVersion,
} from '@whiskeysockets/baileys';
import { pino } from 'pino';
import { rmSync, mkdtempSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { resolveWaVersion, WA_VERSION_FLOOR } from '../src/config/waVersion';

const fmt = (v: WAVersion) => v.join('.');

function parseArg(raw: string): WAVersion {
  const parts = raw.split('.').map(Number);
  if (parts.length !== 3 || parts.some(n => !Number.isInteger(n) || n < 0)) {
    console.error(`Versión inválida: "${raw}". Formato esperado: 2.3000.1044032412`);
    process.exit(1);
  }
  return parts as WAVersion;
}

/** Abre un socket desechable: ¿WhatsApp nos da QR o nos rechaza? */
function testConnection(version: WAVersion): Promise<boolean> {
  return new Promise((resolve) => {
    const dir = mkdtempSync(join(tmpdir(), 'wacheck-'));
    const cleanup = () => rmSync(dir, { recursive: true, force: true });

    useMultiFileAuthState(dir).then(({ state, saveCreds }) => {
      const sock = makeWASocket({
        version,
        auth: state,
        logger: pino({ level: 'silent' }) as any,
        browser: ['WhatHero', 'Chrome', '121.0.0'],
        printQRInTerminal: false,
      });
      sock.ev.on('creds.update', saveCreds);

      let settled = false;
      const finish = (ok: boolean, msg: string) => {
        if (settled) return;
        settled = true;
        console.log(msg);
        try { sock.end(undefined); } catch { /* el socket ya podía estar cerrado */ }
        cleanup();
        resolve(ok);
      };

      sock.ev.on('connection.update', (u) => {
        if (u.qr) finish(true, `   ✅ ACEPTADA — WhatsApp generó QR con ${fmt(version)}`);
        if (u.connection === 'close') {
          const code = (u.lastDisconnect?.error as any)?.output?.statusCode;
          finish(false, `   ❌ RECHAZADA — statusCode=${code}${code === 405 ? ' (versión cortada por WhatsApp)' : ''}`);
        }
      });

      setTimeout(() => finish(false, '   ⏱️ TIMEOUT — sin respuesta en 30s'), 30000);
    });
  });
}

async function main() {
  const target = process.argv[2] ? parseArg(process.argv[2]) : null;

  console.log('\n═══ Fuentes de versión ═══\n');

  const wa = await fetchLatestWaWebVersion();
  console.log(`  web.whatsapp.com   ${wa.isLatest ? fmt(wa.version as WAVersion) : '(falló)'}`);

  const bl = await fetchLatestBaileysVersion();
  console.log(`  pin de Baileys     ${bl.isLatest ? fmt(bl.version as WAVersion) : '(falló)'}`);

  console.log(`  WA_VERSION_FLOOR   ${fmt(WA_VERSION_FLOOR)}   (constante en src/config/waVersion.ts)`);
  console.log(`  WA_VERSION (env)   ${process.env.WA_VERSION || '(no seteada — normal)'}`);

  console.log('\n═══ Lo que usaría el backend ═══\n');
  const resolved = await resolveWaVersion();
  console.log(`  → ${fmt(resolved)}`);

  const toTest = target ?? resolved;
  console.log(`\n═══ Prueba de conexión con ${fmt(toTest)} ═══\n`);
  const ok = await testConnection(toTest);

  if (ok && target && !target.every((n, i) => n === resolved[i])) {
    console.log(`\n  Para usarla: setea WA_VERSION=${fmt(target)} en Railway y reinicia.`);
  }
  process.exit(ok ? 0 : 1);
}

main();
