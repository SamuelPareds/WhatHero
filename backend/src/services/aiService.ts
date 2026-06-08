import admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';
import OpenAI from 'openai';
import { SessionData } from '../types';
import { ACCOUNTS_COLLECTION } from '../config/env';
import { incrementUnrespondedCount, resetUnrespondedCount } from './firestoreService';
import { sendHumanAttentionNotification } from './notificationService';
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
  'Cada mensaje del historial viene prefijado con su fecha/hora entre corchetes, ej. "[dom 8 jun, 1:49 p. m.]". Eso es METADATA para que entiendas cuánto tiempo pasó entre mensajes: úsalo para no saludar como "de nuevo" si la conversación es continua, ni asumir que retomas algo viejo cuando en realidad acaba de empezar. NUNCA copies esos corchetes en tu respuesta.';

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
  operatorInstruction?: string
): Promise<string | null> {
  try {
    // Sin historial no hay nada que responder (caso muy edge: Firestore vacío).
    if (!history || history.length === 0) {
      console.warn('[AI] generateAIResponse llamado con history vacío, abortando.');
      return null;
    }

    // Enriquecemos el system prompt con conciencia temporal: qué hora es ahora
    // + cómo interpretar los timestamps del historial. Esto vale para los 3
    // providers, por eso se hace acá una sola vez.
    // Instrucción puntual del operador humano (modo copiloto). Efímera: guía
    // SOLO esta generación, no muta el system prompt de la sesión. Se anexa como
    // bloque de máxima prioridad; vale para los 3 providers porque Gemini la
    // prependea al primer turn user y OpenAI/DeepSeek la mandan como `system`.
    const operatorBlock = operatorInstruction?.trim()
      ? `\n\n=== INSTRUCCIÓN PRIORITARIA DEL OPERADOR HUMANO (máxima prioridad) ===\n` +
        `El agente humano que supervisa esta conversación te indica explícitamente para ESTA respuesta: "${operatorInstruction.trim()}".\n` +
        `Cumple esta instrucción al redactar tu próxima respuesta, integrándola de forma natural con el contexto y el último mensaje del cliente (por ejemplo, saluda si corresponde Y entrega lo que el operador pide). Esta indicación tiene prioridad sobre cualquier ambigüedad del historial.`
      : '';
    const temporalSystemPrompt = `${buildTemporalContext(timezone)}\n\n${TIMESTAMP_METADATA_NOTE}\n\n${systemPrompt}${operatorBlock}`;

    if (provider === 'openai' || provider === 'deepseek') {
      // Ambos comparten la misma ruta OpenAI-compatible; DeepSeek solo añade baseURL.
      const isDeepSeek = provider === 'deepseek';
      return await generateAIResponseOpenAI(
        (isDeepSeek ? deepseekApiKey : openaiApiKey) || apiKey,
        temporalSystemPrompt,
        history,
        modelName,
        isDeepSeek ? DEEPSEEK_BASE_URL : undefined
      );
    } else {
      return await generateAIResponseGemini(
        apiKey,
        temporalSystemPrompt,
        history,
        modelName
      );
    }
  } catch (error) {
    console.error('[AI] Error calling AI service:', error);
    return null;
  }
}

// Generate AI response using Gemini
async function generateAIResponseGemini(
  apiKey: string,
  systemPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash'
): Promise<string | null> {
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

    // Usamos `generateContent` directo (no `startChat`) porque el historial
    // termina en `user` y eso es justamente lo que Gemini necesita para
    // generar el siguiente turn model. `startChat` espera que el historial
    // termine en `model` y manda el siguiente user via `sendMessage`.
    const result = await model.generateContent({
      contents: enhancedHistory,
    });
    return result.response.text();
  } catch (error) {
    console.error('[AI] Error calling Gemini:', error);
    return null;
  }
}

// Generate AI response using OpenAI (o cualquier API compatible: DeepSeek).
// `baseURL` undefined → OpenAI oficial; con valor → endpoint compatible.
async function generateAIResponseOpenAI(
  apiKey: string,
  systemPrompt: string,
  history: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gpt-4o-mini',
  baseURL?: string
): Promise<string | null> {
  try {
    const client = new OpenAI({ apiKey, ...(baseURL && { baseURL }) });

    const messages: OpenAI.Chat.ChatCompletionMessageParam[] = [
      {
        role: 'system',
        content: systemPrompt,
      },
      ...history.map(msg => ({
        role: (msg.role === 'user' ? 'user' : 'assistant') as 'user' | 'assistant',
        content: msg.parts[0]?.text || '',
      })),
    ];

    const response = await client.chat.completions.create({
      model: modelName,
      messages,
      temperature: 0.7,
      max_tokens: 1000,
    });

    return response.choices[0]?.message.content || null;
  } catch (error) {
    console.error('[AI] Error calling OpenAI:', error);
    return null;
  }
}

// Normalize message history to preserve all messages for better context.
// Cada turn se prefija con su fecha/hora ([dom 8 jun, 1:49 p. m.]) como
// metadata para que el modelo perciba el tiempo transcurrido entre mensajes.
export function normalizeHistory(
  rawDocs: any[],
  timezone: string = DEFAULT_TIMEZONE
): { role: 'user' | 'model'; parts: { text: string }[] }[] {
  return rawDocs
    .filter(d => d.text && d.text.trim().length > 0)
    .map(d => {
      const stamp = formatMessageTimestamp(d.timestamp, timezone);
      const text = stamp ? `[${stamp}] ${d.text}` : (d.text as string);
      return {
        role: d.fromMe ? ('model' as const) : ('user' as const),
        parts: [{ text }],
      };
    });
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
  modelName: string = 'gpt-4o-mini',
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

// Divide la respuesta en grupos de párrafos (alternando 2 y 3) para simular escritura humana.
// Cada chunk enviado se registra en pendingSenders con AI_SENDER para que el
// upsert lo guarde con senderType='ai'.
async function sendChunkedResponse(session: SessionData, remoteJid: string, response: string): Promise<void> {
  const sock = session.sock;
  const tagAi = (sent: any) => {
    if (sent?.key?.id) session.pendingSenders.set(sent.key.id, AI_SENDER);
  };

  const chunks = response.split(/\n\n+/);

  // Si es texto corto (1 párrafo), enviar directo sin chunking
  if (chunks.length <= 1) {
    const sent = await sock.sendMessage(remoteJid, { text: response.trim() });
    tagAi(sent);
    return;
  }

  let i = 0;
  let groupSize = 2;
  while (i < chunks.length) {
    const group = chunks.slice(i, i + groupSize).join('\n\n').trim();
    if (group) {
      const sent = await sock.sendMessage(remoteJid, { text: group });
      tagAi(sent);
      // Delay proporcional a la longitud del chunk (mínimo 800ms, máximo 2500ms)
      const delay = Math.min(2500, Math.max(800, group.length * 10));
      await new Promise(resolve => setTimeout(resolve, delay));
    }
    i += groupSize;
    groupSize = groupSize === 2 ? 3 : 2;
  }
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

  try {
    // Combine all buffered messages into one context
    const combinedMessage = bufferedMessages.join('\n');
    console.log(`[Buffer] Processing ${bufferedMessages.length} message(s) for ${contactPhone}: "${combinedMessage.substring(0, 50)}..."`);

    // Zona horaria del negocio para etiquetar mensajes y el contexto "ahora".
    const timezone = getSessionTimezone(aiConfig);

    // Fetch last 10 messages for conversation history
    let history: { role: 'user' | 'model'; parts: { text: string }[] }[] = [];

    try {
      const historyDocs = await getDb()
        .collection(ACCOUNTS_COLLECTION).doc(accountId)
        .collection('whatsapp_sessions').doc(session.phoneNumber!)
        .collection('chats').doc(contactPhone)
        .collection('messages')
        .orderBy('timestamp', 'desc')
        .limit(20)
        .get();

      const rawDocs = historyDocs.docs.reverse().map(d => d.data());
      history = normalizeHistory(rawDocs, timezone);
    } catch (error) {
      console.log('[Buffer] Could not fetch message history, continuing without context:', error);
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
        // Incrementamos el contador por la ráfaga completa de mensajes que el discriminador clasificó
        await incrementUnrespondedCount(
          accountId,
          session.phoneNumber!,
          contactPhone,
          bufferedMessages.length
        );

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
          console.error('[Buffer] Error stamping human_attention_at:', error);
        }

        getIO().to(accountId).emit('human_attention_required', {
          sessionKey,
          chatId: contactPhone,
          phoneNumber: session.phoneNumber,
          timestamp: new Date().toISOString(),
        });

        // Push FCM en paralelo: el flujo de IA no espera al envío de notificación.
        // Errores de FCM no deben romper el procesamiento del mensaje.
        sendHumanAttentionNotification({
          accountId,
          sessionPhone: session.phoneNumber!,
          sessionKey,
          chatId: contactPhone,
          reason: 'discriminator',
          messagePreview: combinedMessage,
        }).catch((err) => console.error('[Notify] discriminator push falló:', err));

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

    if (aiResponse) {
      // Pasamos a 'responding' justo antes de empezar a mandar chunks: este es
      // el momento crítico donde el usuario puede querer interceptar.
      emitAiState(accountId, sessionKey, contactPhone, 'responding');
      await sendChunkedResponse(session, remoteJid, aiResponse);
      console.log(`[Buffer] Auto-responded to ${remoteJid} en chunks`);
      // La IA respondió: cualquier pendiente previo queda cubierto
      await resetUnrespondedCount(accountId, session.phoneNumber!, contactPhone);
    }
  } catch (error) {
    console.error('[Buffer] Error processing message buffer:', error);
  } finally {
    // Cierre garantizado del ciclo: tanto en éxito como en error volvemos a idle
    // para que el frontend libere el spinner y muestre el icono de IA normal.
    emitAiState(accountId, sessionKey, contactPhone, 'idle');
  }
}