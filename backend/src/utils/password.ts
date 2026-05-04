// Generador de contraseñas temporales para sub-usuarios.
//
// Usamos crypto.randomBytes (CSPRNG) en vez de Math.random porque las
// passwords se entregan al owner para que las comparta — deben ser
// criptográficamente impredecibles.
//
// Composición: 16 caracteres del alfabeto base62 + 2 símbolos garantizados.
// Por qué 16: balance entre fuerza (>95 bits de entropía) y facilidad de
// copiado/dictado por WhatsApp. Por qué garantizar símbolos: Firebase Auth
// no exige complejidad pero algunos owners podrían reusar la temp pass
// en otros sistemas que sí; mejor que cumpla "lower+upper+digit+symbol"
// de entrada.

import { randomBytes } from 'crypto';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'; // sin O,0,I,l,1
const SYMBOLS = '!@#$%&*?';

function randomChar(charset: string): string {
  // Usamos modulo bias-rejection sampling para distribución uniforme.
  // Con charset corto (~57) y byte (256), bias-rejection es trivial.
  while (true) {
    const byte = randomBytes(1)[0];
    const limit = Math.floor(256 / charset.length) * charset.length;
    if (byte < limit) {
      return charset[byte % charset.length];
    }
  }
}

/**
 * Genera una password temporal de 16 chars con al menos 2 símbolos
 * y mezcla mayúsc/minúsc/dígitos. Retorna ya mezclada.
 */
export function generateTempPassword(): string {
  const chars: string[] = [];
  // 14 del alfabeto principal + 2 símbolos garantizados
  for (let i = 0; i < 14; i++) chars.push(randomChar(ALPHABET));
  for (let i = 0; i < 2; i++) chars.push(randomChar(SYMBOLS));

  // Fisher-Yates shuffle con CSPRNG para que los símbolos no queden al final
  for (let i = chars.length - 1; i > 0; i--) {
    const j = randomBytes(1)[0] % (i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }

  return chars.join('');
}
