import admin from 'firebase-admin';
import { SessionData } from '../types';
import { extractPhoneNumber } from '../utils/phone';
import { saveMessageToFirestore } from './firestoreService';

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

interface ReminderConfig {
  enabled: boolean;
  apiUrl: string;
  scheduledTime: string;
  timezone: string;
  template: string;
  loadedAt: number;
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
        .collection('accounts').doc(accountId)
        .collection('whatsapp_sessions').doc(sessionId);

      const doc = await sessionDocRef.get();
      const data = doc.data();

      if (!data) return null;

      return {
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

      // Save to Firestore using existing utility
      if (message) {
        await saveMessageToFirestore(
          message,
          sessionKey,
          session.accountId,
          sessions,
          session.sock.user?.id,
          session.sock
        );
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
    sessions: Map<string, SessionData>
  ) {
    const session = sessions.get(sessionKey);
    if (!session || !session.isReady || !session.sock) {
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

      for (const appointment of sortedAppointments) {
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
      if (!session.isReady || !session.phoneNumber) continue;

      const config = await this.getReminderConfig(session.accountId, session.phoneNumber);
      if (!config || !config.enabled) continue;

      if (config.scheduledTime === currentTime) {
        console.log(`[ReminderService] Running scheduled reminders for ${session.phoneNumber} at ${currentTime}`);
        this.processReminders(session.accountId, session.phoneNumber, sessionKey, sessions)
          .then(result => {
            console.log(`[ReminderService] Scheduled run result for ${session.phoneNumber}:`, result);
          })
          .catch(err => {
            console.error(`[ReminderService] Scheduled run failed for ${session.phoneNumber}:`, err);
          });
      }
    }
  }
}
