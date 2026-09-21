import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crm_whatsapp/core.dart';

/// Stepper compacto del AppBar para recorrer chats sin volver a la lista.
///
/// Vive en `actions`, así que compite por ancho con el nombre del contacto:
/// por eso los tap targets van a 32px y el contador a 11px, en vez de los
/// 48px de un `IconButton`. Se pinta al 55% de opacidad — es cromo de
/// navegación, no una acción que reclame atención.
///
/// La geometría manda sobre la semántica: la lista es reciente↑ / antiguo↓,
/// así que ↓ avanza hacia lo más viejo y ↑ retrocede hacia lo más reciente.
/// Chevrones verticales, no flechas ←→, para que no haya que traducir nada.
class ChatNavStepper extends StatelessWidget {
  /// Posición 1-based dentro de la cola (lo que ve el humano).
  final int position;
  final int total;

  /// `null` deshabilita la flecha (estás en un extremo de la cola).
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const ChatNavStepper({
    required this.position,
    required this.total,
    required this.onPrev,
    required this.onNext,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavArrow(
          icon: Icons.keyboard_arrow_up,
          tooltip: 'Anterior · más reciente  (${chatNavShortcutHint('↑')})',
          onTap: onPrev,
        ),
        // El contador es la mitad del valor: dice "vas en la 4 de 12" y, de
        // paso, comunica sin palabras que estás recorriendo una secuencia
        // congelada y no la lista viva.
        Text(
          '$position/$total',
          style: TextStyle(
            color: white.withValues(alpha: 0.45),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        _NavArrow(
          icon: Icons.keyboard_arrow_down,
          tooltip: 'Siguiente · más antiguo  (${chatNavShortcutHint('↓')})',
          onTap: onNext,
        ),
      ],
    );
  }
}

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _NavArrow({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final arrow = SizedBox(
      width: 32,
      height: 40,
      child: Icon(
        icon,
        size: 20,
        color: white.withValues(alpha: enabled ? 0.55 : 0.18),
      ),
    );

    // Sin acción no hay tooltip: prometería un destino que no existe.
    if (!enabled) return arrow;

    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: arrow,
      ),
    );
  }
}

/// Atajos de teclado para recorrer la cola sin soltar el teclado: ⌥↑/⌥↓ en
/// Mac, Alt+↑/Alt+↓ en Windows y Linux. **También ⌘↑/⌘↓**, porque en Mac
/// mucha gente llama "alt" a Command y equivocarse de tecla no debería costar
/// el atajo.
///
/// **No depende del foco.** Escucha el teclado directo en [HardwareKeyboard]
/// en vez de usar `Shortcuts`, que sólo oye las teclas que suben desde el
/// widget enfocado. El foco se escapaba del detalle por tres caminos, y cada
/// uno dejaba el atajo sordo sin aviso: `unfocus()` sobre el propio scope (un
/// tap en la conversación lo manda al scope PADRE), el `unfocus()` de abrir un
/// chat desde la lista, y la web, que al cerrarse el input estaciona el foco
/// en la raíz y al volver lo reparte al primer campo enfocable, casi siempre
/// el buscador de la lista. En web el motor escucha el teclado en `window`,
/// así que las teclas llegan igual; lo que fallaba era a quién se las daba.
///
/// Sin el foco para acotarlo, el atajo se apaga solo en tres casos:
/// - **Hay una ruta encima** (diálogo, hoja, visor de fotos): no es suyo.
/// - **[enabled] en `false`**: lo que tapa el detalle sin ser ruta, como la
///   galería de medios en desktop.
/// - **Escribiendo, las flechas son del texto.** Con el foco en un input que
///   ya tiene texto, ⌘⇧↑, ⌘↑ o ⌥↑ llegan al editor: seleccionar hasta el
///   inicio, ir al final, saltar de párrafo. Navegar ahí tiraba el borrador,
///   que muere con el chat. No basta con confiar en `shift: false`: en Chrome
///   sobre Mac el framework a veces recibe ⌘↑ cuando se tecleó ⌘⇧↑ (el ⇧ llega
///   tarde en el acorde). Devolviendo `false`, el navegador aplica el evento
///   DOM real, con su ⇧ verdadero, al `<textarea>`.
///
/// Van con modificador porque las flechas solas ya pertenecen al selector de
/// respuestas rápidas del composer. `includeRepeats: false` evita que mantener
/// la flecha pulsada atraviese la cola entera de un tirón.
class ChatNavShortcuts extends StatefulWidget {
  /// `delta` en posiciones de la cola: -1 hacia lo más reciente, +1 hacia lo
  /// más antiguo.
  final void Function(int delta) onStep;

  /// `false` mientras algo que no es una ruta tapa el detalle. Las rutas se
  /// detectan solas.
  final bool enabled;

  final Widget child;

  const ChatNavShortcuts({
    required this.onStep,
    required this.child,
    this.enabled = true,
    super.key,
  });

  @override
  State<ChatNavShortcuts> createState() => _ChatNavShortcutsState();
}

class _ChatNavShortcutsState extends State<ChatNavShortcuts> {
  static const _bindings = <(SingleActivator, int)>[
    // ⌥ en Mac, Alt en Windows/Linux.
    (SingleActivator(LogicalKeyboardKey.arrowUp, alt: true, includeRepeats: false), -1),
    (SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, includeRepeats: false), 1),
    // ⌘, para que confundir Command con Option no rompa nada.
    (SingleActivator(LogicalKeyboardKey.arrowUp, meta: true, includeRepeats: false), -1),
    (SingleActivator(LogicalKeyboardKey.arrowDown, meta: true, includeRepeats: false), 1),
  ];

  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (!widget.enabled) return false;
    if (!(_route?.isCurrent ?? true)) return false;

    int? delta;
    for (final (activator, step) in _bindings) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        delta = step;
        break;
      }
    }
    if (delta == null || _isEditingText()) return false;

    widget.onStep(delta);
    return true;
  }

  // Foco en un input con texto. El contexto del nodo enfocado es el `Focus`
  // que monta `EditableText` por dentro, así que el estado está arriba.
  bool _isEditingText() {
    final editing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    return editing != null && editing.textEditingValue.text.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Cómo se escribe el atajo en esta plataforma. En Mac el modificador se
/// dibuja; en el resto se nombra.
String chatNavShortcutHint(String arrow) {
  final isApple = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return isApple ? '⌥$arrow o ⌘$arrow' : 'Alt+$arrow';
}
