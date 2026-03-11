# 🦸‍♂️ WhatHero - WhatsApp CRM con Superpoderes

## 🎯 Contexto y Objetivo
WhatHero nace de la necesidad de tener un **CRM de WhatsApp de control total**, evitando las limitaciones de costo, historial y rigidez de las APIs oficiales de Meta o plataformas cerradas como Kommo. 

El objetivo principal es crear una herramienta que permita:
1. **Conexión vía QR:** Sin depender de la API de Cloud de WhatsApp (usando Baileys).
2. **Historial Completo:** Acceso a mensajes previos a la conexión.
3. **Control de IA:** Un switch manual para activar/desactivar respuestas automáticas por contacto.
4. **Respuestas Rápidas Multimedia:** Enviar imágenes y plantillas de forma ágil.

---

## 🏗️ Arquitectura del Proyecto (Separación de Preocupaciones)
El proyecto está dividido en dos grandes bloques para permitir escalabilidad y despliegue profesional:

### 1. `/backend` (El Cerebro)
- **Tecnología:** Node.js + TypeScript + Baileys.
- **Razón de existir:** WhatsApp requiere una conexión por sockets constante que no puede vivir dentro de un celular de forma eficiente. Este backend gestiona la sesión de WhatsApp 24/7 en un servidor.
- **Estado:** Mantiene la sesión en `auth_info/` y gestiona el flujo de la IA.

### 2. `/ (Raíz de Flutter)` (La Interfaz)
- **Tecnología:** Flutter (com.sintaxis.whathero).
- **Razón de existir:** Es la consola de control para el usuario. Se comunica con el backend para mostrar chats y enviar comandos.

---

## 🌉 El Puente: Socket.io
La comunicación entre la App y el Backend es **bidireccional y en tiempo real**.
- El Backend emite eventos como `qr`, `ready` y `new_message`.
- La App envía comandos como `send_message` o `toggle_ai`.

---

## 🛠️ Stack Tecnológico
- **Frontend:** Flutter (Stateful Widgets por ahora, evolucionando a Provider/Riverpod).
- **Backend:** Node.js, Express, Socket.io, @whiskeysockets/baileys.
- **Persistencia:** Firebase Firestore (Próximo paso) y Auth Info local.

---

## 🤖 Instrucciones
- **Desafío Técnico:** Antes de implementar cualquier solución que yo te proponga, analiza si es la más eficiente. 
- **Regla:** Si conoces una manera más sencilla, corta o con mejor rendimiento de solucionar el problema que la que yo estoy planteando, **debes decirme primero:** "Existe una forma más sencilla de hacer esto" y explicarme por qué antes de escribir el código.
- **Minimalismo:** Prefiero menos líneas de código y menos dependencias si el resultado es el mismo.