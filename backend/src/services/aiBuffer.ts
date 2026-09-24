// ============================================
// El buffer de la IA: junta la ráfaga de mensajes del cliente y dispara UNA
// respuesta tras `delayMs` de silencio ("esperando…").
//
// Vivía como closure dentro de startSession, imposible de testear, y sus
// carreras hacían que la IA contestara DESPUÉS de que un humano ya había
// respondido. Tres reglas lo impiden, y las fijan los tests:
//
//   1. Un buffer sólo se borra a sí mismo. El timer de un buffer viejo borraba
//      del mapa a cualquiera: si el cliente escribía mientras la IA procesaba,
//      el buffer nuevo quedaba huérfano con su timer armado. La respuesta
//      humana ya no lo encontraba, no lo cancelaba, y la IA disparaba igual.
//   2. Un timer cuyo buffer ya no está en el mapa no hace nada. Cubre cualquier
//      huérfano, venga de donde venga (cesión al humano, media bloqueada,
//      reemplazo por uno nuevo).
//   3. Un buffer que ya está respondiendo no recibe mensajes: el siguiente abre
//      uno nuevo. Antes el mensaje se empujaba también al array que el ciclo en
//      vuelo estaba usando, y los pendientes se contaban dos veces.
//
// Mientras un operador tiene texto escrito en el chat (presencia del equipo),
// el buffer no dispara: la IA cede el turno y re-chequea cada 3 s. Retoma sola
// cuando el operador envía (la IA se cancela), borra, sale del chat o pasan
// 3 min sin tocar la app. Sólo aplica a "esperando…": un ciclo que ya está
// pensando o respondiendo sigue su curso.
// ============================================
import { aiStateKey, type AiLifecycleState } from './aiStateRegistry';

export const AI_COMPOSING_RECHECK_MS = 3_000;

export interface AiBufferContext {
  accountId: string;
  sessionKey: string;
  contactPhone: string;
}

export interface AiBufferDeps {
  emitAiState(
    accountId: string,
    sessionKey: string,
    contactPhone: string,
    state: AiLifecycleState,
    expectedRespondAt?: number,
  ): unknown;
  cancelCycle(sessionKey: string, contactPhone: string): boolean;
  hasState(sessionKey: string, contactPhone: string): boolean;
  /** ¿Algún operador tiene texto escrito en ese chat? */
  isComposing(ctx: AiBufferContext): boolean;
  now?(): number;
}

interface PendingBurst {
  messages: string[];
  timeout: ReturnType<typeof setTimeout> | null;
  // true desde que el timer entregó la ráfaga a la IA.
  responded: boolean;
}

export class AiBuffers {
  private buffers = new Map<string, PendingBurst>();

  constructor(private readonly deps: AiBufferDeps) {}

  /**
   * Llega un mensaje del cliente: arma (o re-arma) la espera. `fire` se
   * construye con el contexto del ÚLTIMO mensaje, y recibe una copia de la
   * ráfaga completa.
   */
  push(
    ctx: AiBufferContext,
    text: string,
    delayMs: number,
    fire: (messages: string[]) => Promise<void>,
  ): void {
    const key = aiStateKey(ctx.sessionKey, ctx.contactPhone);
    let buffer = this.buffers.get(key);
    if (!buffer || buffer.responded) {
      buffer = { messages: [], timeout: null, responded: false };
      this.buffers.set(key, buffer);
    }
    buffer.messages.push(text);
    if (buffer.timeout) clearTimeout(buffer.timeout);

    const now = this.deps.now?.() ?? Date.now();
    this.deps.emitAiState(ctx.accountId, ctx.sessionKey, ctx.contactPhone, 'buffering', now + delayMs);
    this.arm(key, ctx, buffer, delayMs, fire);
  }

  /**
   * Un humano respondió (o está por hacerlo): la IA suelta el chat. Borra la
   * espera, corta el ciclo en vuelo y apaga el indicador. Devuelve cuántos
   * mensajes del cliente soltó, para contarlos como pendientes si el envío
   * del humano termina fallando.
   */
  yieldToHuman(ctx: AiBufferContext, reason: string): number {
    const key = aiStateKey(ctx.sessionKey, ctx.contactPhone);
    const buffer = this.buffers.get(key);
    if (buffer?.timeout) clearTimeout(buffer.timeout);
    const hadBuffer = this.buffers.delete(key);
    const hadCycle = this.deps.cancelCycle(ctx.sessionKey, ctx.contactPhone);
    // Sin nada activo no hay nada que apagar: un `idle` por cada envío del
    // CRM sería ruido para toda la sala de la cuenta.
    if (hadBuffer || hadCycle || this.deps.hasState(ctx.sessionKey, ctx.contactPhone)) {
      console.log(`[AI] Cede ante un humano en ${ctx.contactPhone} (${reason})`);
      this.deps.emitAiState(ctx.accountId, ctx.sessionKey, ctx.contactPhone, 'idle');
    }
    return buffer?.messages.length ?? 0;
  }

  has(key: string): boolean {
    return this.buffers.has(key);
  }

  private arm(
    key: string,
    ctx: AiBufferContext,
    buffer: PendingBurst,
    delayMs: number,
    fire: (messages: string[]) => Promise<void>,
  ): void {
    buffer.timeout = setTimeout(() => {
      // Una promesa rechazada sin catch tumba el proceso en Node 20.
      this.run(key, ctx, buffer, fire).catch((error) => {
        console.error(`[Buffer] Error inesperado en la espera de ${ctx.contactPhone}:`, error);
      });
    }, delayMs);
  }

  private async run(
    key: string,
    ctx: AiBufferContext,
    buffer: PendingBurst,
    fire: (messages: string[]) => Promise<void>,
  ): Promise<void> {
    // Regla 2: huérfano → nada.
    if (this.buffers.get(key) !== buffer) return;

    // Un operador está escribiendo en este chat: la IA espera su turno. El
    // chequeo es síncrono a propósito; un await acá reabriría la ventana de
    // huérfanos.
    if (this.deps.isComposing(ctx)) {
      this.arm(key, ctx, buffer, AI_COMPOSING_RECHECK_MS, fire);
      return;
    }

    buffer.responded = true;
    try {
      await fire([...buffer.messages]);
    } catch (error) {
      console.error(`[Buffer] Error procesando la ráfaga de ${ctx.contactPhone}:`, error);
      // `fire` no llegó a soltar el indicador: si nadie lo tomó, lo apagamos.
      if (this.buffers.get(key) === buffer) {
        this.deps.emitAiState(ctx.accountId, ctx.sessionKey, ctx.contactPhone, 'idle');
      }
    } finally {
      // Regla 1: sólo nos borramos a nosotros mismos.
      if (this.buffers.get(key) === buffer) this.buffers.delete(key);
    }
  }
}
