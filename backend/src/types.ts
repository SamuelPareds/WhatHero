export interface SessionData {
  sock: any;
  isReady: boolean;
  currentQR: string | undefined;
  phoneNumber: string | undefined;
  isReconnecting: boolean;
  reconnectCount: number;
  accountId: string;
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
