# 🔗 JID Format Fix: Resolver Problema de Mensajes no Entregados

## El Problema Que Solucionamos

Cuando un contacto con WhatsApp Business o formato `@lid` te escribe:
1. ✅ Baileys recibe: `remoteJid = "115767152529428@lid"`
2. ✅ El mensaje se guarda en Firestore correctamente
3. ❌ **Pero cuando TÚ respondes, el contacto NO recibe el mensaje**

### Por Qué Pasaba

La app enviaba el mensaje a:
```
115767152529428@s.whatsapp.net  ❌ FORMATO INCORRECTO
```

Pero el contacto estaba registrado como:
```
115767152529428@lid  ✅ FORMATO CORRECTO
```

Baileys intenta enviar a un JID que no existe.

---

## La Solución: Almacenar el JID Completo

### 1️⃣ **Guardar el `remoteJid` en Firestore**

Cuando se recibe un mensaje, ahora guardamos el `remoteJid` completo en el documento del chat:

```dart
// En Firestore
chats/{chatId} = {
  phoneNumber: "115767152529428",      // ID del chat (sin @)
  remoteJid: "115767152529428@lid",    // ✅ JID completo con formato correcto
  lastMessage: "...",
  ...
}
```

### 2️⃣ **Recuperar y Usar el JID Correcto al Enviar**

Cuando envías un mensaje:

```typescript
// Backend busca el chat en Firestore
const chatDoc = await db.collection(...).doc(to).get();
const jid = chatDoc.data()?.remoteJid || `${to}@s.whatsapp.net`;

// Usa el JID correcto para enviar
await sock.sendMessage(jid, { text });
```

### 3️⃣ **Frontend Pasa `accountId`**

El frontend ahora envía `accountId` junto con el mensaje:

```dart
final response = await http.post(
  Uri.parse('$backendUrl/send-message'),
  body: jsonEncode({
    'to': widget.phoneNumber,
    'text': text,
    'sessionKey': widget.sessionKey,
    'accountId': widget.accountId,  // ✅ NUEVO
  }),
);
```

---

## Flujo Completo (Bidireccional)

### Mensaje Entrante (Contacto → Tú)
```
1. Contacto envía con: remoteJid = "115767152529428@lid"
   ↓
2. Baileys lo recibe y saveMessageToFirestore lo procesa
   ↓
3. Guardamos en Firestore:
   - chatId = "115767152529428" (para document ID)
   - remoteJid = "115767152529428@lid" (formato completo)
   ↓
4. ✅ El chat aparece con ID "115767152529428" en la app
```

### Mensaje Saliente (Tú → Contacto)
```
1. Tú escribes un mensaje
   ↓
2. Frontend envía: POST /send-message {to: "115767152529428", accountId, sessionKey}
   ↓
3. Backend busca en Firestore el chat con ID "115767152529428"
   ↓
4. Recupera: remoteJid = "115767152529428@lid"
   ↓
5. Usa ese JID para enviar: sock.sendMessage("115767152529428@lid", {text})
   ↓
6. ✅ Baileys envía con el formato CORRECTO al contacto
```

---

## Casos Soportados

| Caso | Antes | Después |
|------|-------|---------|
| **Primer contacto @lid** | ❌ No se entregaba | ✅ Se entrega |
| **WhatsApp Business** | ❌ No se entregaba | ✅ Se entrega |
| **Contactos normales** | ✅ Funcionaba | ✅ Sigue funcionando |
| **Contactos con `@s.whatsapp.net`** | ✅ Funcionaba | ✅ Sigue funcionando |

---

## Logs de Debugging

Cuando envías un mensaje, verás en el backend:

```
[/send-message] Using stored remoteJid: 115767152529428@lid
[/send-message] Sending message to JID: 115767152529428@lid
Message sent to 115767152529428: Hola
```

O si no hay remoteJid guardado:

```
[/send-message] No stored remoteJid found for 115767152529428, using default: 115767152529428@s.whatsapp.net
```

---

## Migración de Chats Existentes

Si tienes chats con el ID "feo" (`115767152529428@lid`):

1. **Próximos mensajes:** Se guardarán correctamente con `remoteJid`
2. **Mensajes posteriores:** Se enviarán al contacto correctamente
3. **Histórico:** Permanece como está (sin cambios)

Si necesitas migrar los antiguos, podríamos agregar un endpoint en el futuro.

---

## Archivos Modificados

1. **backend/src/services/firestoreService.ts**
   - Ahora guarda `remoteJid` completo en el documento del chat

2. **backend/index.ts**
   - Endpoint `/send-message` recupera el `remoteJid` guardado
   - Fallback a `@s.whatsapp.net` si no existe

3. **lib/features/chat/messages_view.dart**
   - Frontend ahora envía `accountId` en el request

---

## Resumen

✅ **El problema:** Usábamos el formato JID incorrecto al enviar
✅ **La solución:** Guardar y usar el JID exacto que Baileys recibió
✅ **Resultado:** Mensajes se entregan correctamente a contactos @lid y WhatsApp Business
