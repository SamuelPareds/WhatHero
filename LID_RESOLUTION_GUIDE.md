# 🔍 Guía de Resolución del Problema de LID (@lid format)

## El Problema

Cuando alguien con WhatsApp Business te escribe **por primera vez**, su número aparece como:
- ❌ `115767152529428@lid` (en lugar de `5215530532906`)

Esto ocurre porque WhatsApp cambió al formato **LID (Local Identifier)** para proteger la privacidad de los números de teléfono.

### ¿Por qué sucede?
1. **Con WhatsApp Business:** Especialmente en primeros contactos, WhatsApp protege el número real usando LID
2. **No es exclusivo de Business:** También puede suceder en cuentas personales con grupos o nuevos contactos
3. **Limitación de Baileys:** No hay forma 100% confiable de mapear `@lid` → número real en chats privados

---

## La Solución: Multi-Layer LID Resolution

He implementado un sistema de **3 capas** para resolver LIDs:

### **Capa 1: Reactive Mapping (Escuchar eventos de WhatsApp)**
```typescript
sock.ev.on('lid-mapping.update', (mappings) => {
  // Cuando WhatsApp envía un mapeo LID → Número
  // Lo almacenamos en memoria para futuras referencias
});
```
✅ **Ventaja:** Automático, sin latencia
⚠️ **Limitación:** Depende de que WhatsApp envíe el mapeo

### **Capa 2: Contact Lookup (Buscar en contactos de Baileys)**
```typescript
const resolved = await resolveLIDFromContacts(contactPhone, sock);
```
- Cuando recibimos un mensaje con @lid, buscamos en la lista de contactos de Baileys
- Si encontramos una coincidencia, resolvemos el LID al número real

✅ **Ventaja:** Trata de resolver proactivamente
⚠️ **Limitación:** Requiere que el contacto esté en la lista de Baileys

### **Capa 3: Fallback Storage**
```typescript
// Si no se puede resolver, usamos el LID como identificador de contacto
// Ejemplo: "115767152529428" (el LID sin @lid)
```
✅ **Ventaja:** Garantiza que los mensajes se guardan sin perder datos
⚠️ **Limitación:** El chat se crea con un ID "feo" hasta que WhatsApp envíe el mapeo

---

## Flujo de Resolución Cuando Llega un Mensaje

```
1. Mensaje llega con remoteJid: "115767152529428@lid"
   ↓
2. Verificar si ya tenemos mapeo: contactPhone = "5215530532906" ✓
   (Si sí, usar ese número)
   ↓
3. Si no, intentar resolveLIDFromContacts()
   (Buscar en lista de contactos de Baileys)
   ↓
4. Si tampoco, usar el LID como identificador:
   contactPhone = "115767152529428"
   (Guardamos con ID de chat: "115767152529428")
   ↓
5. Cuando WhatsApp envíe lid-mapping.update:
   Almacenamos: "115767152529428" → "5215530532906"
   (En futuras referencias se resuelve automáticamente)
```

---

## Para Casos "Stuck" (LID que no se Resuelve)

Si un chat permanece con un ID como `115767152529428` y no se resuelve:

### **Opción 1: Esperar y Tomar Acción**
- Cuando el usuario responda ese mensaje desde WhatsApp Web
- WhatsApp enviará el `lid-mapping.update` automáticamente
- El siguiente mensaje se guardará con el número correcto

### **Opción 2: Acción Manual (Future)**
Podríamos agregar un endpoint para:
```bash
POST /resolve-lid-chat
{
  "accountId": "...",
  "sessionId": "...",
  "lidContactPhone": "115767152529428",
  "realPhoneNumber": "5215530532906"
}
```
Esto podría:
1. Migrar todos los mensajes del chat LID al número real
2. Eliminar el chat LID antiguo
3. Sincronizar con Firestore

---

## Debugging y Logs

Cuando se activa la resolución de LID, verás logs como:

```
[startSession] LID-Mapping update received with 3 mappings
[LID-Mapping] Stored mapping: 115767152529428 -> 5215530532906
[AI] Message from LID format: 115767152529428@lid, attempting to resolve...
[AI] Successfully resolved LID to 5215530532906
```

---

## Limitaciones Conocidas

1. **LIDs que nunca se resuelven:** Si WhatsApp nunca envía el mapeo, quedan como `115767152529428` indefinidamente
2. **No es 100% garantizado:** Depende del comportamiento de WhatsApp
3. **Solo aplica a mensajes nuevos:** Los mensajes históricos con LID no se actualizan automáticamente

---

## Próximos Pasos (Opcional)

1. **Migración de Chats LID:** Crear un endpoint para mover mensajes de chats LID a números reales una vez que se resuelvan
2. **Notificación al Usuario:** Badge de ⚠️ en chats que todavía tienen IDs resueltos
3. **Sincronización Inversa:** Si el usuario escribe a un contacto LID, automáticamente sincronizar con el número real cuando WhatsApp envíe el mapeo

---

## Links Útiles

- [Baileys GitHub Issue #1718](https://github.com/WhiskeySockets/Baileys/issues/1718) - LID Format Problem
- [Baileys Migration Guide to v7](https://baileys.wiki/docs/migration/to-v7.0.0/)
- [WhatsApp Business API](https://developers.facebook.com/docs/whatsapp) - Context sobre LID
