import 'package:crm_whatsapp/core/services/internal_messages_service.dart';

/// Mezcla la conversación de WhatsApp (paginada) con los internos del equipo,
/// del más nuevo al más viejo, que es el orden de la lista `reverse`. Devuelve
/// cada elemento tal cual: un [W] de WhatsApp o un [InternalMessage].
///
/// Reglas (fijadas en test/internal_timeline_test.dart):
/// - Mientras quede historial de WhatsApp por cargar, un interno más viejo que
///   el mensaje más viejo cargado NO se muestra: pertenece a una página que no
///   llegó, y pintarlo arriba de todo lo sacaría de contexto. Aparece cuando
///   el scroll carga esa página.
/// - Sin internos no se lee ni una hora de WhatsApp: `waTime` obliga a
///   `d.data()`, que reconstruye el mapa entero del doc. Con internos, cada
///   hora se lee una sola vez.
List<Object> mergeTimeline<W extends Object>({
  required List<W> wa,
  required DateTime Function(W) waTime,
  // Del más nuevo al más viejo.
  required List<InternalMessage> internal,
  required bool waComplete,
}) {
  if (internal.isEmpty) return List<Object>.of(wa);
  final oldestLoaded = (!waComplete && wa.isNotEmpty) ? waTime(wa.last) : null;

  final out = <Object>[];
  var i = 0;
  DateTime? head; // hora de wa[i], leída una sola vez
  for (final m in internal) {
    if (oldestLoaded != null && m.timestamp.isBefore(oldestLoaded)) break;
    while (i < wa.length && (head ??= waTime(wa[i])).isAfter(m.timestamp)) {
      out.add(wa[i++]);
      head = null;
    }
    out.add(m);
  }
  out.addAll(wa.skip(i));
  return out;
}
