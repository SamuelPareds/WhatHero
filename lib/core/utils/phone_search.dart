/// Buscar un chat pegando un número tal como lo copiaste.
///
/// El problema: los números se guardan en formato WhatsApp (`5215512345678`),
/// pero lo que el operador copia de WhatsApp Web, de un CRM o de un correo
/// viene en E.164 con separadores y **sin el `1` móvil mexicano**:
/// `+52 55 1234 5678`. Buscar eso como texto plano no encontraba nada — ni el
/// `+`, ni los espacios, ni el `521` coinciden con lo guardado.
///
/// La solución es no comparar números completos: comparamos **la cola de
/// dígitos**. Da igual qué código de país, qué prefijo móvil o qué separadores
/// traiga lo pegado; los últimos dígitos son los mismos en las dos formas.
///
/// Funciones puras sin dependencias. Tests en `test/phone_search_test.dart`.
library;

/// Cuántos dígitos finales comparamos como máximo.
///
/// 10 es el nacional más largo de la región (MX, CO, AR, VE, BR y EE.UU.
/// tienen 10; CL, PE, EC y ES tienen 9; Centroamérica 8), así que cortar ahí
/// deja fuera el código de país y el prefijo móvil sin comerse nunca un dígito
/// del número en sí. Brasil móvil tiene 11 con la nona, pero recortarle el
/// primer dígito de área no rompe nada: la cola sigue siendo un sufijo del
/// número guardado, que es lo único que la comparación necesita.
///
/// Un número más corto que eso (Costa Rica: 8) usa todos sus dígitos: la cola
/// es `min(10, lo que haya)`, nunca rellenamos.
const int kPhoneSearchTailDigits = 10;

final RegExp _nonDigits = RegExp(r'\D');

/// Sólo dígitos y puntuación de teléfono, con al menos un dígito.
///
/// Este guard es lo que evita que buscar un nombre con número dentro ("Ana 2",
/// "Sala 3") se interprete como teléfono: con una sola cifra la cola sería `2`
/// y coincidiría con casi todos los chats. Si hay letras, no es un número.
final RegExp _phoneLike = RegExp(r'^[\s+\-().]*\d[\d\s+\-().]*$');

/// Dígitos de [raw], sin `+`, espacios, guiones ni paréntesis.
String phoneDigits(String raw) => raw.replaceAll(_nonDigits, '');

/// La cola de dígitos que hay que buscar, o `null` si [query] no parece un
/// número (tiene letras, o no tiene dígitos) y por lo tanto debe buscarse como
/// texto normal contra nombre y nota.
String? phoneSearchTail(String query) {
  if (!_phoneLike.hasMatch(query)) return null;
  final digits = phoneDigits(query);
  if (digits.isEmpty) return null;
  if (digits.length <= kPhoneSearchTailDigits) return digits;
  return digits.substring(digits.length - kPhoneSearchTailDigits);
}

/// ¿El número guardado [stored] coincide con la cola [tail]?
///
/// Es `contains` y no `endsWith` a propósito: así sigue funcionando escribir a
/// mano los primeros dígitos ("5215" mientras tecleas). Con una cola de 10
/// dígitos la distinción es teórica — no hay número de WhatsApp donde 10
/// dígitos consecutivos calcen en el medio y no al final.
bool phoneMatchesTail(String stored, String tail) =>
    phoneDigits(stored).contains(tail);
