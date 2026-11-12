// ============================================
// Campañas de seguimiento: la parte que no habla con nadie.
//
// El owner escribe una instrucción ("de los últimos 7 días, a los que
// preguntaron por microblading y no compraron, mándales…") y la IA la
// convierte en un plan. Este archivo es lo que el backend hace con ese plan
// sin depender de Firestore ni del LLM, para que se pueda probar:
//
//   - La IA NO hace aritmética de fechas. Devuelve "últimos 7 días" y aquí se
//     calculan los límites en la zona horaria de la sesión (resolvePeriod).
//     Un LLM que "sabe" qué día es hoy se equivoca de mes con facilidad.
//   - Lo que se descarta sin gastar IA (structuralSkip): grupos, opt-outs,
//     chats pendientes, conversaciones vivas y seguimientos recientes.
//   - El mensaje: `{nombre}` se llena al analizar; `{faltan_dias}` y
//     `{fecha_limite}` al ENVIAR, para que lo aprobado hoy y enviado mañana
//     diga los días de mañana (renderCampaignMessage).
//   - Los parsers de lo que devuelve la IA fallan cerrado: ante la duda, el
//     cliente NO entra a la campaña. Es mejor perder un seguimiento que
//     escribirle a quien no había que escribirle.
//
// Ver CLAUDE.md, "📣 Campañas de seguimiento".
// ============================================

export const MAX_PERIOD_DAYS = 90;
export const MAX_MESSAGE_LENGTH = 1000;
export const MAX_INSTRUCTION_LENGTH = 2000;
// Un chat con actividad reciente es una conversación viva, no un lead frío.
export const RECENT_ACTIVITY_MS = 12 * 60 * 60_000;
// A quien ya le escribimos un seguimiento no le mandamos otro tan pronto.
export const RECENT_FOLLOWUP_MS = 7 * 24 * 60 * 60_000;
// Una propuesta sin fecha límite vence a los 7 días: el borrador ya no
// responde a la conversación.
export const PROPOSAL_TTL_DAYS = 7;
// Cuánto se puede fijar una fecha límite hacia adelante.
export const MAX_DEADLINE_DAYS_AHEAD = 120;

// Variables que entiende el mensaje. Cualquier otra `{…}` saldría literal al
// cliente, así que se rechaza.
export const MESSAGE_VARIABLES = ['nombre', 'faltan_dias', 'fecha_limite'] as const;
const DATE_VARIABLES = ['faltan_dias', 'fecha_limite'];

export type PeriodSpec =
  | { kind: 'last_days'; days: number }
  | { kind: 'range'; from: string; to: string }
  | { kind: 'last_month' }
  | { kind: 'this_month' };

export interface ResolvedPeriod {
  start: Date;
  end: Date;
  // Días calendario (inclusive) en la zona de la sesión, para la tarjeta.
  fromDate: string;
  toDate: string;
  // El rango pedido superaba MAX_PERIOD_DAYS y se recortó.
  clamped: boolean;
}

export interface CampaignPlan {
  period: PeriodSpec;
  // A quién SÍ (criterio de inclusión), en palabras del owner.
  audience: string;
  // A quién NO. Se suma a las reglas de exclusión del seguimiento diario.
  exclusions: string;
  // Texto con variables. Ver MESSAGE_VARIABLES.
  message: string;
  // 'YYYY-MM-DD' en la zona de la sesión, o null.
  deadline: string | null;
  // true: la IA adapta el arranque a cada conversación sin tocar la oferta.
  adapt: boolean;
}

export type PlanMissing = 'period' | 'audience' | 'message' | 'deadline';

// ───────────────────────── Fechas en la zona de la sesión ─────────────────────────

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** Offset (pared − UTC) en ms para un instante, consciente de DST. */
export function tzOffsetMs(instant: Date, timezone: string): number {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone, hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const p: Record<string, string> = {};
  for (const part of dtf.formatToParts(instant)) p[part.type] = part.value;
  // 'en-US' h24 a veces emite '24' a medianoche.
  const hour = p.hour === '24' ? 0 : Number(p.hour);
  const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, hour, +p.minute, +p.second);
  return asUtc - Math.floor(instant.getTime() / 1000) * 1000;
}

/** Instante UTC de las 00:00 del día `dateStr` ('YYYY-MM-DD') en `timezone`. */
export function zonedMidnightUtc(dateStr: string, timezone: string): Date {
  const [y, m, d] = dateStr.split('-').map(Number);
  const wallAsUtc = Date.UTC(y, m - 1, d);
  // Dos pasadas: el offset correcto es el de la medianoche local, no el de la
  // medianoche UTC (que en América cae la tarde del día anterior).
  const guess = wallAsUtc - tzOffsetMs(new Date(wallAsUtc), timezone);
  return new Date(wallAsUtc - tzOffsetMs(new Date(guess), timezone));
}

/** 'YYYY-MM-DD' de `instant` en `timezone`. */
export function localDate(instant: Date, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(instant);
}

/** Suma días a un 'YYYY-MM-DD' sobre los componentes de fecha (sin DST). */
export function addDays(dateStr: string, days: number): string {
  const [y, m, d] = dateStr.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d) + days * 86_400_000);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
}

/** Días calendario de `from` a `to` (puede ser negativo). */
export function daysBetween(from: string, to: string): number {
  const [y1, m1, d1] = from.split('-').map(Number);
  const [y2, m2, d2] = to.split('-').map(Number);
  return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / 86_400_000);
}

export function isValidDate(value: unknown): value is string {
  if (typeof value !== 'string' || !DATE_RE.test(value)) return false;
  const [y, m, d] = value.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}

/**
 * Límites del periodo en la zona de la sesión. "Últimos 7 días" es desde las
 * 00:00 de hace 7 días hasta ahora: cubre 7 días completos más lo que va de
 * hoy, que es lo que una persona espera al decirlo. Un rango que termina hoy
 * o después se corta en "ahora".
 */
export function resolvePeriod(spec: PeriodSpec, now: Date, timezone: string): ResolvedPeriod {
  const today = localDate(now, timezone);
  let fromDate: string;
  let toDate: string;

  switch (spec.kind) {
    case 'last_days': {
      const days = Math.min(Math.max(Math.round(spec.days), 1), MAX_PERIOD_DAYS);
      fromDate = addDays(today, -days);
      toDate = today;
      break;
    }
    case 'this_month':
      fromDate = `${today.slice(0, 7)}-01`;
      toDate = today;
      break;
    case 'last_month': {
      const firstThis = `${today.slice(0, 7)}-01`;
      const lastPrev = addDays(firstThis, -1);
      fromDate = `${lastPrev.slice(0, 7)}-01`;
      toDate = lastPrev;
      break;
    }
    case 'range': {
      fromDate = spec.from;
      toDate = spec.to;
      if (daysBetween(fromDate, toDate) < 0) [fromDate, toDate] = [toDate, fromDate];
      if (daysBetween(toDate, today) < 0) toDate = today;
      break;
    }
  }

  // Nunca más de MAX_PERIOD_DAYS hacia atrás desde hoy: más es ruido viejo y
  // un lote que no termina.
  let clamped = false;
  const oldest = addDays(today, -MAX_PERIOD_DAYS);
  if (daysBetween(oldest, fromDate) < 0) {
    fromDate = oldest;
    clamped = true;
  }
  if (spec.kind === 'last_days' && (spec.days > MAX_PERIOD_DAYS || spec.days < 1)) clamped = true;

  const start = zonedMidnightUtc(fromDate, timezone);
  const endOfTo = zonedMidnightUtc(addDays(toDate, 1), timezone);
  const end = endOfTo.getTime() > now.getTime() ? now : endOfTo;
  return { start, end, fromDate, toDate, clamped };
}

// ───────────────────────── El mensaje ─────────────────────────

/** Variables `{…}` del texto que no entendemos (saldrían literales). */
export function unknownVariables(template: string): string[] {
  const found = new Set<string>();
  for (const m of template.matchAll(/\{([^{}\n]{0,40})\}/g)) {
    const name = m[1].trim();
    if (!(MESSAGE_VARIABLES as readonly string[]).includes(name)) found.add(m[1]);
  }
  return [...found];
}

/** `{ Nombre }` → `{nombre}`: el resto del código busca la forma exacta. */
export function canonicalizeVariables(template: string): string {
  return template.replace(/\{\s*([A-Za-z_]+)\s*\}/g, (whole, name: string) => {
    const lower = name.toLowerCase();
    return (MESSAGE_VARIABLES as readonly string[]).includes(lower) ? `{${lower}}` : whole;
  });
}

export function usesDateVariables(template: string): boolean {
  return DATE_VARIABLES.some((v) => template.includes(`{${v}}`));
}

/** Problemas que impiden usar el mensaje, en palabras para el owner. */
export function messageProblems(template: string, deadline: string | null): string[] {
  const problems: string[] = [];
  const text = template.trim();
  if (!text) problems.push('Falta el mensaje.');
  if (text.length > MAX_MESSAGE_LENGTH) problems.push(`El mensaje pasa de ${MAX_MESSAGE_LENGTH} caracteres.`);
  const unknown = unknownVariables(text);
  if (unknown.length) {
    problems.push(`No conozco ${unknown.map((u) => `{${u}}`).join(', ')}: saldría tal cual al cliente.`);
  }
  if (usesDateVariables(text) && !deadline) {
    problems.push('El mensaje cuenta los días que faltan: falta la fecha en que termina.');
  }
  return problems;
}

/**
 * Primer nombre usable de un contacto, o null. Un "nombre" que es un número,
 * un correo o sólo emojis no se usa: "Hola +52 55…" es peor que "Hola".
 */
export function firstName(contactName: unknown): string | null {
  if (typeof contactName !== 'string') return null;
  const raw = contactName.trim();
  if (!raw || raw.includes('@')) return null;
  const digits = raw.replace(/\D/g, '').length;
  if (digits >= 5) return null;
  for (const token of raw.split(/\s+/)) {
    const word = token.replace(/^[^\p{L}]+|[^\p{L}]+$/gu, '');
    if (word.length < 2 || !/^\p{L}+$/u.test(word)) continue;
    const lower = word.toLocaleLowerCase('es');
    return (lower[0].toLocaleUpperCase('es') + lower.slice(1)).slice(0, 20);
  }
  return null;
}

/**
 * Llena `{nombre}`. Sin nombre usable, lo quita sin dejar huecos:
 * "Hola {nombre}, faltan…" → "Hola, faltan…".
 */
export function fillName(template: string, contactName: unknown): string {
  const name = firstName(contactName);
  if (name) return template.replace(/\{\s*nombre\s*\}/g, name);
  let out = template.replace(/[ \t]*\{\s*nombre\s*\}/g, '');
  out = out.replace(/[ \t]+([,.!?;:])/g, '$1');
  out = out.replace(/^[,.;:]\s*/gm, '');
  out = out.replace(/[ \t]{2,}/g, ' ');
  return capitalizeFirst(out.trim());
}

function capitalizeFirst(text: string): string {
  const i = text.search(/\p{L}/u);
  if (i < 0) return text;
  return text.slice(0, i) + text[i].toLocaleUpperCase('es') + text.slice(i + 1);
}

const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio',
  'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];

/** "15 de noviembre". */
export function formatDayMonth(dateStr: string): string {
  const [, m, d] = dateStr.split('-').map(Number);
  return `${d} de ${MONTHS[m - 1]}`;
}

/** "Faltan 3 días" / "Falta 1 día" / "Hoy es el último día"; null si ya pasó. */
export function daysLeftPhrase(deadline: string, today: string): string | null {
  const left = daysBetween(today, deadline);
  if (left < 0) return null;
  if (left === 0) return 'Hoy es el último día';
  if (left === 1) return 'Falta 1 día';
  return `Faltan ${left} días`;
}

/**
 * Llena las variables de fecha. null = no se puede enviar (la fecha límite
 * ya pasó, o el texto cuenta días y no hay fecha).
 */
export function renderDateVariables(
  template: string,
  deadline: string | null,
  today: string,
): string | null {
  if (!usesDateVariables(template)) return template;
  if (!deadline) return null;
  const phrase = daysLeftPhrase(deadline, today);
  if (!phrase) return null;
  let out = template.replace(/\{\s*fecha_limite\s*\}/g, formatDayMonth(deadline));
  // A mitad de frase va en minúscula: "…, faltan 3 días para…".
  out = out.replace(/\{\s*faltan_dias\s*\}/g, (_m, offset: number, whole: string) => {
    const before = whole.slice(0, offset).trimEnd();
    const startsSentence = before === '' || /[.!?¡¿:\n]$/.test(before);
    return startsSentence ? phrase : phrase[0].toLocaleLowerCase('es') + phrase.slice(1);
  });
  return out;
}

/** El mensaje final para un contacto en una fecha. */
export function renderCampaignMessage(
  template: string,
  opts: { contactName: unknown; deadline: string | null; today: string },
): string | null {
  const dated = renderDateVariables(fillName(template, opts.contactName), opts.deadline, opts.today);
  return dated === null ? null : dated.trim();
}

/** Último día (inclusive) en que una propuesta se puede enviar. */
export function proposalLastDay(deadline: string | null, createdOn: string): string {
  const ttl = addDays(createdOn, PROPOSAL_TTL_DAYS);
  if (!deadline) return ttl;
  return daysBetween(deadline, ttl) < 0 ? ttl : deadline;
}

// ───────────────────────── Lo que devuelve la IA ─────────────────────────

/** Primer objeto JSON del texto (tolera ```json y texto alrededor). */
export function extractJsonObject(raw: string): Record<string, unknown> | null {
  if (typeof raw !== 'string') return null;
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(raw.slice(start, end + 1));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function str(value: unknown, max: number): string {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

export function parsePeriodSpec(value: unknown): PeriodSpec | null {
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  switch (v.kind) {
    case 'last_days': {
      const days = Number(v.days);
      return Number.isFinite(days) && days >= 1 ? { kind: 'last_days', days: Math.round(days) } : null;
    }
    case 'range':
      return isValidDate(v.from) && isValidDate(v.to) ? { kind: 'range', from: v.from, to: v.to } : null;
    case 'last_month':
      return { kind: 'last_month' };
    case 'this_month':
      return { kind: 'this_month' };
    default:
      return null;
  }
}

/**
 * Valida un plan (de la IA o editado por el owner en la tarjeta). Nunca lanza:
 * lo que falta o no sirve se devuelve en `missing` para que la app lo pida.
 */
export function normalizePlan(
  input: unknown,
  today: string,
): { plan: CampaignPlan; missing: PlanMissing[]; problems: string[] } {
  const v = (input && typeof input === 'object' ? input : {}) as Record<string, unknown>;
  const period = parsePeriodSpec(v.period);
  const audience = str(v.audience, 500);
  const exclusions = str(v.exclusions, 1000);
  const message = canonicalizeVariables(str(v.message, MAX_MESSAGE_LENGTH + 200));
  let deadline: string | null = isValidDate(v.deadline) ? v.deadline : null;
  const problems: string[] = [];
  if (deadline) {
    const ahead = daysBetween(today, deadline);
    if (ahead < 0) {
      problems.push(`La fecha límite (${formatDayMonth(deadline)}) ya pasó.`);
      deadline = null;
    } else if (ahead > MAX_DEADLINE_DAYS_AHEAD) {
      problems.push('La fecha límite está a más de 4 meses.');
      deadline = null;
    }
  }

  const missing: PlanMissing[] = [];
  if (!period) missing.push('period');
  if (!audience) missing.push('audience');
  if (!message) missing.push('message');
  if (message && usesDateVariables(message) && !deadline) missing.push('deadline');
  if (message) {
    // La fecha que falta ya está en `missing`; no la repetimos como problema.
    problems.push(...messageProblems(message, deadline).filter((p) => !p.includes('falta la fecha')));
  }

  return {
    plan: {
      period: period ?? { kind: 'last_days', days: 7 },
      audience,
      exclusions,
      message,
      deadline,
      adapt: v.adapt === true,
    },
    missing,
    problems,
  };
}

export interface CandidateDecision {
  match: boolean;
  reason: string;
  quote: string | null;
}

/** Decisión del clasificador sobre un chat. Sin parseo claro → no entra. */
export function parseCandidateJson(raw: string): CandidateDecision {
  const obj = extractJsonObject(raw);
  if (obj) {
    const match = obj.match === true || obj.match === 'true';
    return {
      match,
      reason: str(obj.reason, 300) || (match ? '(sin razón)' : '(no coincide)'),
      quote: str(obj.quote, 300) || null,
    };
  }
  const m = /"?match"?\s*[:=]\s*(true|false)/i.exec(raw || '');
  if (m && m[1].toLowerCase() === 'true') {
    return { match: true, reason: '(respuesta sin formato)', quote: null };
  }
  return { match: false, reason: `(respuesta ilegible) ${String(raw || '').slice(0, 120)}`, quote: null };
}

function normalizeForMatch(text: string): string {
  return text
    .normalize('NFD').replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

export interface ClientLine {
  text: string;
  at: number | null;
}

/**
 * La cita que da la IA tiene que existir en un mensaje del CLIENTE. Si no
 * está, se descarta la cita (el operador vería algo que nadie dijo); el
 * candidato sigue, porque la decisión puede ser buena aunque cite mal.
 */
export function verifyEvidence(quote: string | null, lines: ClientLine[]): ClientLine | null {
  if (!quote) return null;
  const q = normalizeForMatch(quote);
  if (q.length < 3) return null;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (normalizeForMatch(lines[i].text).includes(q)) {
      return { text: quote.trim().slice(0, 300), at: lines[i].at };
    }
  }
  return null;
}

/**
 * Un mensaje adaptado por la IA tiene que conservar lo que el owner escribió
 * que importa: las variables y cada cifra ("$200", "15"). Si pierde algo, se
 * usa el texto exacto.
 */
export function adaptedKeepsOffer(template: string, adapted: string): boolean {
  if (!adapted.trim() || adapted.length > MAX_MESSAGE_LENGTH) return false;
  if (unknownVariables(adapted).length) return false;
  for (const v of MESSAGE_VARIABLES) {
    if (template.includes(`{${v}}`) && !adapted.includes(`{${v}}`)) return false;
  }
  const numbers = template.match(/\$?\d[\d.,]*/g) ?? [];
  return numbers.every((n) => adapted.includes(n));
}

// ───────────────────────── Descartes sin IA ─────────────────────────

export type SkipReason =
  | 'group'
  | 'opted_out'
  | 'pending'
  | 'recent_activity'
  | 'recent_followup'
  | 'already_scheduled'
  | 'in_other_campaign'
  | 'no_history'
  | 'no_match'
  | 'ai_error';

/** Etiquetas para el resumen de la tarjeta. */
export const SKIP_LABELS: Record<SkipReason, string> = {
  group: 'Grupos',
  opted_out: 'Pidieron no recibir mensajes',
  pending: 'Esperan tu respuesta',
  recent_activity: 'Conversación activa hoy',
  recent_followup: 'Ya recibieron seguimiento esta semana',
  already_scheduled: 'Ya tienen un seguimiento programado',
  in_other_campaign: 'Están en otra campaña',
  no_history: 'Sin mensajes legibles',
  no_match: 'No coinciden con lo que pediste',
  ai_error: 'La IA no pudo revisarlos',
};

function toMillis(value: unknown): number | null {
  if (!value) return null;
  if (typeof value === 'number') return value;
  if (value instanceof Date) return value.getTime();
  const v = value as { toMillis?: () => number; _seconds?: number; seconds?: number };
  if (typeof v.toMillis === 'function') return v.toMillis();
  if (typeof v._seconds === 'number') return v._seconds * 1000;
  if (typeof v.seconds === 'number') return v.seconds * 1000;
  return null;
}

export interface ExistingProposal {
  status?: string;
  campaignId?: string | null;
}

// Estados en los que una propuesta está viva (alguien la va a revisar o enviar).
export const OPEN_PROPOSAL_STATUSES = ['pending', 'approved'] as const;

/**
 * ¿Se descarta este chat sin preguntarle a la IA? null = hay que revisarlo.
 * `chat` es el doc del chat; `existing`, su propuesta actual si la hay.
 */
export function structuralSkip(
  chatId: string,
  chat: Record<string, unknown>,
  existing: ExistingProposal | null,
  campaignId: string,
  now: number,
): SkipReason | null {
  const jid = typeof chat.remoteJid === 'string' ? chat.remoteJid : '';
  if (jid.endsWith('@g.us') || chatId.includes('-') || chatId.endsWith('@g.us')) return 'group';
  if (chat.followup_opt_out === true || chat.marketing_opt_out_at) return 'opted_out';
  // Un chat pendiente espera una RESPUESTA, no un seguimiento: mandarle la
  // promo encima de una pregunta sin contestar es lo peor que podemos hacer.
  const unresponded = Number(chat.unresponded_count ?? 0);
  if (unresponded > 0 || chat.marked_pending === true) return 'pending';
  const last = toMillis(chat.lastMessageTimestamp);
  if (last !== null && now - last < RECENT_ACTIVITY_MS) return 'recent_activity';
  const lastFollowup = toMillis(chat.followup_last_at);
  if (lastFollowup !== null && now - lastFollowup < RECENT_FOLLOWUP_MS) return 'recent_followup';
  if (existing?.status === 'approved' || existing?.status === 'sending' || existing?.status === 'in_doubt') {
    return 'already_scheduled';
  }
  if (existing?.status === 'pending' && existing.campaignId && existing.campaignId !== campaignId) {
    return 'in_other_campaign';
  }
  return null;
}

export { toMillis };

// ───────────────────────── Justo antes de enviar ─────────────────────────

export interface ProposalForSend {
  status?: string;
  messageTemplate?: string;
  editedText?: string | null;
  deadline?: string | null;
  lastDay?: string;
  chatLastMessageId?: string | null;
}

export type SendCheck =
  | { ok: true; text: string }
  | { ok: false; status: 'stale' | 'expired'; reason: string };

/**
 * ¿Sigue valiendo lo aprobado? Se pregunta dentro de la transacción que
 * reclama la propuesta, con el chat recién leído. Si la conversación se movió
 * desde que la IA la analizó (el cliente escribió, alguien contestó, salió un
 * recordatorio), el borrador ya no responde a lo que pasó y no se envía.
 */
export function checkSendable(
  p: ProposalForSend,
  chat: Record<string, unknown> | null,
  today: string,
): SendCheck {
  if (!chat) return { ok: false, status: 'stale', reason: 'chat_deleted' };
  if (chat.followup_opt_out === true || chat.marketing_opt_out_at) {
    return { ok: false, status: 'stale', reason: 'opted_out' };
  }
  if ((chat.lastMessageId ?? null) !== (p.chatLastMessageId ?? null)) {
    return { ok: false, status: 'stale', reason: 'conversation_moved' };
  }
  if (Number(chat.unresponded_count ?? 0) > 0 || chat.marked_pending === true) {
    return { ok: false, status: 'stale', reason: 'pending' };
  }
  if (p.lastDay && daysBetween(today, p.lastDay) < 0) {
    return { ok: false, status: 'expired', reason: 'expired' };
  }
  const edited = typeof p.editedText === 'string' ? p.editedText.trim() : '';
  const text = edited || renderDateVariables(p.messageTemplate ?? '', p.deadline ?? null, today);
  if (!text || !text.trim()) return { ok: false, status: 'expired', reason: 'expired' };
  return { ok: true, text: text.trim() };
}

/** Lo que el chat doc dice de su seguimiento (lo lee el chip "Seguimiento"). */
export function chatFollowupStatus(proposalStatus: string): string {
  switch (proposalStatus) {
    case 'pending': return 'queued';
    case 'approved':
    case 'sending': return 'scheduled';
    case 'sent':
    case 'handled':
    case 'in_doubt': return 'sent';
    case 'rejected': return 'dismissed';
    default: return proposalStatus; // stale, expired, cancelled, failed
  }
}
