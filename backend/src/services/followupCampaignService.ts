// ============================================
// Campañas de seguimiento: Firestore, IA y WhatsApp.
//
// La parte pura (fechas, mensaje, descartes, validación) vive en
// followupCampaigns.ts; el ritmo del envío, en followupOutbox.ts. Aquí se
// juntan:
//
//   plan      → la IA convierte la instrucción en un plan. No escribe nada.
//   campaña   → se crea el doc y corre el análisis en segundo plano: por cada
//               chat del periodo, descartes sin IA → la IA decide si entra →
//               propuesta en `followup_queue/{chatId}` con el mensaje listo.
//   revisión  → aprobar / rechazar / editar (cualquiera con acceso a la sesión).
//   goteo     → lo aprobado sale espaciado (followupOutbox.ts).
//
// Reglas que no se pueden romper:
//   - Una propuesta por chat (el doc se llama como el chat): dos campañas no
//     le escriben dos veces al mismo cliente.
//   - Sólo el backend escribe la cola y las campañas (firestore.rules).
//   - Si la conversación se movió desde el análisis, la propuesta se cierra
//     sola y no se envía (closeOnActivity + checkSendable).
//   - Un envío sin respuesta queda `in_doubt` y no se reintenta nunca.
//
// Ver CLAUDE.md, "📣 Campañas de seguimiento".
// ============================================
import admin from 'firebase-admin';
import { generateMessageIDV2 } from '@whiskeysockets/baileys';
import type { SessionData, SenderInfo } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { getAIConfig } from './firestoreService';
import { isSessionGone } from './sessionSupervisor';
import {
  AiCredentials,
  AiError,
  AiProvider,
  buildTemporalContext,
  buildTranscript,
  completeText,
  DEFAULT_TIMEZONE,
  hasAiCredentials,
  normalizeHistory,
} from './aiService';
import {
  CampaignPlan,
  ClientLine,
  OPEN_PROPOSAL_STATUSES,
  PlanMissing,
  SkipReason,
  adaptedKeepsOffer,
  canonicalizeVariables,
  chatFollowupStatus,
  checkSendable,
  daysBetween,
  extractJsonObject,
  fillName,
  localDate,
  MAX_INSTRUCTION_LENGTH,
  normalizePlan,
  parseCandidateJson,
  proposalLastDay,
  renderCampaignMessage,
  renderDateVariables,
  resolvePeriod,
  structuralSkip,
  toMillis,
  verifyEvidence,
} from './followupCampaigns';
import { FollowupOutbox, OutboxStatus, SendResult } from './followupOutbox';

// Tope de chats revisados por campaña: acota el costo de IA y el tiempo.
export const MAX_CHATS_PER_CAMPAIGN = 600;
const PAGE_SIZE = 30;
const CONCURRENCY = 3;
// Mensajes de historial que lee la IA por chat. Alcanza para ver la pregunta
// de hace días y si después compró.
const HISTORY_LIMIT = 80;
// Tantos errores de IA seguidos = la llave no sirve o el proveedor cayó.
const MAX_CONSECUTIVE_AI_ERRORS = 8;
const SEND_TIMEOUT_MS = 30_000;
const IN_FLIGHT_WINDOW_MS = 2 * 60_000;
// Ventana de atención de Meta: sin mensaje del cliente en 24 h, Cloud API
// rechaza el texto libre.
const CLOUD_WINDOW_MS = 24 * 60 * 60_000;
const PLAN_RATE_LIMIT = 10;
const PLAN_RATE_WINDOW_MS = 60_000;

export const FOLLOWUP_SENDER: SenderInfo = { type: 'bot', name: 'Seguimiento', via: 'followup' };

type Db = FirebaseFirestore.Firestore;
type DocData = FirebaseFirestore.DocumentData;

function db(): Db {
  return admin.firestore();
}

function sessionRef(accountId: string, sessionId: string) {
  return db().collection(ACCOUNTS_COLLECTION).doc(accountId).collection('whatsapp_sessions').doc(sessionId);
}
const queueCol = (a: string, s: string) => sessionRef(a, s).collection('followup_queue');
const campaignsCol = (a: string, s: string) => sessionRef(a, s).collection('followup_campaigns');
const chatsCol = (a: string, s: string) => sessionRef(a, s).collection('chats');
const outboxRef = (a: string, s: string) => sessionRef(a, s).collection('followup_outbox').doc('state');

const laneKey = (accountId: string, sessionId: string) => `${accountId}/${sessionId}`;
function splitLaneKey(key: string): { accountId: string; sessionId: string } {
  const i = key.indexOf('/');
  return { accountId: key.slice(0, i), sessionId: key.slice(i + 1) };
}

const FieldValue = admin.firestore.FieldValue;
const now = () => FieldValue.serverTimestamp();

// ───────────────────────── Dependencias que pone index.ts ─────────────────────────

export interface CampaignServiceDeps {
  sessions: Map<string, SessionData>;
  // Envía un texto etiquetado con `sender` y el id que generamos nosotros.
  sendText(session: SessionData, chatId: string, text: string, sender: SenderInfo, messageId: string): Promise<void>;
}

let deps: CampaignServiceDeps | null = null;

export function initFollowupCampaigns(d: CampaignServiceDeps): void {
  deps = d;
}

function requireDeps(): CampaignServiceDeps {
  if (!deps) throw new Error('followupCampaignService sin inicializar');
  return deps;
}

/** La sesión principal viva de un doc, si está en memoria. */
export function findPrimarySession(accountId: string, sessionId: string): { key: string; session: SessionData } | null {
  for (const [key, session] of requireDeps().sessions) {
    if (session.accountId === accountId && session.sessionId === sessionId && session.role === 'primary') {
      return { key, session };
    }
  }
  return null;
}

export class CampaignError extends Error {
  constructor(public code: string, message: string, public http = 400) {
    super(message);
  }
}

// ───────────────────────── Zona horaria y credenciales ─────────────────────────

async function sessionDocData(accountId: string, sessionId: string): Promise<DocData> {
  const snap = await sessionRef(accountId, sessionId).get();
  if (!snap.exists || snap.get('deleting_at')) {
    throw new CampaignError('session_gone', 'Esta sesión ya no existe.', 410);
  }
  return snap.data() ?? {};
}

function timezoneOf(data: DocData): string {
  return data.followup_timezone || data.ai_active_hours?.timezone || DEFAULT_TIMEZONE;
}

async function credentialsFor(accountId: string, sessionId: string): Promise<AiCredentials> {
  // getAIConfig cachea en la sesión viva; sin ella (sesión caída) igual sirve:
  // el análisis no necesita WhatsApp, sólo la llave de IA.
  const live = findPrimarySession(accountId, sessionId)?.session ?? ({ sessionId } as SessionData);
  const config = await getAIConfig(live, accountId);
  return {
    apiKey: config.apiKey,
    provider: (config.provider || 'gemini') as AiProvider,
    model: config.model,
    openaiApiKey: config.openaiApiKey,
    deepseekApiKey: config.deepseekApiKey,
  };
}

// ───────────────────────── Propuestas abiertas en memoria ─────────────────────────
// Cada mensaje que entra o sale pregunta si su chat tiene una propuesta viva.
// Leer Firestore para eso costaría una lectura por mensaje; con el conjunto en
// memoria cuesta un `has`. Se llena con una consulta al arrancar la sesión.

const openProposals = new Map<string, Set<string>>();

function openSet(accountId: string, sessionId: string): Set<string> | undefined {
  return openProposals.get(laneKey(accountId, sessionId));
}

function noteOpen(accountId: string, sessionId: string, chatId: string, open: boolean): void {
  const set = openSet(accountId, sessionId);
  if (!set) return;
  if (open) set.add(chatId);
  else set.delete(chatId);
}

async function loadOpenProposals(accountId: string, sessionId: string): Promise<void> {
  const snap = await queueCol(accountId, sessionId).where('status', 'in', [...OPEN_PROPOSAL_STATUSES]).get();
  openProposals.set(laneKey(accountId, sessionId), new Set(snap.docs.map((d) => d.id)));
}

/**
 * Algo pasó en un chat (entró o salió un mensaje). Si tenía una propuesta
 * viva, se cierra: el borrador ya no responde a la conversación. Si escribió
 * el cliente queda `stale`; si contestó alguien del equipo (CRM o celular),
 * `handled`, y cuenta como el seguimiento de esa semana.
 * El eco del propio seguimiento no llega aquí (la propuesta ya está `sending`).
 */
export function closeOnActivity(
  accountId: string,
  sessionId: string,
  chatId: string,
  direction: 'incoming' | 'outgoing',
): void {
  const set = openSet(accountId, sessionId);
  if (!set?.has(chatId)) return;
  set.delete(chatId);
  const status = direction === 'incoming' ? 'stale' : 'handled';
  void db().runTransaction(async (tx) => {
    const ref = queueCol(accountId, sessionId).doc(chatId);
    const chatRef = chatsCol(accountId, sessionId).doc(chatId);
    const [snap, chat] = await Promise.all([tx.get(ref), tx.get(chatRef)]);
    if (!snap.exists || !(OPEN_PROPOSAL_STATUSES as readonly string[]).includes(snap.get('status'))) return;
    tx.update(ref, {
      status,
      closedReason: direction === 'incoming' ? 'client_wrote' : 'team_replied',
      updatedAt: now(),
    });
    if (chat.exists) {
      tx.update(chatRef, {
        followup_status: chatFollowupStatus(status),
        ...(status === 'handled' && {
          followup_last_at: now(),
          followup_count: FieldValue.increment(1),
        }),
      });
    }
  }).catch((error) => console.warn(`[Seguimiento] No se pudo cerrar la propuesta de ${chatId}:`, error));
}

// ───────────────────────── Escribir una propuesta ─────────────────────────

export interface ProposalInput {
  chatId: string;
  contactName: string | null;
  source: 'campaign' | 'daily';
  campaignId: string | null;
  messageTemplate: string;
  deadline: string | null;
  lastDay: string;
  reason: string;
  evidence: { text: string; at: number | null } | null;
  // `lastMessageId` del chat cuando se leyó para el análisis. Si cambió antes
  // de escribir, la IA decidió sobre una conversación vieja.
  expectedLastMessageId: string | null;
  today: string;
}

export type WriteResult = 'written' | 'already_scheduled' | 'in_other_campaign' | 'moved' | 'gone';

export async function writeProposal(accountId: string, sessionId: string, p: ProposalInput): Promise<WriteResult> {
  if (isSessionGone(accountId, sessionId)) return 'gone';
  const ref = queueCol(accountId, sessionId).doc(p.chatId);
  const chatRef = chatsCol(accountId, sessionId).doc(p.chatId);
  const result = await db().runTransaction(async (tx): Promise<WriteResult> => {
    const [existing, chat] = await Promise.all([tx.get(ref), tx.get(chatRef)]);
    if (!chat.exists) return 'gone';
    if ((chat.get('lastMessageId') ?? null) !== p.expectedLastMessageId) return 'moved';
    const status = existing.get('status') as string | undefined;
    if (status === 'approved' || status === 'sending' || status === 'in_doubt') return 'already_scheduled';
    const existingCampaign = (existing.get('campaignId') as string | null | undefined) ?? null;
    if (status === 'pending' && existingCampaign && existingCampaign !== p.campaignId) return 'in_other_campaign';
    // La misma campaña retomada tras un reinicio vuelve a pasar por la página
    // que estaba a medias: lo que el owner ya rechazó o se envió no renace.
    if (p.campaignId && existingCampaign === p.campaignId && status && status !== 'pending') return 'already_scheduled';

    const draft = renderDateVariables(p.messageTemplate, p.deadline, p.today) ?? p.messageTemplate;
    // `set` sin merge a propósito: una propuesta nueva no hereda el texto
    // editado, el messageId ni el error de la anterior.
    tx.set(ref, {
      chatId: p.chatId,
      contactName: p.contactName,
      source: p.source,
      campaignId: p.campaignId,
      messageTemplate: p.messageTemplate,
      // El borrador de hoy. Lo precarga el composer (envío a mano desde el chat).
      draftMessage: draft,
      editedText: null,
      deadline: p.deadline,
      lastDay: p.lastDay,
      reason: p.reason,
      evidence: p.evidence,
      chatLastMessageId: p.expectedLastMessageId,
      chatLastMessageAt: chat.get('lastMessageTimestamp') ?? null,
      status: 'pending',
      createdAt: now(),
      updatedAt: now(),
    });
    tx.update(chatRef, {
      followup_status: chatFollowupStatus('pending'),
      followup_last_reason: p.reason,
    });
    return 'written';
  });
  if (result === 'written') noteOpen(accountId, sessionId, p.chatId, true);
  return result;
}

// ───────────────────────── Revisión: aprobar, rechazar, editar ─────────────────────────

export type DecideAction = 'approve' | 'reject' | 'edit' | 'unapprove';

const TRANSITIONS: Record<DecideAction, string[]> = {
  approve: ['pending', 'failed'],
  reject: ['pending', 'approved', 'failed'],
  edit: ['pending', 'approved', 'failed'],
  unapprove: ['approved'],
};

function cloudWindowClosed(session: DocData, chat: DocData | undefined, nowMs: number): boolean {
  if (session.provider !== 'cloud_api') return false;
  const last = toMillis(chat?.lastIncomingTimestamp);
  return last === null || nowMs - last > CLOUD_WINDOW_MS;
}

async function decideOne(
  accountId: string,
  sessionId: string,
  chatId: string,
  action: DecideAction,
  uid: string,
  ctx: { session: DocData; today: string },
  text?: string,
): Promise<{ status: string } | { error: string }> {
  const ref = queueCol(accountId, sessionId).doc(chatId);
  const chatRef = chatsCol(accountId, sessionId).doc(chatId);
  return db().runTransaction(async (tx) => {
    const [snap, chat] = await Promise.all([tx.get(ref), tx.get(chatRef)]);
    if (!snap.exists) return { error: 'not_found' };
    const current = snap.get('status') as string;
    if (!TRANSITIONS[action].includes(current)) return { error: `already_${current}` };

    if (action === 'edit') {
      const edited = (text ?? '').trim();
      if (!edited) return { error: 'empty_text' };
      if (edited.length > 1000) return { error: 'too_long' };
      tx.update(ref, { editedText: edited, draftMessage: edited, updatedAt: now(), editedBy: uid });
      return { status: current };
    }

    let next = action === 'approve' ? 'approved' : action === 'reject' ? 'rejected' : 'pending';
    if (action === 'approve') {
      const lastDay = snap.get('lastDay') as string | undefined;
      if (lastDay && daysBetween(ctx.today, lastDay) < 0) next = 'expired';
      else if (!chat.exists) next = 'stale';
      else if (cloudWindowClosed(ctx.session, chat.data(), Date.now())) return { error: 'window_closed' };
    }
    tx.update(ref, {
      status: next,
      updatedAt: now(),
      ...(next === 'approved' && { approvedBy: uid, approvedAt: now(), error: null }),
      ...(next === 'rejected' && { decidedBy: uid }),
    });
    if (chat.exists) tx.update(chatRef, { followup_status: chatFollowupStatus(next) });
    return { status: next };
  });
}

export async function decideProposal(
  accountId: string,
  sessionId: string,
  chatId: string,
  action: DecideAction,
  uid: string,
  text?: string,
): Promise<{ status: string }> {
  const session = await sessionDocData(accountId, sessionId);
  const today = localDate(new Date(), timezoneOf(session));
  const result = await decideOne(accountId, sessionId, chatId, action, uid, { session, today }, text);
  if ('error' in result) {
    const messages: Record<string, string> = {
      not_found: 'Esta propuesta ya no existe.',
      empty_text: 'El mensaje no puede ir vacío.',
      too_long: 'El mensaje pasa de 1000 caracteres.',
      window_closed: 'Pasaron más de 24 h desde el último mensaje del cliente: por Cloud API sólo puede ir una plantilla aprobada.',
    };
    throw new CampaignError(result.error, messages[result.error] ?? 'Esta propuesta ya cambió. Recarga la lista.', 409);
  }
  noteOpen(accountId, sessionId, chatId, (OPEN_PROPOSAL_STATUSES as readonly string[]).includes(result.status));
  if (result.status === 'approved') outbox.kick(laneKey(accountId, sessionId));
  return result;
}

async function mapLimit<T>(items: T[], limit: number, fn: (item: T) => Promise<void>): Promise<void> {
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const item = items[i++];
      await fn(item);
    }
  });
  await Promise.all(workers);
}

/** "Aprobar todos": cada propuesta en su propia transacción, para no pisar
 *  una que se cerró sola (el cliente escribió) entre la lectura y la escritura. */
export async function approveAll(
  accountId: string,
  sessionId: string,
  campaignId: string,
  uid: string,
): Promise<{ approved: number; skipped: number }> {
  const session = await sessionDocData(accountId, sessionId);
  const today = localDate(new Date(), timezoneOf(session));
  const snap = await queueCol(accountId, sessionId).where('campaignId', '==', campaignId).get();
  const pending = snap.docs.filter((d) => d.get('status') === 'pending').map((d) => d.id);
  let approved = 0;
  let skipped = 0;
  await mapLimit(pending, 8, async (chatId) => {
    try {
      const r = await decideOne(accountId, sessionId, chatId, 'approve', uid, { session, today });
      if ('status' in r && r.status === 'approved') approved++;
      else skipped++;
      if ('status' in r) noteOpen(accountId, sessionId, chatId, r.status === 'approved');
    } catch (error) {
      skipped++;
      console.warn(`[Seguimiento] No se pudo aprobar ${chatId}:`, error);
    }
  });
  if (approved > 0) outbox.kick(laneKey(accountId, sessionId));
  return { approved, skipped };
}

// ───────────────────────── Chats que se borran o se mueven ─────────────────────────

/** /delete-chat: sin esto, el borrador renacía con el chat. */
export async function deleteProposalForChat(accountId: string, sessionId: string, chatId: string): Promise<void> {
  await queueCol(accountId, sessionId).doc(chatId).delete();
  noteOpen(accountId, sessionId, chatId, false);
}

/**
 * Consolidación LID → teléfono: la propuesta viva sigue al chat. Sólo las
 * vivas: el history sync emite cientos de mapeos y una lectura por cada uno
 * sería un desperdicio para chats que nunca tuvieron propuesta.
 */
export async function repointProposal(accountId: string, sessionId: string, fromChatId: string, toChatId: string): Promise<void> {
  if (fromChatId === toChatId || !openSet(accountId, sessionId)?.has(fromChatId)) return;
  const from = queueCol(accountId, sessionId).doc(fromChatId);
  const to = queueCol(accountId, sessionId).doc(toChatId);
  const moved = await db().runTransaction(async (tx) => {
    const [a, b] = await Promise.all([tx.get(from), tx.get(to)]);
    if (!a.exists) return false;
    if (!b.exists) tx.set(to, { ...a.data(), chatId: toChatId });
    tx.delete(from);
    return !b.exists;
  });
  noteOpen(accountId, sessionId, fromChatId, false);
  if (moved) noteOpen(accountId, sessionId, toChatId, true);
}

// ───────────────────────── La instrucción → un plan ─────────────────────────

const planCalls = new Map<string, number[]>();

function checkPlanRate(accountId: string): void {
  const t = Date.now();
  const recent = (planCalls.get(accountId) ?? []).filter((x) => t - x < PLAN_RATE_WINDOW_MS);
  if (recent.length >= PLAN_RATE_LIMIT) {
    throw new CampaignError('rate_limited', 'Demasiadas consultas seguidas. Espera un minuto.', 429);
  }
  recent.push(t);
  planCalls.set(accountId, recent);
}

const PLANNER_INSTRUCTIONS = `Eres el asistente de un CRM de WhatsApp. El dueño de un negocio te da una instrucción para una campaña de seguimiento: a quién escribirle y qué mensaje enviar. Conviértela en un plan.

Responde SOLO un objeto JSON, sin texto antes ni después:
{"period": …, "audience": "…", "exclusions": "…", "message": "…", "deadline": "YYYY-MM-DD" o null, "adapt": false}

- period: qué conversaciones revisar.
  · {"kind":"last_days","days":N} para "últimos N días", "esta semana" (7), "últimas dos semanas" (14), "último mes" o "últimos 30 días" (30).
  · {"kind":"last_month"} para "el mes pasado" (el mes calendario anterior).
  · {"kind":"this_month"} para "este mes".
  · {"kind":"range","from":"YYYY-MM-DD","to":"YYYY-MM-DD"} para fechas concretas.
  · null si no dice ningún periodo. NO lo inventes.
- audience: a quién SÍ, en una frase con sus palabras. Ej: "Preguntaron por el servicio de microblading". Vacío si no lo dice.
- exclusions: a quién NO, en una frase. Ej: "Ya compraron o agendaron su cita". "Y no compraron" va aquí. Vacío si no lo dice.
- message: el texto que el dueño quiere enviar, PALABRA POR PALABRA. Sólo puedes:
  · corregir faltas de ortografía evidentes ("liquitar" → "liquidar"), sin cambiar palabras, cifras ni el orden;
  · si el texto dice cuántos días faltan ("faltan x días", "quedan 3 días"), cambiar SÓLO esa parte por {faltan_dias}. Se rellena sola con "Faltan 3 días", "Falta 1 día" u "Hoy es el último día", así que la frase debe leerse bien con las tres;
  · si pide saludar por su nombre, usar {nombre}.
  No agregues saludos, emojis ni frases. Si no dio un texto, message = "" (no lo redactes tú).
- deadline: si dice cuándo termina la promoción o la oferta, esa fecha. Usa el contexto temporal para resolver "el viernes", "fin de mes", etc. null si no lo dice.
- adapt: true sólo si pide que cada mensaje se personalice o se adapte a cada cliente.`;

export interface PlanResponse {
  plan: CampaignPlan;
  missing: PlanMissing[];
  problems: string[];
  period: { fromDate: string; toDate: string; clamped: boolean };
  candidates: number;
  cap: number;
  preview: string | null;
  timezone: string;
  settingsExclusions: string;
}

async function countCandidates(accountId: string, sessionId: string, start: Date): Promise<number> {
  const agg = await chatsCol(accountId, sessionId)
    .where('lastMessageTimestamp', '>=', admin.firestore.Timestamp.fromDate(start))
    .count()
    .get();
  return agg.data().count;
}

/**
 * Con `instruction`, la IA arma el plan. Con `plan` (la tarjeta editada), sólo
 * se valida y se vuelve a contar. Nunca escribe nada.
 */
export async function planCampaign(
  accountId: string,
  sessionId: string,
  input: { instruction?: unknown; plan?: unknown },
): Promise<PlanResponse> {
  const session = await sessionDocData(accountId, sessionId);
  const tz = timezoneOf(session);
  const today = localDate(new Date(), tz);

  let rawPlan: unknown = input.plan;
  if (typeof input.instruction === 'string' && input.instruction.trim()) {
    const instruction = input.instruction.trim().slice(0, MAX_INSTRUCTION_LENGTH);
    checkPlanRate(accountId);
    const creds = await credentialsFor(accountId, sessionId);
    if (!hasAiCredentials(creds)) {
      throw new CampaignError('ai_credentials_missing', 'Configura la llave de IA en Ajustes › Asistente para usar campañas.', 409);
    }
    let raw: string;
    try {
      raw = await completeText(
        creds,
        `${PLANNER_INSTRUCTIONS}\n\n${buildTemporalContext(tz)}\nHoy es ${today} (formato YYYY-MM-DD).`,
        `### INSTRUCCIÓN DEL DUEÑO\n${instruction}`,
        { maxTokens: 800, temperature: 0 },
      );
    } catch (error) {
      const message = error instanceof AiError ? error.message : 'La IA no respondió.';
      throw new CampaignError('ai_failed', `No pude leer la instrucción: ${message}`, 502);
    }
    rawPlan = extractJsonObject(raw);
    if (!rawPlan) {
      console.warn(`[Seguimiento] Plan ilegible: ${raw.slice(0, 200)}`);
      throw new CampaignError('ai_unreadable', 'No entendí la instrucción. Prueba a escribirla con otras palabras.', 422);
    }
  }
  if (!rawPlan) throw new CampaignError('missing_instruction', 'Escribe a quién quieres darle seguimiento.');

  const { plan, missing, problems } = normalizePlan(rawPlan, today);
  const period = resolvePeriod(plan.period, new Date(), tz);
  const candidates = missing.includes('period') ? 0 : await countCandidates(accountId, sessionId, period.start);
  return {
    plan,
    missing,
    problems,
    period: { fromDate: period.fromDate, toDate: period.toDate, clamped: period.clamped },
    candidates,
    cap: MAX_CHATS_PER_CAMPAIGN,
    preview: plan.message
      ? renderCampaignMessage(plan.message, { contactName: 'Ana', deadline: plan.deadline, today })
      : null,
    timezone: tz,
    settingsExclusions: (session.followup_exclusion_prompt as string | undefined)?.trim() ?? '',
  };
}

// ───────────────────────── Crear, cancelar ─────────────────────────

export async function createCampaign(
  accountId: string,
  sessionId: string,
  uid: string,
  input: { instruction?: unknown; plan?: unknown },
): Promise<{ campaignId: string }> {
  const session = await sessionDocData(accountId, sessionId);
  const tz = timezoneOf(session);
  const nowDate = new Date();
  const today = localDate(nowDate, tz);
  const { plan, missing, problems } = normalizePlan(input.plan, today);
  if (missing.length || problems.length) {
    throw new CampaignError('invalid_plan', problems[0] ?? 'Faltan datos de la campaña.', 400);
  }
  const creds = await credentialsFor(accountId, sessionId);
  if (!hasAiCredentials(creds)) {
    throw new CampaignError('ai_credentials_missing', 'Configura la llave de IA en Ajustes › Asistente para usar campañas.', 409);
  }
  const running = await campaignsCol(accountId, sessionId).where('status', '==', 'analyzing').limit(1).get();
  if (!running.empty) {
    throw new CampaignError('already_analyzing', 'Ya hay una campaña revisando chats en esta sesión. Espera a que termine o cancélala.', 409);
  }

  const period = resolvePeriod(plan.period, nowDate, tz);
  const totalInPeriod = await countCandidates(accountId, sessionId, period.start);
  const ref = campaignsCol(accountId, sessionId).doc();
  await ref.create({
    instruction: typeof input.instruction === 'string' ? input.instruction.trim().slice(0, MAX_INSTRUCTION_LENGTH) : '',
    plan,
    timezone: tz,
    fromDate: period.fromDate,
    toDate: period.toDate,
    periodStart: admin.firestore.Timestamp.fromDate(period.start),
    periodEnd: admin.firestore.Timestamp.fromDate(period.end),
    lastDay: proposalLastDay(plan.deadline, today),
    status: 'analyzing',
    totalInPeriod,
    total: Math.min(totalInPeriod, MAX_CHATS_PER_CAMPAIGN),
    analyzed: 0,
    matched: 0,
    skipped: {},
    cursor: null,
    createdBy: uid,
    createdAt: now(),
    heartbeatAt: now(),
  });
  startAnalysis(accountId, sessionId, ref.id);
  return { campaignId: ref.id };
}

const runningAnalyses = new Set<string>();
const cancelledCampaigns = new Set<string>();

export async function cancelCampaign(
  accountId: string,
  sessionId: string,
  campaignId: string,
): Promise<{ cancelled: number }> {
  const ref = campaignsCol(accountId, sessionId).doc(campaignId);
  const snap = await ref.get();
  if (!snap.exists) throw new CampaignError('not_found', 'Esta campaña ya no existe.', 404);
  cancelledCampaigns.add(campaignId);
  if (snap.get('status') !== 'cancelled') {
    await ref.update({ status: 'cancelled', finishedAt: now(), heartbeatAt: now() });
  }
  // Lo pendiente y lo aprobado que todavía no salió se cancela. Lo enviado, enviado está.
  const queue = await queueCol(accountId, sessionId).where('campaignId', '==', campaignId).get();
  const open = queue.docs.filter((d) => (OPEN_PROPOSAL_STATUSES as readonly string[]).includes(d.get('status')));
  let cancelled = 0;
  await mapLimit(open, 8, async (d) => {
    const done = await db().runTransaction(async (tx) => {
      const fresh = await tx.get(d.ref);
      const chatRef = chatsCol(accountId, sessionId).doc(d.id);
      const chat = await tx.get(chatRef);
      if (!(OPEN_PROPOSAL_STATUSES as readonly string[]).includes(fresh.get('status'))) return false;
      tx.update(d.ref, { status: 'cancelled', updatedAt: now() });
      if (chat.exists) tx.update(chatRef, { followup_status: chatFollowupStatus('cancelled') });
      return true;
    }).catch(() => false);
    if (done) {
      cancelled++;
      noteOpen(accountId, sessionId, d.id, false);
    }
  });
  return { cancelled };
}

// ───────────────────────── El análisis ─────────────────────────

const CLASSIFIER_INSTRUCTIONS = `Eres un analista que revisa UNA conversación de WhatsApp entre un negocio ("Asistente") y un cliente ("Cliente") para decidir si ese cliente entra en una campaña de seguimiento que definió el dueño.

Cada mensaje trae su fecha entre corchetes.

GUÍAS FIJAS — NO entra si:
- Ya compró, pagó, agendó o confirmó (aunque haya sido después del periodo).
- Es una conversación personal o no comercial (familia, amistad, proveedor, spam, número equivocado).
- Pidió no ser contactado, rechazó la oferta o dijo claramente que no le interesa.
Ante la duda, NO entra. Es mejor no escribirle a alguien que escribirle a quien no había que escribirle.

Responde SOLO un objeto JSON, sin texto antes ni después:
{"match": true o false, "reason": "una frase breve en español", "quote": "fragmento textual corto (máx. 15 palabras) de un mensaje del CLIENTE que lo demuestre, o vacío"}`;

function classifierSystem(plan: CampaignPlan, fromDate: string, toDate: string, settingsExclusions: string, tz: string): string {
  return `${CLASSIFIER_INSTRUCTIONS}

### CAMPAÑA
- Periodo: del ${fromDate} al ${toDate}. El cliente tuvo que mostrar ese interés DENTRO del periodo (mira las fechas).
- Entra quien cumpla: ${plan.audience}
- No entra: ${plan.exclusions || '(sin exclusiones extra)'}
${settingsExclusions ? `- Reglas generales del negocio (tampoco entra): ${settingsExclusions}` : ''}

### CONTEXTO TEMPORAL
${buildTemporalContext(tz)}`;
}

const ADAPT_INSTRUCTIONS = `Vas a personalizar un mensaje de seguimiento de WhatsApp para UN cliente, a partir de su conversación con el negocio.

Reglas:
- Puedes agregar al inicio UNA frase corta y natural que conecte con lo que el cliente preguntó (ej. "Vi que te interesó el microblading 😊").
- El resto del mensaje base va TAL CUAL: la oferta, los precios, las fechas y las variables entre llaves ({faltan_dias}, {nombre}, {fecha_limite}) escritas igual, con sus llaves.
- No inventes precios, fechas, promociones ni datos que no estén en el mensaje base.
- No saludes dos veces. No firmes.
Responde SOLO con el mensaje final.`;

async function adaptMessage(creds: AiCredentials, template: string, transcript: string): Promise<string> {
  try {
    const adapted = (await completeText(
      creds,
      ADAPT_INSTRUCTIONS,
      `### MENSAJE BASE\n${template}\n\n### CONVERSACIÓN\n${transcript}`,
      { maxTokens: 600, temperature: 0.4 },
    )).trim().replace(/^["“]|["”]$/g, '');
    return adaptedKeepsOffer(template, adapted) ? canonicalizeVariables(adapted) : template;
  } catch {
    return template;
  }
}

interface AnalysisCtx {
  accountId: string;
  sessionId: string;
  campaignId: string;
  plan: CampaignPlan;
  creds: AiCredentials;
  tz: string;
  today: string;
  lastDay: string;
  fromDate: string;
  toDate: string;
  settingsExclusions: string;
}

type ChatOutcome = { matched: true } | { skip: SkipReason };

async function analyzeChat(
  ctx: AnalysisCtx,
  chatId: string,
  chat: DocData,
  existing: DocData | undefined,
): Promise<ChatOutcome> {
  const skip = structuralSkip(chatId, chat, existing ? { status: existing.status, campaignId: existing.campaignId } : null, ctx.campaignId, Date.now());
  if (skip) return { skip };

  const msgs = await chatsCol(ctx.accountId, ctx.sessionId).doc(chatId).collection('messages')
    .orderBy('timestamp', 'desc').limit(HISTORY_LIMIT).get();
  const raw = msgs.docs.reverse().map((d) => d.data());
  const history = normalizeHistory(raw, ctx.tz);
  if (history.length === 0) return { skip: 'no_history' };
  const transcript = buildTranscript(history);
  const clientLines: ClientLine[] = raw
    .filter((d) => !d.fromMe && typeof d.text === 'string' && d.text.trim())
    .map((d) => ({ text: d.text as string, at: toMillis(d.timestamp) }));

  let decision;
  try {
    const answer = await completeText(
      ctx.creds,
      classifierSystem(ctx.plan, ctx.fromDate, ctx.toDate, ctx.settingsExclusions, ctx.tz),
      `### CONVERSACIÓN\n${transcript}`,
      { maxTokens: 300, temperature: 0.1 },
    );
    decision = parseCandidateJson(answer);
  } catch (error) {
    console.warn(`[Seguimiento] La IA no pudo revisar ${chatId}:`, (error as Error).message);
    return { skip: 'ai_error' };
  }
  if (!decision.match) return { skip: 'no_match' };

  const base = ctx.plan.adapt ? await adaptMessage(ctx.creds, ctx.plan.message, transcript) : ctx.plan.message;
  const contactName = (chat.contactName as string | undefined) ?? null;
  const written = await writeProposal(ctx.accountId, ctx.sessionId, {
    chatId,
    contactName,
    source: 'campaign',
    campaignId: ctx.campaignId,
    messageTemplate: fillName(base, contactName),
    deadline: ctx.plan.deadline,
    lastDay: ctx.lastDay,
    reason: decision.reason,
    evidence: verifyEvidence(decision.quote, clientLines),
    expectedLastMessageId: (chat.lastMessageId as string | undefined) ?? null,
    today: ctx.today,
  });
  switch (written) {
    case 'written': return { matched: true };
    case 'already_scheduled': return { skip: 'already_scheduled' };
    case 'in_other_campaign': return { skip: 'in_other_campaign' };
    default: return { skip: 'recent_activity' };
  }
}

function startAnalysis(accountId: string, sessionId: string, campaignId: string): void {
  if (runningAnalyses.has(campaignId)) return;
  runningAnalyses.add(campaignId);
  runAnalysis(accountId, sessionId, campaignId)
    .catch(async (error) => {
      console.error(`[Seguimiento] La campaña ${campaignId} falló:`, error);
      await campaignsCol(accountId, sessionId).doc(campaignId)
        .update({ status: 'failed', error: 'Se interrumpió la revisión. Puedes lanzarla de nuevo.', finishedAt: now() })
        .catch(() => undefined);
    })
    .finally(() => runningAnalyses.delete(campaignId));
}

async function runAnalysis(accountId: string, sessionId: string, campaignId: string): Promise<void> {
  const ref = campaignsCol(accountId, sessionId).doc(campaignId);
  const snap = await ref.get();
  if (!snap.exists || snap.get('status') !== 'analyzing') return;
  const c = snap.data()!;
  const session = await sessionDocData(accountId, sessionId);
  const creds = await credentialsFor(accountId, sessionId);
  const tz: string = c.timezone || timezoneOf(session);
  const ctx: AnalysisCtx = {
    accountId, sessionId, campaignId,
    plan: c.plan as CampaignPlan,
    creds, tz,
    today: localDate(new Date(), tz),
    lastDay: c.lastDay,
    fromDate: c.fromDate,
    toDate: c.toDate,
    settingsExclusions: (session.followup_exclusion_prompt as string | undefined)?.trim() ?? '',
  };
  if (!hasAiCredentials(creds)) {
    await ref.update({ status: 'failed', error: 'Falta la llave de IA (Ajustes › Asistente).', finishedAt: now() });
    return;
  }

  let analyzed: number = c.analyzed ?? 0;
  let matched: number = c.matched ?? 0;
  const skipped: Record<string, number> = { ...(c.skipped ?? {}) };
  let cursorId: string | null = c.cursor?.id ?? null;
  let consecutiveAiErrors = 0;
  const total: number = c.total ?? MAX_CHATS_PER_CAMPAIGN;
  console.log(`[Seguimiento] Campaña ${campaignId} (${sessionId}): revisando ${total} chats desde ${c.fromDate}`);

  while (analyzed < total) {
    if (cancelledCampaigns.has(campaignId) || isSessionGone(accountId, sessionId)) return;
    let query = chatsCol(accountId, sessionId)
      .where('lastMessageTimestamp', '>=', c.periodStart)
      .orderBy('lastMessageTimestamp', 'desc')
      .limit(Math.min(PAGE_SIZE, total - analyzed));
    if (cursorId) {
      const cursorSnap = await chatsCol(accountId, sessionId).doc(cursorId).get();
      query = cursorSnap.exists
        ? query.startAfter(cursorSnap)
        : query.startAfter(c.cursor?.ts ?? c.periodStart);
    }
    const page = await query.get();
    if (page.empty) break;

    const queueRefs = page.docs.map((d) => queueCol(accountId, sessionId).doc(d.id));
    const existing = await db().getAll(...queueRefs);
    const existingById = new Map(existing.map((d) => [d.id, d.exists ? d.data() : undefined]));

    let aborted = false;
    await mapLimit(page.docs, CONCURRENCY, async (doc) => {
      if (aborted || cancelledCampaigns.has(campaignId)) return;
      let outcome: ChatOutcome;
      try {
        outcome = await analyzeChat(ctx, doc.id, doc.data(), existingById.get(doc.id));
      } catch (error) {
        console.warn(`[Seguimiento] Error revisando ${doc.id}:`, error);
        outcome = { skip: 'ai_error' };
      }
      if ('matched' in outcome) {
        matched++;
        consecutiveAiErrors = 0;
      } else {
        skipped[outcome.skip] = (skipped[outcome.skip] ?? 0) + 1;
        if (outcome.skip === 'ai_error') {
          if (++consecutiveAiErrors >= MAX_CONSECUTIVE_AI_ERRORS) aborted = true;
        } else if (outcome.skip === 'no_match') {
          consecutiveAiErrors = 0;
        }
      }
    });
    analyzed += page.size;
    const last = page.docs[page.docs.length - 1];
    cursorId = last.id;

    if (aborted) {
      await ref.update({
        status: 'failed',
        error: 'La IA dejó de responder. Revisa la llave en Ajustes › Asistente y vuelve a lanzarla.',
        analyzed, matched, skipped, finishedAt: now(),
      });
      return;
    }
    if (cancelledCampaigns.has(campaignId)) return;
    await ref.update({
      analyzed, matched, skipped,
      cursor: { id: last.id, ts: last.get('lastMessageTimestamp') ?? null },
      heartbeatAt: now(),
    });
    if (page.size < PAGE_SIZE) break;
  }

  if (cancelledCampaigns.has(campaignId)) return;
  await ref.update({ status: 'ready', analyzed, matched, skipped, finishedAt: now(), heartbeatAt: now() });
  console.log(`[Seguimiento] Campaña ${campaignId} lista: ${matched} encontrados de ${analyzed} revisados`);
}

// ───────────────────────── El goteo ─────────────────────────

async function sendNext(key: string, today: string): Promise<SendResult> {
  const { accountId, sessionId } = splitLaneKey(key);
  if (isSessionGone(accountId, sessionId)) return 'none';
  const live = findPrimarySession(accountId, sessionId);
  if (!live?.session.isReady || !live.session.sock) return 'skipped';

  const approved = await queueCol(accountId, sessionId).where('status', '==', 'approved').limit(25).get();
  if (approved.empty) return 'none';
  const next = [...approved.docs].sort((a, b) => (toMillis(a.get('approvedAt')) ?? 0) - (toMillis(b.get('approvedAt')) ?? 0))[0];
  const ref = next.ref;
  const chatRef = chatsCol(accountId, sessionId).doc(next.id);
  const messageId = generateMessageIDV2(live.session.sock.user?.id);

  // Se reclama en una transacción con el chat recién leído: si algo cambió
  // desde que se aprobó, no sale.
  const claim = await db().runTransaction(async (tx) => {
    const [p, chat] = await Promise.all([tx.get(ref), tx.get(chatRef)]);
    if (p.get('status') !== 'approved') return { kind: 'gone' as const };
    const check = checkSendable(p.data() ?? {}, chat.exists ? chat.data()! : null, today);
    if (!check.ok) {
      tx.update(ref, { status: check.status, closedReason: check.reason, updatedAt: now() });
      if (chat.exists) tx.update(chatRef, { followup_status: chatFollowupStatus(check.status) });
      return { kind: 'skip' as const, reason: check.reason };
    }
    tx.update(ref, { status: 'sending', messageId, sendingAt: now(), sentText: check.text, updatedAt: now() });
    if (chat.exists) tx.update(chatRef, { followup_status: chatFollowupStatus('sending') });
    return { kind: 'send' as const, text: check.text };
  });
  if (claim.kind === 'gone') return 'skipped';
  if (claim.kind === 'skip') {
    noteOpen(accountId, sessionId, next.id, false);
    console.log(`[Seguimiento] ${next.id} no sale (${claim.reason})`);
    return 'skipped';
  }
  noteOpen(accountId, sessionId, next.id, false);

  let outcome: 'sent' | 'failed' | 'in_doubt';
  let errorText: string | null = null;
  try {
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error('__timeout__')), SEND_TIMEOUT_MS);
    });
    try {
      await Promise.race([requireDeps().sendText(live.session, next.id, claim.text, FOLLOWUP_SENDER, messageId), timeout]);
    } finally {
      clearTimeout(timer);
    }
    outcome = 'sent';
  } catch (error) {
    const message = (error as Error)?.message ?? String(error);
    outcome = message === '__timeout__' ? 'in_doubt' : 'failed';
    errorText = outcome === 'in_doubt' ? 'WhatsApp no confirmó el envío a tiempo.' : message.slice(0, 300);
  }

  await db().runTransaction(async (tx) => {
    const chat = await tx.get(chatRef);
    tx.update(ref, {
      status: outcome,
      updatedAt: now(),
      ...(outcome === 'sent' ? { sentAt: now() } : { error: errorText }),
    });
    if (chat.exists) {
      tx.update(chatRef, {
        followup_status: chatFollowupStatus(outcome),
        ...(outcome !== 'failed' && { followup_last_at: now(), followup_count: FieldValue.increment(1) }),
      });
    }
  }).catch((error) => console.error(`[Seguimiento] No se pudo registrar el envío a ${next.id}:`, error));
  console.log(`[Seguimiento] ${next.id}: ${outcome}${errorText ? ` (${errorText})` : ''}`);
  return outcome;
}

const timezoneCache = new Map<string, { tz: string; at: number }>();

export const outbox = new FollowupOutbox({
  now: () => Date.now(),
  random: () => Math.random(),
  setTimer: (fn, ms) => setTimeout(fn, ms),
  clearTimer: (h) => clearTimeout(h as NodeJS.Timeout),
  timezone: async (key) => {
    const cached = timezoneCache.get(key);
    if (cached && Date.now() - cached.at < 10 * 60_000) return cached.tz;
    const { accountId, sessionId } = splitLaneKey(key);
    const tz = timezoneOf((await sessionRef(accountId, sessionId).get()).data() ?? {});
    timezoneCache.set(key, { tz, at: Date.now() });
    return tz;
  },
  isOnline: (key) => {
    const { accountId, sessionId } = splitLaneKey(key);
    const live = findPrimarySession(accountId, sessionId);
    return !!live?.session.isReady && !!live.session.sock;
  },
  loadState: async (key) => {
    const { accountId, sessionId } = splitLaneKey(key);
    const d = (await outboxRef(accountId, sessionId).get()).data() ?? {};
    return {
      paused: d.paused === true,
      pausedReason: (d.pausedReason as string | undefined) ?? null,
      day: (d.day as string | undefined) ?? null,
      sentToday: Number(d.sentToday ?? 0),
    };
  },
  saveState: async (key, status: OutboxStatus) => {
    const { accountId, sessionId } = splitLaneKey(key);
    if (isSessionGone(accountId, sessionId)) return;
    await outboxRef(accountId, sessionId).set({
      ...status,
      nextAt: status.nextAt ? admin.firestore.Timestamp.fromMillis(status.nextAt) : null,
      updatedAt: now(),
    });
  },
  sendNext,
  onPaused: (key, reason) => console.warn(`[Seguimiento] Goteo de ${key} pausado (${reason})`),
});

export async function setOutboxPaused(accountId: string, sessionId: string, paused: boolean, reason: string | null): Promise<void> {
  await outbox.setPaused(laneKey(accountId, sessionId), paused, reason);
}

/** Cambio de número: lo aprobado saldría desde un número que nadie conoce. */
export function pauseOutboxForNumberChange(accountId: string, sessionId: string): void {
  void setOutboxPaused(accountId, sessionId, true, 'number_change')
    .catch((error) => console.warn('[Seguimiento] No se pudo pausar el goteo tras el cambio de número:', error));
}

// ───────────────────────── Arranque de cada sesión ─────────────────────────

const bootstrapped = new Set<string>();

/**
 * Un envío que quedó `sending` (el proceso murió a mitad): si su mensaje está
 * en el chat, salió; si no, `in_doubt`. Nunca se reenvía.
 */
async function resolveStuckSending(accountId: string, sessionId: string): Promise<void> {
  const stuck = await queueCol(accountId, sessionId).where('status', '==', 'sending').get();
  for (const doc of stuck.docs) {
    const since = toMillis(doc.get('sendingAt')) ?? 0;
    if (Date.now() - since < IN_FLIGHT_WINDOW_MS) continue;
    const messageId = doc.get('messageId') as string | undefined;
    const echoed = messageId
      ? (await chatsCol(accountId, sessionId).doc(doc.id).collection('messages').doc(messageId).get()).exists
      : false;
    const status = echoed ? 'sent' : 'in_doubt';
    await doc.ref.update({
      status,
      updatedAt: now(),
      ...(echoed ? { sentAt: now() } : { error: 'El servidor se reinició a mitad del envío. Revisa el chat antes de volver a escribirle.' }),
    });
    await chatsCol(accountId, sessionId).doc(doc.id)
      .update({ followup_status: chatFollowupStatus(status), followup_last_at: now(), followup_count: FieldValue.increment(1) })
      .catch(() => undefined);
    console.warn(`[Seguimiento] ${doc.id} quedó a mitad del envío al reiniciar → ${status}`);
  }
}

async function bootstrapSession(accountId: string, sessionId: string): Promise<void> {
  await loadOpenProposals(accountId, sessionId);
  await resolveStuckSending(accountId, sessionId);
  const analyzing = await campaignsCol(accountId, sessionId).where('status', '==', 'analyzing').get();
  for (const doc of analyzing.docs) {
    console.log(`[Seguimiento] Retomando la campaña ${doc.id} de ${sessionId}`);
    startAnalysis(accountId, sessionId, doc.id);
  }
  outbox.kick(laneKey(accountId, sessionId), 30_000);
}

/**
 * Tick del cron (cada minuto). La primera vez que ve una sesión principal
 * conectada la arranca: propuestas abiertas, envíos a medias, análisis que un
 * reinicio cortó y el goteo. Después todo va por eventos.
 */
export function tickFollowupCampaigns(sessions: Map<string, SessionData>): void {
  for (const session of sessions.values()) {
    if (!session.isReady || !session.sessionId || session.role !== 'primary') continue;
    const key = laneKey(session.accountId, session.sessionId);
    if (bootstrapped.has(key)) {
      // Volvió de una caída: el goteo que esperaba la conexión arranca ya.
      if (outbox.status(key)?.waiting === 'offline') outbox.kick(key);
      continue;
    }
    if (isSessionGone(session.accountId, session.sessionId)) continue;
    bootstrapped.add(key);
    bootstrapSession(session.accountId, session.sessionId).catch((error) => {
      bootstrapped.delete(key);
      console.error(`[Seguimiento] No se pudo arrancar ${key}:`, error);
    });
  }
}

/** La sesión se eliminó: se suelta lo que había en memoria. */
export function forgetFollowupSession(accountId: string, sessionId: string): void {
  const key = laneKey(accountId, sessionId);
  bootstrapped.delete(key);
  openProposals.delete(key);
  outbox.forget(key);
}

export { MAX_INSTRUCTION_LENGTH };
