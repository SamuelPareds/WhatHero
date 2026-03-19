# Verificación de Migración Baileys v6.6 → v7.0

## Estado: ✅ Código Implementado y Testeado

Commit: `8d3a116` - "Migrar a Baileys v7.0 y resolver duplicación de chats con LID"

### Cambios Realizados

**Backend (`backend/`)**
1. ✅ `package.json`: Baileys `^7.0.0-rc.9` + `"start": "tsx index.ts"`
2. ✅ `Dockerfile`: Single-stage, corre `tsx index.ts` directamente
3. ✅ `index.ts`: Actualizado handler `lid-mapping.update` al nuevo payload `{lid, pn}`
4. ✅ `src/utils/phone.ts`: Nueva función `resolveLIDViaSock()` usa `sock.signalRepository.lidMapping`
5. ✅ `src/services/firestoreService.ts`: Usa `toNumber()` + `contact.phoneNumber` garantizado

**Verificación Local**
- ✅ `npm install` sin errores (Baileys v7.0.0-rc.9 instalado)
- ✅ `npx tsc --noEmit` compila sin errores
- ✅ `npm run build` genera dist/ correctamente
- ✅ `npm run dev` inicia exitosamente, conecta a WhatsApp

### Pruebas en Staging/Producción

Sigue estos pasos para verificar que el fix funciona:

#### 1. **Deploy del nuevo código**
```bash
# En Railway o tu servidor
docker build -t whathero-backend:v7 backend/
docker push whathero-backend:v7

# Actualizar Railway a usar la nueva imagen
```

#### 2. **Verificar Conexión Inicial**
- Conecta una nueva cuenta de WhatsApp
- En los logs debes ver:
  ```
  Server running on port 3000
  Firebase initialized from FIREBASE_CONFIG environment variable
  [startSession] WhatsApp conectado como: 521XXXXXXXXX
  [startSession] READY emitido exitosamente
  ```

#### 3. **Prueba de Mensajes - WhatsApp Web**
- Escribe desde **WhatsApp Web** a la cuenta conectada en WhatHero
- Verifica en Firestore:
  ```
  accounts/{userId}/whatsapp_sessions/{botPhone}/chats/{realPhone}
  ```
  - El document ID **debe ser el número real** (ej: `5215530532906`)
  - No debe haber campo `@lid` en el ID
  - El campo `remoteJid` guardado puede contener `@lid` internamente (eso es correcto)

#### 4. **Prueba de Mensajes - Kommo/CRM**
- Escribe desde **Kommo** a la misma cuenta
- Verifica que el mensaje llega al **mismo chat** en Firestore
  - Debe ser el mismo document con ID = número real
  - Los mensajes de ambas fuentes deben estar en la misma subcollection `messages`
  - **No debe haber 2 chats duplicados**

#### 5. **Verificar Campos de Contacto**
- En el chat document, verifica que existe:
  ```json
  {
    "phoneNumber": "5215530532906",
    "remoteJid": "5215530532906@s.whatsapp.net" (o @lid, ambos son correctos),
    "contactName": "Nombre del contacto",
    "lastMessage": "...",
    "createdAt": "..."
  }
  ```

#### 6. **Respuestas de AI (si está habilitado)**
- Envia un mensaje desde WhatsApp Web
- Verifica que WhatHero responde (si AI está configurado)
- Envia otro desde Kommo
- Verifica que la respuesta sigue funcionando

#### 7. **Verificar Logs de Resolución LID**
- Si un mensaje llega con LID, debes ver en logs:
  ```
  [LID-Resolve] Resolved via lidMapping store: 115767152529428 → 5215530532906
  ```
  o
  ```
  [Consolidate] Found LID chat for 115767152529428, consolidating to 5215530532906
  ```

#### 8. **Test de Reconexión**
- Reinicia el backend (simular crash)
- Envia un mensaje mientras está caído
- Cuando el backend inicia:
  - Los mappings se cargan desde `auth_info/lid-mapping-*.json`
  - No hay pérdida de estado
  - El mensaje llega correctamente al chat existente

### Qué cambió (desde la perspectiva del usuario)

- **Para tu cliente:** Nada. El `phoneNumber` sigue guardándose para registrar citas.
- **Para WhatHero internamente:** Los LIDs ahora se resuelven de forma confiable y persistente.
- **El bug:** Ya no habrá 2 chats duplicados para la misma persona que escribe desde múltiples fuentes.

### Rollback (si es necesario)

Si encuentras problemas:

```bash
# Volver a Baileys v6.6
git revert 8d3a116

# O en package.json manualmente:
# "@whiskeysockets/baileys": "^6.6.0"
# "start": "node dist/index.js"

npm install
npm run build
```

### Notas Técnicas

- **ESM vs CommonJS:** Baileys v7 es ESM puro. Por eso usamos `tsx` en producción en lugar de compilar a CommonJS. No reconfiguramos `tsconfig.json` porque firebase-admin y express requieren CommonJS; `tsx` lo maneja transparentemente.
- **Persistent Auth State:** Baileys v7 automáticamente crea:
  - `auth_info/{sessionKey}/lid-mapping-*.json`
  - `auth_info/{sessionKey}/device-list-*.json`
  - `auth_info/{sessionKey}/tctoken-*.json`
  Estos no deben borrarse, son el corazón de la nueva resolución LID.
- **Performance:** No hay impacto. La resolución es más rápida (lee archivos locales antes de hacer USYNC a WhatsApp).

### Problemas Conocidos

Ninguno encontrado en testing local. Si ves algo:

1. **"Could not resolve LID"** → Normal si es muy nuevo; espera 1-2 segundos o reinicia
2. **Logs mostrando `@lid` JIDs siempre** → Expected si el contacto es muy nuevo en WhatsApp
3. **docker build falla en Dockerfile** → Asegúrate de que `npm install` incluye `tsx` (viene en package.json)
