import type { WAMessageKey } from '@whiskeysockets/baileys';

// Quién originó cada mensaje saliente. El frontend muestra `name` arriba del
// bubble (ej. "Samuel", "ai", "bot", "WhatsApp"). El `type` es lo único que
// consume el contexto del asistente/discriminador para decidir routing.
export type SenderType = 'human' | 'ai' | 'bot';

export interface SenderInfo {
  type: SenderType;
  name: string;     // snapshot al momento de envío (no se resuelve en lectura)
  uid?: string;     // sólo cuando type='human' y vino vía app autenticada
}

/** Estados que puede tener el doc de sesión en Firestore. */
export type SessionStatus =
  | 'connected'
  | 'reconnecting'
  | 'reconnect_failed'
  | 'disconnected';

export interface SessionData {
  sock: any;
  isReady: boolean;
  currentQR: string | undefined;
  phoneNumber: string | undefined;
  reconnectCount: number;
  accountId: string;

  // --- Supervisión de la conexión (ver services/sessionSupervisor.ts) ---
  // Contador monotónico de sockets creados para esta sessionKey. Cada
  // `startSession` lo incrementa y el handler de `connection.update` captura el
  // suyo al nacer: así un socket viejo que emite tarde se descarta comparando,
  // en vez de programar una reconexión que mataría al socket sano que ya tomó
  // su lugar.
  generation: number;
  // Timer del deadline de arranque. Si el socket no da señales de vida (`qr` u
  // `open`) antes de que venza, lo damos por muerto por nuestra cuenta: Baileys
  // puede no avisar NUNCA si el connect TCP queda colgado.
  connectDeadline?: NodeJS.Timeout;
  // Timer del próximo intento de reconexión. Su ausencia, con la sesión
  // desconectada, es la firma exacta de una sesión huérfana: es lo que busca
  // el watchdog.
  reconnectTimer?: NodeJS.Timeout;
  // Epoch ms en que se creó el socket actual.
  socketStartedAt: number;
  // Epoch ms de la última vez que la sesión llegó a `open`. undefined = nunca.
  lastConnectedAt?: number;
  // Último status que escribimos en Firestore. Memo para que el barrido
  // periódico no pague un read por sesión sólo para comparar.
  lastWrittenStatus?: SessionStatus;
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
  // Llaves de los mensajes entrantes que todavía NO confirmamos como leídos
  // ante WhatsApp (contactPhone -> llaves). Se vacía al responderle al chat.
  // Ver readReceiptService.ts para la política completa.
  unreadKeys: Map<string, WAMessageKey[]>;
  aiConfig?: {
    enabled: boolean;
    apiKey: string;
    provider?: 'gemini' | 'openai' | 'deepseek';
    openaiApiKey?: string;
    // DeepSeek habla el protocolo de OpenAI: reutilizamos el SDK de OpenAI
    // con baseURL 'https://api.deepseek.com'. Solo necesitamos su propia key.
    deepseekApiKey?: string;
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
      // Adjunto opcional: la regla lleva como máximo uno (imagen O documento),
      // garantizado por el editor del cliente. Prioridad de envío: documento >
      // imagen > solo texto (ver buildRuleMessageContent en index.ts).
      imageUrl?: string;
      documentUrl?: string;
      documentName?: string;
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
    // Confirmar lectura en WhatsApp al responderle a un chat. Vive acá porque
    // getAIConfig ya cachea el doc de sesión 60s: leerlo no cuesta un read extra.
    markReadOnReply: boolean;
    loadedAt: number;
  };
}

export interface MessageBuffer {
  contactPhone: string;
  messages: string[];
  timeout: NodeJS.Timeout | null;
  responded: boolean;
}
