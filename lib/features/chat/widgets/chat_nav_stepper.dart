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
          tooltip: 'Anterior · más reciente  (Alt+↑)',
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
          tooltip: 'Siguiente · más antiguo  (Alt+↓)',
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

/// Atajos Alt+↑ / Alt+↓ para recorrer la cola sin soltar el teclado.
///
/// Van con Alt porque las flechas solas ya pertenecen al selector de
/// respuestas rápidas del composer. Envuelve al detalle del chat, así que
/// queda por DEBAJO de `DefaultTextEditingShortcuts` en el árbol y se queda
/// con la tecla aunque el foco esté en el input (MessagesView lo enfoca al
/// montar). `includeRepeats: false` evita que mantener la flecha pulsada
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
        SingleActivator(LogicalKeyboardKey.arrowUp,
            alt: true, includeRepeats: false): _StepChatIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowDown,
            alt: true, includeRepeats: false): _StepChatIntent(1),
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
        child: child,
      ),
    );
  }
}

class _StepChatIntent extends Intent {
  final int delta;
  const _StepChatIntent(this.delta);
}
