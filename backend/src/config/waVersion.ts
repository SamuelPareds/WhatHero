// Resolución de la versión de WhatsApp Web con la que hacemos el handshake.
//
// POR QUÉ EXISTE ESTE ARCHIVO
// El 28-jul-2026 se cayeron todas las sesiones de producción con
// `405 Connection Failure` y sin poder generar QR. Causa: WhatsApp dejó de
// aceptar la versión 2.3000.1035194821 y el backend la seguía usando.
//
// Esa versión venía de `fetchLatestBaileysVersion()`, que NO le pregunta a
// WhatsApp: hace fetch a un .ts en raw.githubusercontent.com y le saca la
// versión con un regex sobre la línea 7. Si el fetch falla, si GitHub sirve
// caché rancio o si alguien refactorea ese archivo, la función devuelve
// `{ version: <valor viejo empaquetado>, isLatest: false, error }` — o sea,
// falla en silencio y el llamador ni se entera si solo destructura `version`.
//
// Aquí invertimos las prioridades y, sobre todo, ponemos un piso: nunca
// aceptamos una versión más vieja que la última que verificamos a mano.

import { fetchLatestWaWebVersion, fetchLatestBaileysVersion, type WAVersion } from '@whiskeysockets/baileys';

// Piso de seguridad: última versión que probamos a mano contra los servidores
// de WhatsApp y que generó QR correctamente (verificada el 29-jul-2026).
// Cumple dos funciones: es el último fallback, y es el mínimo aceptable —
// cualquier fuente remota que devuelva algo MÁS VIEJO que esto se descarta.
// Ese descarte es justamente lo que habría evitado la caída del 28-jul.
//
// Al actualizarla, verifícala primero (debe generar QR, no dar 405).
export const WA_VERSION_FLOOR: WAVersion = [2, 3000, 1044017588];

// Cachear evita que una tormenta de reconexiones dispare N fetches remotos.
// El TTL corto tras un fallback existe para no quedarnos clavados una hora en
// el piso si las fuentes remotas se recuperan enseguida.
const CACHE_TTL_OK_MS = 60 * 60 * 1000;      // resolución remota buena: 1h
const CACHE_TTL_FALLBACK_MS = 5 * 60 * 1000; // caímos al piso: reintenta pronto

let cached: { version: WAVersion; expiresAt: number } | null = null;
let inFlight: Promise<WAVersion> | null = null;

const format = (v: WAVersion) => v.join('.');

/** Compara elemento por elemento: ¿`a` es >= `b`? */
function isAtLeast(a: WAVersion, b: WAVersion): boolean {
  for (let i = 0; i < 3; i++) {
    if (a[i] > b[i]) return true;
    if (a[i] < b[i]) return false;
  }
  return true; // iguales
}

/**
 * Lee WA_VERSION del entorno. Escape hatch manual: si WhatsApp vuelve a cortar
 * una versión, cambias esta env var en Railway y reinicias — sin tocar código
 * ni esperar a que Baileys publique su bump.
 *
 * Formato: "2.3000.1044017588". Se salta el piso a propósito: si la seteaste
 * a mano es porque sabes lo que haces (incluido bajar de versión a drede).
 */
function fromEnv(): WAVersion | null {
  const raw = process.env.WA_VERSION?.trim();
  if (!raw) return null;

  const parts = raw.split('.').map(Number);
  if (parts.length !== 3 || parts.some(n => !Number.isInteger(n) || n < 0)) {
    console.error(`[WA-Version] WA_VERSION="${raw}" no tiene formato válido (esperado "2.3000.1044017588"). Ignorada.`);
    return null;
  }

  const version = parts as WAVersion;
  if (!isAtLeast(version, WA_VERSION_FLOOR)) {
    console.warn(`[WA-Version] ⚠️ WA_VERSION=${format(version)} es más vieja que el piso ${format(WA_VERSION_FLOOR)}. Se respeta por ser override manual, pero WhatsApp podría rechazarla con 405.`);
  }
  return version;
}

/**
 * Envuelve las funciones de Baileys aplicando lo que ellas no hacen: tratar
 * `isLatest: false` como fallo (porque significa "no pude, toma este valor
 * empaquetado") y rechazar cualquier versión por debajo del piso.
 */
async function fromRemote(
  label: string,
  fetcher: () => Promise<{ version: WAVersion; isLatest: boolean; error?: unknown }>,
): Promise<WAVersion | null> {
  try {
    const { version, isLatest, error } = await fetcher();

    if (!isLatest) {
      const detail = error instanceof Error ? error.message : String(error ?? 'sin detalle');
      console.warn(`[WA-Version] ${label} no pudo resolver (${detail}). Descartada.`);
      return null;
    }
    if (!isAtLeast(version, WA_VERSION_FLOOR)) {
      console.warn(`[WA-Version] ${label} devolvió ${format(version)}, más vieja que el piso ${format(WA_VERSION_FLOOR)}. Descartada (probable caché rancio).`);
      return null;
    }

    return version;
  } catch (error) {
    console.warn(`[WA-Version] ${label} lanzó excepción:`, error);
    return null;
  }
}

/**
 * Devuelve la versión de WhatsApp Web a usar en `makeWASocket`.
 *
 * Orden de preferencia:
 *   1. `WA_VERSION` (override manual)
 *   2. la propia sw.js de web.whatsapp.com — la fuente de verdad real
 *   3. el pin de Baileys en GitHub — va segundo porque suele ir a la zaga
 *   4. `WA_VERSION_FLOOR` — constante verificada a mano
 *
 * Nunca lanza: en el peor caso devuelve el piso.
 */
export async function resolveWaVersion(): Promise<WAVersion> {
  if (cached && Date.now() < cached.expiresAt) return cached.version;
  if (inFlight) return inFlight;

  inFlight = (async () => {
    const override = fromEnv();
    if (override) {
      console.log(`[WA-Version] Usando ${format(override)} (override WA_VERSION)`);
      // Sin expiración: la env var no cambia sin reiniciar el proceso. Cachear
      // aquí además evita repetir el log en cada reconexión.
      cached = { version: override, expiresAt: Infinity };
      return override;
    }

    const fromWhatsApp = await fromRemote('web.whatsapp.com/sw.js', fetchLatestWaWebVersion);
    if (fromWhatsApp) {
      console.log(`[WA-Version] Usando ${format(fromWhatsApp)} (web.whatsapp.com)`);
      cached = { version: fromWhatsApp, expiresAt: Date.now() + CACHE_TTL_OK_MS };
      return fromWhatsApp;
    }

    const fromBaileys = await fromRemote('pin de Baileys (GitHub)', fetchLatestBaileysVersion);
    if (fromBaileys) {
      console.log(`[WA-Version] Usando ${format(fromBaileys)} (pin de Baileys)`);
      cached = { version: fromBaileys, expiresAt: Date.now() + CACHE_TTL_OK_MS };
      return fromBaileys;
    }

    console.warn(`[WA-Version] ⚠️ Ninguna fuente remota sirvió. Usando el piso ${format(WA_VERSION_FLOOR)}. Si empiezan los 405, actualiza WA_VERSION_FLOOR o setea WA_VERSION.`);
    cached = { version: WA_VERSION_FLOOR, expiresAt: Date.now() + CACHE_TTL_FALLBACK_MS };
    return WA_VERSION_FLOOR;
  })();

  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}
