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