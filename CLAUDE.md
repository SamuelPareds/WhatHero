# 🦸‍♂️ WhatHero - WhatsApp CRM con Superpoderes

## 🎯 Contexto y Objetivo
WhatHero es un **CRM Multi-tenant** de control total que rompe las limitaciones de las APIs oficiales de Meta. Permite gestionar múltiples cuentas de WhatsApp Business desde una única interfaz profesional, integrando persistencia en la nube y preparación para asistentes de IA 24/7.

---

## 🏗️ Arquitectura Multi-Tenant (Escalabilidad SaaS)

El proyecto utiliza una estructura jerárquica para permitir que N usuarios gestionen M cuentas de WhatsApp de forma aislada y segura.

### 1. Estructura de Datos (Firestore)
La "Fuente de Verdad" sigue un patrón de documentos anidados para optimizar costos y velocidad:
`{accountsCollection}/{userId}/whatsapp_sessions/{phoneNumber}`
- **Colección raíz:** `accounts` en producción, `accounts_dev` en desarrollo (ver sección *Separación de Entornos*).
- **Atributos de Sesión:** `alias`, `phone_number`, `status`, `session_key`.
- **Sub-colección de Mensajes:** `chats/{chatId}/messages/{messageId}`.

### 2. El Orquestador de Sesiones (/backend)
- **Tecnología:** Node.js + TypeScript + Baileys + Docker.
- **Multi-instancia:** El backend gestiona un `Map<string, SessionData>` en memoria. Cada sesión es una instancia independiente de Baileys.
- **Persistencia de Sesión:** Las llaves de autenticación se guardan en `/app/auth_info/${sessionKey}`. En producción (Railway), esta carpeta está mapeada a un **Volumen Persistente**.
- **Seguridad:** Las credenciales de Firebase se inyectan vía variable de entorno `FIREBASE_CONFIG` (JSON string).

### 3. El Frontend (/lib)
- **Tecnología:** Flutter Web/Mobile.
- **Gestión de Sesiones:** La app permite navegar entre diferentes `whatsapp_sessions`. El `StreamBuilder` se suscribe dinámicamente al path del `phoneNumber` activo.
- **Conectividad:** Switcher de entorno automático (`kReleaseMode`) para alternar entre Railway y Localhost, y también para escoger la colección Firestore.

---

## 🌐 Separación de Entornos (Dev vs Prod)

Para evitar que el backend local y Railway se pisen entre sí (por ejemplo, el `HealthCheck` marcando como desvinculadas las sesiones del otro), usamos **el mismo proyecto Firebase pero distintas colecciones raíz**. No usamos Flutter flavors — la separación se resuelve con una sola constante en cada extremo.

### Mapeo de entornos

| Entorno | Flutter | Backend | Colección raíz |
|---|---|---|---|
| **Producción** | Release build (APK/AAB/IPA firmado) | Railway (`NODE_ENV=production`) | `accounts` |
| **Desarrollo** | Debug (`flutter run`) | Local (`NODE_ENV=development`) | `accounts_dev` |

### Helpers centralizados

- **Flutter:** `lib/core/config.dart` expone `String get accountsCollection` usando `kReleaseMode`. Se evalúa en tiempo de compilación — el APK/AAB de release no contiene siquiera el string `'accounts_dev'`.
- **Backend:** `backend/src/config/env.ts` exporta `ACCOUNTS_COLLECTION` e `IS_PRODUCTION` leyendo `process.env.NODE_ENV`. Fail-safe: si `NODE_ENV` no está definido, cae en `accounts_dev`.

### Regla obligatoria para nuevo código
**Nunca hardcodear `collection('accounts')`.** Siempre usar el helper:
- En Flutter: `FirebaseFirestore.instance.collection(accountsCollection).doc(...)`.
- En Backend: `db.collection(ACCOUNTS_COLLECTION).doc(...)`.

### Qué comparten y qué no ambos entornos
- ✅ **Compartido:** Firebase Auth (mismo pool de usuarios → puedes loguearte cruzado sin romper nada; solo verás una app vacía si tu `uid` no tiene datos en esa colección).
- ❌ **Aislado:** sesiones de WhatsApp, chats, mensajes, quick responses, configuración de IA y `auth_info` de Baileys (el filesystem local es distinto al volumen persistente de Railway).

---

## 🌉 El Puente: Socket.io con Rooms
Para garantizar que la data llegue al usuario correcto, implementamos **Rooms**:
- El socket del cliente se une a una sala con su `userId` (Firebase UID).
- El backend emite eventos (`qr`, `ready`) únicamente a esa sala: `io.to(userId).emit(...)`.
- **Eventos:** Incluyen un `sessionKey` (UUID) para que el frontend distinja entre múltiples procesos de vinculación simultáneos.

---

## 🔍 Discriminador de Intenciones (Intent Filter)
Un sistema inteligente de filtrado que intercepta mensajes ANTES del asistente IA:
- **Configuración:** Por sesión de WhatsApp (en `SessionSettingsPanel`)
- **Reglas:** Usuario escribe en lenguaje natural ("Pasa al humano si pregunta sobre disponibilidad...")
- **Funcionamiento:**
  1. Mensaje llega → Discriminador analiza (Gemini + historial)
  2. Gemini responde "Respuesta: SI" (IA responde) o "Respuesta: NO" (requiere humano)
  3. Si "NO": Marca chat como `needs_human: true`, emite evento Socket.io, NO responde IA
  4. Si "SI": Continúa flujo normal del asistente
- **UI Feedback:** Badge rojo 🟥⚠️ en chats que requieren humano
- **Firestore:** Campos `ai_discriminator_enabled`, `ai_discriminator_prompt`, y `needs_human` por chat
- **Ver guía:** `DISCRIMINATOR_GUIDE.md` (documentación completa con ejemplos)

---

## 🎛️ Estados de IA por Chat (UI Feedback)

Cómo la app comunica visualmente qué está pasando con la IA en un chat abierto. Vive en el AppBar de `ChatsScreen` (subtítulo + franja inferior 2px).

### El toggle del icono `face_retouching_natural` (acción del AppBar)
**2 estados puros — activar / desactivar IA en este chat.** No muta a spinner durante un ciclo de IA: la actividad se comunica abajo (subtítulo + barra), nunca secuestrando el botón de apagado.
- **Aqua sólido** (#10B981): IA auto-on para este chat → tap apaga.
- **Gris** (#9CA3AF): IA auto-off para este chat → tap enciende.
- **Gris atenuado** (alpha 0.4): asistente no configurado a nivel sesión → tap abre `SessionSettingsPanel`.

### Botón `auto_awesome` "Sugerir respuesta con IA" (composer) — tri-estado
Independiente del master switch del auto-responder. Se habilita por **credenciales del provider activo**, no por `ai_enabled`. Permite el modo copiloto (cliente cauteloso que apaga la IA pero quiere ver qué propondría).
- **Aqua sólido**: credenciales + `ai_enabled=true` → `Generar respuesta con IA`.
- **Aqua atenuado** (alpha 0.6): credenciales + `ai_enabled=false` → `Sugerir respuesta con IA (asistente apagado)`. Genera, no envía solo.
- **Gris atenuado**: sin credenciales del provider activo → abre `SessionSettingsPanel`.

Backend: `/generate-ai-response` exige sólo `hasValidApiKey`, no `aiConfig.enabled`.

### Subtítulo + franja inferior — 4 modos con prioridad estricta

| Prioridad | Modo | Cuándo aparece | Subtítulo | Franja 2px |
|---|---|---|---|---|
| 1 | **cancelado** | Usuario apaga la IA durante un ciclo activo | `cancelado` (gris) | Gris sólida |
| 2 | **ciclo IA** | `AiStateService` reporta `buffering`/`thinking`/`responding` | `esperando…` / `pensando…` / `respondiendo…` (aqua) | `LinearProgressIndicator` aqua deslizante |
| 3 | **tu turno** | `sessionAiEnabled && aiAutoResponse && unrespondedCount > 0` | `tu turno` (ámbar) | Ámbar sólida |
| 4 | **reposo** | Ninguno de los anteriores | vacío | invisible (altura constante) |

Transiciones entre modos: `AnimatedSwitcher` 220ms para no saltar.

### Reglas de oro (qué aparece y qué NO)
- **Con IA off para ese chat → nunca aparece "tu turno".** Si la IA está apagada, por default responde el humano todos los mensajes — la etiqueta sería ruido. La condición `needsHuman` exige `aiAutoResponse: true`.
- **Mientras hay ciclo IA → NUNCA aparece "tu turno", aunque haya pendientes.** Es turno de la IA, no del humano. La prioridad lo asegura.
- **El flash "cancelado" sólo dispara si había ciclo IA activo al apagar.** Si la IA estaba ociosa, basta el toast "IA desactivada" — sin flash innecesario.
- **El flash dura 3s exactos**, controlado por `_cancelledTimer` en `_ChatsScreenState`. Pasados esos segundos vuelve al modo "reposo" (no a "tu turno", aunque haya pendientes — IA off).
- **Toast confirmatorio en cada toggle:** verde "IA activada" al encender, gris "IA desactivada" al apagar. El error muestra gris "Error al cambiar IA".

### Socket lifecycle — inicialización canónica
**`SocketService().init(accountId)` vive sólo en `SessionDispatcher` (main.dart)**, único punto de entrada tras el login que conoce el `accountId`. El método es idempotente (guard interno por accountId). 

**No reinicializar en otras pantallas.** El bug histórico (estados IA mudos tras cold start con sesión guardada) existió porque el `init` vivía únicamente en `AccountsScreen.initState`; al saltar directo a `ChatsScreen` el listener `ai_state` nunca se registraba. Si en el futuro se agrega una nueva pantalla raíz post-login, el `init` debe vivir arriba de ella, no dentro.

### Flujo de eventos backend → UI
1. Backend emite `ai_state` con `{sessionKey, contactPhone, state, expectedRespondAt?}` por Socket.io.
2. `SocketService` (`socket_service.dart:112`) dispatcha al singleton `AiStateService.applySocketPayload(...)`.
3. `AiStateService` (extends `ChangeNotifier`) actualiza el `Map<key, AiChatStatus>` y dispara `notifyListeners()`.
4. Los `ListenableBuilder(listenable: AiStateService(), ...)` en el AppBar y en `_ChatTile` rebuildan.
5. Watchdog de 90s: si en ese plazo no llega un nuevo evento, el estado vuelve a `idle` solo (evita spinners zombies si se cae el socket).

### Cancelar un ciclo IA desde el cliente
`SocketService().emit('cancel_ai_buffer', {sessionKey, contactPhone})`. **Nunca** usar `sendMessage(...)` — ese método siempre emite `send_message_socket` (handler de mensajes WhatsApp) y rompe con `Unauthorized accountId`. El backend (`backend/index.ts:1199`) limpia el buffer y emite automáticamente `ai_state: idle`, así que la UI se apaga sola.

---

## ✂️ Respuestas completas (defensa anti-truncamiento)

Tres caminos distintos hacían que el cliente viera media respuesta. Los tres están cerrados en `aiService.ts`; si tocas esa zona, no los reabras.

### 1. El techo de tokens del proveedor
`AI_MAX_OUTPUT_TOKENS = 4000` para la ruta OpenAI-compatible. **Estaba en 1000 y era la causa raíz:** al agotarse, la API devuelve HTTP 200 con el texto cortado a media frase y `finish_reason: 'length'`, que nadie miraba. La ruta Gemini nunca mandó `maxOutputTokens` en generación (usa el default del modelo) y por eso jamás truncó — el límite existía solo donde fallaba.
- Los modelos de razonamiento (GPT-5, familia o*) **descuentan sus tokens de pensamiento de ese mismo presupuesto**, así que un techo bajo los estrangula. Además rechazan `max_tokens` (exigen `max_completion_tokens`) y solo aceptan la temperatura por defecto: lo resuelve `isReasoningModel()`.
- **Nunca entregar una respuesta con `truncated: true`.** El auto-responder no la envía y deriva a humano (`ai_truncated`); el copiloto lanza `AiError('truncated')` para que el operador no pegue media frase sin darse cuenta.

### 2. El ciclo de IA es cancelable
Un ciclo va desde que dispara el buffer hasta que sale el último chunk — pueden ser 10s. `activeAiCycles` permite cortarlo **durante la generación y entre chunks**: la respuesta contestaba lo anterior y ya nació vieja, así que se descarta y el buffer nuevo genera una que sí atienda lo último. Es lo que hace una persona al ver entrar un mensaje mientras escribe.
- Cancelan: el cliente escribiendo, el humano respondiendo (CRM o celular) y `cancel_ai_buffer`.
- Los chunks ya enviados se quedan; cancelar **no** resetea `unresponded_count` (el mensaje que interrumpió sigue pendiente).
- El `finally` no emite `idle` si el ciclo fue cancelado: ya hay un ciclo nuevo y su indicador es el válido.

### 3. Los chunks propios no son "el humano tomó el control"
Cada chunk que manda la IA vuelve por `messages.upsert` como `fromMe`. Esa rama cancelaba el buffer que el cliente acababa de crear al escribir durante el envío: **su mensaje se perdía sin respuesta y sin quedar marcado como pendiente**. `isAiSentMessage(id)` (set con TTL de 60s, poblado al enviar cada chunk) desactiva ahí el cancel y el reset. No sirve `pendingSenders` para esto: `saveMessageToFirestore` lo consume y borra antes de que corra esa rama.

**Chunking:** el envío en grupos de 2-3 párrafos con pausas es intencional y **no se toca** — humaniza la conversación. Un chunk que falla se reintenta una vez; si no sale, el chat se deriva a humano (`send_failed`) en vez de quedar mudo en un `console.error`.

---

## 📥 Ingesta de mensajes entrantes (defensa anti-pérdida)

Un `messages.upsert` **no es un mensaje: es un lote**. Baileys bufferea los eventos durante el handshake (`socket.js`, `ev.buffer()`) y los vacía de golpe cuando WhatsApp avisa que terminó de entregar lo pendiente (`CB:ib,,offline`). El backlog completo acumulado durante una caída llega en **un único evento con un array de N mensajes**.

- **Nunca leer `m.messages[0]`.** Fue el bug: cada redespliegue de Railway, cada reconexión y cada blip de red descartaba en silencio todo el backlog menos el primer mensaje. El cliente los veía en su WhatsApp y para WhatHero nunca existieron. Sin log, sin contador, sin rastro.
- El listener recorre **todo** `m.messages` de forma **secuencial** (los buffers de IA y los contadores de pendientes dependen del orden) y llama a `handleUpsertedMessage(raw, m.type)` con un `try/catch` **por mensaje**: uno que falle no puede llevarse puesto al resto del lote.
- Log `[Upsert] Lote de N mensajes (type=…)` cuando `N > 1` — es el termómetro de cuánto backlog está entrando por reconexión.

### Las tres guardas de `handleUpsertedMessage`
1. **Stub `CIPHERTEXT` → se descarta con `console.warn`.** Baileys emite el mensaje aunque no lo haya podido descifrar y en paralelo le pide un reintento al emisor. Ingerirlo escribía una burbuja vacía y sumaba un pendiente fantasma que se volvía a sumar cuando llegaba el reintento ya descifrado. El warn (con el `key.id`) es el único rastro si el reintento nunca llega.
2. **Dedupe por `key.id`** (`processedMessageIds`, TTL 10 min). El vaciado del backlog se solapa con el tráfico vivo y un mismo id puede re-entregarse; reprocesarlo duplicaba `unresponded_count` y podía hacer que la IA contestara dos veces. **El stub `CIPHERTEXT` sale ANTES de registrarse a propósito**, para que su reintento —mismo id, ya descifrado— sí se procese. Las ediciones, revokes y reacciones tienen id propio de sobre (el target va en `protocolMessage.key` / `targetMessageKey`), así que el dedupe no las toca.
3. **Mensajes rancios no disparan automatismos.** `AI_STALE_MESSAGE_MINUTES` (default 15) define la ventana. Fuera de ella el mensaje se guarda y queda como pendiente, pero no dispara IA, keyword rules ni cancelación del ciclo en curso: llegó tarde a una conversación que ya siguió sin él, y la IA no sabe disculparse por una demora de tres horas. `type === 'prepend'` (relleno de historial) es siempre rancio. Un `messageTimestamp` ausente o ilegible se trata como fresco (fail-open: no bloqueamos una respuesta por un timestamp raro).

---

## 👁️ Confirmaciones de lectura (la bandeja del teléfono como red de seguridad)

WhatHero es un dispositivo vinculado: **todo mensaje que ingiere sigue contando como NO leído en el WhatsApp del teléfono** hasta que alguien emita el recibo. Nadie lo emitía, así que la bandeja crecía sin techo y dejaba de servir para nada — justo cuando es el único lugar donde aparecen los mensajes que WhatsApp nunca nos entregó.

**Política (`backend/src/services/readReceiptService.ts`): se marca leído SÓLO cuando respondemos.** Un chat sin responder se queda no-leído **a propósito**. Así lo que sigue en negrita en el teléfono es exactamente lo que falta atender, y el filtro "No leídos" se vuelve una lista corta y accionable en vez de un cementerio.

- **Un solo punto de emisión:** la rama `fromMe` de `messages.upsert`, junto al `resetUnrespondedCount` que ya vivía ahí. Cubre todas las vías de salida —CRM, IA, keyword rules, recordatorios, follow-ups y el celular del operador— sin hooks dispersos por cada entry point.
- **Va SIN el guard `isOwnAiChunk`**, al revés que el reset del contador: si contestó la IA, contestamos nosotros. Los chunks 2 y 3 encuentran el registro vacío y no hacen nada, así que se deduplica solo.
- **El registro (`session.unreadKeys`) se llena con TODO entrante**, antes de cualquier corte por rancio o por IA no elegible, y también con el switch apagado: si el usuario lo enciende, la primera respuesta arrastra lo acumulado. Topes de 50 llaves por chat y 2000 chats por sesión (evicción del más viejo) para que un proceso de semanas no se infle.
- **`sock.readMessages()` respeta la privacidad de la cuenta sin preguntarla:** manda `'read'` (palomitas azules) si el usuario tiene las confirmaciones activadas y `'read-self'` si no. En ambos casos la bandeja del teléfono se limpia, así que la decisión **no se expone en la UI**.
- **Un fallo de red devuelve las llaves al registro** para que el próximo envío reintente. Un blip no debe dejar el chat en negrita para siempre.
- **`POST /mark-chat-read`** hace lo mismo sin enviar nada: lo usa el botón "Listo" del CRM, porque cerrar un pendiente sin responder también tiene que limpiar el teléfono. Respeta el mismo switch.

**Coherencia con `unresponded_count`:** un recordatorio o follow-up saliente marca leído, igual que ya reseteaba el contador de pendientes. Todo saliente cuenta como "atendido" en ambos sistemas — si algún día eso cambia, tiene que cambiar en los dos a la vez.

**Switch:** `mark_read_on_reply` en el doc de sesión, default `true`, editable en *Ajustes de Sesión → General → Sincronización con WhatsApp*. Se lee dentro de `getAIConfig` (que ya cachea el doc 60s) para no pagar un read extra. Si la config no se puede leer, falla cerrado: no se toca el estado de lectura del teléfono.

---

## 📱 Versión de WhatsApp Web (defensa anti-405)

El backend se declara ante WhatsApp como una versión concreta de WhatsApp Web (`2.3000.<revisión>`). WhatsApp **corta las versiones viejas cada pocas semanas**, y cuando lo hace caen todas las sesiones a la vez con `405 Connection Failure` — sin poder siquiera generar un QR para revincular. Pasó el 28-jul-2026 con las 3 cuentas de producción.

- **Nunca usar `fetchLatestBaileysVersion()` directo.** Esa función parsea un `.ts` de GitHub por número de línea y, si falla, devuelve un valor viejo con `isLatest: false` sin avisar. Fue la causa raíz de la caída.
- **Siempre usar `resolveWaVersion()`** de `backend/src/config/waVersion.ts`. Cadena: `WA_VERSION` (env) → `web.whatsapp.com/sw.js` → pin de Baileys → `WA_VERSION_FLOOR`. Descarta cualquier fuente que devuelva algo más viejo que el piso, y trata `isLatest: false` como fallo.
- **Diagnóstico y emergencias:** `cd backend && npm run check:wa` (agrega una versión como argumento para probarla antes de usarla).
- **Ver runbook completo:** `backend/WA_VERSION_GUIDE.md`.

### Logs de Baileys
El logger raíz (`index.ts`) aplica `redact` sobre los campos base64 gigantes de `histNotification` (el bootstrap del history sync pesa ~50 KB por línea). Se redactan campos puntuales en vez de subir el nivel a `warn` a propósito: durante la caída del 405 el dato que reveló la causa (`appVersion`) venía en una línea `info`. Para silenciar sólo a Baileys sin tocar los logs propios: `BAILEYS_LOG_LEVEL=warn` en Railway.

---

## 🤖 Reglas de Oro para el Desarrollo
- **Objetivo real:** Optimiza para que el código sea *fácil de entender y mantener* por una persona nueva en el proyecto. Menos líneas y menos dependencias son medios para eso, no el objetivo: si una abstracción, estructura o cache hace el proyecto más entendible o más rápido donde importa, la inversión es válida aunque agregue código.
- **Desafío técnico (con umbral):** Si mi propuesta tiene una alternativa significativamente más simple, robusta o rápida, dímelo ANTES de codear ("Existe una forma más sencilla...") y espera mi decisión. Si la diferencia es menor (estilo, micro-detalles, ±pocas líneas), decide tú por la opción simple y menciónalo brevemente al final — no me interrumpas por eso.
- **Dependencias:** Prefiere lo que ya trae Flutter/Dart o lo que ya está en pubspec. Un paquete nuevo se justifica solo si resuelve un problema no-central que sería costoso mantener a mano (no para ahorrar unas líneas).
- **Empates:** Cuando simplicidad y rendimiento compitan, gana el rendimiento en flujos de usuarios registrados (prioridad del producto) y la simplicidad en todo lo demás.
- **Seguridad:** Los datos de la sesión (`auth_info`) nunca se suben al repo; se gestionan vía Volúmenes o Variables de Entorno.

---

## 🛠️ Stack Tecnológico
- **Frontend:** Flutter (Web/Mobile).
- **Backend:** Node.js + Express + Socket.io + Baileys 7.0.
- **Infraestructura:** Railway (Docker + Volumes) & Firebase (Auth + Firestore + Hosting).