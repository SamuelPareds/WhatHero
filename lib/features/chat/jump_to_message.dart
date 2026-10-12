import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:crm_whatsapp/core/theme.dart';

// Llevar la conversación hasta un mensaje (cita tocada o resultado del
// buscador) aunque esté a cientos de mensajes. Vive aparte de MessagesView
// para poder probarlo sin Firestore: test/jump_to_message_test.dart.
//
// Por qué no basta con `jumpTo(índice / total × maxScrollExtent)` +
// `ensureVisible`: el maxScrollExtent de un ListView.builder es una
// estimación (el promedio de lo que ya construyó por la cantidad de ítems).
// En un chat con fotos (~300px) entre textos (~70px) ese cálculo cae varias
// pantallas lejos del destino, el destino nunca se construye y ensureVisible
// no tiene contexto: el operador aterrizaba en otra parte sin ningún aviso.
//
// Lo que sí es exacto: al hacer jumpTo, RenderSliverList acomoda uno por uno
// los hijos que atraviesa, así que la posición donde cae es real. Cada paso de
// revealListItem mide sobre esa posición real qué índices quedaron
// construidos, decide hacia dónde está el destino y corrige.

/// Qué índices de una lista perezosa están construidos ahora mismo. Lo
/// alimenta [IndexProbe], que envuelve cada ítem de la lista.
class BuiltIndexTracker {
  // Conteo y no Set: durante un frame pueden convivir el elemento que sale y
  // el que entra en el mismo índice.
  final Map<int, int> _counts = {};

  void _add(int index) =>
      _counts.update(index, (c) => c + 1, ifAbsent: () => 1);

  void _remove(int index) {
    final c = _counts[index];
    if (c == null) return;
    if (c <= 1) {
      _counts.remove(index);
    } else {
      _counts[index] = c - 1;
    }
  }

  /// Menor y mayor índice construidos, o null si la lista no tiene nada.
  ({int lo, int hi})? get range {
    if (_counts.isEmpty) return null;
    var lo = _counts.keys.first;
    var hi = lo;
    for (final i in _counts.keys) {
      if (i < lo) lo = i;
      if (i > hi) hi = i;
    }
    return (lo: lo, hi: hi);
  }
}

/// Registra en [tracker] que el ítem [index] está construido. Se da de baja
/// en `deactivate`, que la lista llama apenas lo saca del área de cache.
class IndexProbe extends StatefulWidget {
  final int index;
  final BuiltIndexTracker tracker;
  final Widget child;

  const IndexProbe({
    required this.index,
    required this.tracker,
    required this.child,
    super.key,
  });

  @override
  State<IndexProbe> createState() => _IndexProbeState();
}

class _IndexProbeState extends State<IndexProbe> {
  @override
  void initState() {
    super.initState();
    widget.tracker._add(widget.index);
  }

  @override
  void didUpdateWidget(IndexProbe old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index || old.tracker != widget.tracker) {
      old.tracker._remove(old.index);
      widget.tracker._add(widget.index);
    }
  }

  @override
  void activate() {
    super.activate();
    widget.tracker._add(widget.index);
  }

  @override
  void deactivate() {
    widget.tracker._remove(widget.index);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Mueve [controller] hasta que el ítem que lleva [anchor] esté construido y
/// lo centra (alignment 0.4). `true` si llegó.
///
/// [indexOf] se vuelve a consultar en cada paso: un mensaje que entra durante
/// el recorrido corre los índices. [stillWanted] corta el recorrido cuando
/// otro salto lo reemplazó.
///
/// Converge por bisección: guarda la última posición desde la que el destino
/// quedaba más arriba y la última desde la que quedaba más abajo, y nunca
/// salta fuera de ese intervalo. Con 20 pasos alcanza para cualquier chat.
Future<bool> revealListItem({
  required ScrollController controller,
  required GlobalKey anchor,
  required BuiltIndexTracker built,
  required int? Function() indexOf,
  required bool Function() stillWanted,
  double alignment = 0.4,
  Duration duration = const Duration(milliseconds: 350),
  int maxSteps = 20,
}) async {
  // Offsets entre los que tiene que estar el destino.
  double? notBefore; // desde aquí el destino seguía hacia offsets mayores
  double? notAfter; // desde aquí el destino había quedado en offsets menores

  for (var step = 0; step < maxSteps; step++) {
    if (!stillWanted() || !controller.hasClients) return false;

    final ctx = anchor.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx,
          alignment: alignment, duration: duration, curve: Curves.easeInOut);
      return stillWanted();
    }

    final index = indexOf();
    final range = built.range;
    if (index == null || range == null) return false;

    final position = controller.position;
    final pixels = position.pixels;
    // Altura media de lo construido ahora: el viewport más la cache a cada
    // lado, repartidos entre los ítems que la ocupan.
    final count = range.hi - range.lo + 1;
    final avg = (position.viewportDimension +
            2 * RenderAbstractViewport.defaultCacheExtent) /
        count;

    double next;
    if (index > range.hi) {
      notBefore = pixels;
      next = pixels + (index - range.hi) * avg;
    } else if (index < range.lo) {
      notAfter = pixels;
      next = pixels - (range.lo - index) * avg;
    } else {
      // Dentro del rango pero sin ancla: el ancla se pone en el próximo
      // build. Esperamos un frame.
      await WidgetsBinding.instance.endOfFrame;
      continue;
    }

    if (notBefore != null && notAfter != null &&
        (next <= notBefore || next >= notAfter)) {
      next = (notBefore + notAfter) / 2;
    }
    next = next.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == pixels) {
      // Pegado a un borde que todavía no creció (el maxScrollExtent se
      // recalcula al construir lo nuevo): un frame y se vuelve a medir.
      await WidgetsBinding.instance.endOfFrame;
      continue;
    }
    controller.jumpTo(next);
    await WidgetsBinding.instance.endOfFrame;
  }
  return false;
}

/// Envuelve una burbuja que puede ser destino de un salto: el resalte aqua y el
/// ancla para [revealListItem].
///
/// Va SIEMPRE, no sólo en el destino. El resalte anterior envolvía el ítem
/// sólo mientras duraba, y al cambiar el padre Flutter destruía y recreaba la
/// burbuja: las fotos y los videos parpadeaban al empezar el resalte y al
/// terminar. Aquí sólo cambian el color y un hermano del hijo, así que la
/// burbuja conserva su estado.
class JumpTarget extends StatelessWidget {
  final bool highlighted;
  // Sólo en el destino de un salto en curso.
  final Key? anchorKey;
  final Widget child;

  const JumpTarget({
    required this.highlighted,
    required this.child,
    this.anchorKey,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      // Entra rápido (se ve al llegar) y se va despacio.
      duration: Duration(milliseconds: highlighted ? 180 : 900),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: primaryAqua.withValues(alpha: highlighted ? 0.22 : 0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          // El ancla ocupa la burbuja entera, así ensureVisible la centra
          // completa. Agregarla o quitarla no toca al hijo del índice 0.
          if (anchorKey != null)
            Positioned.fill(child: SizedBox(key: anchorKey)),
        ],
      ),
    );
  }
}
