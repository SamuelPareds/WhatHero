# 🦸‍♂️ Guía: Dar acceso a WhatHero en iPhone (TestFlight)

Guía rápida para repartir WhatHero a clientes en iOS de forma privada y controlada.
Datos de tu app: **WhatHero** · Bundle ID `com.sintaxis.whathero`

---

## 🔑 Conceptos clave (leer una vez)

- **Pruebas internas:** solo para ti y personas de tu cuenta de Apple. Acceso instantáneo, sin revisión. Ya lo usas para tu iPhone.
- **Pruebas externas:** para clientes. Se invitan con **solo su correo**, sin darles acceso a nada tuyo. Es lo que usarás para vender.
- **Beta App Review:** Apple revisa el *build* la **primera vez** que lo pones en externas (tarda de unas horas a ~1 día). Después, agregar nuevos clientes a ese build ya aprobado es **instantáneo**, sin más revisiones.
- **Caducidad de 90 días:** cada build vive 90 días. Cada ~2-3 meses sube uno nuevo para que los clientes no se queden sin servicio.

---

## ⚙️ Configuración inicial (solo la PRIMERA vez)

1. App Store Connect → **WhatHero** → pestaña **TestFlight**.
2. En la barra izquierda, **PRUEBAS EXTERNAS → +** → crea el grupo **"Clientes"**.
3. Dentro del grupo → **Compilaciones (Builds) → +** → agrega tu build actual (ej. `1.0.0 (2)`).
4. Llena **"Información para las pruebas"** (Beta App Review):
   - Email de feedback y datos de contacto (nombre, correo, teléfono).
   - Descripción / qué probar: *"CRM para gestionar cuentas de WhatsApp Business."*
   - **Cuenta de demo (importante):** como la app pide login, dale a Apple un **usuario y contraseña de prueba** que funcione, o rechazan la revisión.
5. Agrega el primer correo y **envía**. El build entra a Beta App Review.
6. Cuando Apple apruebe (te llega correo), el grupo "Clientes" queda **listo para sumar gente al instante**.

---

## 👤 Agregar un cliente nuevo (proceso RECURRENTE)

Una vez el build del grupo ya está aprobado, cada cliente nuevo es así de simple:

1. App Store Connect → **WhatHero → TestFlight → Pruebas externas → grupo "Clientes"**.
2. Pestaña **Testers → +** → **Añadir nuevo tester**.
3. Escribe su **correo** (y nombre, opcional). Guarda.
4. El cliente recibe un correo de invitación. Debe:
   - Descargar la app gratuita **TestFlight** desde la App Store.
   - Abrir el correo → tocar **"View in TestFlight" / Aceptar**.
   - Instalar **WhatHero** desde TestFlight.
5. Listo: ya tiene la app. ⏱️ Acceso casi inmediato (sin esperar revisión).

> 💡 Si el correo de invitación no le llega (problema conocido de Apple), reenvíalo desde el panel o comparte el **enlace público** del grupo. Ojo: el enlace público lo puede usar cualquiera que lo tenga, así que úsalo con confianza.

---

## ❌ Quitar acceso a un cliente (ej. dejó de pagar)

1. Grupo **"Clientes" → Testers**.
2. Marca la casilla del correo del cliente → **Eliminar (Remove)**.
3. Pierde el acceso a futuras versiones y la app deja de actualizársele.

---

## 🔄 Subir una versión nueva (cada ~2-3 meses o con cambios)

1. En `pubspec.yaml`, sube el número de build (y versión si aplica): ej. `1.0.0+2` → `1.0.1+3`.
2. Terminal:
   ```bash
   cd /Users/samuelparedes/Desktop/Flutter/whathero
   flutter build ios --release
   ```
3. Xcode (`open ios/Runner.xcworkspace`) → destino **"Any iOS Device"** → **Product → Archive**.
4. Organizer → **Distribute App → App Store Connect → Upload**.
5. Con la **distribución automática** activada en tus grupos, el build nuevo se reparte solo a tus testers en cuanto procesa (las externas pueden requerir una revisión rápida si es un cambio mayor).

---

## ✅ Checklist mental al agregar un cliente
- [ ] ¿El build del grupo "Clientes" ya está aprobado? (solo la 1ª vez tarda)
- [ ] Agregué su correo en Pruebas externas → Clientes → Testers
- [ ] Le avisé que instale **TestFlight** y acepte el correo
- [ ] (Si cobro) recibí el pago antes de agregarlo
