// Quién originó cada mensaje saliente. El frontend muestra `name` arriba del
// bubble (ej. "Samuel", "ai", "bot", "WhatsApp"). El `type` es lo único que
// consume el contexto del asistente/discriminador para decidir routing.
export type SenderType = 'human' | 'ai' | 'bot';

export interface SenderInfo {
  type: SenderType;
  name: string;     // snapshot al momento de envío (no se resuelve en lectura)
  uid?: string;     // sólo cuando type='human' y vino vía app autenticada
}

export interface SessionData {
  sock: any;
  isReady: boolean;
  currentQR: string | undefined;
  phoneNumber: string | undefined;
  isReconnecting: boolean;
  reconnectCount: number;
  accountId: string;
  // Cache en memoria de nombres de agenda (phoneNumber -> name).
  // Se llena con contacts.upsert/contacts.update sin tocar Firestore.
  // Se persiste a un chat doc solo cuando hay un mensaje real para ese contacto
  // o durante la reconciliación post-connect.
  contactNames: Map<string, string>;
  // Timer para debouncear la reconciliación de nombres tras contacts.upsert.
  reconcileTimer?: NodeJS.Timeout;
  // Intenciones de envío pendientes (messageId -> sender).
  // Cada entry point (humano API/socket, IA, keyword rules, recordatorios)
  // registra aquí su SenderInfo después del sock.sendMessage. El handler de
  // messages.upsert lo consume para etiquetar el doc en Firestore. Si no hay
  // entry → el mensaje fue enviado desde el WhatsApp oficial del teléfono.
  pendingSenders: Map<string, SenderInfo>;
  aiConfig?: {
    enabled: boolean;
    apiKey: string;
    provider?: 'gemini' | 'openai';
    openaiApiKey?: string;
    systemPrompt: string;
    responseDelayMs: number;
    model: string;
    activeHours?: {
      enabled: boolean;
      timezone: string;
      start: string;
      end: string;
    };
    keywordRules: {
      keyword: string;
      response: string;
      imageUrl?: string;
      // Cuándo se dispara la regla:
      //   'incoming' → solo cuando el cliente escribe la keyword (comportamiento histórico).
      //   'outgoing' → solo cuando nosotros (operador o WA Web) enviamos un mensaje con la keyword.
      //   'both'     → en cualquiera de los dos casos.
      // Si el campo no existe en Firestore, se asume 'incoming' por back-compat.
      trigger?: 'incoming' | 'outgoing' | 'both';
    }[];
    discriminator?: {
      enabled: boolean;
      prompt: string;
    };
    // Allowlist de tipos de media que la IA SÍ puede leer.
    // Por defecto todo en false: la IA solo entiende texto. Cuando llega un
    // mensaje con un tipo no permitido se hace handoff a humano para evitar
    // respuestas sin contexto. Stickers y GIFs son siempre decorativos
    // (no controlados por este allowlist).
    mediaAllowlist: {
      image: boolean;
      audio: boolean;
      video: boolean;
      document: boolean;
    };
    loadedAt: number;
  };
}

export interface MessageBuffer {
  contactPhone: string;
  messages: string[];
  timeout: NodeJS.Timeout | null;
  responded: boolean;
}
