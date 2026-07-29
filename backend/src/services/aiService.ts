import admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';
import OpenAI from 'openai';
import { SessionData } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { incrementUnrespondedCount, resetUnrespondedCount } from './firestoreService';
import { sendHumanAttentionNotification, HumanAttentionReason } from './notificationService';
import { isBlockedMediaDoc } from './mediaService';
import { AI_SENDER } from './senderResolver';

// Lazy evaluation: getDb() is called only after Firebase is initialized
function getDb() {
  return admin.firestore();
}

// Lazy evaluation: getIO() is called only after Socket.io is initialized
function getIO() {
  // This will be injected by index.ts
  return (global as any).__WhatHeroIO;
}

// Estados efímeros del ciclo de vida de la IA por chat. Se emiten via Socket.io
// (no se persisten en Firestore) para que el frontend pinte feedback en vivo
// sin disparar writes ni lecturas adicionales.
export type AiLifecycleState = 'buffering' | 'thinking' | 'responding' | 'idle';

// DeepSeek es compatible con la API de OpenAI: reutilizamos el SDK de OpenAI
// apuntando a este baseURL. Así no duplicamos las funciones de generación ni
// las del discriminador — solo cambia el endpoint y la api key.
const DEEPSEEK_BASE_URL = 'https://api.deepseek.com';

export type AiProvider = 'gemini' | 'openai' | 'deepseek';

// Techo de tokens de salida para la ruta OpenAI-compatible. Estaba en 1000 y
// era la causa de las respuestas cortadas a media frase: al agotarse, la API
// devuelve 200 con el texto mutilado y `finish_reason: 'length'`. La ruta
// Gemini nunca mandó `maxOutputTokens` en generación (usa el default del
// modelo, enorme) y por eso jamás truncó. 4000 deja aire de sobra para un
// mensaje de WhatsApp largo MÁS los tokens de razonamiento, que DeepSeek V4 y
// la familia GPT-5 descuentan de este mismo presupuesto.
const AI_MAX_OUTPUT_TOKENS = 4000;

// Los modelos de razonamiento (GPT-5, familia o*) rechazan `max_tokens` —exigen
// `max_completion_tokens`— y solo aceptan la temperatura por defecto. Sin esta
// distinción, elegir "GPT-5 Mini" en el panel de sesión hacía fallar la llamada
// entera con un 400 del proveedor.
function isReasoningModel(modelName: string): boolean {
  return /^(gpt-5|o[1-9])/i.test(modelName);
}

// Resultado de una generación. `truncated` viaja aparte del texto porque un
// mensaje cortado a media frase NO debe enviarse al cliente: el caller decide
// (el auto-responder deriva a humano; el copiloto avisa al operador).
export type AiGenerationResult = {
  text: string | null;
  truncated: boolean;
};

// Error estructurado de IA con un `code` estable que el endpoint manual traduce
// a HTTP + mensaje claro para el operador. SOLO se usa en el modo copiloto
// (botón auto_awesome): el auto-responder nunca pide `throwOnError`, así que para
// él el comportamiento sigue siendo "ante cualquier fallo, devolver null y NO
// enviar nada". Esa garantía es intencional y no debe romperse.
export class AiError extends Error {
  constructor(public code: string, message: string) {
    super(message);
    this.name = 'AiError';
  }
}

// Corta la espera de una promesa a los `ms` indicados. Importante: NO cancela la
// request subyacente (el SDK la seguirá resolviendo en background), solo deja de
// esperarla para poder responderle al operador en un tiempo acotado.
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) =>
      setTimeout(
        () => reject(new AiError('timeout', `La IA no respondió en ${Math.round(ms / 1000)}s.`)),
        ms
      )
    ),
  ]);
}

// Traduce un error crudo del proveedor a un AiError con `code` estable. Mira el
// status HTTP del SDK (OpenAI/DeepSeek lo exponen en `.status`) y, como fallback,
// olfatea el mensaje de Gemini (que lanza al bloquear por safety).
function classifyAiError(error: any): AiError {
  if (error instanceof AiError) return error;
  const status = error?.status ?? error?.response?.status;
  const msg = error?.message || 'Error desconocido del proveedor de IA';
  if (status === 401 || status === 403) {
    return new AiError('auth', 'Credenciales del proveedor de IA inválidas o sin permisos.');
  }
  if (status === 429) {
    return new AiError('rate_limit', 'El proveedor de IA está saturado o alcanzaste el límite de uso.');
  }
  if (typeof status === 'number' && status >= 500) {
    return new AiError('provider_down', 'El proveedor de IA tuvo un error interno.');
  }
  if (/safety|blocked|candidate|recitation/i.test(msg)) {
    return new AiError('safety_block', 'La respuesta fue bloqueada por los filtros de seguridad del modelo.');
  }
  return new AiError('provider_error', msg);
}

// ─────────────────────────────────────────────────────────────────────────
// Ciclos de IA cancelables
// ─────────────────────────────────────────────────────────────────────────
// Un ciclo va desde que dispara el buffer hasta que sale el último chunk.
// Si el cliente escribe en medio, la respuesta que estábamos generando (o
// terminando de enviar) ya nació vieja: la cortamos ahí mismo y dejamos que el
// buffer nuevo produzca una que sí conteste lo último que dijo. Es lo que haría
// una persona que ve entrar un mensaje mientras escribe: se detiene y ajusta.
// Los chunks ya enviados se quedan, igual que en una conversación real.
type AiCycle = { cancelled: boolean };
const activeAiCycles = new Map<string, AiCycle>();

function cycleKey(sessionKey: string, contactPhone: string): string {
  return `${sessionKey}:${contactPhone}`;
}

// Corta el ciclo de IA en vuelo de ese chat. Devuelve true si había uno activo.
export function cancelAiCycle(sessionKey: string, contactPhone: string): boolean {
  const cycle = activeAiCycles.get(cycleKey(sessionKey, contactPhone));
  if (!cycle || cycle.cancelled) return false;
  cycle.cancelled = true;
  return true;
}

// IDs de los mensajes que envió la propia IA. La rama `fromMe` de
// `messages.upsert` los consulta para no confundir un chunk del asistente con
// "el humano tomó el control": esa confusión cancelaba el buffer que el cliente
// acababa de crear al escribir durante el envío, y se tragaba su mensaje sin
// responderlo ni marcarlo como pendiente. TTL corto: solo hace falta vivo hasta
// que llegue el upsert del propio envío.
const AI_SENT_ID_TTL_MS = 60_000;
const aiSentMessageIds = new Set<string>();

export function isAiSentMessage(messageId: string): boolean {
  return aiSentMessageIds.has(messageId);
}

function rememberAiSentMessage(messageId: string): void {
  aiSentMessageIds.add(messageId);
  setTimeout(() => aiSentMessageIds.delete(messageId), AI_SENT_ID_TTL_MS);
}

export function emitAiState(
  accountId: string,
  sessionKey: string,
  contactPhone: string,
  state: AiLifecycleState,
  expectedRespondAt?: number,
): void {
  const io = getIO();
  if (!io) return;
  const payload: Record<string, unknown> = { sessionKey, contactPhone, state };
  if (expectedRespondAt !== undefined) {
    payload.expectedRespondAt = expectedRespondAt;
  }
  io.to(accountId).emit('ai_state', payload);
}

// Check if current time is within active hours
export function isWithinActiveHours(aiConfig: any): boolean {
  if (!aiConfig.activeHours?.enabled) {
    return true; // Active hours disabled = always within hours
  }

  try {
    const { timezone, start, end } = aiConfig.activeHours;
    if (!timezone || !start || !end) {
      return true; // Invalid config = allow
    }

    // Get current time in the specified timezone
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });

    const currentTimeStr = formatter.format(new Date());
    const [currentHour, currentMinute] = currentTimeStr.split(':').map(Number);
    const currentTime = currentHour * 60 + currentMinute; // Minutes since midnight

    // Parse start and end times
    const [startHour, startMinute] = start.split(':').map(Number);
    const [endHour, endMinute] = end.split(':').map(Number);

    const startTime = startHour * 60 + startMinute;
    const endTime = endHour * 60 + endMinute;

    // Check if current time is within range
    if (startTime <= endTime) {
      // Normal case: 09:00 - 18:00
      return currentTime >= startTime && currentTime < endTime;
    } else {
      // Overnight case: 22:00 - 06:00
      return currentTime >= startTime || currentTime < endTime;
    }
  } catch (error) {
    console.error('[AI] Error checking active hours:', error);
    return true; // On error, allow response
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Conciencia temporal del asistente
// ─────────────────────────────────────────────────────────────────────────
// Por defecto todos los clientes son de México. Si el negocio configuró una
// zona horaria en sus horas activas, la respetamos; si no, caemos en MX.
export const DEFAULT_TIMEZONE = 'America/Mexico_City';

export function getSessionTimezone(aiConfig: any): string {
  return aiConfig?.activeHours?.timezone || DEFAULT_TIMEZONE;
}

// Bloque que le dice al modelo qué fecha/hora es AHORA. Se antepone al system
// prompt para que pueda saludar acorde al momento del día y razonar fechas al
// agendar ("¿para qué día?" sabiendo cuál es hoy).
export function buildTemporalContext(timezone: string): string {
  const ahora = new Intl.DateTimeFormat('es-MX', {
    timeZone: timezone,
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  }).format(new Date());
  return `[Contexto temporal] Ahora mismo es ${ahora} (zona horaria ${timezone}). Usa esta fecha y hora para saludar acorde al momento del día y para razonar sobre fechas al agendar.`;
}

// Nota que explica al modelo que los corchetes de fecha/hora en el historial
// son metadata, no contenido. Clave para matar el "Hola de nuevo": si ve que
// los mensajes llegaron con segundos de diferencia, entiende que es una
// conversación fresca y continua, no un reencuentro tras días.
const TIMESTAMP_METADATA_NOTE =
  'En el historial, cada mensaje viene prefijado con su fecha/hora entre corchetes, ej. "[dom 8 jun, 1:49 p. m.]". Eso es METADATA INTERNA para que percibas cuánto tiempo pasó entre mensajes: úsalo para no saludar como "de nuevo" si la conversación es continua, ni asumir que retomas algo viejo cuando en realidad acaba de empezar.\n\nREGLA DE SALUDO ÚNICO: saluda a lo sumo UNA vez por conversación activa. Si en el historial ya hay un saludo en un turno del asistente (lo hayas escrito tú o el equipo humano, para el cliente es la misma persona) y según los timestamps han pasado menos de ~4 horas desde ese intercambio, NO abras tu respuesta con "Hola", "Buenas tardes" ni similar: responde directo al mensaje, como una persona que continúa la misma charla. Vuelve a saludar solo si el cliente retoma tras una pausa larga (varias horas o un día distinto). Esta regla tiene prioridad sobre cualquier instrucción genérica de "saludar cálidamente": esas aplican al INICIO de la conversación, no a cada mensaje.\n\nREGLA ESTRICTA DE FORMATO DE SALIDA: tu respuesta es un mensaje de WhatsApp que verá el cliente. NUNCA escribas corchetes con fecha ni hora, ni imites ese formato "[día, hora]" al inicio ni en medio de tu texto. El cliente jamás debe ver una marca de tiempo entre corchetes. Empieza tu respuesta directamente con el contenido, sin ningún corchete.';

// Red de seguridad: aunque el prompt le pide explícitamente al modelo NO copiar
// los corchetes de fecha/hora del historial, a veces igual se filtran (los LLM
// no siguen instrucciones de formato al 100%). Acá eliminamos cualquier bloque
// "[ ... H:MM ... ]" que el modelo haya prependeado o incrustado imitando la
// metadata temporal. El patrón exige una hora tipo "1:49" dentro del corchete,
// así no tocamos corchetes legítimos del negocio (ej. "[NOTA]", "[oferta 2x1]").
function stripTimestampBrackets(text: string): string {
  return text.replace(/\[[^\]\n]*\d{1,2}:\d{2}[^\]\n]*\]\s*/g, '').trimStart();
}

// Formatea el timestamp de un mensaje (Firestore Timestamp, epoch ms o ISO)
// a una etiqueta compacta en la zona del negocio. Devuelve null si no parsea.
function formatMessageTimestamp(ts: any, timezone: string): string | null {
  try {
    let date: Date;
    if (ts?.toDate) date = ts.toDate(); // Firestore Timestamp
    else if (typeof ts?._seconds === 'number') date = new Date(ts._seconds * 1000);
    else if (typeof ts === 'string' || typeof ts === 'number') date = new Date(ts);
    else return null;
    if (isNaN(date.getTime())) return null;
    return new Intl.DateTimeFormat('es-MX', {
      timeZone: timezone,
      weekday: 'short',
      day: 'numeric',
      month: 'short',
      hour: 'numeric',
      minute: '2-digit',
      hour12: true,
    }).format(date);
  } catch {
    return null;
  }
}

// Generate AI response using Gemini or OpenAI.
//
// Contrato: `history` ya contiene la conversación completa incluyendo el
// último turn del cliente al final (los mensajes del buffer se persisten en
// Firestore ANTES de que dispare `processMessageBuffer`, así que el history
// recuperado los incluye como turns naturales). No hay un `userMessage`
// separado para evitar duplicación.
export async function generateAIResponse(
  apiKey: string,
  systemPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  provider: AiProvider = 'gemini',
  openaiApiKey?: string,
  deepseekApiKey?: string,
  timezone: string = DEFAULT_TIMEZONE,
  operatorInstruction?: string,
  // Opciones SOLO usadas por el endpoint manual (copiloto). El auto-responder no
  // las pasa → `throwOnError=false` y sin timeout = comportamiento idéntico al
  // histórico: ante cualquier fallo devuelve `text: null` y el caller NO envía
  // nada. El truncamiento sí viaja siempre en el resultado, para los dos modos.
  options?: { throwOnError?: boolean; timeoutMs?: number }
): Promise<AiGenerationResult> {
  const throwOnError = options?.throwOnError ?? false;
  const timeoutMs = options?.timeoutMs;
  try {
    // Sin historial no hay nada que responder (caso muy edge: Firestore vacío).
    if (!history || history.length === 0) {
      if (throwOnError) throw new AiError('empty_history', 'No hay mensajes suficientes para generar una respuesta.');
      console.warn('[AI] generateAIResponse llamado con history vacío, abortando.');
      return { text: null, truncated: false };
    }

    // Enriquecemos el system prompt con conciencia temporal: qué hora es ahora
    // + cómo interpretar los timestamps del historial. Esto vale para los 3
    // providers, por eso se hace acá una sola vez.
    // Instrucción puntual del operador humano (modo copiloto). Efímera: guía
    // SOLO esta generación, no muta el system prompt de la sesión. NO se anexa
    // al system prompt: ahí queda enterrada lejos del punto de generación (en
    // Gemini el system entero se prependea al PRIMER turn user, a ~20 turnos
    // del final) y pierde contra las reglas duras del prompt del negocio
    // ("REGLA BLOQUEANTE", plantillas EXACTAS). Se inyecta al FINAL de la
    // conversación —donde el modelo pone máxima atención— con estrategia por
    // provider: OpenAI/DeepSeek como mensaje `system` de cierre; Gemini
    // fusionada al último turn user.
    const operatorNote = operatorInstruction?.trim()
      ? buildOperatorNote(operatorInstruction.trim())
      : undefined;
    const temporalSystemPrompt = `${buildTemporalContext(timezone)}\n\n${TIMESTAMP_METADATA_NOTE}\n\n${systemPrompt}`;

    let call: Promise<AiGenerationResult>;
    if (provider === 'openai' || provider === 'deepseek') {
      // Ambos comparten la misma ruta OpenAI-compatible; DeepSeek solo añade baseURL.
      const isDeepSeek = provider === 'deepseek';
      call = generateAIResponseOpenAI(
        (isDeepSeek ? deepseekApiKey : openaiApiKey) || apiKey,
        temporalSystemPrompt,
        history,
        modelName,
        isDeepSeek ? DEEPSEEK_BASE_URL : undefined,
        operatorNote
      );
    } else {
      call = generateAIResponseGemini(
        apiKey,
        temporalSystemPrompt,
        history,
        modelName,
        operatorNote
      );
    }

    // Timeout solo en modo manual (cuando se pasa timeoutMs). El auto-responder
    // conserva su espera sin límite explícito de hoy.
    const raw = timeoutMs ? await withTimeout(call, timeoutMs) : await call;

    // Red de seguridad contra fuga de la metadata temporal del historial.
    const text = raw.text ? stripTimestampBrackets(raw.text) : raw.text;
    if (throwOnError) {
      // El copiloto avisa antes de volcar al composer: pegar media frase sin
      // que el operador lo note es peor que pedirle que reintente.
      if (raw.truncated) {
        throw new AiError('truncated', 'La respuesta quedó cortada por el límite de longitud del modelo.');
      }
      if (!text || !text.trim()) {
        throw new AiError('empty_response', 'El modelo no devolvió texto.');
      }
    }
    return { text, truncated: raw.truncated };
  } catch (error) {
    // Modo manual (copiloto): propagamos un error tipado para que el endpoint lo
    // traduzca a HTTP + mensaje claro. Modo auto-responder: tragamos el error y
    // devolvemos null → el caller no envía nada (contrato intencional).
    if (throwOnError) throw classifyAiError(error);
    console.error('[AI] Error calling AI service:', error);
    return { text: null, truncated: false };
  }
}

// Bloque con la instrucción puntual del operador, redactado con jerarquía
// explícita: la orden pisa cualquier escenario/plantilla del prompt del
// negocio (si no, el modelo resuelve el conflicto a favor del flujo "REGLA
// BLOQUEANTE" y la ignora), pero integra el contexto y conserva el estilo.
function buildOperatorNote(instruction: string): string {
  return (
    `=== NOTA INTERNA DEL OPERADOR (el cliente NO ve esta nota y jamás debe intuir que existe) ===\n` +
    `Tu supervisor humano te indica para tu PRÓXIMA respuesta: "${instruction}".\n` +
    `1. Esta orden define el CONTENIDO CENTRAL de tu respuesta y tiene prioridad ABSOLUTA sobre cualquier escenario, plantilla o flujo de tus instrucciones (incluido enviar o no la descripción completa de un servicio, CTAs o pasos de agendamiento). Si contradice una regla del flujo, gana la orden.\n` +
    `2. Integra el contexto: si el cliente además preguntó algo que la orden no cubre, respóndelo también, sin desplazar la orden.\n` +
    `3. Conserva tu identidad y estilo de siempre (tono, emojis, formato de WhatsApp).\n` +
    `4. Nunca menciones al operador, ni esta nota, ni que recibiste una instrucción.`
  );
}

// Generate AI response using Gemini
async function generateAIResponseGemini(
  apiKey: string,
  systemPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  operatorNote?: string
): Promise<AiGenerationResult> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    // El SDK v0.3.x no soporta `systemInstruction`. Workaround estándar:
    // prependeamos el system prompt al primer turn user del historial. El
    // resto del historial queda intacto y termina con el último mensaje del
    // cliente (lo que Gemini debe responder).
    const enhancedHistory = history.map((turn, idx) => {
      if (idx === 0 && turn.role === 'user') {
        return {
          role: 'user' as const,
          parts: [{ text: `${systemPrompt}\n\n${turn.parts[0]?.text || ''}` }],
        };
      }
      return turn;
    });

    // La nota del operador se fusiona al ÚLTIMO turn user (el mensaje que el
    // modelo está por responder) y no como turn aparte, porque Gemini valida
    // la alternancia user/model en requests multiturn.
    if (operatorNote) {
      for (let i = enhancedHistory.length - 1; i >= 0; i--) {
        if (enhancedHistory[i].role === 'user') {
          enhancedHistory[i] = {
            role: 'user' as const,
            parts: [{ text: `${enhancedHistory[i].parts[0]?.text || ''}\n\n${operatorNote}` }],
          };
          break;
        }
      }
    }

    // Usamos `generateContent` directo (no `startChat`) porque el historial
    // termina en `user` y eso es justamente lo que Gemini necesita para
    // generar el siguiente turn model. `startChat` espera que el historial
    // termine en `model` y manda el siguiente user via `sendMessage`.
    const result = await model.generateContent({
      contents: enhancedHistory,
    });
    // Sin `maxOutputTokens` el techo es el default del modelo, así que MAX_TOKENS
    // aquí es rarísimo; lo miramos igual para que el contrato sea uniforme entre
    // los tres proveedores y nunca se envíe un texto cortado.
    const finishReason = result.response.candidates?.[0]?.finishReason;
    const text = result.response.text();
    console.log(
      `[AI] gemini model=${modelName} finish=${finishReason ?? 'n/a'} chars=${text?.length ?? 0}`
    );
    return { text, truncated: finishReason === 'MAX_TOKENS' };
  } catch (error) {
    // Logueamos y re-lanzamos: el catch externo de generateAIResponse decide si
    // tragar (auto-responder → null) o clasificar y propagar (manual → throw).
    console.error('[AI] Error calling Gemini:', error);
    throw error;
  }
}

// Generate AI response using OpenAI (o cualquier API compatible: DeepSeek).
// `baseURL` undefined → OpenAI oficial; con valor → endpoint compatible.
async function generateAIResponseOpenAI(
  apiKey: string,
  systemPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gpt-4.1-mini',
  baseURL?: string,
  operatorNote?: string
): Promise<AiGenerationResult> {
  try {
    const client = new OpenAI({ apiKey, ...(baseURL && { baseURL }) });

    // La nota del operador va como mensaje `system` de CIERRE (después del
    // último mensaje del cliente): es el mecanismo estándar de steering y pesa
    // mucho más que texto dentro del system prompt inicial.
    const messages: OpenAI.Chat.ChatCompletionMessageParam[] = [
      {
        role: 'system',
        content: systemPrompt,
      },
      ...history.map(msg => ({
        role: (msg.role === 'user' ? 'user' : 'assistant') as 'user' | 'assistant',
        content: msg.parts[0]?.text || '',
      })),
      ...(operatorNote ? [{ role: 'system' as const, content: operatorNote }] : []),
    ];

    const reasoning = isReasoningModel(modelName);
    const response = await client.chat.completions.create({
      model: modelName,
      messages,
      ...(reasoning ? {} : { temperature: 0.7 }),
      ...(reasoning
        ? { max_completion_tokens: AI_MAX_OUTPUT_TOKENS }
        : { max_tokens: AI_MAX_OUTPUT_TOKENS }),
    });

    // `finish_reason: 'length'` = el modelo agotó el presupuesto y cortó a media
    // frase. Antes se devolvía como si fuera una respuesta sana y salía así al
    // cliente. Logueamos el consumo para poder ver en producción si algún
    // prompt de negocio se está acercando al techo.
    const choice = response.choices[0];
    const usage = response.usage;
    const reasoningTokens =
      (usage?.completion_tokens_details as { reasoning_tokens?: number } | undefined)?.reasoning_tokens ?? 0;
    console.log(
      `[AI] ${baseURL ? 'deepseek' : 'openai'} model=${modelName} finish=${choice?.finish_reason ?? 'n/a'} ` +
      `completion_tokens=${usage?.completion_tokens ?? '?'} reasoning_tokens=${reasoningTokens} ` +
      `chars=${choice?.message.content?.length ?? 0}`
    );

    return {
      text: choice?.message.content || null,
      truncated: choice?.finish_reason === 'length',
    };
  } catch (error) {
    // Logueamos y re-lanzamos: el catch externo de generateAIResponse decide si
    // tragar (auto-responder → null) o clasificar y propagar (manual → throw).
    console.error('[AI] Error calling OpenAI:', error);
    throw error;
  }
}

// Etiquetas para representar adjuntos en el historial que ve el modelo.
const MEDIA_HISTORY_LABEL: Record<string, string> = {
  image: 'una imagen',
  audio: 'un audio',
  video: 'un video',
  document: 'un documento',
};

// Placeholder textual del adjunto de un mensaje, o null si no aplica (sin
// media, sticker o GIF decorativo). Antes la media sin caption era invisible
// para el modelo: el asistente respondía como si el cliente no hubiera
// enviado nada (ej. repetía instrucciones de pago tras recibir el
// comprobante). El placeholder le da la existencia del adjunto sin fingir
// que puede abrirlo.
function mediaPlaceholder(d: any): string | null {
  const type = d?.mediaType as string | undefined;
  if (!type || type === 'sticker') return null;
  if (type === 'video' && d?.mediaIsGif) return null;
  const label = MEDIA_HISTORY_LABEL[type];
  if (!label) return null;
  return d.fromMe
    ? `[Adjuntaste ${label} en este mensaje]`
    : `[El cliente adjuntó ${label}; no puedes ver ni escuchar su contenido]`;
}

// Normalize message history to preserve all messages for better context.
// Cada turn se prefija con su fecha/hora ([dom 8 jun, 1:49 p. m.]) como
// metadata para que el modelo perciba el tiempo transcurrido entre mensajes.
// Los mensajes con adjunto no decorativo entran como placeholder (+ caption
// si traía) en vez de descartarse.
export function normalizeHistory(
  rawDocs: any[],
  timezone: string = DEFAULT_TIMEZONE
): { role: 'user' | 'model'; parts: { text: string }[] }[] {
  return rawDocs
    .map(d => {
      const rawText = typeof d.text === 'string' ? d.text.trim() : '';
      const placeholder = mediaPlaceholder(d);
      if (!rawText && !placeholder) return null;
      const body = placeholder
        ? (rawText ? `${placeholder} ${rawText}` : placeholder)
        : rawText;
      const stamp = formatMessageTimestamp(d.timestamp, timezone);
      const text = stamp ? `[${stamp}] ${body}` : body;
      return {
        role: d.fromMe ? ('model' as const) : ('user' as const),
        parts: [{ text }],
      };
    })
    .filter((t): t is { role: 'user' | 'model'; parts: { text: string }[] } => t !== null);
}

// Construye el transcripto de la conversación en texto plano para que el
// discriminador lo lea como contexto. Etiquetas en español; agrupamos los
// últimos turns user contiguos como "intención más reciente" implícita
// (el LLM la identifica sola a partir del orden).
function buildTranscript(
  history: { role: 'user' | 'model'; parts: { text: string }[] }[]
): string {
  if (!history || history.length === 0) return '(historial vacío)';
  return history
    .map(msg => {
      const role = msg.role === 'user' ? 'Cliente' : 'Asistente';
      return `${role}: ${msg.parts[0]?.text || ''}`;
    })
    .join('\n');
}

// Parser tolerante: busca "Decisión: X" donde X ∈ {AI, ASISTENTE, SI, HUMANO,
// HUMAN, NO}. Si no parsea, defaultea a TalkToAiAssistant (seguro: dejamos
// que la IA responda en vez de bloquear al cliente).
function parseDiscriminatorDecision(
  raw: string
): { decision: 'TalkToAiAssistant' | 'TalkToHuman'; reason: string } {
  const text = (raw || '').trim();
  const upper = text.toUpperCase();

  const decisionMatch = upper.match(/DECISI[ÓO]N\s*:\s*(AI|ASISTENTE|SI|S[IÍ]|HUMANO|HUMAN|NO)/);
  const reasonMatch = text.match(/Raz[óo]n\s*:\s*(.+?)(?:\n|$)/i);
  const reason = reasonMatch?.[1]?.trim() || '(sin razón)';

  if (decisionMatch) {
    const token = decisionMatch[1];
    if (token === 'HUMANO' || token === 'HUMAN' || token === 'NO') {
      return { decision: 'TalkToHuman', reason };
    }
    return { decision: 'TalkToAiAssistant', reason };
  }

  // Fallback ambiguo: HUMANO. Si no pudimos parsear la respuesta del modelo,
  // es más seguro escalar a humano que dejar que la IA responda con
  // información posiblemente incorrecta sobre algo que ni entendimos.
  return { decision: 'TalkToHuman', reason: `(parse fallido) ${text.substring(0, 120)}` };
}

// Classify message intent using discriminator (TalkToAiAssistant or TalkToHuman)
//
// CÓMO FUNCIONA:
// 1. El operador escribe sus reglas en lenguaje natural (las edita en
//    SessionSettingsPanel y se guardan en `ai_discriminator_prompt`).
// 2. Las reglas + criterios generales se envían como `system` (OpenAI) o
//    como sección "INSTRUCCIONES DEL OPERADOR" (Gemini v0.3.x, sin
//    systemInstruction nativo).
// 3. El historial completo (que ya incluye el burst del cliente al final)
//    va como contenido a clasificar.
// 4. El modelo responde:
//      Decisión: AI | HUMANO
//      Razón: <una frase>
// 5. Parseamos y devolvemos.
export async function classifyMessageIntent(
  apiKey: string,
  discriminatorPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  provider: AiProvider = 'gemini',
  openaiApiKey?: string,
  deepseekApiKey?: string,
  timezone: string = DEFAULT_TIMEZONE
): Promise<'TalkToAiAssistant' | 'TalkToHuman'> {
  try {
    if (provider === 'openai' || provider === 'deepseek') {
      // Ruta OpenAI-compatible compartida; DeepSeek solo cambia baseURL y key.
      const isDeepSeek = provider === 'deepseek';
      return await classifyMessageIntentOpenAI(
        (isDeepSeek ? deepseekApiKey : openaiApiKey) || apiKey,
        discriminatorPrompt,
        history,
        modelName,
        isDeepSeek ? DEEPSEEK_BASE_URL : undefined,
        timezone
      );
    } else {
      return await classifyMessageIntentGemini(
        apiKey,
        discriminatorPrompt,
        history,
        modelName,
        timezone
      );
    }
  } catch (error) {
    console.error('[Discriminator] Error classifying intent:', error);
    return 'TalkToAiAssistant';
  }
}

// Bloque común de criterios que ayudan al modelo a clasificar bien.
// Se inyecta en el prompt junto con las reglas del operador.
const DISCRIMINATOR_META_INSTRUCTIONS = `Eres un clasificador de intenciones en una conversación de WhatsApp entre un cliente y un asistente virtual. Tu única tarea es analizar el HISTORIAL completo y decidir si la INTENCIÓN MÁS RECIENTE del cliente (los últimos mensajes consecutivos del cliente al final del historial) puede responderla el asistente o requiere un humano.

GUÍAS GENERALES:
- Las reglas del operador pueden tener dos secciones:
  • "Pasa al humano si: ..." → casos donde debés clasificar como HUMANO.
  • "Pasa al asistente si: ..." → casos donde debés clasificar como AI.
  Si la intención más reciente matchea ambas listas al mismo tiempo, prevalece HUMANO (por seguridad).
- Si la intención más reciente no matchea claramente NINGUNA de las dos listas, preferí HUMANO. Es mejor que un humano responda algo no previsto a que el asistente entregue una respuesta incorrecta o imprecisa.
- La intención más reciente puede estar fragmentada en varios mensajes consecutivos del cliente. Analizalos como una sola unidad de intención.
- Si el último mensaje del cliente es una respuesta breve ("sí", "ok", "claro", "no"), interpretalo en función del último mensaje del asistente. La respuesta cobra significado por el contexto.
- Si el historial es corto pero el mensaje del cliente es claro y general (saludo inicial, consulta sobre un servicio), clasificá por el CONTENIDO del mensaje — no escales a humano solo por falta de historial.`;

// Classify using Gemini (SDK v0.3.x: sin systemInstruction nativo)
async function classifyMessageIntentGemini(
  apiKey: string,
  discriminatorPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  timezone: string = DEFAULT_TIMEZONE
): Promise<'TalkToAiAssistant' | 'TalkToHuman'> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    const transcript = buildTranscript(history);

    const prompt = `### INSTRUCCIONES DEL OPERADOR (reglas del negocio)
${discriminatorPrompt}

### CONTEXTO TEMPORAL
${buildTemporalContext(timezone)}

### CONTEXTO Y CRITERIOS
${DISCRIMINATOR_META_INSTRUCTIONS}

### HISTORIAL DE LA CONVERSACIÓN
${transcript}

### TU RESPUESTA (formato obligatorio, sin texto extra)
Decisión: <AI | HUMANO>
Razón: <una frase breve explicando por qué>`;

    const result = await model.generateContent({
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 200,
      },
    });

    const responseText = result.response.text();
    console.log(`[Discriminator] Gemini raw response: ${responseText.substring(0, 200)}`);

    const { decision } = parseDiscriminatorDecision(responseText);
    return decision;
  } catch (error) {
    console.error('[Discriminator] Error classifying intent with Gemini:', error);
    return 'TalkToAiAssistant';
  }
}

// Classify using OpenAI (sí tiene `role: system` nativo). También sirve para
// DeepSeek vía `baseURL` (mismo protocolo).
async function classifyMessageIntentOpenAI(
  apiKey: string,
  discriminatorPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gpt-4.1-mini',
  baseURL?: string,
  timezone: string = DEFAULT_TIMEZONE
): Promise<'TalkToAiAssistant' | 'TalkToHuman'> {
  try {
    const client = new OpenAI({ apiKey, ...(baseURL && { baseURL }) });

    const transcript = buildTranscript(history);

    const systemContent = `${DISCRIMINATOR_META_INSTRUCTIONS}

### CONTEXTO TEMPORAL
${buildTemporalContext(timezone)}

### REGLAS DEL OPERADOR
${discriminatorPrompt}`;

    const userContent = `### HISTORIAL DE LA CONVERSACIÓN
${transcript}

### TU RESPUESTA (formato obligatorio, sin texto extra)
Decisión: <AI | HUMANO>
Razón: <una frase breve explicando por qué>`;

    const response = await client.chat.completions.create({
      model: modelName,
      messages: [
        { role: 'system', content: systemContent },
        { role: 'user', content: userContent },
      ],
      temperature: 0.1,
      max_tokens: 200,
    });

    const responseText = response.choices[0]?.message.content || '';
    console.log(`[Discriminator] OpenAI raw response: ${responseText.substring(0, 200)}`);

    const { decision } = parseDiscriminatorDecision(responseText);
    return decision;
  } catch (error) {
    console.error('[Discriminator] Error classifying intent with OpenAI:', error);
    return 'TalkToAiAssistant';
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Agente de Seguimiento de Ventas (Re-engagement)
// ─────────────────────────────────────────────────────────────────────────
// Gemelo del Discriminador, pero en vez de "¿IA o humano?" responde
// "¿vale la pena reactivar este lead frío?". El operador escribe las reglas de
// exclusión en lenguaje natural (chats personales, ya cerrados, "luego te aviso",
// etc.) y el modelo lee la conversación completa para decidir FOLLOW_UP | SKIP.

// Parser tolerante para la decisión de seguimiento. Default SEGURO = SKIP:
// inverso al discriminador. Ante la duda NO molestamos al cliente (mejor perder
// un seguimiento que mandar un mensaje no deseado a alguien que ya cerró o es
// una conversación personal).
function parseFollowupDecision(
  raw: string
): { decision: 'FOLLOW_UP' | 'SKIP'; reason: string } {
  const text = (raw || '').trim();
  const upper = text.toUpperCase();

  const decisionMatch = upper.match(/DECISI[ÓO]N\s*:\s*(FOLLOW[_\s-]?UP|SEGUIR|S[IÍ]|SKIP|OMITIR|NO)/);
  const reasonMatch = text.match(/Raz[óo]n\s*:\s*(.+?)(?:\n|$)/i);
  const reason = reasonMatch?.[1]?.trim() || '(sin razón)';

  if (decisionMatch) {
    const token = decisionMatch[1].replace(/[_\s-]/g, '');
    if (token === 'FOLLOWUP' || token === 'SEGUIR' || token === 'SI' || token === 'SÍ') {
      return { decision: 'FOLLOW_UP', reason };
    }
    return { decision: 'SKIP', reason };
  }

  // Sin parseo claro → SKIP (no molestar). Guardamos un recorte para auditar.
  return { decision: 'SKIP', reason: `(parse fallido) ${text.substring(0, 120)}` };
}

// Criterios comunes que ayudan al modelo a no reactivar leads que no debe.
// Se inyectan junto con las reglas del operador.
const FOLLOWUP_META_INSTRUCTIONS = `Eres un analista de ventas que revisa una conversación de WhatsApp YA FRÍA (el cliente dejó de responder hace ~1 día). Tu única tarea es decidir si vale la pena enviar UN mensaje de seguimiento para intentar cerrar la venta, o si hay que dejar la conversación en paz.

GUÍAS GENERALES (clasifica como SKIP cuando):
- La venta YA se cerró (hay confirmación de cita/compra, agradecimiento de cierre, o el negocio ya envió un mensaje de confirmación).
- Es una conversación PERSONAL o no comercial (familiar, amistad, proveedor, spam, número equivocado).
- El cliente pidió explícitamente NO ser contactado, dijo "luego te aviso", "yo te escribo", "lo pienso y te digo", o rechazó la oferta.
- El cliente ya está siendo atendido activamente por un humano y la conversación sigue viva.
- No hay ninguna intención de compra real (solo saludó, se equivocó, o preguntó algo no relacionado con servicios).

Clasifica como FOLLOW_UP SÓLO cuando: el cliente mostró interés en un servicio o producto (preguntó precios, disponibilidad, detalles) pero la conversación se enfrió SIN cerrar y SIN una negativa ni un "yo te aviso". Ese es el lead recuperable.

Ante la duda, responde SKIP. Es mejor no molestar a un cliente que mandar un mensaje inoportuno.`;

// Clasifica un chat frío como FOLLOW_UP | SKIP. Misma forma que
// classifyMessageIntent (routing por provider). Default SKIP ante error.
export async function classifyFollowupCandidate(
  apiKey: string,
  exclusionPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  provider: AiProvider = 'gemini',
  openaiApiKey?: string,
  deepseekApiKey?: string,
  timezone: string = DEFAULT_TIMEZONE
): Promise<{ decision: 'FOLLOW_UP' | 'SKIP'; reason: string }> {
  try {
    const transcript = buildTranscript(history);

    const operatorRules = exclusionPrompt?.trim()
      ? exclusionPrompt.trim()
      : '(El operador no definió reglas extra; usa solo las guías generales.)';

    // Una sola pasada al proveedor que devuelve el texto crudo. La envolvemos en
    // un reintento porque DeepSeek (y a veces OpenAI) devuelve contenido vacío de
    // forma intermitente; sin reintento ese vacío caía en parse fallido → SKIP,
    // descartando leads válidos.
    const runOnce = async (): Promise<string> => {
      if (provider === 'openai' || provider === 'deepseek') {
        const isDeepSeek = provider === 'deepseek';
        const client = new OpenAI({
          apiKey: (isDeepSeek ? deepseekApiKey : openaiApiKey) || apiKey,
          ...(isDeepSeek && { baseURL: DEEPSEEK_BASE_URL }),
        });
        const systemContent = `${FOLLOWUP_META_INSTRUCTIONS}

### CONTEXTO TEMPORAL
${buildTemporalContext(timezone)}

### REGLAS DE EXCLUSIÓN DEL OPERADOR
${operatorRules}`;
        const userContent = `### HISTORIAL DE LA CONVERSACIÓN
${transcript}

### TU RESPUESTA (formato obligatorio, sin texto extra)
Decisión: <FOLLOW_UP | SKIP>
Razón: <una frase breve explicando por qué>`;
        const response = await client.chat.completions.create({
          model: modelName,
          messages: [
            { role: 'system', content: systemContent },
            { role: 'user', content: userContent },
          ],
          temperature: 0.1,
          max_tokens: 200,
        });
        return response.choices[0]?.message.content || '';
      }

      // Gemini (sin systemInstruction nativo en v0.3.x): todo en un prompt user.
      const genAI = new GoogleGenerativeAI(apiKey);
      const model = genAI.getGenerativeModel({ model: modelName });
      const prompt = `### REGLAS DE EXCLUSIÓN DEL OPERADOR
${operatorRules}

### CONTEXTO TEMPORAL
${buildTemporalContext(timezone)}

### CONTEXTO Y CRITERIOS
${FOLLOWUP_META_INSTRUCTIONS}

### HISTORIAL DE LA CONVERSACIÓN
${transcript}

### TU RESPUESTA (formato obligatorio, sin texto extra)
Decisión: <FOLLOW_UP | SKIP>
Razón: <una frase breve explicando por qué>`;
      const result = await model.generateContent({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0.1, maxOutputTokens: 200 },
      });
      return result.response.text();
    };

    let responseText = await runOnce();
    if (!responseText.trim()) {
      console.warn(`[Followup] ${provider} devolvió vacío, reintentando una vez`);
      responseText = await runOnce();
    }
    console.log(`[Followup] ${provider} raw: ${responseText.substring(0, 200)}`);
    return parseFollowupDecision(responseText);
  } catch (error) {
    // Ante cualquier fallo → SKIP (no molestar al cliente).
    console.error('[Followup] Error clasificando candidato:', error);
    return { decision: 'SKIP', reason: '(error del clasificador IA)' };
  }
}

// Redacta el mensaje de seguimiento reusando generateAIResponse. El history
// puede terminar en un turn `model` (el último mensaje lo enviamos nosotros) y
// Gemini exige cerrar en `user`; por eso anexamos una instrucción `user`
// sintética. Vale para los 3 providers. Devuelve null si la IA falla (el caller
// no encola nada en ese caso).
export async function draftFollowupMessage(
  apiKey: string,
  messagePrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash',
  provider: AiProvider = 'gemini',
  openaiApiKey?: string,
  deepseekApiKey?: string,
  timezone: string = DEFAULT_TIMEZONE
): Promise<string | null> {
  const systemPrompt = `Eres un asistente de ventas redactando UN mensaje de seguimiento por WhatsApp para retomar una conversación que quedó fría sin cerrar la venta.

INDICACIONES DEL OPERADOR (tono y contenido):
${messagePrompt?.trim() || 'Sé cálido, cercano y breve. Retoma con naturalidad lo que el cliente preguntó e invítalo a continuar, sin presionar.'}

REGLAS DE REDACCIÓN:
- Escribe UN solo mensaje, breve (1-3 frases), cálido y natural, como lo haría una persona del negocio.
- Haz referencia a lo que el cliente mostró interés (el servicio/producto que preguntó) para que se sienta personal, no genérico.
- No suenes insistente ni desesperado. Una invitación amable, no una venta agresiva.
- No inventes datos (precios, fechas, promociones) que no aparezcan en la conversación.
- Responde SOLO con el texto del mensaje, sin comillas, sin firmar, sin explicaciones.`;

  const syntheticTurn = {
    role: 'user' as const,
    parts: [{ text: '[Instrucción interna: redacta ahora el mensaje de seguimiento según las indicaciones. Responde solo con el mensaje.]' }],
  };

  const result = await generateAIResponse(
    apiKey,
    systemPrompt,
    [...history, syntheticTurn],
    modelName,
    provider,
    openaiApiKey,
    deepseekApiKey,
    timezone
  );

  // Un seguimiento cortado a media frase es peor que no mandar ninguno: el
  // caller no encola nada cuando devolvemos null.
  if (result.truncated) {
    console.warn('[Followup] Mensaje descartado: el modelo lo cortó por límite de longitud.');
    return null;
  }
  return result.text;
}

// Divide la respuesta en grupos de párrafos (alternando 2 y 3) para simular escritura humana.
// Cada chunk enviado se registra en pendingSenders con AI_SENDER para que el
// upsert lo guarde con senderType='ai'.
//
// Entre chunk y chunk pasan hasta 2.5s, así que es la ventana natural para que
// el cliente interrumpa: antes de cada envío consultamos el ciclo y, si fue
// cancelado, dejamos de escupir la respuesta vieja.
async function sendChunkedResponse(
  session: SessionData,
  remoteJid: string,
  response: string,
  cycle: AiCycle,
): Promise<{ sent: number; total: number; cancelled: boolean; failed: boolean }> {
  const sock = session.sock;
  const tagAi = (sent: any) => {
    if (sent?.key?.id) {
      session.pendingSenders.set(sent.key.id, AI_SENDER);
      rememberAiSentMessage(sent.key.id);
    }
  };

  // Un fallo puntual de WhatsApp (blip de conexión, rate limit) no debe dejar la
  // respuesta a medias sin que nadie se entere: reintentamos una vez y, si no
  // sale, el caller deriva el chat a un humano.
  const sendChunk = async (text: string): Promise<boolean> => {
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        tagAi(await sock.sendMessage(remoteJid, { text }));
        return true;
      } catch (error) {
        console.error(`[AI] Error enviando chunk (intento ${attempt}/2):`, error);
        if (attempt === 1) await new Promise(resolve => setTimeout(resolve, 300));
      }
    }
    return false;
  };

  // Armamos los grupos primero para poder razonar sobre "cuántos faltan" al
  // cancelar o fallar. Texto de 1 párrafo = un solo mensaje, sin chunking.
  const chunks = response.split(/\n\n+/);
  const groups: string[] = [];
  if (chunks.length <= 1) {
    groups.push(response.trim());
  } else {
    let i = 0;
    let groupSize = 2;
    while (i < chunks.length) {
      const group = chunks.slice(i, i + groupSize).join('\n\n').trim();
      if (group) groups.push(group);
      i += groupSize;
      groupSize = groupSize === 2 ? 3 : 2;
    }
  }

  let sent = 0;
  for (const group of groups) {
    if (cycle.cancelled) {
      return { sent, total: groups.length, cancelled: true, failed: false };
    }
    if (!(await sendChunk(group))) {
      return { sent, total: groups.length, cancelled: false, failed: true };
    }
    sent++;
    // Delay proporcional a la longitud del chunk (mínimo 800ms, máximo 2500ms)
    if (sent < groups.length) {
      const delay = Math.min(2500, Math.max(800, group.length * 10));
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  return { sent, total: groups.length, cancelled: false, failed: false };
}

// Process buffered messages: fetch history, run discriminator, and send AI response
export async function processMessageBuffer(
  sessionKey: string,
  accountId: string,
  session: SessionData,
  remoteJid: string,
  contactPhone: string,
  aiConfig: any,
  bufferedMessages: string[]
) {
  // Marcamos 'thinking' al inicio: el buffer ya cerró y empieza el trabajo
  // pesado (historial + discriminador + generación). El frontend reemplaza
  // el icono de IA por un spinner mientras dure este bloque.
  emitAiState(accountId, sessionKey, contactPhone, 'thinking');

  // Registramos el ciclo para que un mensaje del cliente pueda cortarlo tanto
  // durante la generación como entre chunks.
  const key = cycleKey(sessionKey, contactPhone);
  const cycle: AiCycle = { cancelled: false };
  activeAiCycles.set(key, cycle);

  // Deriva el chat a un humano: cuenta los pendientes, sella el chat, avisa al
  // CRM en vivo y manda el push. Es el mismo camino para las cuatro razones por
  // las que la IA se abstiene de responder (media que no puede leer,
  // discriminador, respuesta truncada por el modelo y chunk que no salió).
  const escalateToHuman = async (reason: HumanAttentionReason, pending: number) => {
    await incrementUnrespondedCount(accountId, session.phoneNumber!, contactPhone, pending);

    try {
      await getDb()
        .collection(ACCOUNTS_COLLECTION)
        .doc(accountId)
        .collection('whatsapp_sessions')
        .doc(session.phoneNumber!)
        .collection('chats')
        .doc(contactPhone)
        .set(
          { human_attention_at: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true }
        );
    } catch (error) {
      console.error(`[Buffer] Error stamping human_attention_at (${reason}):`, error);
    }

    getIO().to(accountId).emit('human_attention_required', {
      sessionKey,
      chatId: contactPhone,
      phoneNumber: session.phoneNumber,
      timestamp: new Date().toISOString(),
      reason,
    });

    sendHumanAttentionNotification({
      accountId,
      sessionPhone: session.phoneNumber!,
      sessionKey,
      chatId: contactPhone,
      reason,
      messagePreview: bufferedMessages.join('\n'),
    }).catch((err) => console.error(`[Notify] ${reason} push falló:`, err));
  };

  try {
    // Combine all buffered messages into one context
    const combinedMessage = bufferedMessages.join('\n');
    console.log(`[Buffer] Processing ${bufferedMessages.length} message(s) for ${contactPhone}: "${combinedMessage.substring(0, 50)}..."`);

    // Zona horaria del negocio para etiquetar mensajes y el contexto "ahora".
    const timezone = getSessionTimezone(aiConfig);

    // Fetch last 10 messages for conversation history
    let history: { role: 'user' | 'model'; parts: { text: string }[] }[] = [];
    let rawDocs: any[] = [];

    try {
      const historyDocs = await getDb()
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(session.phoneNumber!)
        .collection('chats').doc(contactPhone)
        .collection('messages')
        .orderBy('timestamp', 'desc')
        .limit(20)
        .get();

      rawDocs = historyDocs.docs.reverse().map(d => d.data());
      history = normalizeHistory(rawDocs, timezone);
    } catch (error) {
      console.log('[Buffer] Could not fetch message history, continuing without context:', error);
    }

    // ============================================
    // MEDIA HOLD: complemento con memoria del media gate de index.ts.
    // El gate corta el ciclo cuando LLEGA la media bloqueada; este hold cubre
    // los textos que el cliente manda DESPUÉS ("listo", "¿ya lo viste?"):
    // mientras en el historial reciente haya media entrante que la IA no puede
    // leer sin una respuesta nuestra posterior, la conversación es del humano
    // (ni discriminador ni asistente). Se levanta solo: cualquier mensaje
    // fromMe posterior a la media (CRM, celular físico, WA Web o sugerencia IA
    // enviada) reactiva el flujo normal. Sin estado nuevo en Firestore — se
    // deriva del historial que ya bajamos arriba.
    // ============================================
    let heldByMedia = false;
    for (const doc of rawDocs) {
      if (doc.fromMe) heldByMedia = false;
      else if (isBlockedMediaDoc(doc, aiConfig.mediaAllowlist)) heldByMedia = true;
    }

    if (heldByMedia) {
      // Push en CADA ráfaga a propósito: si el operador olvidó responder la
      // media, cada nuevo mensaje del cliente re-alerta. El collapse tag por
      // chat evita que se apilen en el notification shade.
      await escalateToHuman('unanswered_media', bufferedMessages.length);

      console.log(
        `[MediaHold] ${contactPhone}: media sin responder en el historial, IA en espera ` +
        `(+${bufferedMessages.length} pendientes)`
      );
      // El finally emite 'idle' y libera el spinner del frontend.
      return;
    }

    // DISCRIMINATOR: Check if message should be handled by AI or human
    if (aiConfig.discriminator?.enabled && aiConfig.discriminator?.prompt) {
      console.log(`[Discriminator] Enabled for ${contactPhone}, prompt length: ${aiConfig.discriminator.prompt.length}, history turns: ${history.length}`);
      console.log(`[Discriminator] Last burst (${bufferedMessages.length} msg): "${combinedMessage.substring(0, 80)}..."`);

      // El historial ya contiene el burst del cliente como turns naturales
      // al final (todos los mensajes se persisten antes de que dispare el
      // buffer). Lo pasamos completo al discriminador; él identifica la
      // "intención más reciente" a partir del orden.
      const classification = await classifyMessageIntent(
        aiConfig.apiKey,
        aiConfig.discriminator.prompt,
        history,
        aiConfig.model,
        aiConfig.provider || 'gemini',
        aiConfig.openaiApiKey,
        aiConfig.deepseekApiKey,
        timezone
      );

      if (classification === 'TalkToHuman') {
        // Contamos la ráfaga completa que el discriminador clasificó. El push
        // FCM sale en paralelo: el flujo de IA no espera a la notificación.
        await escalateToHuman('discriminator', bufferedMessages.length);

        console.log(
          `[Buffer] Emitted human_attention_required for ${contactPhone} (+${bufferedMessages.length} unresponded)`
        );
        // Discriminador derivó a humano: terminamos el ciclo de IA → idle
        emitAiState(accountId, sessionKey, contactPhone, 'idle');
        return; // Skip AI response
      }

      console.log(`[Buffer] Discriminator classification: ${classification}, proceeding with AI response`);
    }

    // Generate and send AI response. El history ya termina en el burst del
    // cliente (los mensajes están persistidos en Firestore antes de que el
    // buffer dispare), por eso no pasamos un userMessage separado: estaría
    // duplicado y confunde al modelo (Gemini además rechaza dos turns user
    // consecutivos en el flujo de chat).
    // Si el cliente escribió mientras corría el discriminador, no gastamos una
    // llamada al proveedor para una respuesta que igual descartaríamos abajo.
    if (cycle.cancelled) {
      console.log(`[Buffer] Ciclo cancelado antes de generar para ${contactPhone}`);
      return;
    }

    const aiResponse = await generateAIResponse(
      aiConfig.apiKey,
      aiConfig.systemPrompt || 'Eres un asistente útil.',
      history,
      aiConfig.model,
      aiConfig.provider || 'gemini',
      aiConfig.openaiApiKey,
      aiConfig.deepseekApiKey,
      timezone
    );

    // El cliente escribió mientras el modelo pensaba: esta respuesta ya nació
    // vieja. La descartamos sin enviar nada y dejamos que el buffer nuevo genere
    // la que sí contesta lo último que dijo.
    if (cycle.cancelled) {
      console.log(`[Buffer] Ciclo cancelado durante la generación para ${contactPhone}, respuesta descartada`);
      return;
    }

    // Respuesta truncada por el modelo: mandar media frase al cliente es peor
    // que no mandar nada, así que derivamos el chat al humano.
    if (aiResponse.truncated) {
      console.warn(
        `[Buffer] Respuesta truncada por límite de tokens para ${contactPhone}; no se envía, deriva a humano`
      );
      await escalateToHuman('ai_truncated', bufferedMessages.length);
      return;
    }

    if (aiResponse.text) {
      // Pasamos a 'responding' justo antes de empezar a mandar chunks: este es
      // el momento crítico donde el usuario puede querer interceptar.
      emitAiState(accountId, sessionKey, contactPhone, 'responding');
      const result = await sendChunkedResponse(session, remoteJid, aiResponse.text, cycle);

      if (result.cancelled) {
        // Interrupción deseada, no un error: no reseteamos el contador porque
        // el mensaje que interrumpió sigue pendiente de respuesta.
        console.log(
          `[Buffer] Envío interrumpido por el cliente en ${contactPhone}: ${result.sent}/${result.total} chunks enviados`
        );
        return;
      }

      if (result.failed) {
        console.error(
          `[Buffer] Envío incompleto a ${contactPhone}: ${result.sent}/${result.total} chunks; deriva a humano`
        );
        await escalateToHuman('send_failed', bufferedMessages.length);
        return;
      }

      console.log(`[Buffer] Auto-responded to ${remoteJid} en ${result.total} chunk(s)`);
      // La IA respondió: cualquier pendiente previo queda cubierto
      await resetUnrespondedCount(accountId, session.phoneNumber!, contactPhone);
    }
  } catch (error) {
    console.error('[Buffer] Error processing message buffer:', error);
  } finally {
    // Solo desregistramos si el ciclo en el mapa sigue siendo el nuestro: si nos
    // cancelaron y el buffer nuevo ya arrancó su propio ciclo, borrarlo aquí lo
    // dejaría fuera del alcance de futuras cancelaciones.
    if (activeAiCycles.get(key) === cycle) activeAiCycles.delete(key);
    // Cierre garantizado del ciclo: tanto en éxito como en error volvemos a idle
    // para que el frontend libere el spinner. Si nos cancelaron, no lo emitimos:
    // ya hay un ciclo nuevo en marcha y su indicador ('buffering') es el válido.
    if (!cycle.cancelled) {
      emitAiState(accountId, sessionKey, contactPhone, 'idle');
    }
  }
}