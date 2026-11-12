import admin from 'firebase-admin';
import { SessionData } from '../types';
import { BOT_SENDER } from './senderResolver';
import { ACCOUNTS_COLLECTION } from '../config/env';

interface Appointment {
  appointmentId: string;
  time: string;         // "4:00p.m."
  startDate: string;    // "viernes, 14 de febrero de 2025, 4:00:00 p.m. GMT-6"
  services: string[];
  status: string;
  contactId: string;
  contactName: string;
  primaryPhone: string;
  messengerUser: string;
  notes: string;
}

// ─────────────────────────────────────────────────────────────────────────
// Una vez por día, y nunca dos lotes a la vez.
// ─────────────────────────────────────────────────────────────────────────
// Los recordatorios no tienen dedupe por cita: correr el lote dos veces el
// mismo día le manda a cada cliente su recordatorio dos veces. Cada corrida
// deja `reminder_last_run` en el doc de la sesión (marcado como `running`
// ANTES de enviar el primero) y la siguiente lo consulta:
//   - el cron se salta el día si ya salió algo hoy, o si una corrida quedó a
//     medias (el proceso murió: reenviar duplicaría lo que sí salió);
//   - el botón "Enviar ahora" pide confirmación (`force`) en esos casos.

export interface ReminderRun {
  day: string;          // 'YYYY-MM-DD' en la zona de los recordatorios
  status: 'running' | 'done';
  via: 'cron' | 'manual';
  sent: number;
  failed: number;
  total: number;
  startedAtMs: number;
}

/** ¿Hoy ya salieron recordatorios (o hay una corrida a medias)? */
export function remindersRanToday(last: Partial<ReminderRun> | null | undefined, today: string): boolean {
  if (!last || last.day !== today) return false;
  return last.status === 'running' || Number(last.sent ?? 0) > 0;
}

function localDay(now: Date, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now);
}

export type ManualRunResult =
  | { status: 'started' }
  | { status: 'running' }
  | { status: 'already_sent_today'; lastRun: Partial<ReminderRun> }
  | { status: 'not_configured' }
  | { status: 'not_ready' };

// Corridas en vuelo en este proceso, por doc de sesión.
const runningReminders = new Set<string>();

interface ReminderConfig {
  enabled: boolean;
  apiUrl: string;
  scheduledTime: string;
  timezone: string;
  template: string;
  loadedAt: number;
  lastRun: Partial<ReminderRun> | null;
}

export class ReminderService {
  private static get db() {
    return admin.firestore();
  }

  /**
   * Normaliza números de teléfono para ser usados como IDs en Firestore
   * Convierte diferentes formatos a: 521XXXXXXXXXX (formato México con código WhatsApp)
   */
  private static normalizePhoneForWhatsApp(phone: string): string {
    // Remover caracteres no numéricos
    const cleaned = phone.replace(/\D/g, '');
    
    // Caso 1: Ya tiene formato completo (5215512345678 - 13 dígitos)
    if (cleaned.length === 13 && cleaned.startsWith('521')) {
      return cleaned;
    }
    
    // Caso 2: Formato internacional sin WhatsApp (525512345678 - 12 dígitos)
    if (cleaned.length === 12 && cleaned.startsWith('52')) {
      return `521${cleaned.substring(2)}`;
    }
    
    // Caso 3: Solo número nacional (5512345678 - 10 dígitos)
    if (cleaned.length === 10) {
      return `521${cleaned}`;
    }
    
    // Si no coincide con ningún formato, intentar extraer los últimos 10 y poner prefijo
    if (cleaned.length >= 10) {
      const lastTenDigits = cleaned.slice(-10);
      return `521${lastTenDigits}`;
    }
    
    return cleaned;
  }

  /**
   * Fetches reminder configuration for a specific session
   */
  static async getReminderConfig(accountId: string, sessionId: string): Promise<ReminderConfig | null> {
    try {
      const sessionDocRef = this.db
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId);

      const doc = await sessionDocRef.get();
      const data = doc.data();

      if (!data) return null;

      return {
        lastRun: (data.reminder_last_run as Partial<ReminderRun> | undefined) ?? null,
        enabled: data.reminder_enabled ?? false,
        apiUrl: data.reminder_api_url ?? '',
        scheduledTime: data.reminder_scheduled_time ?? '09:00',
        timezone: data.reminder_timezone ?? 'America/Mexico_City',
        template: data.reminder_template ?? '¡Hola {name}! 🌸\n\nTe recordamos tu cita para mañana a las {time}. ¿Confirmamos tu asistencia? 🤗',
        loadedAt: Date.now(),
      };
    } catch (error) {
      console.error('[ReminderService] Error fetching config:', error);
      return null;
    }
  }

  /**
   * Formats the reminder message template
   */
  private static formatTemplate(template: string, appointment: Appointment): string {
    // Extraer primer nombre si es posible
    const firstName = appointment.contactName.split(' ')[0];

    return template
      .replace(/{name}/g, firstName)
      .replace(/{full_name}/g, appointment.contactName)
      .replace(/{time}/g, appointment.time)
      .replace(/{date}/g, appointment.startDate.split(',')[1]?.trim() || '');
  }

  /**
   * Sends a single appointment reminder
   */
  static async sendAppointmentReminder(
    appointment: Appointment,
    session: SessionData,
    template: string,
    sessionKey: string,
    sessions: Map<string, SessionData>
  ): Promise<boolean> {
    try {
      const cleanPhone = this.normalizePhoneForWhatsApp(appointment.primaryPhone);
      if (!cleanPhone || cleanPhone.length < 10) {
        console.warn(`[ReminderService] Invalid phone number after normalization: ${appointment.primaryPhone} -> ${cleanPhone}`);
        return false;
      }

      const jid = `${cleanPhone}@s.whatsapp.net`;
      const messageText = this.formatTemplate(template, appointment);

      console.log(`[ReminderService] Sending reminder to ${cleanPhone} (${appointment.contactName})`);

      const message = await session.sock.sendMessage(jid, { text: messageText });

      // Etiqueta 'bot': el mensaje saldrá por el flujo normal de
      // messages.upsert que persiste a Firestore. Aquí sólo registramos
      // la intención para que ese guardado lo marque como bot.
      if (message?.key?.id) {
        session.pendingSenders.set(message.key.id, BOT_SENDER);
      }

      return true;
    } catch (error) {
      console.error(`[ReminderService] Error sending to ${appointment.primaryPhone}:`, error);
      return false;
    }
  }

  /**
   * Main function to fetch and send all reminders for an account
   */
  static async processReminders(
    accountId: string,
    sessionId: string,
    sessionKey: string,
    sessions: Map<string, SessionData>,
    via: 'cron' | 'manual' = 'cron',
  ) {
    const runKey = `${accountId}/${sessionId}`;
    if (runningReminders.has(runKey)) {
      console.warn(`[ReminderService] Ya hay un lote en curso para ${sessionId}; no se inicia otro`);
      return { success: false, error: 'Already running' };
    }
    runningReminders.add(runKey);
    try {
      return await this.runReminders(accountId, sessionId, sessionKey, sessions, via);
    } finally {
      runningReminders.delete(runKey);
    }
  }

  private static async writeRun(accountId: string, sessionId: string, run: ReminderRun): Promise<void> {
    // `update`: el status de una sesión eliminada no puede resucitar su doc.
    await this.db
      .collection(ACCOUNTS_COLLECTION).doc(accountId)
      .collection('whatsapp_sessions').doc(sessionId)
      .update({ reminder_last_run: run });
  }

  /**
   * "Enviar ahora" desde Ajustes. Sin `force`, no repite un día que ya salió:
   * devuelve `already_sent_today` para que la app pregunte. Corre en segundo
   * plano (sale uno cada 7 s): el resultado queda en `reminder_last_run`.
   */
  static async startManualRun(
    accountId: string,
    sessionId: string,
    sessionKey: string,
    sessions: Map<string, SessionData>,
    force: boolean,
  ): Promise<ManualRunResult> {
    const session = sessions.get(sessionKey);
    if (!session || !session.isReady || !session.sock || session.role !== 'primary') return { status: 'not_ready' };
    if (runningReminders.has(`${accountId}/${sessionId}`)) return { status: 'running' };
    const config = await this.getReminderConfig(accountId, sessionId);
    if (!config || !config.enabled || !config.apiUrl) return { status: 'not_configured' };
    const today = localDay(new Date(), config.timezone);
    if (!force && remindersRanToday(config.lastRun, today)) {
      return { status: 'already_sent_today', lastRun: config.lastRun! };
    }
    this.processReminders(accountId, sessionId, sessionKey, sessions, 'manual')
      .then((result) => console.log(`[ReminderService] Envío manual de ${sessionId}:`, result))
      .catch((err) => console.error(`[ReminderService] Envío manual de ${sessionId} falló:`, err));
    return { status: 'started' };
  }

  private static async runReminders(
    accountId: string,
    sessionId: string,
    sessionKey: string,
    sessions: Map<string, SessionData>,
    via: 'cron' | 'manual',
  ) {
    const session = sessions.get(sessionKey);
    // `role`: una línea anterior (tras un cambio de número) nunca envía.
    if (!session || !session.isReady || !session.sock || session.role !== 'primary') {
      console.error(`[ReminderService] Session ${sessionKey} not ready for reminders`);
      return { success: false, error: 'Session not ready' };
    }

    const config = await this.getReminderConfig(accountId, sessionId);
    if (!config || !config.enabled || !config.apiUrl) {
      console.log(`[ReminderService] Reminders not enabled or missing API URL for ${sessionId}`);
      return { success: false, error: 'Reminders not configured/enabled' };
    }

    try {
      console.log(`[ReminderService] Fetching appointments from ${config.apiUrl}`);
      const response = await fetch(config.apiUrl);
      if (!response.ok) {
        throw new Error(`Failed to fetch appointments: ${response.statusText}`);
      }

      const appointments = await response.json() as Appointment[];
      console.log(`[ReminderService] Found ${appointments.length} appointments for ${sessionId}`);

      if (appointments.length === 0) {
        return { success: true, count: 0, message: 'No appointments for tomorrow' };
      }

      // Ordenar por hora (opcional, como en tu código original)
      const sortedAppointments = appointments.sort((a, b) => a.time.localeCompare(b.time));

      let successCount = 0;
      let errorCount = 0;
      const failedNumbers: string[] = [];

      // La marca va ANTES del primer envío: si el proceso muere a mitad, la
      // corrida queda `running` y el cron de hoy no la repite.
      const run: ReminderRun = {
        day: localDay(new Date(), config.timezone),
        status: 'running',
        via,
        sent: 0,
        failed: 0,
        total: sortedAppointments.length,
        startedAtMs: Date.now(),
      };
      await this.writeRun(accountId, sessionId, run);

      for (const appointment of sortedAppointments) {
        // La sesión se retiró a mitad del lote (eliminada, o cerrada desde el
        // teléfono): ya no hay socket por el cual mandar el resto.
        if (!sessions.has(sessionKey)) break;
        const success = await this.sendAppointmentReminder(
          appointment,
          session,
          config.template,
          sessionKey,
          sessions
        );

        if (success) {
          successCount++;
        } else {
          errorCount++;
          failedNumbers.push(appointment.primaryPhone);
        }

        // 7-second delay between messages to avoid rate limiting
        await new Promise(resolve => setTimeout(resolve, 7000));
      }

      console.log(`[ReminderService] Completed: ${successCount} sent, ${errorCount} failed`);
      await this.writeRun(accountId, sessionId, { ...run, status: 'done', sent: successCount, failed: errorCount })
        .catch((error) => console.error('[ReminderService] No se pudo guardar el resultado del lote:', error));

      return {
        success: true,
        sent: successCount,
        failed: errorCount,
        failedNumbers
      };
    } catch (error) {
      console.error(`[ReminderService] Error processing reminders for ${sessionId}:`, error);
      return { success: false, error: (error as any).message };
    }
  }

  /**
   * Checks all active sessions and runs reminders if scheduled time matches
   */
  static async checkAndRunScheduledReminders(sessions: Map<string, SessionData>) {
    // Get current time in Mexico City (or allow per-account timezone)
    const now = new Date();
    const formatter = new Intl.DateTimeFormat('en-US', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
      timeZone: 'America/Mexico_City'
    });
    const currentTime = formatter.format(now); // "09:00"

    // Solo loggear cada minuto si hay sesiones activas para no saturar el log
    if (sessions.size > 0) {
      // console.log(`[ReminderService] Checking scheduled reminders for ${currentTime} (Mexico City time)`);
    }

    for (const [sessionKey, session] of sessions) {
      if (!session.isReady || !session.sessionId) continue;
      // La línea anterior comparte doc con el número nuevo: correrlo también
      // por ella mandaría todo dos veces, y desde el número viejo.
      if (session.role !== 'primary') continue;

      const config = await this.getReminderConfig(session.accountId, session.sessionId);
      if (!config || !config.enabled) continue;

      if (config.scheduledTime === currentTime) {
        if (remindersRanToday(config.lastRun, localDay(now, config.timezone))) {
          console.log(`[ReminderService] ${session.sessionId}: hoy ya salieron recordatorios (${config.lastRun?.via}); el cron no los repite`);
          continue;
        }
        console.log(`[ReminderService] Running scheduled reminders for ${session.sessionId} at ${currentTime}`);
        this.processReminders(session.accountId, session.sessionId, sessionKey, sessions)
          .then(result => {
            console.log(`[ReminderService] Scheduled run result for ${session.sessionId}:`, result);
          })
          .catch(err => {
            console.error(`[ReminderService] Scheduled run failed for ${session.sessionId}:`, err);
          });
      }
    }
  }
}
