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

// ============================================
// Tokenización para búsqueda de texto en mensajes.
//
// Firestore no soporta búsqueda full-text ni "contains" de substrings: solo
// igualdad, rangos y `array-contains`. Para poder buscar palabras dentro de los
// mensajes guardamos, junto a cada mensaje indexable, un array `searchTokens`
// con sus palabras normalizadas. La búsqueda se resuelve con
// `where('searchTokens', 'array-contains', palabra)`.
//
// Normalización (clave en español):
//   - minúsculas
//   - sin acentos: "está" → "esta", "ñ" → "n" (NFD + strip de diacríticos)
//   - split por todo lo que no sea letra/número
//   - dedupe y límite de seguridad (mensajes enormes no inflan el índice)
//
// Coincidencia por PALABRA COMPLETA: "factura" encuentra el mensaje, "fact" no.
// Las frases se resuelven en el cliente refinando sobre el campo `text`.
// ============================================

// Normaliza un texto a minúsculas sin acentos. Reutilizable para comparar el
// query del usuario contra `searchTokens` con el mismo criterio.
export function normalizeForSearch(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, ''); // quita diacríticos combinantes
}

// Máximo de tokens por mensaje. Cubre mensajes normales de sobra; trunca
// pastes gigantes para no inflar el doc del índice ni el costo de escritura.
const MAX_SEARCH_TOKENS = 80;

// Convierte el texto de un mensaje en un array de palabras únicas para indexar.
// Devuelve [] si el texto no tiene palabras indexables (media sin caption, etc).
export function buildSearchTokens(text: string | undefined | null): string[] {
  if (!text) return [];
  const normalized = normalizeForSearch(text);
  const seen = new Set<string>();
  for (const raw of normalized.split(/[^a-z0-9]+/)) {
    if (!raw) continue;
    // Tokens de 1 char (a, y, o) son ruido y disparan reads masivos; los
    // ignoramos. Números cortos sí pueden importar (ej. "10"), así que el
    // filtro es solo por longitud, no por tipo.
    if (raw.length < 2) continue;
    seen.add(raw);
    if (seen.size >= MAX_SEARCH_TOKENS) break;
  }
  return [...seen];
}
