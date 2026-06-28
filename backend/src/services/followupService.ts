import admin from 'firebase-admin';
import { SessionData } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { getAIConfig } from './firestoreService';
import {
  normalizeHistory,
  classifyFollowupCandidate,
  draftFollowupMessage,
  DEFAULT_TIMEZONE,
  type AiProvider,
} from './aiService';

// ─────────────────────────────────────────────────────────────────────────
// Agente de Seguimiento de Ventas (Re-engagement)
// ─────────────────────────────────────────────────────────────────────────
// Primo de ReminderService: barre a diario (cron a hora fija) las conversaciones
// que quedaron frías "ayer", decide con IA cuáles son leads recuperables y deja
// un borrador en la cola `followup_queue` para que el operador revise y apruebe.
//
// FASE 1 (este archivo): construir la cola. NO envía ningún mensaje.
// FASE 2 (futuro): drainFollowupQueue() enviará los aprobados con pacing.

// Tope de candidatos analizados por corrida para acotar el costo de IA.
const MAX_CANDIDATES_PER_RUN = 50;
// Cuántos mensajes de historial pasamos al clasificador / redactor.
const HISTORY_LIMIT = 20;

interface FollowupConfig {
  enabled: boolean;
  scheduledTime: string;   // "09:00"
  timezone: string;
  exclusionPrompt: string; // reglas naturales de a quién excluir
  messagePrompt: string;   // tono/instrucciones del mensaje a redactar
  autoSend: boolean;       // Fase 3: saltarse la cola de revisión
}

export class FollowupService {
  private static get db() {
    return admin.firestore();
  }

  /**
   * Lee la configuración de seguimiento de una sesión (campos followup_*).
   */
  static async getFollowupConfig(accountId: string, sessionId: string): Promise<FollowupConfig | null> {
    try {
      const doc = await this.db
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId)
        .get();

      const data = doc.data();
      if (!data) return null;

      return {
        enabled: data.followup_enabled ?? false,
        scheduledTime: data.followup_scheduled_time ?? '09:00',
        timezone: data.followup_timezone ?? DEFAULT_TIMEZONE,
        exclusionPrompt: data.followup_exclusion_prompt ?? '',
        messagePrompt: data.followup_message_prompt ?? '',
        autoSend: data.followup_auto_send ?? false,
      };
    } catch (error) {
      console.error('[FollowupService] Error leyendo config:', error);
      return null;
    }
  }

  /**
   * Offset (tz − UTC) en ms para un instante dado, consciente de DST. Usa
   * Intl para leer cómo se ve `instant` en la zona y restar contra UTC.
   */
  private static tzOffsetMs(instant: Date, timezone: string): number {
    const dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone, hour12: false,
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    const p: Record<string, string> = {};
    for (const part of dtf.formatToParts(instant)) p[part.type] = part.value;
    // 'en-US' h24 a veces emite '24' a medianoche; lo normalizamos a 0.
    const hour = p.hour === '24' ? 0 : Number(p.hour);
    const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, hour, +p.minute, +p.second);
    return asUTC - instant.getTime();
  }

  /**
   * Instante UTC de las 00:00:00 del día `dateStr` ('YYYY-MM-DD') en `timezone`.
   */
  private static zonedMidnightUtc(dateStr: string, timezone: string): Date {
    const [y, m, d] = dateStr.split('-').map(Number);
    const wallAsUtc = Date.UTC(y, m - 1, d); // como si la pared fuera UTC
    const offset = this.tzOffsetMs(new Date(wallAsUtc), timezone);
    return new Date(wallAsUtc - offset);
  }

  /**
   * Límites [inicio, fin) del día calendario "ayer" en la zona del negocio,
   * como instantes UTC. inicio = ayer 00:00, fin = hoy 00:00 (exclusivo).
   */
  private static yesterdayBoundsUtc(timezone: string): { start: Date; end: Date } {
    const now = new Date();
    const todayStr = new Intl.DateTimeFormat('en-CA', {
      timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
    }).format(now); // 'YYYY-MM-DD'
    // Ayer = hoy − 1 día, calculado sobre los componentes de fecha (sin DST).
    const [y, m, d] = todayStr.split('-').map(Number);
    const yest = new Date(Date.UTC(y, m - 1, d) - 86_400_000);
    const pad = (n: number) => String(n).padStart(2, '0');
    const yesterdayStr = `${yest.getUTCFullYear()}-${pad(yest.getUTCMonth() + 1)}-${pad(yest.getUTCDate())}`;
    return {
      start: this.zonedMidnightUtc(yesterdayStr, timezone),
      end: this.zonedMidnightUtc(todayStr, timezone),
    };
  }

  /**
   * Candidatos estructurales: chats cuyo último mensaje cayó DENTRO del día
   * calendario "ayer" (en la zona del negocio), que no estén excluidos
   * manualmente ni hayan recibido ya un seguimiento. Filtro de rango sobre un
   * campo único (lastMessageTimestamp) → índice automático en Firestore.
   */
  static async findColdChats(
    accountId: string,
    sessionId: string,
    config: FollowupConfig
  ): Promise<{ chatId: string; data: FirebaseFirestore.DocumentData }[]> {
    const { start, end } = this.yesterdayBoundsUtc(config.timezone);
    const oldest = admin.firestore.Timestamp.fromDate(start);
    const newest = admin.firestore.Timestamp.fromDate(end);

    const snap = await this.db
      .collection(ACCOUNTS_COLLECTION).doc(accountId)
      .collection('whatsapp_sessions').doc(sessionId)
      .collection('chats')
      .where('lastMessageTimestamp', '>=', oldest)
      .where('lastMessageTimestamp', '<', newest)
      .orderBy('lastMessageTimestamp', 'desc')
      .limit(MAX_CANDIDATES_PER_RUN)
      .get();

    return snap.docs
      .filter(d => {
        const data = d.data();
        if (data.followup_opt_out === true) return false;   // excluido manual (chat personal)
        if ((data.followup_count ?? 0) >= 1) return false;  // ya recibió su seguimiento
        return true;
      })
      .map(d => ({ chatId: d.id, data: d.data() }));
  }

  /**
   * Trae el historial reciente de un chat ya normalizado para la IA.
   */
  private static async fetchHistory(
    accountId: string,
    sessionId: string,
    chatId: string,
    timezone: string
  ): Promise<{ role: 'user' | 'model'; parts: { text: string }[] }[]> {
    try {
      const historyDocs = await this.db
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId)
        .collection('chats').doc(chatId)
        .collection('messages')
        .orderBy('timestamp', 'desc')
        .limit(HISTORY_LIMIT)
        .get();

      const rawDocs = historyDocs.docs.reverse().map(d => d.data());
      return normalizeHistory(rawDocs, timezone);
    } catch (error) {
      console.warn(`[FollowupService] No se pudo leer historial de ${chatId}:`, error);
      return [];
    }
  }

  /**
   * Construye (o refresca) la cola de seguimiento de una sesión. Por cada chat
   * frío: clasifica → si FOLLOW_UP, redacta y encola; si SKIP, marca el chat.
   * NO envía mensajes. Devuelve un resumen para el endpoint manual / logs.
   */
  static async buildFollowupQueue(
    accountId: string,
    sessionId: string,
    sessionKey: string,
    sessions: Map<string, SessionData>
  ) {
    const session = sessions.get(sessionKey);
    if (!session || !session.isReady) {
      return { success: false, error: 'Session not ready' };
    }

    const config = await this.getFollowupConfig(accountId, sessionId);
    if (!config || !config.enabled) {
      return { success: false, error: 'Followup not enabled' };
    }

    // Credenciales de IA: reusamos la config del asistente (apiKey/provider/model).
    // El seguimiento funciona aunque el auto-responder esté apagado: solo necesita
    // la llave del provider activo (igual que el modo copiloto).
    const aiConfig = await getAIConfig(session, accountId);
    if (!aiConfig.apiKey && !aiConfig.openaiApiKey && !aiConfig.deepseekApiKey) {
      return { success: false, error: 'AI credentials missing' };
    }

    const candidates = await this.findColdChats(accountId, sessionId, config);
    console.log(`[FollowupService] ${sessionId}: ${candidates.length} chats con último mensaje de ayer (${config.timezone})`);

    let queued = 0;
    let skipped = 0;
    const results: { chatId: string; decision: string; reason: string; draftPreview?: string }[] = [];

    for (const { chatId, data } of candidates) {
      const history = await this.fetchHistory(accountId, sessionId, chatId, config.timezone);
      if (history.length === 0) {
        skipped++;
        results.push({ chatId, decision: 'SKIP', reason: '(sin historial legible)' });
        continue;
      }

      const { decision, reason } = await classifyFollowupCandidate(
        aiConfig.apiKey,
        config.exclusionPrompt,
        history,
        aiConfig.model,
        (aiConfig.provider || 'gemini') as AiProvider,
        aiConfig.openaiApiKey,
        aiConfig.deepseekApiKey,
        config.timezone
      );

      const chatRef = this.db
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId)
        .collection('chats').doc(chatId);

      if (decision === 'SKIP') {
        skipped++;
        await chatRef.set(
          { followup_status: 'skipped', followup_last_reason: reason },
          { merge: true }
        );
        results.push({ chatId, decision, reason });
        continue;
      }

      // FOLLOW_UP → redactar borrador y encolar.
      const draft = await draftFollowupMessage(
        aiConfig.apiKey,
        config.messagePrompt,
        history,
        aiConfig.model,
        (aiConfig.provider || 'gemini') as AiProvider,
        aiConfig.openaiApiKey,
        aiConfig.deepseekApiKey,
        config.timezone
      );

      if (!draft || !draft.trim()) {
        // La IA no produjo texto: no encolamos basura. Lo marcamos como skip
        // con razón clara para auditar.
        skipped++;
        await chatRef.set(
          { followup_status: 'skipped', followup_last_reason: '(IA no generó borrador)' },
          { merge: true }
        );
        results.push({ chatId, decision: 'SKIP', reason: '(IA no generó borrador)' });
        continue;
      }

      await this.db
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId)
        .collection('followup_queue').doc(chatId)
        .set({
          chatId,
          contactName: data.contactName ?? null,
          draftMessage: draft.trim(),
          status: 'pending',
          reason,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

      await chatRef.set(
        { followup_status: 'queued', followup_last_reason: reason },
        { merge: true }
      );

      queued++;
      results.push({ chatId, decision, reason, draftPreview: draft.trim().substring(0, 120) });
    }

    console.log(`[FollowupService] ${sessionId}: ${queued} encolados, ${skipped} omitidos`);
    return { success: true, scanned: candidates.length, queued, skipped, results };
  }

  /**
   * Tick de cron (cada minuto): corre el barrido para las sesiones cuyo horario
   * configurado coincide con la hora actual. Espejo de
   * ReminderService.checkAndRunScheduledReminders.
   */
  static async checkAndRunScheduledFollowups(sessions: Map<string, SessionData>) {
    for (const [sessionKey, session] of sessions) {
      if (!session.isReady || !session.phoneNumber) continue;

      const config = await this.getFollowupConfig(session.accountId, session.phoneNumber);
      if (!config || !config.enabled) continue;

      const currentTime = new Intl.DateTimeFormat('en-US', {
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
        timeZone: config.timezone,
      }).format(new Date());

      if (config.scheduledTime === currentTime) {
        console.log(`[FollowupService] Barrido programado para ${session.phoneNumber} a las ${currentTime}`);
        this.buildFollowupQueue(session.accountId, session.phoneNumber, sessionKey, sessions)
          .then(result => console.log(`[FollowupService] Resultado para ${session.phoneNumber}:`, result))
          .catch(err => console.error(`[FollowupService] Fallo para ${session.phoneNumber}:`, err));
      }
    }
  }
}
