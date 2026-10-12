// ============================================
// Reintentar un envío del CRM no puede mandarlo dos veces.
//
// La app pinta cada mensaje del operador como burbuja local con un `tempId` y
// la da por fallida si en 25 s no llega el ack. Pero el ack se pierde sin que
// el envío falle: un socket que se cae entre el emit y la respuesta (lo típico
// en un celular) deja el mensaje enviado y la burbuja en rojo. Si el operador
// toca "Reintentar", el cliente lo recibía dos veces. Lo mismo si Baileys
// tardaba más que el timeout de la app.
//
// La clave es `uid:tempId`. El uid sale del handshake o del middleware, nunca
// del payload, así que nadie puede consultar los envíos de otro.
//
//   - En vuelo: el reintento recibe la MISMA promesa. No sale dos veces.
//   - Salió: durante 10 min el reintento recibe el mismo resultado, sin enviar.
//   - Falló: la entrada se borra para que el reintento sí reenvíe.
//
// Envuelve a performSendMessage COMPLETO a propósito: un reintento deduplicado
// no vuelve a hacer ceder a la IA, porque mataría el buffer de un mensaje que
// el cliente mandó después del envío original.
//
// Vive en memoria: un redeploy a mitad de un envío no queda cubierto.
// ============================================

export const SEND_DEDUPE_TTL_MS = 10 * 60_000;

// El tempId lo genera la app ('tmp-<µs>-<seq>'). Cualquier otra cosa no se
// deduplica ni se guarda en el doc del mensaje.
const TEMP_ID_MAX = 64;

export function validTempId(tempId: unknown): string | null {
  return typeof tempId === 'string' && tempId.length > 0 && tempId.length <= TEMP_ID_MAX
    ? tempId
    : null;
}

export function sendDedupeKey(uid: string, tempId: unknown): string | null {
  const id = validTempId(tempId);
  return id ? `${uid}:${id}` : null;
}

interface Entry {
  promise: Promise<unknown>;
  // undefined mientras está en vuelo: no vence hasta que se resuelva.
  expiresAt?: number;
}

export class SendDedupe {
  private readonly entries = new Map<string, Entry>();

  constructor(private readonly now: () => number = Date.now) {}

  run<T>(key: string | null, send: () => Promise<T>): Promise<T> {
    if (!key) return send();
    this.prune();

    const existing = this.entries.get(key);
    if (existing) return existing.promise as Promise<T>;

    const entry: Entry = { promise: Promise.resolve() };
    const promise = send().then(
      (result) => {
        entry.expiresAt = this.now() + SEND_DEDUPE_TTL_MS;
        return result;
      },
      (error) => {
        // Sólo si sigue siendo la nuestra.
        if (this.entries.get(key) === entry) this.entries.delete(key);
        throw error;
      },
    );
    entry.promise = promise;
    this.entries.set(key, entry);
    return promise;
  }

  get size(): number {
    return this.entries.size;
  }

  private prune(): void {
    const now = this.now();
    for (const [key, entry] of this.entries) {
      if (entry.expiresAt !== undefined && entry.expiresAt <= now) this.entries.delete(key);
    }
  }
}

export const sendDedupe = new SendDedupe();
