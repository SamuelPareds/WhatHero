# 📱 Guía de la Versión de WhatsApp Web

## El problema en una frase

Tu backend se hace pasar por WhatsApp Web. Para eso le declara a WhatsApp **qué versión de WhatsApp Web dice ser** — y WhatsApp corta las versiones viejas cada pocas semanas. Cuando eso pasa, **todas** tus sesiones se caen a la vez y no puedes ni generar un QR para revincular.

Eso fue exactamente la caída del **28-jul-2026**: las 3 cuentas de producción cayeron con `405 Connection Failure`.

---

## ¿Qué es una "versión de WhatsApp Web"?

Tres números, así: `2.3000.1044032412`

| Parte | Valor | Qué es |
|---|---|---|
| Mayor | `2` | Fijo, no cambia |
| Menor | `3000` | Fijo, no cambia |
| **Revisión** | **`1044032412`** | **El que importa.** Sube cada pocos días |

En la práctica solo cambia el tercer número, y **más grande = más nuevo**.

---

## Cómo saber si tienes este problema

Busca esto en los logs de Railway:

```
connection errored ... statusCode=405
[Reconexión] Intento 1/10 para <sessionKey> (code: 405)
```

**Las tres señales juntas = versión cortada:**

1. Código `405` (no 401, no 408, no 515)
2. `not logged in, attempting registration...` justo antes
3. **Nunca aparece un QR** — ni siquiera al intentar vincular desde cero

⚠️ **El `515` NO es este problema.** Ese aparece siempre justo después de escanear un QR (`pairing configured successfully`), es normal y se resuelve solo en la reconexión.

---

## Cómo lo resuelve el backend (automático)

En cada `startSession()` se llama a `resolveWaVersion()` ([src/config/waVersion.ts](src/config/waVersion.ts)), que prueba 4 fuentes **en orden** y se queda con la primera válida:

```
1. WA_VERSION (variable de entorno)  ← tu palanca manual de emergencia
        ↓ si no está seteada
2. web.whatsapp.com/sw.js            ← se lo preguntamos a WhatsApp directo
        ↓ si falla
3. Pin de Baileys en GitHub          ← suele ir atrasado, por eso va tercero
        ↓ si falla
4. WA_VERSION_FLOOR                  ← constante en el código, verificada a mano
```

### Las dos guardas que evitan que se repita la caída

1. **Piso de seguridad:** si una fuente remota devuelve algo **más viejo** que `WA_VERSION_FLOOR`, se descarta. En la caída del 28-jul el backend aceptó una versión rancia que era *más vieja* que la que él mismo traía. Ahora eso es imposible.

2. **Un fallo silencioso ya no pasa desapercibido:** las funciones de Baileys, cuando no pueden resolver, devuelven un valor viejo con la bandera `isLatest: false`. Antes se aceptaba a ciegas. Ahora esa bandera se trata como fallo y se pasa a la siguiente fuente.

**En condiciones normales no tienes que hacer nada.** El paso 2 se actualiza solo.

---

## `WA_VERSION` vs `WA_VERSION_FLOOR` — la diferencia

Es la duda más común. No son lo mismo ni se usan igual:

| | `WA_VERSION` | `WA_VERSION_FLOOR` |
|---|---|---|
| **Dónde vive** | Variable de entorno en Railway | Constante en el código ([waVersion.ts](src/config/waVersion.ts)) |
| **Normalmente** | **Vacía.** No la toques | Siempre tiene un valor |
| **Para qué sirve** | Forzar una versión concreta **ya**, sin redesplegar código | Ser el mínimo aceptable y el último recurso |
| **Quién gana** | Máxima prioridad, ignora todo lo demás | Última prioridad |
| **Cada cuánto se cambia** | Solo en una emergencia | Cada 2-3 meses, con calma |
| **Cómo se cambia** | Railway → Variables → reiniciar (2 min) | Editar código → commit → deploy |

> 💡 **La regla:** `WA_VERSION` es el extintor — está en la pared y ojalá nunca lo uses. `WA_VERSION_FLOOR` es el mantenimiento preventivo.

---

## De dónde saco el número de versión

**No lo inventes ni lo copies de un blog.** Usa la herramienta incluida:

```bash
cd backend
npm run check:wa
```

Salida:

```
═══ Fuentes de versión ═══

  web.whatsapp.com   2.3000.1044032412
  pin de Baileys     2.3000.1043857760
  WA_VERSION_FLOOR   2.3000.1044017588   (constante en src/config/waVersion.ts)
  WA_VERSION (env)   (no seteada — normal)

═══ Lo que usaría el backend ═══

  → 2.3000.1044032412

═══ Prueba de conexión con 2.3000.1044032412 ═══

   ✅ ACEPTADA — WhatsApp generó QR con 2.3000.1044032412
```

La línea de `web.whatsapp.com` es **la fuente de verdad**: es la versión que usa el WhatsApp Web real en este momento.

Para probar una versión específica **antes** de ponerla en producción:

```bash
npm run check:wa 2.3000.1044032412
```

Solo hay dos resultados posibles:

- `✅ ACEPTADA — WhatsApp generó QR` → sirve, puedes usarla
- `❌ RECHAZADA — statusCode=405` → está cortada, no la uses

---

## 🚨 Runbook: producción caída con 405

### Paso 1 — Confirma que es esto

```bash
cd backend
npm run check:wa
```

Si la prueba de conexión da `❌ RECHAZADA`, es este problema. Si da `✅ ACEPTADA`, **el problema es otro** — no sigas con este runbook.

### Paso 2 — Consigue una versión que funcione

La misma salida ya te dice qué versión usa el WhatsApp Web real. Pruébala:

```bash
npm run check:wa <la-version-de-web.whatsapp.com>
```

Si da `✅ ACEPTADA`, esa es tu versión.

### Paso 3 — Aplícala en Railway (~2 minutos)

1. Railway → tu servicio → pestaña **Variables**
2. **New Variable**:
   - Nombre: `WA_VERSION`
   - Valor: `2.3000.1044032412` *(la que verificaste, sin comillas ni espacios)*
3. Guarda. Railway reinicia solo.

### Paso 4 — Verifica en los logs

Busca:

```
[WA-Version] Usando 2.3000.1044032412 (override WA_VERSION)
[startSession] <key> → handshake con WA Web 2.3000.1044032412
```

Tus sesiones deberían reconectar solas desde el volumen persistente, **sin escanear QR** — siempre que las credenciales sigan en `auth_info/`.

### Paso 5 — Limpia después (importante, no lo saltes)

`WA_VERSION` **congela** la versión: mientras esté seteada, el backend deja de actualizarse solo y volverá a caerse cuando WhatsApp corte *esa* versión.

Cuando pase la emergencia (mismo día o al siguiente):

1. Actualiza `WA_VERSION_FLOOR` en [src/config/waVersion.ts](src/config/waVersion.ts) con la versión verificada
2. Actualiza el comentario con la fecha de verificación
3. Commit + deploy
4. **Borra `WA_VERSION` de Railway**

Así el backend vuelve a auto-actualizarse y quedas protegido por un piso más alto.

---

## 🔧 Mantenimiento preventivo (cada 2-3 meses)

```bash
cd backend
npm run check:wa
```

Si `WA_VERSION_FLOOR` quedó muy por debajo de lo que dice `web.whatsapp.com`, súbelo:

1. `npm run check:wa <version-nueva>` → confirma que da `✅ ACEPTADA`
2. Edita `WA_VERSION_FLOOR` en [src/config/waVersion.ts](src/config/waVersion.ts)
3. Actualiza la fecha en el comentario
4. Commit + deploy

**Por qué importa:** el piso es tu red de seguridad para cuando *todas* las fuentes remotas fallen. Un piso viejo = una red que ya no aguanta.

---

## ❓ Preguntas frecuentes

**¿Tengo que setear `WA_VERSION` ahora mismo?**
No. Déjala vacía. El backend resuelve solo. Solo la usas en emergencia.

**¿Puedo poner una versión más nueva que la de `web.whatsapp.com`?**
No sirve de nada. Esa es la más nueva que existe. Inventar un número más alto no funciona — WhatsApp valida contra sus versiones reales.

**¿Y si `WA_VERSION` tiene un formato mal escrito?**
Se ignora con un error en los logs (`no tiene formato válido`) y sigue con las demás fuentes. No tumba el backend.

**¿Puedo poner en `WA_VERSION` una versión más vieja que el piso?**
Sí — es un override manual y se respeta a propósito, pero verás un `⚠️` en los logs. Úsalo solo si sabes lo que haces.

**¿Cada cuánto corta WhatsApp una versión?**
No hay calendario público. Históricamente, cada varias semanas. Por eso la defensa es automática, no un recordatorio en el calendario.

**¿Esto me hace perder las sesiones vinculadas?**
No. Cambiar la versión no toca `auth_info/`. Las sesiones reconectan solas al reiniciar.

**¿Qué pasó realmente el 28-jul-2026?**
WhatsApp cortó `2.3000.1035194821`. El backend la seguía usando porque leía el pin de Baileys desde un archivo en GitHub (parseando la línea 7 con un regex) y aceptaba a ciegas lo que llegara — incluso una respuesta cacheada rancia. Se comprobó con un experimento controlado: misma máquina, misma IP, mismo Baileys, cambiando solo la versión → `1035194821` daba 405, `1044017588` generaba QR.

---

## 📂 Archivos relacionados

| Archivo | Qué hace |
|---|---|
| [src/config/waVersion.ts](src/config/waVersion.ts) | El resolver y `WA_VERSION_FLOOR` |
| [scripts/check-wa-version.ts](scripts/check-wa-version.ts) | La herramienta `npm run check:wa` |
| [index.ts](index.ts) | Llama a `resolveWaVersion()` en `startSession()` |
