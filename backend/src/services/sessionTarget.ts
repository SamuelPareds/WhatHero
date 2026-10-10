// A qué doc de Firestore le escribe una sesión de WhatsApp cuando conecta, y
// cómo una sesión cambia de número sin mover sus datos.
//
// El id del doc de sesión es el número con el que se vinculó POR PRIMERA VEZ.
// Cambiar de número NO copia nada: el número nuevo entra en el mismo doc,
// `phone_number` pasa a decir el nuevo y `number_history` guarda el anterior.
// Así reglas, permisos, presencia, pushes, Storage e índices siguen apuntando
// al mismo id. Copiar todo a `{nuevo}` y borrar el viejo se descartó: cada paso
// tenía una carrera con el tráfico en vivo y un modo de perder mensajes. Ver
// CLAUDE.md, "📲 Cambiar de número".
import admin from 'firebase-admin';
import { ACCOUNTS_COLLECTION } from '../config/env';

/** Lo que pidió quien escaneó el QR. Viaja en meta.json hasta el primer `open`. */
export interface LinkIntent {
  intoSessionId: string;       // doc al que se quiere vincular
  allowNumberChange: boolean;  // sólo el owner: aceptar un número distinto al del doc
  keepPrevious: boolean;       // dejar la línea anterior conectada, sólo recibiendo
  expectedPhone: string;       // `phone_number` del doc cuando se pidió el QR
}

export type RejectReason =
  | 'not_found'       // el doc del intent ya no existe
  | 'wrong_number'    // pidió reconectar el mismo número y escaneó otro
  | 'stale'           // el número del doc cambió mientras se escaneaba
  | 'has_history'     // el número nuevo ya tiene chats propios en WhatHero
  | 'in_use'          // el número nuevo ya es el de otra sesión
  | 'number_replaced' // ese número fue reemplazado en una sesión: no vuelve como línea aparte
  | 'deleting'        // alguno de los docs en juego se está eliminando (ver sessionDeletion.ts)
  | 'error';

export type TargetDecision =
  | { kind: 'relink' | 'new'; sessionId: string }
  | {
      kind: 'number_change';
      sessionId: string;
      fromPhone: string;
      // Doc `{nuevo}` vacío que dejó una vinculación anterior del número nuevo:
      // se borra para que no quede una tarjeta fantasma en la lista.
      dropEmptyDocOf: string | null;
    }
  | { kind: 'reject'; reason: RejectReason; sessionId?: string };

export interface DocFacts {
  exists: boolean;
  phone?: string;     // campo `phone_number`
  hasChats?: boolean; // sólo se consulta cuando importa
}

export interface TargetFacts {
  linked: string;            // número realmente vinculado (sock.user.id)
  pinnedSessionId?: string;  // doc fijado en meta.json por un `open` anterior
  intent?: LinkIntent;
  intoDoc?: DocFacts;        // doc del intent
  ownDoc: DocFacts;          // doc cuyo id es `linked`
  adoptedBy: string[];       // otros docs (id ≠ linked) cuyo phone_number es `linked`
  deleting?: string[];       // de los docs leídos, los que son lápida (`deleting_at`)
}

export function defaultSessionAlias(phone: string): string {
  return `Sucursal - ${phone}`;
}

/**
 * La decisión, sin I/O. Las reglas viven en sessionTarget.test.ts.
 *
 * 1. Reconexión: el doc ya quedó fijado en el primer `open` → ese doc.
 * 2. Con intent (re-vincular una tarjeta o el asistente de cambio de número):
 *    mismo número → relink; otro número → cambio de número sólo si se pidió
 *    explícitamente y nada lo contradice.
 * 3. Vinculación normal: si el número vive en una sesión migrada, vuelve a
 *    ella; si es un número reemplazado, no puede volver como línea aparte
 *    (su id está ocupado por la sesión que ahora usa otro número).
 */
export function decideSessionTarget(f: TargetFacts): TargetDecision {
  if (f.pinnedSessionId) return { kind: 'relink', sessionId: f.pinnedSessionId };

  // Si cualquiera de los docs en juego se está eliminando, no se decide nada
  // hasta que termine: ni re-vincular, ni cambiar de número, ni "Agregar
  // número" con ese mismo número. Escribirle sería pelear con el borrado, que
  // se llevaría la sesión recién conectada.
  if (f.deleting && f.deleting.length > 0) {
    return { kind: 'reject', reason: 'deleting', sessionId: f.deleting[0] };
  }

  // El doc `{linked}` es "suyo" si sigue usando ese número. Si dice otro, es
  // una sesión que cambió de número y sólo conserva el id.
  const ownIsNatural = f.ownDoc.exists && (f.ownDoc.phone ?? f.linked) === f.linked;

  if (f.intent) {
    const into = f.intent.intoSessionId;
    if (!f.intoDoc?.exists) return { kind: 'reject', reason: 'not_found', sessionId: into };

    const intoPhone = f.intoDoc.phone ?? into;
    if (intoPhone === f.linked) return { kind: 'relink', sessionId: into };

    // Escanear otro número sin haberlo pedido nunca cambia el número de una
    // sesión: un QR leído con el teléfono equivocado no puede secuestrarla.
    if (!f.intent.allowNumberChange) return { kind: 'reject', reason: 'wrong_number', sessionId: into };
    if (intoPhone !== f.intent.expectedPhone) return { kind: 'reject', reason: 'stale', sessionId: into };
    if (f.adoptedBy.some((id) => id !== into)) return { kind: 'reject', reason: 'in_use', sessionId: into };
    // Juntar dos historiales es fase 2: si el número nuevo ya trabajó por su
    // cuenta, no lo mezclamos en silencio.
    if (ownIsNatural && f.ownDoc.hasChats) return { kind: 'reject', reason: 'has_history', sessionId: into };

    return {
      kind: 'number_change',
      sessionId: into,
      fromPhone: intoPhone,
      dropEmptyDocOf: ownIsNatural ? f.linked : null,
    };
  }

  if (f.adoptedBy.length > 0) return { kind: 'relink', sessionId: f.adoptedBy[0] };
  if (f.ownDoc.exists && !ownIsNatural) {
    return { kind: 'reject', reason: 'number_replaced', sessionId: f.linked };
  }
  return { kind: f.ownDoc.exists ? 'relink' : 'new', sessionId: f.linked };
}

// Automáticos que salen solos hacia muchos contactos. Un número recién
// estrenado que manda decenas de mensajes a gente que no lo tiene guardado es
// la firma que WhatsApp castiga con un bloqueo: al cambiar de número se pausan
// y el operador los reactiva cuando el número nuevo ya tenga unos días.
export const PAUSABLE_AUTOMATIONS = [
  { field: 'followup_enabled', name: 'followups' },
  { field: 'reminder_enabled', name: 'reminders' },
] as const;

/**
 * Lo que se escribe en el doc de sesión al cambiar de número. Pura: recibe el
 * doc ya leído dentro de la transacción.
 */
export function buildNumberChangePatch(
  current: Record<string, any>,
  fromPhone: string,
  linked: string,
  at: unknown,
  keepPreviousLine: boolean,
): { patch: Record<string, unknown>; pausedAutomations: string[] } {
  const pausedAutomations: string[] = [];
  const patch: Record<string, unknown> = { phone_number: linked };

  for (const automation of PAUSABLE_AUTOMATIONS) {
    if (current[automation.field] === true) {
      patch[automation.field] = false;
      pausedAutomations.push(automation.name);
    }
  }

  // El alias por defecto lleva el número adentro: con el viejo, la tarjeta
  // diría un número que ya no es. Un alias puesto por el operador se respeta.
  if (current.alias === defaultSessionAlias(fromPhone)) {
    patch.alias = defaultSessionAlias(linked);
  }

  const history = Array.isArray(current.number_history) ? current.number_history : [];
  patch.number_history = [...history, { phone: fromPhone, until: at }];

  // Líneas anteriores: la que se queda recibiendo entra; si el número nuevo
  // era una línea anterior (volver a un número), deja de serlo.
  const lines: Record<string, unknown> = { ...(current.previous_lines ?? {}) };
  delete lines[linked];
  if (keepPreviousLine) {
    lines[fromPhone] = { status: 'connected', since: at, last_sync: at };
  }
  patch.previous_lines = lines;

  patch.number_change = { from: fromPhone, to: linked, at, pausedAutomations };
  return { patch, pausedAutomations };
}

/** Último `until` de `number_history`, en epoch ms. */
export function lastNumberChangeMs(data: Record<string, any> | undefined): number | undefined {
  const history = Array.isArray(data?.number_history) ? data!.number_history : [];
  let latest: number | undefined;
  for (const entry of history) {
    const ms = entry?.until?.toMillis?.();
    if (typeof ms === 'number' && (latest === undefined || ms > latest)) latest = ms;
  }
  return latest;
}

function sessionsCollection(accountId: string) {
  return admin
    .firestore()
    .collection(ACCOUNTS_COLLECTION)
    .doc(accountId)
    .collection('whatsapp_sessions');
}

/** Las lecturas que alimentan a `decideSessionTarget`. Una reconexión no lee nada. */
export async function gatherTargetFacts(
  accountId: string,
  linked: string,
  pinnedSessionId: string | undefined,
  intent: LinkIntent | undefined,
): Promise<TargetFacts> {
  if (pinnedSessionId) {
    return { linked, pinnedSessionId, ownDoc: { exists: false }, adoptedBy: [] };
  }

  const col = sessionsCollection(accountId);
  const [ownSnap, byPhone, intoSnap] = await Promise.all([
    col.doc(linked).get(),
    col.where('phone_number', '==', linked).get(),
    intent ? col.doc(intent.intoSessionId).get() : Promise.resolve(null),
  ]);

  const ownPhone = ownSnap.data()?.phone_number as string | undefined;
  const deleting = [ownSnap, ...byPhone.docs, ...(intoSnap ? [intoSnap] : [])]
    .filter((snap) => snap.exists && snap.data()?.deleting_at)
    .map((snap) => snap.id);
  let hasChats = false;
  if (intent && ownSnap.exists && (ownPhone ?? linked) === linked) {
    hasChats = !(await ownSnap.ref.collection('chats').limit(1).get()).empty;
  }

  return {
    linked,
    intent,
    intoDoc: intoSnap
      ? { exists: intoSnap.exists, phone: intoSnap.data()?.phone_number as string | undefined }
      : undefined,
    ownDoc: { exists: ownSnap.exists, phone: ownPhone, hasChats },
    adoptedBy: byPhone.docs.map((d) => d.id).filter((id) => id !== linked),
    deleting: [...new Set(deleting)],
  };
}

export class NumberChangeError extends Error {
  constructor(readonly reason: RejectReason) {
    super(`number_change rechazado: ${reason}`);
  }
}

/**
 * Cambia el número de la sesión en una transacción. Vuelve a comprobar que el
 * doc siga diciendo `fromPhone`: entre la decisión y la escritura otro cambio
 * pudo ganarle.
 */
export async function applyNumberChange(
  accountId: string,
  sessionId: string,
  fromPhone: string,
  linked: string,
  keepPreviousLine: boolean,
): Promise<{ pausedAutomations: string[]; changedAtMs: number }> {
  const ref = sessionsCollection(accountId).doc(sessionId);
  return admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new NumberChangeError('not_found');
    const data = snap.data()!;
    if (data.deleting_at) throw new NumberChangeError('deleting');
    if ((data.phone_number ?? sessionId) !== fromPhone) throw new NumberChangeError('stale');

    const at = admin.firestore.Timestamp.now();
    const { patch, pausedAutomations } = buildNumberChangePatch(data, fromPhone, linked, at, keepPreviousLine);
    tx.update(ref, patch);
    return { pausedAutomations, changedAtMs: at.toMillis() };
  });
}
