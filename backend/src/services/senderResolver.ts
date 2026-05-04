// Resolución del SenderInfo a partir del contexto de cada entry point.
//
// Para humanos autenticados (HTTP/socket), buscamos el displayName en
// users/{uid} y extraemos el primer nombre. Cacheamos por uid 5 min para
// evitar pegarle a Firestore en cada mensaje. Cuando el owner edita el
// displayName de un sub-user en el futuro, el cache expira y se refresca.
//
// Para IA / bot / WhatsApp directo no hace falta nada dinámico: son constantes.

import admin from 'firebase-admin';
import type { SenderInfo } from '../types';

const HUMAN_NAME_CACHE_TTL_MS = 5 * 60_000;
const humanNameCache = new Map<string, { name: string; expiresAt: number }>();

// Toma "Samuel Paredes" → "Samuel". Acepta nulos/vacíos y devuelve fallback.
function extractFirstName(displayName: string | null | undefined): string {
  if (!displayName) return 'Usuario';
  const trimmed = displayName.trim();
  if (!trimmed) return 'Usuario';
  return trimmed.split(/\s+/)[0];
}

export async function resolveHumanSender(uid: string): Promise<SenderInfo> {
  const cached = humanNameCache.get(uid);
  if (cached && cached.expiresAt > Date.now()) {
    return { type: 'human', name: cached.name, uid };
  }
  try {
    const snap = await admin.firestore().collection('users').doc(uid).get();
    const displayName = snap.exists ? (snap.data()?.displayName as string | null) : null;
    const name = extractFirstName(displayName);
    humanNameCache.set(uid, { name, expiresAt: Date.now() + HUMAN_NAME_CACHE_TTL_MS });
    return { type: 'human', name, uid };
  } catch (error) {
    console.warn(`[senderResolver] Error resolviendo displayName uid=${uid}:`, error);
    // Fail-soft: si falla la lectura, igual tagueamos como humano genérico
    // para no perder el envío. No cacheamos el fallback.
    return { type: 'human', name: 'Usuario', uid };
  }
}

// Constantes reutilizables para los tres senders no-humanos-app.
export const AI_SENDER: SenderInfo = { type: 'ai', name: 'ai' };
export const BOT_SENDER: SenderInfo = { type: 'bot', name: 'bot' };
export const WHATSAPP_SENDER: SenderInfo = { type: 'human', name: 'WhatsApp' };
