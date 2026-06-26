import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../services/active_chat_tracker.dart';
import '../services/notification_service.dart';
import '../services/notification_sound.dart';

/// Host de banner in-app para pushes en **foreground**.
///
/// Por qué existe: en web, cuando la pestaña está enfocada/visible, FCM NO
/// pasa por el Service Worker (`onBackgroundMessage`), sino que entrega el
/// push vía `FirebaseMessaging.onMessage`. El SO no muestra notificación.
/// `NotificationService` emite esos pushes por `foregroundStream`, pero antes
/// nadie los escuchaba → cero feedback con la página al frente (el caso de uso
/// típico del CRM, abierto todo el día). Este host cierra ese hueco mostrando
/// un banner aqua tipo Kommo/HubSpot.
///
/// Es aditivo y multiplataforma: en Android foreground también mejora, sin
/// tocar la bandeja del SO ni el flujo de background.
///
/// Tap en el banner → publica la intención de deep-link vía `forwardTap`,
/// reutilizando el mismo canal que el tap nativo (SessionDispatcher cambia de
/// sesión si hace falta y ChatsScreen abre el chat).
class ForegroundPushHost extends StatefulWidget {
  final Widget child;

  const ForegroundPushHost({required this.child, super.key});

  @override
  State<ForegroundPushHost> createState() => _ForegroundPushHostState();
}

class _ForegroundPushHostState extends State<ForegroundPushHost> {
  StreamSubscription<HumanAttentionPush>? _sub;
  OverlayEntry? _entry;
  Timer? _autoDismiss;

  // El audio web nace bloqueado por la política de autoplay; lo desbloqueamos
  // en el primer gesto del operador (ver _unlockAudioOnce).
  bool _audioUnlocked = false;

  // Cuánto vive el banner en pantalla antes de auto-cerrarse.
  static const _visibleFor = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _sub = NotificationService().foregroundStream.listen(_onPush);
    // Puente SW→página: permite sonar con la ventana minimizada (web). No-op
    // en móvil. Idempotente, así que es seguro llamarlo aquí.
    initBackgroundSoundBridge();
  }

  // Desbloqueo del AudioContext: debe ocurrir DENTRO de un gesto del usuario.
  // Envolvemos el árbol en un Listener; el primer pointer down reanuda el
  // contexto y nos desuscribimos (el flag evita repetir trabajo).
  void _unlockAudioOnce(_) {
    if (_audioUnlocked) return;
    _audioUnlocked = true;
    unlockNotificationAudio();
  }

  void _onPush(HumanAttentionPush push) {
    if (!mounted) return;
    // Si ya estás viendo justo ese chat, la notificación sobra: ni banner ni
    // beep. (Solo aplica en foreground; minimizado suena por el puente del SW.)
    if (push.isValid &&
        ActiveChatTracker.instance.isViewing(push.sessionPhone, push.chatId)) {
      return;
    }
    // Beep primero (no depende de la UI) y luego el banner visual.
    playNotificationBeep();
    _showBanner(push);
  }

  void _showBanner(HumanAttentionPush push) {
    // Si ya hay un banner visible, lo reemplazamos por el más reciente.
    _dismiss();

    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _PushBanner(
        push: push,
        onTap: () {
          _dismiss();
          NotificationService().forwardTap(push);
        },
        onClose: _dismiss,
      ),
    );
    overlay.insert(_entry!);

    _autoDismiss?.cancel();
    _autoDismiss = Timer(_visibleFor, _dismiss);
  }

  void _dismiss() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listener en modo passthrough (HitTestBehavior.translucent) para captar el
    // primer gesto y desbloquear el audio sin interferir con los hijos.
    return Listener(
      onPointerDown: _unlockAudioOnce,
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

/// El banner en sí: tarjeta aqua arriba, con icono, título/cuerpo, tap y cierre.
/// Anima la entrada con un slide-down + fade para no aparecer de golpe.
class _PushBanner extends StatefulWidget {
  final HumanAttentionPush push;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _PushBanner({
    required this.push,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_PushBanner> createState() => _PushBannerState();
}

class _PushBannerState extends State<_PushBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final title = widget.push.title?.trim();
    final body = widget.push.body?.trim();

    return Positioned(
      top: mq.padding.top + 12,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: _ctrl,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: widget.onTap,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      decoration: BoxDecoration(
                        color: surfaceDark,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primaryAqua.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: primaryAqua.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: const Icon(
                              Icons.support_agent,
                              color: primaryAqua,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  (title != null && title.isNotEmpty)
                                      ? title
                                      : 'Atención humana requerida',
                                  style: const TextStyle(
                                    color: white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (body != null && body.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    body,
                                    style: const TextStyle(
                                      color: lightText,
                                      fontSize: 13,
                                      height: 1.25,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: widget.onClose,
                            icon: const Icon(Icons.close,
                                color: lightText, size: 18),
                            splashRadius: 18,
                            tooltip: 'Cerrar',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
