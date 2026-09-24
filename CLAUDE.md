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
- El socket del cliente se une a la sala de su cuenta, `accountId` (el UID del owner; un miembro del equipo entra a la del owner).
- El backend emite eventos (`qr`, `ready`) únicamente a esa sala: `io.to(accountId).emit(...)`.
- **Eventos:** Incluyen un `sessionKey` (UUID) para que el frontend distinja entre múltiples procesos de vinculación simultáneos.
- **Ojo:** la sala `accountId` llega a **todos** los miembros, incluidos los restringidos a otras sesiones. Lo que no deba ver un miembro sin acceso a esa sesión va por salas por sesión con chequeo de acceso, como la presencia del equipo (`tp:{accountId}:{sessionPhone}`, ver *👥 Presencia del equipo*).

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
- Los modelos de razonamiento (GPT-5.x —incluida la 5.6 Luna—, familia o*) **descuentan sus tokens de pensamiento de ese mismo presupuesto**, así que un techo bajo los estrangula. Además rechazan `max_tokens` (exigen `max_completion_tokens`) y solo aceptan la temperatura por defecto: lo resuelve `isReasoningModel()`, y `outputParams()` es el único lugar que arma esos parámetros. **Toda llamada a `chat.completions.create` tiene que pasar por ahí.** Los dos clasificadores (discriminador y agente de seguimiento) mandaban `temperature` y `max_tokens` a pelo: con un modelo de razonamiento eso es un 400 que tumba la llamada, y ambos fallan en silencio (el discriminador deja de aplicar las reglas del operador, el seguimiento no encola a nadie) porque su `catch` devuelve un default.
- **Techos separados por familia:** 4000 para no-razonadores, `AI_MAX_OUTPUT_TOKENS_REASONING = 16000` para los que piensan (16k porque un esfuerzo medio quema miles de tokens antes de la primera letra, y con 4000 el resultado no era una respuesta cortada sino `truncated: true` con texto vacío). Los clasificadores van con 200 / 2000: su respuesta útil son ~30 tokens, pero el pensamiento sale del mismo presupuesto. **El techo alto es gratis: se factura lo usado, no lo reservado.**
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

## ✓ Dirección del mensaje (una palomita, y sólo una)

El operador tiene que poder distinguir de un vistazo lo que **salió** de lo que **entró**. Se resuelve con el mismo patrón asimétrico de WhatsApp: el saliente lleva ✓ delante, el entrante va limpio. Sin palomita = habló el cliente = probablemente es tu turno.

- **Es `Icons.done` (✓), NUNCA `Icons.done_all` (✓✓).** No rastreamos acks: no hay listener de `messages.update` ni de `message-receipt.update` en el backend, así que lo único que sabemos de un saliente es que WhatsApp lo aceptó — que es exactamente lo que significa una palomita sola. Un ✓✓ prometería "entregado al dispositivo del cliente" y sería mentira. **Si alguien lo "arregla" a ✓✓ para parecerse más a WhatsApp, está reintroduciendo el bug.**
- **Dos lugares, un solo significado:** la burbuja saliente (`message_bubble.dart`, junto al timestamp — incluye stickers) y el preview de la lista de chats (`_ChatTile` en `chats_screen.dart`). La sección "Chats" del buscador lo hereda porque reusa `_buildChatTile`.
- **En la burbuja el ✓ convive con dos estados en vuelo** que vienen de `PendingMessagesService`: 🕓 `pending` (emitido, sin ack del backend) y ✕ rojo `failed` (tap → reintentar). El ✓ es el estado confirmado; un mensaje que ya está en Firestore siempre lo tiene.
- **La lista lee `lastMessageFromMe`** del chat doc, escrito por `saveMessageToFirestore` dentro del `set` que ya hacía (cero writes extra) y recalculado por `recalcChatLastMessage` cuando se borra el último mensaje. **Es `bool?`: `null` en chats sin mensajes nuevos desde que existe el campo** → no se pinta nada y se auto-repara con el siguiente mensaje. No se hizo backfill a propósito: un chat sin actividad es un chat que nadie está mirando.

**Palomitas reales (entregado / leído) son Fase 2 y no están hechas.** Costo real: listener de `messages.update` + `message-receipt.update` (este último obligatorio para grupos, hay que agregar por participante), campo `status` con guarda monotónica (los acks llegan desordenados y un `delivered` tardío no puede pisar un `read`), +2 writes por saliente sobre los 3 actuales —multiplicado por chunk, y la IA manda 2-3 por respuesta— y +2 reads por cliente conectado. Se difiere hasta que un operador pregunte "¿le llegó?", no antes.

---

## 💬 Escribir primero (chat con un número que nunca escribió)

El FAB de la lista de chats abre `NewChatSheet`: bandera + código de país a la izquierda, número nacional a la derecha. El operador escribe **sus 10 dígitos de siempre** y nosotros armamos el E.164.

**El país por defecto sale del número de la propia sesión** (`countryForE164(sessionId)`): un cliente mexicano abre el panel ya en 🇲🇽 y uno colombiano en 🇨🇴, sin configurar nada. La bandera va SIEMPRE junto al `+52` porque en Windows el emoji no renderiza y el código tiene que seguir diciendo todo.

### El campo se limpia solo (`normalizeTyped`, `lib/core/utils/phone_input.dart`)

Quien ya sabe de códigos los pega incluidos; quien no sabe, no los pone. Las dos formas funcionan porque el campo guarda **siempre** el número nacional pelado y quita lo que sobre, avisando qué quitó: `+52`, el `521` legacy, el `549` argentino, el `0` de marcado nacional. Pegar un `+57` estando en 🇲🇽 mueve el selector a Colombia solo.

**Manda el largo, no el prefijo.** Un número que ya cabe en el rango nacional del país se respeta intacto aunque empiece con los mismos dígitos que su código de país — sin esa regla, un `5212345678` mexicano legítimo perdería sus primeros dígitos. Cuando nada encaja, no tocamos nada: preferimos que el operador vea su número raro a recortárselo por nuestra cuenta. Las reglas viven en `test/phone_input_test.dart`; es lógica sutil y silenciosa cuando falla.

### `onWhatsApp` es la fuente de verdad, no una tabla de prefijos

`POST /resolve-contact` verifica el número **antes** de abrir el chat. Es obligatorio, y cierra dos fallas que terminan igual: el operador esperando una respuesta que nunca va a llegar.

1. **Número sin WhatsApp:** el envío se acepta, el eco vuelve, se crea el chat doc con el mensaje adentro y su palomita ✓. Todo parece bien. Nunca llega nada.
2. **México/Argentina:** hay cuentas registradas como `521` y otras como `52`, y desde afuera no se puede saber cuál. Si mandamos a la variante equivocada, el eco vuelve con el JID que WhatsApp considera bueno y el mensaje se guarda en **otro chat doc** del que la app está mostrando: el operador ve su mensaje desaparecer.

Ninguna se arregla con una tabla de prefijos más lista. Se arreglan preguntando: `onWhatsApp` devuelve el JID canónico (`node.attrs.jid` del USync) y omite de la lista a los que no existen. Mismo principio que `resolveWaVersion()` — **no adivinamos, preguntamos**.

- **`onWhatsApp` es variádico y lo aprovechamos:** `waNumberCandidates()` arma las dos variantes y ambas viajan en **una sola** consulta USync. Cuál existe deja de ser decisión nuestra.
- **El `chatId` que abre la app es el que devolvió WhatsApp**, no el que se tecleó: es el mismo bajo el que `saveMessageToFirestore` guardará el eco, así que pantalla y Firestore no pueden desincronizarse.
- **Si ya existe chat bajo el id hermano, gana el hermano.** Abrir el canónico partiría el historial en dos. `performSendMessage` lee el `remoteJid` guardado en ese doc, así que el envío sigue saliendo por donde ya salía.
- **Rate limit de 20/min por sesión.** Consultar números en masa es la firma de un spammer y WhatsApp banea por eso; el costo lo pagaría la cuenta del cliente. Sólo se consulta con acción explícita del operador, **nunca por tecla**.

### El chat no existe hasta que se manda el primer mensaje

`NewChatSheet` **no escribe nada en Firestore** y el botón dice "Abrir chat", no "Enviar": abrimos la conversación vacía (`selectedChatPhone`) y el operador escribe con el composer de siempre. El doc lo crea el eco del primer saliente, como cualquier otro chat. Si se arrepiente y no escribe, no queda basura en la lista.

Por eso el toggle de IA del chat abierto usa `set(merge)` y no `update`: en un chat recién abierto todavía no hay doc, y un `update` sobre un doc inexistente tira excepción.

---

## 🔎 Buscar un chat pegando el número (cola de dígitos)

El operador copia el número de WhatsApp Web, de un correo o de otro CRM y lo pega en el buscador. Lo pegado viene en E.164 con separadores y **sin el `1` móvil mexicano** (`+52 55 1234 5678`); lo guardado es el JID pelado (`5215512345678`). Como texto plano no coincide **nada**: ni el `+`, ni los espacios, ni el `521`. El chat existía y la búsqueda decía que no.

**No se comparan números, se compara la cola de dígitos** (`lib/core/utils/phone_search.dart`). Se le quita al término todo lo que no sea dígito y se toman los **últimos 10** — el nacional más largo de la región. Eso deja fuera el código de país y el prefijo móvil sin tocar el número en sí, así que las dos formas colapsan en la misma cadena y da igual cuál de las dos esté guardada.

- **10 es un techo, no un largo.** Un número más corto usa todos sus dígitos (`min(10, los que haya)`); nunca se rellena. Brasil móvil tiene 11 con la nona: recortarle el dígito de área no rompe nada, la cola sigue siendo un sufijo del guardado, que es lo único que la comparación necesita.
- **Es `contains`, no `endsWith`**, para que escribir a mano los primeros dígitos siga encontrando. Con 10 dígitos la distinción es teórica.
- **El guard `_phoneLike` es lo que evita inundar la lista.** Sólo se interpreta como teléfono lo que es dígitos + puntuación (`+ - ( ) . espacio`) con al menos un dígito. Sin él, buscar "Ana 2" daría una cola de `2` que coincide con casi todos los chats. Si hay letras, se busca como texto contra nombre y nota, igual que siempre.
- **La cola se calcula una vez por build de la lista, no por chat.** Se compara contra `phoneNumber` y también contra `contactName` (hay contactos guardados con su propio número como nombre); la nota conserva su búsqueda de texto literal.
- Las reglas viven en `test/phone_search_test.dart`. Es lógica silenciosa cuando falla: si se rompe, la búsqueda no da error, sólo dice que el chat no existe.

---

## ⇅ Recorrer chats sin volver a la lista (cola congelada)

Revisar la bandeja de ayer costaba dos gestos por chat: back a la lista, encontrar dónde te quedaste, entrar al siguiente. Encontrar dónde te quedaste era el caro, porque **la lista se mueve debajo de los pies**: la ordena `lastMessageTimestamp descending`, así que contestar un chat lo manda al puesto 1, y en *Pendientes* además lo saca del filtro al poner `unresponded_count: 0`. La referencia visual se evapora justo por haber hecho el trabajo.

Por eso el stepper del AppBar (`ChatNavStepper`, ↑ 4/12 ↓) **no camina la lista viva**. Camina `_navQueue`: una **foto** del orden filtrado, copiada en `_openChatFromList` en el momento de entrar desde la lista.

- **Congelada es la característica, no un atajo.** Contestar reordena y filtra la lista real; la cola no se entera y tu posición sobrevive. ↑ te devuelve al chat que acabas de contestar **aunque ya no figure en el filtro**, porque la cola conserva a los que salieron.
- **Sale del mismo `filteredChats`** que pinta la lista ([`chats_screen.dart`](lib/features/chat/chats_screen.dart)), o sea con filtro rápido + búsqueda ya aplicados: funciona igual en *Todos*, *Pendientes*, *Seguimiento*, *Con notas* y cualquier etiqueta, sin código por filtro.
- **Sin cola no hay flechas.** Abrir por push, desde la galería de medios, desde un hit de la sección "Mensajes" o con "Nuevo chat" limpia la cola: ninguna de esas aperturas es una posición dentro de una secuencia, y un `4/12` ahí sería mentira. El guard `_hasNavQueue` exige además que el cursor apunte al chat abierto.
- **Cambiar de filtro a mano** (`_setFilter`) la limpia — la secuencia que recorrías ya no es la que se ve. La degradación **automática** de *Seguimiento* → *Todos* (cuando el agente vacía la cola) **no** la limpia a propósito: el usuario no cambió de contexto, y es justo el momento en que perder las flechas dolería.
- **La geometría manda sobre la semántica:** la lista es reciente↑ / antiguo↓, así que ↓ avanza hacia lo más viejo. Chevrones verticales, no flechas ←→.
- **El contador es la mitad del valor y no cuesta nada.** Responde el "¿dónde me quedé?" que era el dolor original y comunica sin palabras que recorres una secuencia congelada. `_navQueue.length` cuenta una lista en RAM que salió del `snapshot` que la lista **ya** tenía suscrito: cero lecturas extra a Firestore.
- **La cola guarda sólo `d.id`, nunca un campo del documento.** Se arma en cada build de la lista —que rebuildea con cada mensaje entrante— y recorre *todos* los chats, no los ~10 que el `ListView` construye perezosamente. Leer un campo obligaría a `d.data()`, que reconstruye el mapa completo del doc en cada llamada: en "Todos" con miles de conversaciones son miles de deserializaciones por mensaje recibido. La primera versión pagaba eso **dos veces por chat** para precargar el nombre del contacto en el tooltip de la flecha; el tooltip se quitó, no valía su precio. El id del doc **es** el número (el backend siempre escribe en `.doc(phoneNumber)`), así que abrir por id abre el mismo chat.
- **Cambiar de chat limpia `_jumpToMessageId`/`_jumpToTimestamp`** (`_clearJumpTarget`): un salto a mensaje pertenece al chat del que salió, y MessagesView intentaría anclar en un id que no vive en la conversación nueva.
- **Borrar un chat lo saca de la cola** y corrige el índice: las flechas no pueden aterrizar en una conversación que ya no existe.

### Los atajos (`ChatNavShortcuts` escucha el teclado, no el foco)

**⌥↑/⌥↓ en Mac, Alt+↑/Alt+↓ en Windows y Linux — y también ⌘↑/⌘↓.** Van con modificador porque las flechas solas ya son del selector de respuestas rápidas del composer. `includeRepeats: false` para que mantener la flecha no atraviese la cola de un tirón.

- **⌘ está atado a propósito.** En Mac la tecla "alt" es Option (⌥), pero mucha gente llama alt a Command; equivocarse no debería costar el atajo.
- **No depende del foco: es un handler de `HardwareKeyboard`, no un `Shortcuts`.** `Shortcuts` sólo oye las teclas que **suben desde el widget enfocado**, y el foco se escapaba del detalle por tres caminos. Los tres dejaban el atajo sordo sin un solo error:
  1. **`unfocus()` sobre un scope manda el foco al scope PADRE.** Con el foco en el `FocusScope` del detalle (el estado normal al abrir un chat), un tap en la conversación lo sacaba por arriba.
  2. **Abrir un chat desde la lista** hace `FocusScope.of(context).unfocus()` sobre el scope de la ruta, que queda por encima del detalle.
  3. **La web mueve el foco sola.** Cuando el DOM pierde el foco (al cerrarse el input de texto, por ejemplo), `View` estaciona el foco de Flutter en la raíz. Cuando lo recupera, se lo da al primer campo enfocable en orden de lectura, casi siempre el buscador de la lista.

  El motor web escucha el teclado en `window`, así que las teclas **llegan igual**; lo que fallaba era a quién se las entregaba el árbol de foco. Hubo dos parches en esa línea: un `FocusScope(autofocus)` y luego "no dejar escapar el foco". Cada uno tapaba un camino y dejaba otro abierto; pelear con el foco de la web es perder. **No volver a colgar este atajo del foco.**
- **Sin el foco para acotarlo, se apaga explícitamente en tres casos:**
  - **Hay una ruta encima** (diálogo, hoja, visor de fotos): `ModalRoute.isCurrent`. Todos los paneles del chat son rutas, así que salen solos.
  - **`enabled: false`**: lo que tapa el detalle **sin** ser ruta. Hoy es sólo la galería de medios en desktop (`_buildMessageDetail(shortcutsEnabled: !_showMediaVault)`). **Una capa nueva de ese tipo tiene que apagarlo igual**, o las flechas cambiarán de chat a ciegas debajo de ella.
  - **Escribiendo, las flechas son del texto.** Con el foco en un input que ya tiene texto (`_isEditingText` busca un `EditableTextState` arriba del foco), ⌘⇧↑, ⌘↑ y ⌥↑ llegan al editor: seleccionar hasta el inicio para borrar un párrafo, ir al final, saltar de párrafo. Fue un bug: el operador seleccionaba con ⌘⇧↑, aterrizaba en otra conversación y **perdía lo que llevaba escrito**, porque el borrador muere con el chat (`MessagesView` va con `ValueKey` por chat).
    - **No basta con los modificadores.** En el framework ⌘⇧↑ nunca coincide con el binding de ⌘↑ (`SingleActivator` exige `shift: false`, y el test lo confirma). Pero en Chrome sobre Mac llegaba ⌘↑ a secas, porque el ⇧ se atrasa en el acorde. Devolviendo `false`, el navegador aplica el **evento DOM real** (con su ⇧ verdadero) al `<textarea>`.
    - **Costo conocido y aceptado:** con texto escrito, el atajo no navega hasta que envías o vacías el composer. Navegar ahí tiraba el borrador de todos modos. Sin foco en el input (tocar la conversación hace `unfocus()`) vuelve a navegar aunque haya texto: ahí las flechas no tienen nada que editar.
- **Un test que enfoca a mano lo que el app no enfoca es un test que miente.** El primero pasaba con `autofocus: true` en su `TextField` y por eso no vio nada. El grupo *el foco no manda* de `test/chat_nav_stepper_test.dart` reproduce cada escape: escribir y borrar, tocar la conversación dos veces, foco estacionado en la raíz. También fija los dos apagados: una ruta encima y `enabled: false`.

**Cuidado con el ancho del AppBar:** el stepper comparte fila con el nombre del contacto, el toggle de IA y el botón de info. `test/chat_nav_stepper_test.dart` fija que quepa en un teléfono de 360dp con un nombre largo; si engorda, ese test revienta con un `RenderFlex overflow` en vez de degradar el título en silencio.

**Fase 2 (no está hecho):** "siguiente y marcar Listo" en un gesto para el filtro *Pendientes* (un tap accidental cerraría un pendiente real), y auto-scroll de la lista al chat activo en desktop.

---

## 👥 Presencia del equipo (quién está en un chat y quién está respondiendo)

Dos operadores abrían el mismo chat sin saberlo y el cliente recibía dos respuestas. Ahora cada uno ve, en la lista y sobre el composer, si un compañero **está en ese chat** o **está respondiendo**, y un choque real ("te respondieron mientras escribías") lo frena antes de enviar.

**Alcance: sólo WhatHero, por decisión de producto.** No se intenta adivinar actividad de WhatsApp Web ni del teléfono (desde un dispositivo vinculado no se ve quién es ni si está escribiendo). Que el equipo trabaje en WhatHero es decisión del dueño de la empresa. La única excepción es gratis: un mensaje enviado desde el teléfono llega etiquetado `senderName: 'WhatsApp'`, y la guarda de choque lo trata como cualquier otra respuesta ajena.

### Efímero, en memoria, sin Firestore

La presencia viaja por Socket.io y el backend la guarda en memoria (`presenceRegistry.ts` es el estado puro; `presenceService.ts`, el cableado). **Cero lecturas y escrituras de Firestore por presencia**, salvo el chequeo de acceso (cacheado) y el nombre (el mismo cache de `resolveHumanSender`).

- **Un evento de ida y uno de vuelta.** El cliente manda `team_presence_set {clientId, sessionPhone|null, chatId|null, composing}` con su estado **completo**; el server responde a la sala `team_presence {sessionPhone, viewers:[…]}` con el estado **completo de la sesión**. No hay deltas que puedan desordenarse, ni watch/unwatch que olvidar: la sesión del set decide a qué sala entra el socket.
- **La entrada muere con el socket. No hay heartbeat, a propósito.** El ping/pong de Socket.io retira a los clientes muertos en ≤45 s, y el cliente reenvía su estado en cada conexión (`PresenceReporter.onConnected`), así que un redeploy de Railway se reconstruye solo. Un heartbeat no arreglaba ningún fallo real y Chrome estrangula los timers de las pestañas ocultas: la presencia habría parpadeado.
- **Salas por sesión con chequeo de acceso** (`memberAccess.ts`, que también usa `computeAllowedUids` de las notificaciones: un solo lugar decide quién ve qué sesión). Quitarle una sesión a un miembro (`PATCH …/access`) lo saca de la sala en el acto (`revalidatePresenceAccess`).
- **Proceso único.** Con réplicas en Railway esto necesitaría el adapter de Redis y un registro compartido.
- **Todo handler va envuelto en `.catch`** y cada set lleva un número de secuencia por socket: tras cada `await` se descarta si llegó uno más nuevo o si el socket se cerró. Sin eso, un set lento podía pisar a uno posterior o resucitar a un socket muerto.
- **Token bucket (20, +5/s) que no pierde el último estado:** lo frenado se aplica igual cuando hay ficha. Tirarlo dejaría al equipo viendo un chat que ya no es.

### Qué cuenta como "estar" y "responder" (`presence_reporter.dart`)

- **`composing` = el composer tiene texto**, no "tecleó hace N segundos". Cambia unas dos veces por mensaje, sin throttle ni timers en el server. El borrador del agente de seguimiento cuenta: el operador está a punto de mandarlo.
- **`clientId` por pestaña, no el socket ni el uid.** Al reconectar llega un socket nuevo antes de que muera el viejo, y el registro retira al "fantasma" de la misma pestaña. En el cliente, `othersIn` excluye **mi `clientId`**, no mi uid: en equipos que comparten login, "tu usuario en otro dispositivo" es otra persona y se muestra así.
- **Registro por pantalla + `TickerMode`.** Puede haber dos `ChatsScreen` vivas (la raíz queda montada bajo `AccountsScreen`; `SessionDispatcher` monta la sesión nueva antes de desmontar la vieja) y la de abajo sigue rebuildeando. Manda la última registrada que está en pantalla (`TickerMode.valuesOf(context).enabled`: se apaga bajo rutas opacas, sigue encendido bajo diálogos, hojas y visores de fotos). `ActiveChatTracker` tenía el mismo bug; ahora sólo reporta en pantalla y su `dispose` sólo limpia si el rastreador es suyo.
- **Salir de un chat se anuncia al instante.** Hubo una espera de 5 s para que el nombre no parpadeara al volver enseguida, y en uso real hacía lo contrario de lo que buscamos: dos operadores en el mismo chat se quedaban esperándose para ver quién soltaba primero. Sólo atrasaba un dato cierto ("ya salí"); pasar de un chat a otro nunca la tuvo. **No volver a ponerla.** Lo que sí espera es la ausencia: app oculta o en segundo plano, 15 s (cubre el selector de fotos y el alt-tab). `inactive` (blur de la ventana web) **no** es ausencia. Sin tocar la app 3 min = ya no estás en el chat, o un escritorio abandonado bloquearía al equipo. En móvil el teclado en pantalla no genera eventos de tecla: los cambios del composer cuentan como actividad.
- **Ausente sólo suelta el chat, no la sesión:** sigues viendo la lista y la presencia de los demás.
- En desktop, la galería de medios tapa el detalle sin ser ruta: mientras está abierta no estás "en" ese chat.
- Con el socket caído, `TeamPresenceService` vacía la presencia a los 10 s si no reconecta: mostrar la última foto sería mentir.

### La guarda de choque (`reply_collision.dart`)

Cubre lo que la presencia no alcanza: dos personas escriben a la vez, una envía primero y la otra pulsa Enter sin mirar arriba.

- **Se detecta por llegada, nunca por reloj.** Un mensaje es nuevo si aparece **arriba** del primer id ya conocido en el snapshot anterior. Paginar agrega ids abajo y borrar el más reciente "asciende" a uno viejo: ninguno de los dos cuenta. Sólo se deserializan los docs nuevos.
- **Los primeros 3 s tras abrir el chat sólo aprenden la baseline**: el snapshot del servidor que sigue al del cache es la conversación poniéndose al día, no respuestas nuevas. No basta con `isFromCache`: si el cache ya estaba al día, Firestore no manda el snapshot del servidor (sólo cambió metadata) y la baseline nunca se fijaría.
- **Choque = mensaje saliente ajeno mientras el composer tiene texto.** Excluye `bot` (reglas y recordatorios). "Mío" es `senderUid == mi uid` **y** que esta vista haya enviado algo en los últimos 2 min; no sirve `PendingMessagesService` porque los adjuntos no llevan `tempId` y la burbuja se purga al llegar el doc.
- **Franja ámbar + diálogo al enviar, sólo en choque real.** `_confirmIfCollision()` es el único punto por el que pasa cada envío de la vista (Enter, botón, adjunto, respuesta rápida). "Revisar" tiene el foco (un Enter reflejo no manda la segunda respuesta) y marca el choque como visto: el siguiente Enter envía.
- **Depende de que el eco traiga el `senderUid` correcto.** `performSendMessage` resuelve el remitente **antes** de `sock.sendMessage`: Baileys emite el eco dentro del propio envío y `saveMessageToFirestore` sólo espera ~60 ms la etiqueta. Resolverlo después metía en esa carrera una lectura de `users/{uid}` con el cache frío, y el mensaje del operador quedaba como "WhatsApp" y sin `senderUid`. **No volver a moverlo después del envío.**

### UI
- Violeta `teamViolet` (#8B5CF6) para el equipo; ámbar `collisionAmber` para el choque. No chocan con el aqua de la IA, el ámbar de "tu turno" (que vive en el AppBar) ni el rojo de "requiere humano".
- **Sobre el composer** (`TeamPresenceBanner`, prioridad choque > respondiendo > en el chat): ahí se decide escribir o no, y sigue a la vista aunque subas a leer el historial. **El AppBar no se toca**: tiene su sistema de cuatro modos y el test de 360 dp.
- **En la lista:** "Ana está respondiendo…" reemplaza la línea de preview (como el "escribiendo…" de WhatsApp) y una inicial violeta abajo a la derecha del avatar dice que alguien está dentro (arriba a la derecha es de los pendientes).
- Las reglas viven en `test/reply_collision_test.dart`, `test/presence_reporter_test.dart`, `test/team_presence_service_test.dart` y `backend/src/services/presenceRegistry.test.ts` (`cd backend && npm test`).

**Fase 2 (no está hecho):** la IA que espera mientras un compañero responde (si no llega a enviar, el cliente se quedaría sin respuesta: merece su propio análisis) y la asignación explícita de chats ("tomar chat").

---

## 📤 Llevarse la evidencia (copiar y guardar fotos y videos)

Una foto abierta a pantalla completa era un callejón sin salida: los dos visores
(`_FullscreenImage`, `_FullscreenVideo` en `message_bubble.dart`) tenían el `AppBar` sin
`actions`, y el menú de long-press sólo ofrecía "Copiar" con la guarda `text.isNotEmpty`, o
sea **nada en una foto sin caption**. El operador que necesitaba adjuntar esa foto a un
correo tenía que salirse de WhatHero.

La acción vive en `lib/core/services/media_transfer.dart`, una fachada con import
condicional calcada de `notification_sound.dart`. **Tiene que ser import condicional y no
`if (kIsWeb)`**: la rama nativa importa `dart:io`, `path_provider` y `gal`, que no compilan
en web; la web importa `package:web`, que no compila en móvil. Con un `if` el compilador
tendría que tragarse las dos. La UI entra por un solo archivo,
`lib/features/chat/widgets/media_actions.dart`, en los cuatro puntos donde aparece: los dos
visores, el menú de long-press y la galería de medios.

| | Web (Chrome/Edge) | Android / iOS |
|---|---|---|
| Foto | Copiar imagen · Descargar · Copiar enlace | Guardar en Fotos · Copiar enlace |
| Video | Descargar · Copiar enlace | Guardar en Fotos · Copiar enlace |

### Las tres cosas que se van a olvidar

1. **El `<a download>` necesita bajar los bytes primero.** El atributo `download` **se
   ignora en URLs cross-origin**, y Storage es otro origen que el Hosting: sin el `fetch`,
   Chrome abre la foto en una pestaña en vez de descargarla con nuestro nombre. Funciona
   porque `firebasestorage.googleapis.com` responde `access-control-allow-origin: *` — el
   token de la URL es la credencial, no hace falta tocar el CORS del bucket ni mandar auth.
2. **Hay que transcodificar a PNG para copiar.** Chrome sólo admite `image/png` en el
   portapapeles y las fotos de WhatsApp son JPEG, así que van por `createImageBitmap` →
   `OffscreenCanvas` → `convertToBlob`. Se hace `await` de los bytes y después `write`; la
   variante de pasarle una `Promise<Blob>` sin resolver al `ClipboardItem` es la única que
   acepta Safari (ahí el `await` consume el gesto del usuario), pero convierte cualquier
   fallo en un rechazo genérico y perdemos el diagnóstico. Si entra Safari de escritorio al
   alcance, son dos líneas.
3. **No hay copiar-imagen en el celular, y es a propósito.** El único paquete serio que lo
   hace es `super_clipboard`, que mete la cadena de compilación de Rust (cargokit) en cada
   release de iOS y Android. Demasiado peaje para un gesto que en el teléfono casi nadie
   usa: ahí se guarda en el carrete y se adjunta desde la galería. **Si alguien agrega
   "copiar imagen en Android", que sepa que ése es el costo.** `canCopyImage` es la
   constante que apaga el botón, no un `if` de plataforma disperso por la UI.

**El plugin de galería es `gal` y se eligió por lo que NO trae:** `dependencies: []` y
`darwin/gal/Package.swift`, o sea SPM puro — no reabre CocoaPods (ver *Dependencias iOS*).
Al tocar esta zona, el chequeo obligatorio después del `pub get` es que los xcconfig sigan
teniendo una sola línea y que no haya reaparecido `ios/Podfile`.

### Detalles con motivo

- **La extensión sale de la URL, nunca del `mediaType`** (`lib/core/utils/media_file_name.dart`).
  El backend guarda en `…/<messageId>.<ext>`, así que la URL ya sabe si ese "video" es un
  mp4. Deducirla del tipo daría un `.jpg` con bytes de webp: un archivo que no abre en
  ningún lado y sin error que lo delate. Las reglas viven en `test/media_file_name_test.dart`.
- **Un GIF se guarda como `.mp4`, porque eso es.** WhatsApp los manda como video con
  `gifPlayback`; renombrarlo a `.gif` daría un archivo roto.
- **Los stickers quedan fuera** aunque reusen `_FullscreenImage`: son webp y iOS los
  rechaza en Fotos. Por eso el visor recibe sus `actions` por parámetro en vez de armarlas
  adentro — no sabe qué está mostrando, y quien lo abre decide.
- **La guarda es "hay URL y no falló", no `mediaStatus == 'ready'`.** Espeja la condición
  con la que la burbuja ya habilita el tap al visor (`hasFullRes`). Con el `== 'ready'`
  estricto habría fotos que se abren a pantalla completa pero sin botón para guardarlas, y
  se rompería con los docs viejos que no tienen el campo.
- **Las acciones reciben el `ScaffoldMessengerState`, no el `BuildContext`.** Bajar un video
  son 16 MB: para cuando termina, la hoja se cerró y el visor puede estar cerrado. Capturado
  antes del `await`, el toast sale igual y no hay `mounted` que chequear.
- **El permiso de Fotos se pide ANTES de bajar los bytes.** Si el operador dice que no, no
  le gastamos sus datos. `NSPhotoLibraryAddUsageDescription` en el `Info.plist` no es
  opcional: sin esa clave la app **crashea** en el primer guardado, no falla.
- **Si el navegador niega el portapapeles, se copia el enlace** y el toast lo dice. Un solo
  fallback cubre los tres modos de fallo (permiso, pestaña sin foco, sin soporte) sin tener
  que distinguirlos. Ojo: ese enlace lleva el token de Storage y sirve para siempre para
  quien lo reciba.

**Fuera de alcance a propósito:** audios y documentos siguen con "Abrir archivo" y
`launchUrl`. En móvil la galería no los acepta, así que el mismo botón se comportaría
distinto según el tipo de archivo.

---

## 🎞️ Videos salientes: tamaño y duración

Baileys mide las **imágenes**, pero de un **video** sólo saca la miniatura con ffmpeg: `width`,
`height` y `seconds` quedan vacíos. Sin `seconds` la burbuja del cliente dice `0:00`. Y como el eco
`fromMe` es de donde `mediaService` saca `mediaWidth/Height/Duration`, la burbuja saliente de WhatHero
quedaba en 16:9 y `0:00`.

- **`probeVideo()` (`backend/src/utils/videoProbe.ts`) mide con `ffprobe` justo antes de enviar**, en
  la rama `videoUrl` de `performSendMessage`, el único punto por donde sale video (composer y
  respuestas rápidas). **Todo camino nuevo que mande video tiene que pasar por ahí.** El binario viene
  en el mismo `apk add ffmpeg` que usa Baileys para la miniatura.
- **Manda cómo se VE el video, no cómo está guardado.** ffprobe da los píxeles guardados y dos marcas
  del archivo los corrigen: la rotación (un vertical de la cámara del iPhone viene como 1920×1080 más
  −90°; sin intercambiar ancho y alto llegaría horizontal) y la proporción de píxel (ver abajo).
- **Va por archivo temporal, no por stdin.** Los `.mov`/`.mp4` de iPhone traen el `moov` al final, y
  por un pipe no se puede llegar ahí.
- **Fail-open:** si `ffprobe` falla o no existe (en la Mac de dev no está), el video sale sin medidas
  y queda `[probeVideo] No se pudo medir` en el log. Si aparece en Railway, la imagen perdió el binario.
- Los videos enviados antes de esto no se corrigen; no hay backfill.

### "En iPhone el video se ve cuadrado y aplastado" → es el archivo, no el código

Pasó el 22-sep-2026 con un tutorial comprimido en **HandBrake**. Con *Anamórfico: Automático* (su
default), al bajar un video vertical a 1080 de alto HandBrake conserva el ancho guardado y agrega una
marca de píxel no cuadrado (caja `pasp`): el archivo guardaba **1076×1080** y pedía mostrarse como
**533×1080**. Android, el mini reproductor de iOS y QuickTime respetan la marca; **el reproductor de
WhatsApp en iPhone no**: dibuja los píxeles guardados. Por eso sólo falla en iPhone y parece bug nuestro.

- **Arreglo: reexportar** con *Dimensiones → Anamórfico: Off*. `probeVideo` ya manda el ancho corregido
  (la burbuja sale con la forma correcta), pero todo indica que ese reproductor mira los píxeles y no
  el mensaje, así que desde el backend no hay arreglo seguro.
- **Diagnóstico sin pedirle el archivo al cliente:** al enviarlo, Railway loguea
  `[probeVideo] Video anamórfico (SAR …)`. Con el archivo en la Mac: `avmediainfo video.mp4`; si
  `Encoded Pixels` ≠ `Presentation Dimensions`, es esto.
- **Recodificar en el backend lo resolvería para todos**, pero cuesta CPU y segundos en cada envío. Se
  descartó mientras sea un caso raro; si empieza a repetirse, ése es el camino.

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

## 🔌 Supervisión de la conexión (nadie se queda sin quien lo reconecte)

El 03-sep-2026 una sesión de producción pasó **26 horas** mostrando "Reconectando…" sin que nadie la estuviera reconectando. El log entero del incidente son tres líneas:

```
17:39:34  [Reconexión] Intento 1/10 para d34a3443 (code: 428)
17:39:37  [startSession] d34a3443 → handshake con WA Web 2.3000.1046734560
          ...silencio absoluto durante 26 horas
```

El socket de ese reintento quedó colgado en `CONNECTING`. Baileys emite `connection.update {connection:'close'}` **sólo** desde su `end()`, y `end()` se dispara únicamente desde los handlers del WebSocket (`open`, `close`, `error`, `CB:*`). Si el connect TCP se traga los paquetes —un SYN sin respuesta, un blackhole en el NAT de salida— no ocurre ninguno y `end()` no corre jamás. El `handshakeTimeout` de la librería `ws` tampoco cubre eso: mide el upgrade HTTP, ya con TCP+TLS establecidos.

**El bug de fondo no era de Baileys, era nuestro.** El reintento N+1 lo disparaba exclusivamente el `close` del intento N: una cadena de un solo eslabón que apostaba toda la recuperación a que una librería de terceros avisara siempre que falla. El día que no avisó no había timer, ni watchdog, ni segunda opinión — ni un log que lo delatara.

### La regla: Baileys informa, el supervisor decide

Toda la lógica vive en `backend/src/services/sessionSupervisor.ts`. **Ninguna reconexión se agenda fuera de `scheduleReconnect()`.** Tres capas redundantes a propósito:

1. **Deadline de arranque** (`armConnectDeadline`, 60s) — un socket que no da señales de vida se da por muerto sin esperar a Baileys. Un `qr` o un `open` lo desarman: a partir de ahí supervisan el `qrTimeout` de Baileys y el watchdog.
2. **Scheduler propio** — `restartSession` envuelve a `startSession` en un `try/catch` que reprograma. Antes iba sin `await` ni `.catch()`: una excepción ahí era una unhandled rejection, que en Node 20 tumba el proceso.
3. **Watchdog** (`sweepSessions`, cada 2 min) — busca la firma exacta del incidente: sesión no conectada **y sin ningún timer armado**. Excepción: la que está mostrando un QR no está huérfana, está esperando a un humano.

**Se reintenta indefinidamente** (backoff 3s→5min). El viejo tope de 10 intentos borraba la sesión del Map a los 21 minutos y dejaba el fantasma. Una caída de red puede durar horas y exigirle al cliente que escanee un QR por eso es peor producto: reintentar es gratis, mentir no.

### El `status` de Firestore es una proyección, no un log de eventos

Se escribía sólo desde `connection.update`, así que cuando el evento no llegó quedó congelado en `reconnecting` para siempre. Ahora `projectStatus()` lo **deriva del estado en memoria** y el barrido lo recalcula cada 2 minutos: no puede desincronizarse.

- `connected` ⟺ `isReady` · `reconnecting` ⟺ caída hace <10 min · `reconnect_failed` ⟺ caída hace >10 min (el backend **sigue** intentando) · `disconnected` ⟺ no está en el Map.
- **`writeSessionStatus()` es el único escritor de ese campo.** No escribir `status` desde ningún otro lado.
- Mientras el estado es `reconnecting` se refresca `last_sync` cada barrido aunque nada cambie. Ese **heartbeat es lo que le permite a la app distinguir "el backend sigue intentando" de "el doc lleva horas congelado"**. Late sólo en esa ventana de 10 min para que una sesión muerta durante días no cueste una escritura cada dos minutos.
- `sweepFirestoreGhosts()` (cada 15 min y al bootear, **después** de restaurar sesiones) es lo único que paga reads: corrige docs que afirman tener sesión viva cuando en memoria no hay ninguna. Reemplaza al viejo HealthCheck, que sólo miraba `status == 'connected'` y por eso era ciego a los atascados en `reconnecting`.

### Un socket por sesión, un número por sesión

- **Teardown antes de reemplazar.** Antes no se hacía en ningún lado: cada reconexión apilaba un socket zombi con sus listeners intactos, capaz de escribir sobre el estado del socket sano. El orden importa — primero `ev.removeAllListeners()`, después `end()`.
- **`generation`**: cada socket nace con un número y su handler captura el suyo. Un socket viejo que emite tarde se descarta comparando, en vez de programar una reconexión que mataría a su reemplazo.
- **`retireDuplicateSessions`**: re-vincular genera un `sessionKey` nuevo, y el anterior se quedaba vivo peleando por la misma cuenta de WhatsApp *y* resucitando en cada arranque desde su `auth_info`. Al conectar, toda otra sesión del mismo número se retira con sus credenciales.

### `meta.json` guarda el número, no sólo la cuenta

`phoneNumber` sólo se conocía tras el primer `open`, y **todas** las escrituras de estado colgaban de `if (session.phoneNumber)`. En un arranque en frío eso significaba que una sesión que moría antes de conectar no podía ni reportar su propia caída. Ahora se persiste al conectar y se hidrata al arrancar.

Eso además desactiva una bomba: la rama `408 && !session.phoneNumber` borraba `auth_info` tratándolo como "QR abandonado" — y en un arranque en frío **toda** sesión restaurada tenía el número vacío, así que un timeout al bootear **destruía credenciales válidas**. Ahora la condición mira también `meta.json`: sólo se limpia lo que nunca llegó a vincularse.

### En la app: el botón de re-vincular no se esconde nunca

`_SessionVisual` (`accounts_screen.dart`) deriva el chip de `status` **cruzado con `last_sync`**: si dice `reconnecting` pero no late hace más de 5 min, el spinner deja de prometer algo que nadie está intentando y pasa a "Sin respuesta". Y el botón de re-vincular aparece en **cualquier** estado que no sea conectado. Esconderlo durante `reconnecting` fue lo que dejó al cliente sin salida: la única acción que arreglaba el problema era justo la que la UI ocultaba.

---


## 📦 Dependencias iOS: sólo Swift Package Manager

**iOS no tiene CocoaPods.** No hay `ios/Podfile`, ni `Podfile.lock`, ni `Pods/`. Los 14 plugins con código nativo iOS —Firebase completo, `just_audio`, `file_picker`, `image_picker_ios`, `video_player_avfoundation`…— se resuelven por SPM a través de `ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage`, y hasta el propio engine llega por ahí (`FLUTTER_FRAMEWORK_SWIFT_PACKAGE_PATH`).

- **Nunca correr `pod install` en `ios/`.** Recrea el estado híbrido: vuelve el `Pods/`, vuelven las dos fases `[CP] Check Pods Manifest.lock` —que corren en **cada** compilación sólo para diffear dos archivos— y Flutter re-inyecta el `#include? "Pods/…"` en los xcconfig. Antes de la limpieza el único pod que quedaba era el stub `Flutter (1.0.0)`: puro peaje sin carga.
- **El centinela son los xcconfig.** `ios/Flutter/Debug.xcconfig` y `Release.xcconfig` deben tener **una sola línea**: `#include "Generated.xcconfig"`. Si reaparece el `#include?` de Pods, alguien dejó un `Podfile` **y** un `Podfile.lock` en `ios/`: con ambos presentes Flutter llama a `addPodsDependencyToFlutterXcconfig` y reescribe esa línea en el siguiente `pub get`. Borrar los dos, no uno.
- **Al agregar un plugin nuevo, verificar que traiga `ios/<nombre>/Package.swift`.** Si sólo trae `.podspec`, Flutter avisa `do not support Swift Package Manager` y regenera el Podfile para ese plugin — se vuelve al híbrido. Buscar alternativa con SPM o asumir el retorno de CocoaPods a conciencia, no por accidente.
- **`flutter clean` en iOS cuesta caro.** Los paquetes de Firebase no apuntan al pub cache sino a `build/ios/SourcePackages/`; borrar `build/` obliga a Xcode a re-resolver `firebase-ios-sdk` y ~19 paquetes remotos desde GitHub. Necesita red y el primer build siguiente se va largo. Es esperado, no es síntoma de que algo se rompió.
- **`Runner.xcworkspace` se conserva** aunque no haya pods: la plantilla oficial de Flutter lo incluye y `flutter build` lo usa si existe. Debe referenciar **sólo** `Runner.xcodeproj`.
- **macOS todavía usa CocoaPods**, aunque también tiene SPM activo y su `Podfile.lock` sólo trae `FlutterMacOS`. Se puede desintegrar igual el día que se retome esa plataforma.

### `file_picker` 12 y la cadena DKImagePickerController (ITMS-90683)

`file_picker` ≤11 arrastra por SPM la cadena `DKImagePickerController → DKCamera`, y `DKCameraLocationManager.swift` llama a `CLLocationManager.requestWhenInUseAuthorization()`. Como se linkea estático dentro de `Runner`, el analizador de Apple ve la API y devuelve **ITMS-90683: Missing purpose string** exigiendo `NSLocationWhenInUseUsageDescription` — aunque ese código nunca corra. Pasó con el build 11 de la 1.1.1.

- **Nunca se ejecutaba.** Los tres `_pickDocument()` usan `FileType.any` / `FileType.custom`, que en iOS abren `UIDocumentPickerViewController`. `DKImagePickerController` sólo entra con `FileType.media/image/video`, y las fotos las maneja `image_picker`. Eran 6 SDKs de terceros (DKImagePickerController, DKCamera, DKPhotoGallery, SDWebImage, SwiftyGif, TOCropViewController) linkeados sin dar servicio.
- **Se resolvió subiendo a `file_picker: ^12.0.0`**, que borró toda la cadena (`dependencies: []` en su `Package.swift`). **No agregar el purpose string** para callar la advertencia: declara un permiso de ubicación que la app no usa y deja los 6 SDKs dentro del binario.
- **Arrastra a `package_info_plus`, y no hay atajo.** `file_picker` 12 exige `win32 ^6.3.0`; `package_info_plus` 8 lo pinea `<6.0.0`. Por eso también subió a `^10`.
- **El changelog de `package_info_plus` 9 asusta de más.** Dice exigir AGP ≥8.12.1, Gradle ≥8.13 y Kotlin 2.2.0, pero eso es el `buildscript` de su propio módulo, no un requisito para la app que lo consume: el `assembleRelease` pasa tal cual con Gradle 8.12 / AGP 8.9.1 / Kotlin 2.1.0. Verificado el 19-ago-2026. (Flutter sí avisa por su cuenta que va a dejar de soportar esas versiones — es un aviso preexistente y ajeno a este cambio.)
- **No intentes cortar por lo sano con `dependency_overrides: win32: ^6.4.0`.** `flutter pub get` lo acepta y parece que funciona — pero `package_info_plus` 8 no compila contra win32 6.x (`GetFileVersionInfo` cambió de firma y devuelve `Win32Result<bool>`). Y aunque `file_version_info.dart` sea Windows-only en runtime, **`kernel_snapshot_program` type-checkea todo el grafo Dart sin importar la plataforma destino**, así que revienta también el build de iOS. Resolver dependencias no es compilar: verificar con un build real, no con `pub get`.
- **`PlatformFile` cambió de forma en 12:** ya no expone `bytes` ni `extension`, sólo `name`, `uri`, `path`, `length()`, `readAsBytes()` y `readAsByteStream()`. Y `pickFiles()` pasó a `allowMultiple: true` por default — para selección única va `FilePicker.pickFile()`, que devuelve `PlatformFile?` directo. Ojo también con `FilePicker.platform`: desapareció, los métodos ahora son estáticos.

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