// Último estado de IA emitido por chat. Puro: sin io ni timers, testeable.
//
// Existe por dos razones:
//   1. Reenviar. `ai_state` se emite una sola vez por transición. Un cliente
//      que (re)conecta a mitad de un ciclo (celular que vuelve de segundo
//      plano, app abierta desde un push) no se enteraba de nada y el operador
//      contestaba encima de la IA. Al conectar se le manda la foto completa,
//      y un latido re-emite los estados vivos.
//   2. Saber de quién es el indicador. Cada emisión lleva un `seq` global. Un
//      ciclo que termina apaga el indicador SÓLO si la última emisión de ese
//      chat sigue siendo suya: si otro (un buffer nuevo, el humano) ya emitió
//      después, el indicador es de ese otro y no se toca.
//      El `seq` es global a propósito. Con uno por chat que se reinicia al
//      borrarse la entrada, un ciclo viejo podía coincidir con el número del
//      ciclo nuevo y apagarle el indicador.

export type AiLifecycleState = 'buffering' | 'thinking' | 'responding' | 'idle';

export interface AiStatePayload {
  sessionKey: string;
  contactPhone: string;
  state: AiLifecycleState;
  expectedRespondAt?: number;
}

interface Entry {
  accountId: string;
  payload: AiStatePayload;
  seq: number;
}

export function aiStateKey(sessionKey: string, contactPhone: string): string {
  return `${sessionKey}:${contactPhone}`;
}

export class AiStateRegistry {
  private entries = new Map<string, Entry>();
  private seq = 0;

  /** Registra una emisión. `idle` borra la entrada. Devuelve su `seq`. */
  apply(accountId: string, payload: AiStatePayload): number {
    const seq = ++this.seq;
    const key = aiStateKey(payload.sessionKey, payload.contactPhone);
    if (payload.state === 'idle') {
      this.entries.delete(key);
    } else {
      this.entries.set(key, { accountId, payload, seq });
    }
    return seq;
  }

  /** ¿La última emisión de este chat sigue siendo la del `seq` dado? */
  isOwner(key: string, seq: number): boolean {
    return this.entries.get(key)?.seq === seq;
  }

  has(key: string): boolean {
    return this.entries.has(key);
  }

  /** Estados activos de una cuenta, para quien acaba de conectarse. */
  snapshotFor(accountId: string): AiStatePayload[] {
    const out: AiStatePayload[] = [];
    for (const entry of this.entries.values()) {
      if (entry.accountId === accountId) out.push(entry.payload);
    }
    return out;
  }

  /**
   * Revisa cada estado contra la realidad. Los vivos se devuelven para
   * re-emitirlos (sin nuevo `seq`: re-emitir no es cambiar de dueño). Los
   * muertos se borran y se devuelven para emitirles `idle`.
   *
   * No hay tope de edad a propósito: la IA puede esperar indefinidamente a un
   * operador que está escribiendo, y un tope inventaría un `idle` falso
   * mientras el buffer sigue armado. Decide `isLive`, no el reloj.
   */
  sweep(isLive: (key: string, state: AiLifecycleState) => boolean): {
    reemit: Entry[];
    dead: Entry[];
  } {
    const reemit: Entry[] = [];
    const dead: Entry[] = [];
    for (const [key, entry] of this.entries) {
      if (isLive(key, entry.payload.state)) {
        reemit.push(entry);
      } else {
        this.entries.delete(key);
        dead.push(entry);
      }
    }
    return { reemit, dead };
  }

  get size(): number {
    return this.entries.size;
  }
}
