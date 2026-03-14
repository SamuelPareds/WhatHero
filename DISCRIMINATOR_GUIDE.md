# 🎯 Guía del Discriminador de Intenciones

## ¿Qué es el Discriminador?

El **Discriminador** es un filtro inteligente que intercepta cada mensaje ANTES de que el asistente IA responda. Su trabajo es decidir:

- ✅ **Respuesta SI**: El asistente IA puede responder este mensaje
- ❌ **Respuesta NO**: Este mensaje requiere atención de un humano

---

## ¿Cómo Funciona?

```
Cliente envía mensaje
    ↓
¿Está activado el discriminador?
    ├─ NO → El asistente responde directamente
    └─ SÍ → El discriminador analiza el mensaje
        ↓
    ¿El mensaje cumple las reglas de "requiere humano"?
        ├─ SÍ → Marca como "requiere atención humana"
        │       Notifica al operador
        │       NO envía respuesta automática
        └─ NO → El asistente responde normalmente
```

---

## Cómo Configurar el Discriminador

### 1. Habilitar en la App
- Abre **Configuración IA** (botón de engranaje en la sesión)
- Activa el toggle **"Discriminador de Intenciones"**
- Se mostrará un campo de texto para escribir tus reglas

### 2. Escribir las Reglas

**Escribe en lenguaje natural, como si le hablaras a un colega.**

❌ **NO hagas esto:**
```
Respuesta: SI si la intención es TalkToAiAssistant
Respuesta: NO si la intención es TalkToHuman
```

✅ **HAZ ESTO:**
```
Pasa el mensaje a un humano si:
- El cliente pregunta sobre disponibilidad en fechas específicas
  (ej: "¿tienes espacio el jueves?", "¿qué fechas tienes libres?")
- El cliente quiere agendar, reprogramar o cancelar una cita
- El cliente pregunta sobre servicios postparto o postquirúrgicos
- El cliente solicita fotos, catálogo o material visual
- El cliente pregunta sobre su saldo o historial de servicios

Para todo lo demás, responde tú mismo.
```

---

## Ejemplos Prácticos

### Ejemplo 1: SPA (Servicio de Belleza)

```
Pasa al humano si el cliente:
- Pregunta disponibilidad en fechas/horarios específicos
- Quiere agendar una cita nueva
- Quiere cambiar o cancelar una cita existente
- Pregunta sobre el servicio postparto o postquirúrgico
- Solicita catálogo de servicios o fotos
- Hace preguntas sobre promociones o descuentos especiales
- Pregunta sobre métodos de pago

Para consultas generales sobre servicios (descripción, duración,
beneficios), responde tú mismo.
```

### Ejemplo 2: Restaurante

```
Pasa al humano si:
- Pregunta si hay mesa disponible para una fecha/hora específica
- Quiere hacer una reserva
- Cambia o cancela una reserva
- Pregunta sobre ingredientes alérgenos
- Solicita menú visual o fotos de platos
- Tiene una queja o reclamo

Responde tú mismo las consultas sobre horarios, ubicación, tipos
de cocina, o información general del menú.
```

---

## Indicadores Visuales en la App

### Badge Rojo en el Chat
Si ves un **🟥 ⚠️** al lado del número, significa:
- El discriminador clasificó este chat como "requiere humano"
- Un operador debe responder manualmente
- El asistente IA no respondió

### Notificación
Recibirás una notificación en la app:
> "Chat 5215561642726 requiere atención humana"

---

## Flujo Técnico (Para Curiosos)

1. **Mensaje llega**: "¿Tienes disponibilidad el jueves?"
2. **Discriminador activa**: Lee el historial completo de la conversación
3. **Envía a Gemini**:
   ```
   Tu regla: "Pasa al humano si pregunta sobre disponibilidad..."
   Historial: [historial completo]
   Último mensaje: "¿Tienes disponibilidad el jueves?"

   ¿Debe ir al humano o al asistente?
   ```
4. **Gemini responde**: "Respuesta: NO" (requiere humano)
5. **Backend ejecuta**:
   - ❌ No envía respuesta automática
   - 📌 Marca el chat con "needs_human: true"
   - 🔔 Emite evento a la app
6. **Operador ve**: Badge rojo en el chat, lo abre y responde

---

## Preguntas Frecuentes

### ¿Qué pasa si el discriminador está deshabilitado?
El asistente responde todos los mensajes normalmente (comportamiento antes del discriminador).

### ¿Puedo cambiar las reglas en tiempo real?
Sí. Cambia el texto, dale a Guardar, y el discriminador usará las nuevas reglas para los próximos mensajes.

### ¿Qué pasa si marca un chat como "requiere humano" por error?
Simplemente responde manualmente. El badge desaparece cuando tú envíes un mensaje.

### ¿El cliente ve que "requiere humano"?
No. Para el cliente es invisible. Solo ves el badge tú en la app.

### ¿Puedo usar español e inglés en las reglas?
Sí, Gemini entiende ambos. Usa lo que te sea más cómodo.

---

## Tips para Mejores Resultados

✅ **Sé específico**: "Pregunta sobre fechas" vs "Pregunta sobre disponibilidad el jueves a las 3pm"
✅ **Agrupa criterios**: Escribe con puntos y guiones para claridad
✅ **Ejemplos en paréntesis**: "¿tienes espacio?" es más claro que solo "disponibilidad"
✅ **Prueba y ajusta**: Los primeros días, revisa algunos chats marcados como "requiere humano" para calibrar
