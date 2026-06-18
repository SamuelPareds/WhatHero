// ============================================
// Normalización de envoltorios de mensajes de WhatsApp.
//
// WhatsApp/Baileys envuelve el contenido real de un mensaje dentro de varios
// "sobres" según el modo del chat. El caso que más nos afecta:
//
//   - ephemeralMessage  → mensajes temporales (disappearing messages). TODO el
//                         contenido (conversation, extendedTextMessage, media,
//                         protocolMessage…) queda un nivel más adentro.
//   - viewOnceMessage / viewOnceMessageV2 / viewOnceMessageV2Extension →
//                         "ver una vez". Mismo patrón de anidamiento.
//
// Si no desempaquetamos, el parser lee `message.message.conversation` como
// undefined y se persiste un mensaje vacío (burbuja fantasma). Este helper
// devuelve una COPIA superficial del mensaje con `message.message` apuntando al
// contenido real, sin mutar el objeto original de Baileys.
// ============================================

// Claves de sobre que sólo contienen otro mensaje adentro (`.message`).
const WRAPPER_KEYS = [
  'ephemeralMessage',
  'viewOnceMessage',
  'viewOnceMessageV2',
  'viewOnceMessageV2Extension',
] as const;

// Desempaqueta recursivamente los sobres conocidos. El límite de profundidad
// es defensa anti-payload malicioso (un sobre dentro de otro sin fin).
export function unwrapMessageContent(message: any): any {
  if (!message?.message) return message;

  let content = message.message;
  let depth = 0;
  while (depth < 5) {
    const wrapperKey = WRAPPER_KEYS.find((k) => content?.[k]?.message);
    if (!wrapperKey) break;
    content = content[wrapperKey].message;
    depth++;
  }

  // Sin sobres: devolvemos el original tal cual (cero overhead).
  if (content === message.message) return message;

  // Copia superficial preservando key/messageTimestamp/etc.; sólo cambiamos
  // `.message` por el contenido desempaquetado.
  return { ...message, message: content };
}
