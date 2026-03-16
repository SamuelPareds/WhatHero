import admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';
import { SessionData } from '../types';

// Lazy evaluation: getDb() is called only after Firebase is initialized
function getDb() {
  return admin.firestore();
}

// Lazy evaluation: getIO() is called only after Socket.io is initialized
function getIO() {
  // This will be injected by index.ts
  return (global as any).__WhatHeroIO;
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

// Generate AI response using Gemini with conversation history
export async function generateAIResponse(
  apiKey: string,
  systemPrompt: string,
  userMessage: string,
  history?: { role: 'user' | 'model'; parts: { text: string }[] }[],
  modelName: string = 'gemini-2.5-flash'
): Promise<string | null> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    // If we have history, use multi-turn chat with system prompt prepended to the first user message
    if (history && history.length > 0) {
      // Inject system prompt at the beginning of the history by prepending to first user message
      const enhancedHistory = [...history];
      if (enhancedHistory.length > 0 && enhancedHistory[0].role === 'user') {
        enhancedHistory[0] = {
          role: 'user',
          parts: [{ text: `${systemPrompt}\n\n${enhancedHistory[0].parts[0]?.text || ''}` }],
        };
      }
      const chat = model.startChat({ history: enhancedHistory });
      const result = await chat.sendMessage(userMessage);
      return result.response.text();
    } else {
      // Single turn: include system prompt in the message
      const fullPrompt = `${systemPrompt}\n\n${userMessage}`;
      const result = await model.generateContent(fullPrompt);
      return result.response.text();
    }
  } catch (error) {
    console.error('[AI] Error calling Gemini:', error);
    return null;
  }
}

// Normalize message history to alternating user/model format for Gemini
export function normalizeHistory(
  rawDocs: any[]
): { role: 'user' | 'model'; parts: { text: string }[] }[] {
  const rawHistory = rawDocs
    .filter(d => d.text)
    .map(d => ({
      role: d.fromMe ? ('model' as const) : ('user' as const),
      parts: [{ text: d.text as string }],
    }));

  const normalized: { role: 'user' | 'model'; parts: { text: string }[] }[] = [];
  for (const msg of rawHistory) {
    if (normalized.length === 0) {
      if (msg.role === 'user') {
        normalized.push(msg);
      }
    } else {
      const lastRole = normalized[normalized.length - 1].role;
      if (lastRole === 'user' && msg.role === 'model') {
        normalized.push(msg);
      } else if (lastRole === 'model' && msg.role === 'user') {
        normalized.push(msg);
      }
    }
  }

  if (normalized.length > 0 && normalized[normalized.length - 1].role !== 'user') {
    normalized.pop();
  }

  return normalized;
}

// Classify message intent using discriminator (TalkToAiAssistant or TalkToHuman)
//
// HOW IT WORKS:
// 1. User writes natural language rules (e.g., "Pass to human if client asks about availability")
// 2. The discriminator prompt is: {USER_RULES} + {CONVERSATION_HISTORY}
// 3. Gemini analyzes if the latest message matches the rules
// 4. Gemini responds with "Respuesta: SI" (AI can respond) or "Respuesta: NO" (needs human)
// 5. Backend parses the response and routes accordingly
//
// EXAMPLE PROMPT (what user writes):
// "Pass messages to a human if:
//  - Client asks about specific availability (dates, times)
//  - Client wants to book/reschedule an appointment
//  - Client asks about personal data or account balance
//
//  For anything else, you can respond directly."
export async function classifyMessageIntent(
  apiKey: string,
  discriminatorPrompt: string,
  conversationHistory: string,
  modelName: string = 'gemini-2.5-flash'
): Promise<'TalkToAiAssistant' | 'TalkToHuman'> {
  try {
    const genAI = new GoogleGenerativeAI(apiKey);
    const model = genAI.getGenerativeModel({ model: modelName });

    // Replace {HISTORY} placeholder with actual conversation
    let userPrompt = discriminatorPrompt.replace('{HISTORY}', conversationHistory);

    // Add instructions for clear response format
    userPrompt += '\n\n---\nResponde SOLO con una de estas dos opciones:\n- Respuesta: SI (si el asistente puede responder)\n- Respuesta: NO (si requiere intervención humana)';

    const result = await model.generateContent(userPrompt);
    const responseText = result.response.text().toUpperCase();

    console.log(`[Discriminator] Gemini response: ${responseText.substring(0, 100)}`);

    // Check response for explicit YES/NO keywords
    if (responseText.includes('RESPUESTA: NO')) {
      console.log('[Discriminator] Decision: TalkToHuman (NO detected)');
      return 'TalkToHuman';
    }

    if (responseText.includes('RESPUESTA: SI')) {
      console.log('[Discriminator] Decision: TalkToAiAssistant (SI detected)');
      return 'TalkToAiAssistant';
    }

    // If response is ambiguous, default to AI response (safety: prefer responding to blocking)
    console.log('[Discriminator] Decision: TalkToAiAssistant (ambiguous, defaulting to AI)');
    return 'TalkToAiAssistant';
  } catch (error) {
    console.error('[Discriminator] Error classifying intent:', error);
    // Default: allow AI response on error
    return 'TalkToAiAssistant';
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
  try {
    // Combine all buffered messages into one context
    const combinedMessage = bufferedMessages.join('\n');
    console.log(`[Buffer] Processing ${bufferedMessages.length} message(s) for ${contactPhone}: "${combinedMessage.substring(0, 50)}..."`);

    // Fetch last 10 messages for conversation history
    let history: { role: 'user' | 'model'; parts: { text: string }[] }[] = [];

    try {
      const historyDocs = await getDb()
        .collection('accounts').doc(accountId)
        .collection('whatsapp_sessions').doc(session.phoneNumber!)
        .collection('chats').doc(contactPhone)
        .collection('messages')
        .orderBy('timestamp', 'desc')
        .limit(20)
        .get();

      const rawDocs = historyDocs.docs.reverse().map(d => d.data());
      history = normalizeHistory(rawDocs);
    } catch (error) {
      console.log('[Buffer] Could not fetch message history, continuing without context:', error);
    }

    // DISCRIMINATOR: Check if message should be handled by AI or human
    if (aiConfig.discriminator?.enabled && aiConfig.discriminator?.prompt) {
      console.log(`[Discriminator] Enabled for ${contactPhone}, prompt length: ${aiConfig.discriminator.prompt.length}`);
      console.log(`[Discriminator] Message: "${combinedMessage.substring(0, 80)}..."`);

      const historyText = history
        .map((msg) => {
          const role = msg.role === 'user' ? 'Customer' : 'Assistant';
          return `${role}: ${msg.parts[0]?.text || ''}`;
        })
        .join('\n');

      const conversationContext = `${historyText}\nCustomer: ${combinedMessage}`;

      const classification = await classifyMessageIntent(
        aiConfig.apiKey,
        aiConfig.discriminator.prompt,
        conversationContext,
        aiConfig.model
      );

      console.log(`[Discriminator] Classification result: ${classification}`);

      if (classification === 'TalkToHuman') {
        try {
          const chatDocRef = getDb()
            .collection('accounts')
            .doc(accountId)
            .collection('whatsapp_sessions')
            .doc(session.phoneNumber!)
            .collection('chats')
            .doc(contactPhone);

          await chatDocRef.update({
            needs_human: true,
            human_attention_at: admin.firestore.FieldValue.serverTimestamp(),
          });

          console.log(`[Buffer] Chat ${contactPhone} marked as needs_human=true`);
        } catch (error) {
          console.error('[Buffer] Error marking chat as needing human attention:', error);
        }

        getIO().to(accountId).emit('human_attention_required', {
          sessionKey,
          chatId: contactPhone,
          phoneNumber: session.phoneNumber,
          timestamp: new Date().toISOString(),
        });

        console.log(
          `[Buffer] Emitted human_attention_required for ${contactPhone} (Session: ${session.phoneNumber})`
        );
        return; // Skip AI response
      }

      console.log(`[Buffer] Discriminator classification: ${classification}, proceeding with AI response`);
    }

    // Generate and send AI response
    const aiResponse = await generateAIResponse(
      aiConfig.apiKey,
      aiConfig.systemPrompt || 'Eres un asistente útil.',
      combinedMessage,
      history,
      aiConfig.model
    );

    if (aiResponse) {
      await session.sock.sendMessage(remoteJid, { text: aiResponse });
      console.log(`[Buffer] Auto-responded to ${remoteJid} on session ${session.phoneNumber} with ${aiResponse.length} chars`);
    }
  } catch (error) {
    console.error('[Buffer] Error processing message buffer:', error);
  }
}
