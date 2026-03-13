# 🦸‍♂️ WhatHero - WhatsApp CRM con Superpoderes

## 🎯 Contexto y Objetivo
WhatHero es un **CRM Multi-tenant** de control total que rompe las limitaciones de las APIs oficiales de Meta. Permite gestionar múltiples cuentas de WhatsApp Business desde una única interfaz profesional, integrando persistencia en la nube y preparación para asistentes de IA 24/7.

---

## 🏗️ Arquitectura Multi-Tenant (Escalabilidad SaaS)

El proyecto utiliza una estructura jerárquica para permitir que N usuarios gestionen M cuentas de WhatsApp de forma aislada y segura.

### 1. Estructura de Datos (Firestore)
La "Fuente de Verdad" sigue un patrón de documentos anidados para optimizar costos y velocidad:
`accounts/{userId}/whatsapp_sessions/{phoneNumber}`
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
- **Conectividad:** Switcher de entorno automático (`kReleaseMode`) para alternar entre Railway y Localhost.

---

## 🌉 El Puente: Socket.io con Rooms
Para garantizar que la data llegue al usuario correcto, implementamos **Rooms**:
- El socket del cliente se une a una sala con su `userId` (Firebase UID).
- El backend emite eventos (`qr`, `ready`) únicamente a esa sala: `io.to(userId).emit(...)`.
- **Eventos:** Incluyen un `sessionKey` (UUID) para que el frontend distinga entre múltiples procesos de vinculación simultáneos.

---

## 🤖 Reglas de Oro para el Desarrollo
- **Desafío de Eficiencia:** Antes de codificar, evalúa si hay una forma más sencilla o con mejor rendimiento. Di: *"Existe una forma más sencilla de hacer esto"* si es el caso.
- **Minimalismo:** Menos dependencias y menos líneas de código son siempre mejores.
- **Seguridad:** Los datos de la sesión (`auth_info`) nunca se suben al repo; se gestionan vía Volúmenes o Variables de Entorno.

---

## 🛠️ Stack Tecnológico
- **Frontend:** Flutter (Web/Mobile).
- **Backend:** Node.js + Express + Socket.io + Baileys.
- **Infraestructura:** Railway (Docker + Volumes) & Firebase (Auth + Firestore + Hosting).