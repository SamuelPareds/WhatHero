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

## 🤖 Reglas de Oro para el Desarrollo
- **Desafío de Eficiencia:** Antes de codificar, evalúa si hay una forma más sencilla o con mejor rendimiento. Di: *"Existe una forma más sencilla de hacer esto"* si es el caso.
- **Minimalismo:** Menos dependencias y menos líneas de código son siempre mejores.
- **Seguridad:** Los datos de la sesión (`auth_info`) nunca se suben al repo; se gestionan vía Volúmenes o Variables de Entorno.
- **Commentarios** Si hay comentarios en el código, siempre ponlos en español, para que los vibecoding podamos entender.

---

## 🛠️ Stack Tecnológico
- **Frontend:** Flutter (Web/Mobile).
- **Backend:** Node.js + Express + Socket.io + Baileys 7.0.
- **Infraestructura:** Railway (Docker + Volumes) & Firebase (Auth + Firestore + Hosting).