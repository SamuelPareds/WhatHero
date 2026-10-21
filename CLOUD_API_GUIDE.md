# ☁️ Guía de WhatsApp Cloud API (Meta oficial)

Cómo probar Cloud API en desarrollo, cómo dar de alta un número real en producción y qué hacer cuando algo no llega. Pensada para quien nunca tocó la plataforma de Meta. El detalle técnico de por qué el código es como es vive en `CLAUDE.md`, sección *☁️ WhatsApp Cloud API*.

> Las pantallas de Meta cambian seguido: si un nombre no coincide exactamente, busca el más parecido.

---

## Cómo funciona, en una frase

El cliente conecta **su propia app de Meta** a WhatHero. WhatHero envía por la API de Meta, y Meta le avisa a WhatHero por **webhook** cada vez que llega un mensaje o cambia un estado de entrega.

```
Cliente (WhatsApp) ──► Meta ──webhook──► WhatHero backend ──► Firestore ──► App WhatHero
App WhatHero ──► WhatHero backend ──Graph API──► Meta ──► Cliente (WhatsApp)
```

A diferencia del QR, **no se sincroniza nada más**: sólo existe en WhatHero lo que entra por webhook y lo que se envía desde WhatHero.

## Glosario mínimo

| Término | Qué es | Dónde se ve |
|---|---|---|
| **App de Meta** | El "programa" registrado en Meta for Developers. Cada cliente tiene la suya. | developers.facebook.com → Mis apps |
| **WABA** (WABA ID) | La cuenta de WhatsApp Business donde viven los números. | WhatsApp → Configuración de la API |
| **Phone Number ID** | El id interno del número (no es el teléfono). | WhatsApp → Configuración de la API |
| **Access Token** | La llave para enviar. El **temporal** dura 24 h; el **permanente** sale de un Usuario del sistema. | Configuración de la API / Configuración del negocio |
| **App Secret** | La clave secreta de la app. WhatHero la usa para comprobar que cada webhook viene de Meta. | Configuración de la app → Básica → Clave secreta |
| **Webhook** | La URL de WhatHero a la que Meta avisa. Se configura con un **token de verificación** y hay que suscribir el campo **`messages`**. | WhatsApp → Configuración → Webhook |
| **App suscrita al WABA** | Sin esto Meta no entrega los mensajes del WABA a la app. **WhatHero lo hace solo al conectar.** | Sólo por API (ver *Comprobar a mano*) |
| **Ventana de 24 h** | Puedes mandar texto libre sólo hasta 24 h después del último mensaje del cliente. Fuera de ella, sólo **plantillas** aprobadas. | Banner "Ventana de 24h cerrada" en el chat |

Valores fijos de WhatHero:
- **Token de verificación:** `whathero_meta_verify_2026`
- **URL del webhook en producción:** `https://whathero.up.railway.app/webhook/meta`

---

## ✅ Checklist: probar en desarrollo

En desarrollo los datos van a `accounts_dev` y el backend corre en tu Mac. Meta no puede llamar a `localhost`, así que hace falta un **túnel**: una URL pública temporal que reenvía a tu backend. Usamos `cloudflared`, la herramienta gratuita de **Cloudflare**.

### Una sola vez
- [ ] Instalar el túnel: `brew install cloudflared`
- [ ] Crear una **app de Meta para pruebas** en developers.facebook.com → Crear app → tipo *Negocio* → agregar el producto **WhatsApp**. Meta te da un **número de prueba** gratis.
- [ ] En WhatsApp → Configuración de la API, en **"Para"**, agrega tu WhatsApp personal a la lista de destinatarios permitidos (el número de prueba sólo escribe a esa lista).

### Cada vez que pruebes
1. [ ] **Backend local:** `cd backend && npm run dev` (en el log debe decir `DEVELOPMENT` y `accounts_dev`).
2. [ ] **Túnel:** en otra terminal, `cloudflared tunnel --url http://localhost:3000`. Copia la URL `https://….trycloudflare.com`. **Deja esa terminal abierta**: si la cierras, la URL cambia.
3. [ ] **Comprueba el túnel** (debe responder `ok`):
   ```bash
   curl "https://<tu-túnel>/webhook/meta?hub.mode=subscribe&hub.verify_token=whathero_meta_verify_2026&hub.challenge=ok"
   ```
4. [ ] **Webhook en Meta:** WhatsApp → Configuración → Webhook → URL `https://<tu-túnel>/webhook/meta`, token `whathero_meta_verify_2026` → **Verificar y guardar**. Después, en *Campos del webhook*, fila **`messages`** → **Suscribirse**. Si el túnel cambió, repite este paso.
5. [ ] **App:** `flutter run` (debug). Opcional, para que la hoja de conexión muestre tu URL: `flutter run --dart-define=WEBHOOK_PUBLIC_URL=https://<tu-túnel>`.
6. [ ] **Conectar:** entra con el **owner** o un miembro con acceso total → **+** → *WhatsApp Cloud API* → pega Phone Number ID, WABA ID, Access Token (el temporal sirve) y App Secret → *Conectar número*. WhatHero valida todo con Meta y suscribe la app al WABA.

### Qué probar
- [ ] Escribe desde tu WhatsApp al número de prueba → aparece el chat en WhatHero.
- [ ] Respóndele desde WhatHero con texto libre → te llega.
- [ ] **Nuevo chat** (FAB de la lista) con tu número → botón de plantillas → `hello_world` → te llega y se ve en WhatHero con ✓, luego ✓✓ al entregarse y ✓✓ aqua al leerse.
- [ ] Un chat cuyo último mensaje del cliente tiene más de 24 h muestra *Ventana de 24h cerrada*.

### Lo que NO va a pasar (y es normal)
- Un mensaje enviado desde el **panel de Meta** no aparece en WhatHero. Meta no avisa de lo que mandan otras herramientas.
- El botón **"Probar"** del webhook en el panel manda un `phone_number_id` ficticio. En el log verás `No hay sesión conectada para phone_number_id=…`: eso confirma que el webhook llega.
- El **token temporal vence a las 24 h**. Pega uno nuevo en ⚙️ → *Actualizar credenciales* (el App Secret puede quedar vacío y se conserva).
- Un miembro **restringido** que conecta un número no lo ve en "Mis Cuentas" (pendiente conocido). Prueba con el owner.

---

## 🚀 Checklist: producción

### A. Desplegar WhatHero (una vez)
- [ ] Commit + push; Railway despliega solo.
- [ ] Comprobar que el webhook existe en producción (debe responder `ok`, no un 404):
  ```bash
  curl "https://whathero.up.railway.app/webhook/meta?hub.mode=subscribe&hub.verify_token=whathero_meta_verify_2026&hub.challenge=ok"
  ```
- [ ] Variables de Railway: **no hace falta ninguna nueva.** `META_APP_SECRET` es opcional (sólo respaldo).

### B. Dar de alta un número real (por cada cliente)
1. [ ] **App de Meta del cliente**, separada de la de pruebas (cada app tiene una sola URL de webhook).
2. [ ] **Liberar el número:** un número no puede estar a la vez en la app de WhatsApp y en Cloud API. Respaldar los chats y, en el teléfono, Ajustes → Cuenta → **Eliminar cuenta**.
3. [ ] **Agregar el número** en la app (Configuración de la API → Agregar número), verificar por SMS o llamada y definir el **PIN de 6 dígitos**. Sin ese registro los envíos fallan con "cuenta no registrada". El **nombre visible** pasa revisión de Meta.
4. [ ] **Token permanente:** Configuración del negocio → *Usuarios del sistema* → crear uno con rol administrador → *Asignar activos*: la app y la cuenta de WhatsApp → *Generar token* con `whatsapp_business_messaging` y `whatsapp_business_management`. El temporal no sirve en producción.
5. [ ] **Método de pago** en WhatsApp Manager, para las plantillas que se cobran. Responder dentro de las 24 h es gratis.
6. [ ] **Webhook de la app:** URL `https://whathero.up.railway.app/webhook/meta`, token `whathero_meta_verify_2026`, campo **`messages`** suscrito.
7. [ ] **Publicar la app** si los mensajes reales no llegan (el panel lo avisa con una franja naranja). Pide una URL de política de privacidad.
8. [ ] **Conectar en WhatHero** desde la app de producción (release), con el owner: Phone Number ID, WABA ID, **token permanente** y App Secret.
9. [ ] **Prueba de humo:** escribir al número, responder desde WhatHero y enviar una plantilla.

> Si ese número ya está vinculado **por QR** en WhatHero, el alta se rechaza ("ya está vinculado por código QR"). Pasarlo a Cloud API conservando el historial todavía no existe: hoy habría que eliminar la sesión QR, que borra su historial en WhatHero.

### C. ¿Hay que verificar el negocio?
**No para empezar.** Sin verificar se puede operar con límites (Meta los ajusta; confírmalos en WhatsApp Manager → tu número → *Límite de mensajes*):

| | Sin verificar | Verificado |
|---|---|---|
| Responder a quien te escribe (24 h) | Sin límite | Sin límite |
| Escribir primero con plantilla | ~250 clientes distintos cada 24 h | Escala según calidad |
| Números en el portafolio | Hasta 2 | Más |
| Palomita verde oficial | No | Requiere además notoriedad |

---

## 🩺 Cuando algo no funciona

Mira primero el **log del backend** (terminal en dev, Railway en producción) y busca `[CloudAPI`.

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| Meta: "No se pudo validar la URL de devolución de llamada" | El backend o el túnel no responde en esa URL (o Railway sin desplegar: 404). | Correr el `curl` del checklist. Revisar que el túnel siga abierto y que la URL sea la actual. |
| Todo en verde, envías bien, pero no llega nada del cliente | Falta el campo `messages`, la app no está suscrita al WABA, o la app sin publicar. | Suscribir `messages`. Hacer *Actualizar credenciales* (vuelve a suscribir la app). Si sigue igual, publicar la app. |
| Log: `Firma inválida para …` | El App Secret guardado no es el de la app que manda el webhook. | *Actualizar credenciales* con el App Secret correcto. |
| Log: `No hay sesión conectada para phone_number_id=…` | Llegó un webhook de un número que no está conectado en este entorno. | Normal con el botón "Probar" del panel. Si es tu número, conéctalo en el entorno correcto. |
| Alta: "El App Secret no corresponde a la app de este Access Token" | App Secret de otra app. | Copiarlo de la misma app que emitió el token. |
| Alta: "El Phone Number ID no pertenece a ese WABA ID" | Ids de pantallas distintas. | Copiar los dos de *Configuración de la API*, con el mismo número elegido. |
| Alta: "Meta no dejó suscribir tu app…" | El token no tiene `whatsapp_business_management`. | Generar el token con los dos permisos de WhatsApp. |
| Chat: "Pasaron más de 24 h…" | Ventana de 24 h cerrada. | Enviar una plantilla. |
| Chat: "El Access Token de Meta expiró o es inválido" | Token temporal vencido o revocado. | *Actualizar credenciales* con un token nuevo (en producción, permanente). |
| Meta: "Application has been deleted" | La app que emitió el token se borró. | Reconectar con el token y el App Secret de una app vigente. |
| Conecté y no aparece en "Mis Cuentas" | Entraste con un miembro restringido. | Entrar con el owner o darle acceso a esa sesión en *Miembros*. |

### Comprobar la configuración de Meta a mano
Con el **Explorador de la Graph API** (developers.facebook.com/tools/explorer): elige la app arriba a la derecha y genera un token con los dos permisos de WhatsApp.

| Para ver… | Método y ruta | Token |
|---|---|---|
| Si la app está suscrita al WABA | `GET {WABA_ID}/subscribed_apps` (con `POST` la suscribe) | De usuario o del sistema |
| Qué números tiene el WABA | `GET {WABA_ID}/phone_numbers` | De usuario o del sistema |
| URL y campos del webhook de la app | `GET {APP_ID}/subscriptions` | "Token de acceso a la app" |

---

## 🔐 Seguridad
- El Access Token y el App Secret se guardan sólo en `cloud_api_secrets`, que ninguna app cliente puede leer. **Nunca los pegues en chats, tickets ni capturas.**
- La cuenta de servicio de Firebase del backend (`FIREBASE_CONFIG`) puede leer los tokens de todos los clientes: es la llave más sensible de WhatHero.
- Si un token se filtra, revócalo en Meta (Usuarios del sistema) y haz *Actualizar credenciales* con uno nuevo.
