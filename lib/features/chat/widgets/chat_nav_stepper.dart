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
/// el atajo; eso pisa el "ir al inicio/fin del texto" de macOS dentro del
/// composer, que en un input de seis líneas no vale lo que vale navegar.
///
/// Van con modificador porque las flechas solas ya pertenecen al selector de
/// respuestas rápidas del composer. Envuelve al detalle del chat, así que
/// queda por DEBAJO de `DefaultTextEditingShortcuts` en el árbol y le gana la
/// tecla. `includeRepeats: false` evita que mantener la flecha pulsada
/// atraviese la cola entera de un tirón.
class ChatNavShortcuts extends StatelessWidget {
  /// `delta` en posiciones de la cola: -1 hacia lo más reciente, +1 hacia lo
  /// más antiguo.
  final void Function(int delta) onStep;
  final Widget child;

  const ChatNavShortcuts({
    required this.onStep,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        // ⌥ en Mac, Alt en Windows/Linux.
        SingleActivator(LogicalKeyboardKey.arrowUp,
            alt: true, includeRepeats: false): _StepChatIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowDown,
            alt: true, includeRepeats: false): _StepChatIntent(1),
        // ⌘, para que confundir Command con Option no rompa nada.
        SingleActivator(LogicalKeyboardKey.arrowUp,
            meta: true, includeRepeats: false): _StepChatIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowDown,
            meta: true, includeRepeats: false): _StepChatIntent(1),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _StepChatIntent: CallbackAction<_StepChatIntent>(
            onInvoke: (intent) {
              onStep(intent.delta);
              return null;
            },
          ),
        },
        // `Shortcuts` sólo ve las teclas que SUBEN desde el widget enfocado,
        // y el detalle del chat pasa la mayor parte del tiempo sin foco
        // adentro: MessagesView no enfoca el composer al abrir un chat (sólo
        // al activar un draft de respuesta), y tocar la conversación hace un
        // `unfocus()` explícito para bajar el teclado. Sin este scope el
        // atajo quedaba sordo salvo que el cursor estuviera en el input.
        //
        // Con él: `autofocus` toma el foco al montar el detalle, y el
        // `unfocus()` del tap devuelve el foco a ESTE scope (la regla es "al
        // scope más cercano"), que sigue estando debajo del `Shortcuts`.
        child: FocusScope(autofocus: true, child: child),
      ),
    );
  }
}

/// Cómo se escribe el atajo en esta plataforma. En Mac el modificador se
/// dibuja; en el resto se nombra.
String chatNavShortcutHint(String arrow) {
  final isApple = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  return isApple ? '⌥$arrow o ⌘$arrow' : 'Alt+$arrow';
}

class _StepChatIntent extends Intent {
  final int delta;
  const _StepChatIntent(this.delta);
}
