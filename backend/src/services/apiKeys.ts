// ============================================
// Llaves del API pública: con qué se autentica un sistema externo (AgendaCool,
// el sistema de un cliente) para enviar plantillas desde una cuenta.
//
// Formato: `whk_<keyId>_<secreto>`. El keyId (16 hex) es el id del doc y no es
// secreto; el secreto (32 bytes) nunca se guarda: sólo su sha256. Con 256 bits
// aleatorios un hash rápido alcanza (no es una contraseña que se pueda adivinar).
//
// Viven en una colección raíz (`api_keys` / `api_keys_dev`) sin regla en
// firestore.rules: ningún cliente las lee, ni el owner. La app las administra
// por el backend (GET/POST /api-keys), sólo el owner.
//
// Ver CLAUDE.md, "🔑 API pública".
// ============================================
import admin from 'firebase-admin';
import { createHash, randomBytes, timingSafeEqual } from 'crypto';
import { ACCOUNTS_COLLECTION, API_KEYS_COLLECTION } from '../config/env';
import { PublicApiError } from './publicApiErrors';

const KEY_RE = /^whk_([0-9a-f]{16})_([A-Za-z0-9_-]{43})$/;
export const API_KEY_NAME_MAX = 60;
export const MAX_ACTIVE_KEYS_PER_ACCOUNT = 25;

export interface GeneratedApiKey {
  keyId: string;
  /** La llave completa: se muestra UNA vez y no se guarda. */
  key: string;
  secretHash: string;
  hint: string;
}

export function hashSecret(secret: string): string {
  return createHash('sha256').update(secret).digest('hex');
}

export function generateApiKey(): GeneratedApiKey {
  const keyId = randomBytes(8).toString('hex');
  const secret = randomBytes(32).toString('base64url');
  return { keyId, key: `whk_${keyId}_${secret}`, secretHash: hashSecret(secret), hint: keyHint(keyId, secret) };
}

/** Lo que la app muestra de una llave después de crearla. */
export function keyHint(keyId: string, secret: string): string {
  return `whk_${keyId.slice(0, 6)}…${secret.slice(-4)}`;
}

export function parseApiKey(raw: unknown): { keyId: string; secret: string } | null {
  if (typeof raw !== 'string') return null;
  const match = KEY_RE.exec(raw.trim());
  return match ? { keyId: match[1], secret: match[2] } : null;
}

export function secretMatches(secret: string, storedHash: unknown): boolean {
  if (typeof storedHash !== 'string' || !/^[0-9a-f]{64}$/.test(storedHash)) return false;
  return timingSafeEqual(Buffer.from(hashSecret(secret), 'hex'), Buffer.from(storedHash, 'hex'));
}

/**
 * Token bucket en memoria: `capacity` de ráfaga y `refillPerSecond` sostenido.
 * Vive en el proceso: un redeploy lo reinicia, y es aceptable para un límite
 * de abuso básico (Meta tiene además sus propios topes por número).
 */
export class TokenBucket {
  private readonly buckets = new Map<string, { tokens: number; at: number }>();

  constructor(
    private readonly capacity: number,
    private readonly refillPerSecond: number,
    private readonly now: () => number = Date.now,
  ) {}

  private tokensNow(id: string, now: number): number {
    const bucket = this.buckets.get(id);
    if (!bucket) return this.capacity;
    return Math.min(this.capacity, bucket.tokens + ((now - bucket.at) / 1000) * this.refillPerSecond);
  }

  /** Segundos hasta la próxima ficha, sin gastar ninguna; 0 si hay. */
  waitSeconds(id: string): number {
    const tokens = this.tokensNow(id, this.now());
    return tokens >= 1 ? 0 : Math.max(1, Math.ceil((1 - tokens) / this.refillPerSecond));
  }

  take(id: string): { ok: true } | { ok: false; retryAfterSeconds: number } {
    const now = this.now();
    const tokens = this.tokensNow(id, now);
    if (tokens < 1) {
      this.buckets.set(id, { tokens, at: now });
      return { ok: false, retryAfterSeconds: Math.max(1, Math.ceil((1 - tokens) / this.refillPerSecond)) };
    }
    this.buckets.set(id, { tokens: tokens - 1, at: now });
    if (this.buckets.size > 10_000) this.buckets.clear();
    return { ok: true };
  }
}

// Ráfaga de 20 y luego ~60 por minuto por llave. Un lote diario de cientos de
// contactos pasa sin problema si quien llama respeta el Retry-After.
const perKeyLimit = new TokenBucket(20, 1);
// Intentos con llaves inválidas por IP: frena a quien adivina antes de que cada
// intento cueste una lectura de Firestore.
const authFailures = new TokenBucket(20, 20 / 60);

// ---------------------------------------------------------------------------
// Verificar la llave de un request
// ---------------------------------------------------------------------------

export interface VerifiedApiKey {
  keyId: string;
  accountId: string;
  name: string;
  allSessions: boolean;
  sessionIds: string[];
}

interface KeyDoc {
  account_id: string;
  name: string;
  secret_hash: string;
  all_sessions?: boolean;
  session_ids?: string[];
  revoked_at?: unknown;
}

// Cache del doc 60 s (también los inexistentes). Revocar desde la app la
// invalida en el acto: el proceso es único.
const KEY_CACHE_TTL_MS = 60_000;
const keyCache = new Map<string, { doc: KeyDoc | null; expiresAt: number }>();

function keysCollection() {
  return admin.firestore().collection(API_KEYS_COLLECTION);
}

async function loadKeyDoc(keyId: string): Promise<KeyDoc | null> {
  const cached = keyCache.get(keyId);
  if (cached && cached.expiresAt > Date.now()) return cached.doc;
  const snap = await keysCollection().doc(keyId).get();
  const doc = snap.exists ? (snap.data() as KeyDoc) : null;
  if (keyCache.size > 5_000) keyCache.clear();
  keyCache.set(keyId, { doc, expiresAt: Date.now() + KEY_CACHE_TTL_MS });
  return doc;
}

function forgetCachedKey(keyId: string): void {
  keyCache.delete(keyId);
}

export function apiKeyAllowsSession(key: VerifiedApiKey, sessionId: string): boolean {
  return key.allSessions || key.sessionIds.includes(sessionId);
}

// `last_used_at` como mucho una vez por minuto por llave: es para que el owner
// sepa si una llave sigue en uso, no un registro de cada envío.
const TOUCH_EVERY_MS = 60_000;
const lastTouched = new Map<string, number>();

function touchApiKey(keyId: string): void {
  const now = Date.now();
  if (now - (lastTouched.get(keyId) ?? 0) < TOUCH_EVERY_MS) return;
  lastTouched.set(keyId, now);
  keysCollection()
    .doc(keyId)
    .update({ last_used_at: admin.firestore.FieldValue.serverTimestamp() })
    .catch((error) => console.warn(`[API] No se pudo anotar el uso de la llave ${keyId}:`, error));
}

/**
 * La llave del header `Authorization: Bearer whk_…`, ya verificada y dentro de
 * su límite. Lanza `unauthorized` o `rate_limited`. Nunca loguea la llave:
 * sólo su keyId.
 */
export async function authenticateApiRequest(authorization: string | undefined, ip: string): Promise<VerifiedApiKey> {
  // Antes de leer nada: una IP que ya agotó sus intentos fallidos no paga lecturas.
  const blockedFor = authFailures.waitSeconds(ip);
  if (blockedFor > 0) {
    throw new PublicApiError('rate_limited', 'Demasiados intentos con llaves inválidas desde esta IP.', {
      retryAfterSeconds: blockedFor,
    });
  }
  const unauthorized = () => {
    authFailures.take(ip);
    return new PublicApiError('unauthorized', 'Llave de API inválida o revocada. Va en el header Authorization: Bearer whk_…');
  };

  const match = /^Bearer\s+(.+)$/i.exec(authorization ?? '');
  const parsed = parseApiKey(match?.[1]);
  if (!parsed) throw unauthorized();

  let doc: KeyDoc | null;
  try {
    doc = await loadKeyDoc(parsed.keyId);
  } catch (error) {
    console.error(`[API] No se pudo leer la llave ${parsed.keyId}:`, error);
    throw new PublicApiError('internal_error', 'No pudimos verificar la llave. Reintenta en unos segundos.', { retryAfterSeconds: 10 });
  }
  if (!doc || doc.revoked_at || !secretMatches(parsed.secret, doc.secret_hash)) throw unauthorized();

  const limited = perKeyLimit.take(parsed.keyId);
  if (!limited.ok) {
    throw new PublicApiError('rate_limited', 'Demasiadas peticiones con esta llave. Respeta el Retry-After.', {
      retryAfterSeconds: limited.retryAfterSeconds,
    });
  }
  touchApiKey(parsed.keyId);
  return {
    keyId: parsed.keyId,
    accountId: doc.account_id,
    name: doc.name,
    allSessions: doc.all_sessions === true,
    sessionIds: Array.isArray(doc.session_ids) ? doc.session_ids : [],
  };
}

// ---------------------------------------------------------------------------
// Administración (sólo el owner, desde la app)
// ---------------------------------------------------------------------------

export class ApiKeyAdminError extends Error {
  constructor(message: string, readonly httpStatus = 400) {
    super(message);
    this.name = 'ApiKeyAdminError';
  }
}

export interface ApiKeySummary {
  keyId: string;
  name: string;
  hint: string;
  allSessions: boolean;
  sessionIds: string[];
  createdAt: string | null;
  lastUsedAt: string | null;
  revokedAt: string | null;
}

function iso(value: unknown): string | null {
  return value instanceof admin.firestore.Timestamp ? value.toDate().toISOString() : null;
}

function summarize(id: string, data: Record<string, any>): ApiKeySummary {
  return {
    keyId: id,
    name: String(data.name ?? ''),
    hint: String(data.hint ?? ''),
    allSessions: data.all_sessions === true,
    sessionIds: Array.isArray(data.session_ids) ? data.session_ids : [],
    createdAt: iso(data.created_at),
    lastUsedAt: iso(data.last_used_at),
    revokedAt: iso(data.revoked_at),
  };
}

/** Activas primero (las más nuevas arriba); las revocadas al final. */
export async function listApiKeys(accountId: string): Promise<ApiKeySummary[]> {
  const snap = await keysCollection().where('account_id', '==', accountId).get();
  return snap.docs
    .map((d) => summarize(d.id, d.data()))
    .sort((a, b) => {
      if (!!a.revokedAt !== !!b.revokedAt) return a.revokedAt ? 1 : -1;
      return (b.createdAt ?? '').localeCompare(a.createdAt ?? '');
    });
}

/**
 * Crea una llave y devuelve la llave completa UNA vez. Sin sesiones elegidas,
 * puede enviar desde todas las sesiones Cloud API de la cuenta (también las que
 * se conecten después). Las elegidas tienen que ser Cloud API y estar vivas.
 */
export async function createApiKey(params: {
  accountId: string;
  createdBy: string;
  name: unknown;
  allSessions: unknown;
  sessionIds: unknown;
}): Promise<{ key: string; summary: ApiKeySummary }> {
  const name = typeof params.name === 'string' ? params.name.replace(/\s+/g, ' ').trim() : '';
  if (!name) throw new ApiKeyAdminError('Ponle un nombre a la llave, como "AgendaCool".');
  if (name.length > API_KEY_NAME_MAX) throw new ApiKeyAdminError(`El nombre pasa de ${API_KEY_NAME_MAX} caracteres.`);

  const allSessions = params.allSessions !== false;
  const sessionIds = allSessions
    ? []
    : [...new Set(Array.isArray(params.sessionIds) ? params.sessionIds.map(String) : [])];
  if (!allSessions) {
    if (sessionIds.length === 0) throw new ApiKeyAdminError('Elige al menos una sesión.');
    if (sessionIds.some((id) => !/^\d{6,20}$/.test(id))) throw new ApiKeyAdminError('Sesión inválida.');
    const sessionsCol = admin.firestore().collection(ACCOUNTS_COLLECTION).doc(params.accountId).collection('whatsapp_sessions');
    const snaps = await admin.firestore().getAll(...sessionIds.map((id) => sessionsCol.doc(id)));
    const bad = snaps.find((s) => !s.exists || s.get('provider') !== 'cloud_api' || s.get('deleting_at'));
    if (bad) throw new ApiKeyAdminError(`La sesión ${bad.id} no es una sesión de WhatsApp Cloud API de esta cuenta.`);
  }

  const active = await keysCollection().where('account_id', '==', params.accountId).get();
  if (active.docs.filter((d) => !d.get('revoked_at')).length >= MAX_ACTIVE_KEYS_PER_ACCOUNT) {
    throw new ApiKeyAdminError(`Ya tienes ${MAX_ACTIVE_KEYS_PER_ACCOUNT} llaves activas: revoca alguna que ya no uses.`);
  }

  const generated = generateApiKey();
  const data = {
    account_id: params.accountId,
    name,
    secret_hash: generated.secretHash,
    hint: generated.hint,
    all_sessions: allSessions,
    session_ids: sessionIds,
    created_at: admin.firestore.Timestamp.now(),
    created_by: params.createdBy,
    last_used_at: null,
    revoked_at: null,
    revoked_by: null,
  };
  await keysCollection().doc(generated.keyId).create(data);
  forgetCachedKey(generated.keyId);
  console.log(`[API] Llave ${generated.keyId} ("${name}") creada en la cuenta ${params.accountId}.`);
  return { key: generated.key, summary: summarize(generated.keyId, data) };
}

/** Deja de funcionar en el acto. El doc se queda para que el owner vea cuándo se revocó. */
export async function revokeApiKey(accountId: string, keyId: unknown, revokedBy: string): Promise<void> {
  if (typeof keyId !== 'string' || !/^[0-9a-f]{16}$/.test(keyId)) throw new ApiKeyAdminError('Llave inválida.');
  const ref = keysCollection().doc(keyId);
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get('account_id') !== accountId) throw new ApiKeyAdminError('Esa llave no existe.', 404);
    if (snap.get('revoked_at')) return;
    tx.update(ref, { revoked_at: admin.firestore.FieldValue.serverTimestamp(), revoked_by: revokedBy });
  });
  forgetCachedKey(keyId);
  console.log(`[API] Llave ${keyId} revocada en la cuenta ${accountId}.`);
}

/**
 * Al eliminar una sesión, las llaves restringidas a ella la pierden: si el
 * número se volviera a vincular, la llave no debe heredar en silencio el envío
 * por la sesión nueva (mismo motivo que los permisos del equipo).
 */
export async function removeSessionFromApiKeys(accountId: string, sessionId: string): Promise<void> {
  const snap = await keysCollection().where('account_id', '==', accountId).get();
  const affected = snap.docs.filter((d) => (d.get('session_ids') ?? []).includes(sessionId));
  await Promise.all(
    affected.map((d) => d.ref.update({ session_ids: admin.firestore.FieldValue.arrayRemove(sessionId) })),
  );
  affected.forEach((d) => forgetCachedKey(d.id));
  if (affected.length > 0) console.log(`[Eliminar] ${sessionId}: quitada de ${affected.length} llave(s) de API.`);
}
