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
    keywordRules: { keyword: string; response: string; imageUrl?: string }[];
    discriminator?: {
      enabled: boolean;
      prompt: string;
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
