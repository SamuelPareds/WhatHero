// ============================================
// Confirmaciones de lectura ("marcar como leído")
//
// WhatHero es un dispositivo vinculado: todo mensaje que ingiere sigue contando
// como NO leído en el WhatsApp del teléfono hasta que alguien emita el recibo.
// Nadie lo emitía, así que la bandeja del teléfono crecía sin techo y dejaba de
// servir para nada.
//
// POLÍTICA: se marca leído SÓLO cuando respondemos — humano desde el CRM, IA,
// keyword rule, recordatorio, o el operador desde su propio celular — o cuando
// cierra el pendiente con "Listo". Un chat sin responder se queda no-leído a
// propósito. Así lo que sigue en negrita en el teléfono es exactamente lo que
// falta atender, incluidos los mensajes que WhatsApp nunca nos entregó a
// nosotros (los que sólo se pueden pescar desde el filtro "No leídos").
//
// `sock.readMessages()` respeta la privacidad de la cuenta sin que tengamos que
// preguntarla: si el usuario tiene las confirmaciones de lectura activadas manda
// 'read' (palomitas azules), si no manda 'read-self', que limpia el no-leído en
// los dispositivos propios sin avisarle al contacto. En ambos casos la bandeja
// del teléfono se limpia, así que la decisión no se expone en la UI.
// ============================================
import type { WAMessageKey } from '@whiskeysockets/baileys';
import type { SessionData } from '../types';
import { getAIConfig } from './firestoreService';

// Tope de llaves guardadas por chat. Un cliente que manda 200 mensajes sin
// respuesta no debe inflar la memoria: con las últimas 50 el recibo cubre de
// sobra lo que el operador va a leer, y WhatsApp limpia el chat igual.
const MAX_TRACKED_PER_CHAT = 50;

// Tope de chats en el registro. Un chat sin responder conserva sus llaves hasta
// que alguien le conteste, así que en una cuenta con mucho tráfico el Map
// crecería sin techo durante toda la vida del proceso. Al pasarse, soltamos el
// chat que entró primero: es el más viejo sin responder y el que menos
// probabilidad tiene de recibir respuesta ahora.
const MAX_TRACKED_CHATS = 2000;

// Registra un mensaje entrante como pendiente de confirmar. Se llama SIEMPRE,
// incluso con la función desactivada en la sesión: así, si el usuario la
// enciende, la primera respuesta ya arrastra lo que se acumuló mientras tanto.
export function trackUnreadMessage(
  session: SessionData,
  contactPhone: string,
  key: WAMessageKey,
): void {
  if (!key?.id) return;

  if (!session.unreadKeys.has(contactPhone) && session.unreadKeys.size >= MAX_TRACKED_CHATS) {
    // Un Map de JS itera en orden de inserción, así que el primero es el más
    // antiguo. Re-registrar un chat existente no lo mueve de lugar, con lo que
    // "antiguo" acá significa "visto por primera vez hace más tiempo".
    const oldest = session.unreadKeys.keys().next().value;
    if (oldest !== undefined) session.unreadKeys.delete(oldest);
  }

  const keys = session.unreadKeys.get(contactPhone) ?? [];
  keys.push(key);
  // Conservamos las más recientes: son las que el operador acaba de contestar.
  if (keys.length > MAX_TRACKED_PER_CHAT) {
    keys.splice(0, keys.length - MAX_TRACKED_PER_CHAT);
  }
  session.unreadKeys.set(contactPhone, keys);
}

// Un chat que se cierra (borrado, sesión caída) no deja llaves colgando.
export function forgetChatUnread(session: SessionData, contactPhone: string): void {
  session.unreadKeys.delete(contactPhone);
}

// Emite el recibo por todo lo pendiente de ese chat. Devuelve cuántos mensajes
// se confirmaron (0 si no había nada, que es el caso normal a partir del
// segundo chunk de una misma respuesta de la IA).
export async function markChatAsRead(
  session: SessionData,
  contactPhone: string,
  reason: string,
): Promise<number> {
  const keys = session.unreadKeys.get(contactPhone);
  if (!keys?.length) return 0;
  if (!session.sock) return 0;

  // Vaciamos ANTES del await: dos chunks que salen casi a la vez entrarían acá
  // en paralelo y mandarían el recibo dos veces.
  session.unreadKeys.delete(contactPhone);

  try {
    await session.sock.readMessages(keys);
    console.log(`[Read] ${keys.length} mensaje(s) marcados como leídos en ${contactPhone} (${reason})`);
    return keys.length;
  } catch (error) {
    // Devolvemos las llaves al registro para que el próximo envío reintente.
    // Un blip de red no debe dejar el chat no-leído para siempre en el teléfono.
    const current = session.unreadKeys.get(contactPhone) ?? [];
    session.unreadKeys.set(contactPhone, [...keys, ...current].slice(-MAX_TRACKED_PER_CHAT));
    console.error(`[Read] No se pudo marcar leído ${contactPhone} (${reason}):`, error);
    return 0;
  }
}

// Igual que markChatAsRead pero respetando el switch de la sesión.
// getAIConfig cachea el doc 60s, así que esto no agrega lecturas a Firestore.
export async function markChatAsReadIfEnabled(
  session: SessionData,
  accountId: string,
  contactPhone: string,
  reason: string,
): Promise<number> {
  if (!session.phoneNumber) return 0;
  // Salida temprana antes de tocar la config: la mayoría de los salientes no
  // tienen nada que confirmar (el segundo chunk de la IA, o el operador
  // mandando varios mensajes seguidos al mismo chat).
  if (!session.unreadKeys.get(contactPhone)?.length) return 0;

  try {
    const config = await getAIConfig(session, accountId);
    if (!config.markReadOnReply) return 0;
  } catch (error) {
    console.warn(`[Read] No se pudo leer la config de ${contactPhone}, omitiendo recibo:`, error);
    return 0;
  }
  return markChatAsRead(session, contactPhone, reason);
}
