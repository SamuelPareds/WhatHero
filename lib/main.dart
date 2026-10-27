import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'core.dart';
import 'core/services/account_context_service.dart';
import 'core/services/socket_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/presence_reporter.dart';
import 'core/services/storage_service.dart';
import 'core/utils/phone_input.dart';
import 'core/widgets/foreground_push_host.dart';
import 'features/accounts/session_switch.dart';
import 'features/auth.dart';
import 'features/chat.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WhatHero',
      theme: buildWhatHeroTheme(),
      // Permitir arrastrar las listas/scroll horizontales con el mouse en web/desktop.
      // Por defecto Flutter solo deja desplazar con touch, así que los filtros de
      // etiquetas y de galería no se podían mover con el cursor. Ver _AppScrollBehavior.
      scrollBehavior: _AppScrollBehavior(),
      home: AuthWrapper(
        onUserAuthenticated: (accountId) => SessionDispatcher(accountId: accountId),
      ),
    );
  }
}

// Habilita el arrastre con mouse y trackpad además del touch. Sin esto, en
// Flutter web/desktop los ScrollView horizontales (filtros de etiquetas, tipos
// de galería) solo respondían a touch y no se podían mover con el cursor.
class _AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };
}

/// Decide qué sesión se ve: la ChatsScreen raíz. Es el ÚNICO que cambia de
/// cuenta, por cualquiera de los tres caminos (selector del título, tarjeta de
/// Mis Cuentas, push de otra sesión): cambia la ChatsScreen raíz por la de la
/// otra sesión (ValueKey) en vez de apilar una encima. Ver CLAUDE.md,
/// "🔀 Cambiar de cuenta".
class SessionDispatcher extends StatefulWidget {
  final String accountId;

  const SessionDispatcher({required this.accountId, super.key});

  @override
  State<SessionDispatcher> createState() => _SessionDispatcherState();
}

class _SessionDispatcherState extends State<SessionDispatcher> {
  // Las sesiones que este usuario puede abrir (sin lápidas), en el orden de
  // Mis Cuentas. null = todavía no llegó la primera foto.
  List<SessionOption>? _sessions;
  StreamSubscription? _sessionsSubscription;

  // Última sesión usada en este dispositivo. Sólo decide al arrancar o si la
  // que se ve desaparece.
  String? _lastUsed;
  bool _lastUsedLoaded = false;

  // La sesión que se ve, y su nombre (para avisar si desaparece: para
  // entonces ya no está en la lista).
  String? _rootId;
  String? _rootName;

  // Sesión pedida a mano o por un push, pendiente de aplicar.
  String? _requestedId;

  // Intención de deep-link compartida con ChatsScreen. Aquí solo decidimos la
  // SESIÓN; la apertura del chat la hace ChatsScreen.
  ValueNotifier<HumanAttentionPush?>? _pendingTap;

  @override
  void initState() {
    super.initState();
    // Inicializar el socket aquí — único punto de entrada tras el login que
    // conoce el accountId y es ancestro garantizado de ChatsScreen y
    // AccountsScreen. Si lo dejábamos sólo en AccountsScreen, en cold start
    // con sesión guardada saltábamos directo a ChatsScreen y el listener
    // 'ai_state' nunca se registraba (los estados IA no funcionaban hasta
    // que el usuario entraba manualmente a AccountsScreen).
    // SocketService.init es idempotente: si ya estamos conectados con este
    // accountId, no hace nada. Es async (necesita pedirle el idToken a
    // Firebase para el handshake), pero no bloqueamos la UI: que se conecte
    // en background.
    unawaited(SocketService().init(widget.accountId));
    // Presencia del equipo: escucha la conexión del socket (para reenviar su
    // estado al reconectar), el ciclo de vida y la actividad. Mismo punto
    // canónico que el socket, por la misma razón. Idempotente.
    PresenceReporter.instance.start();

    // NotificationService.init sigue el MISMO patrón canónico: vive aquí, no
    // dentro de pantallas hijas. Si el día de mañana se agrega una pantalla
    // raíz post-login, el init de FCM tiene que estar arriba de ella —
    // de otro modo en cold-start con sesión guardada el token nunca se
    // registraría hasta que el usuario navegara manualmente.
    // Es async pero no esperamos: la UI no debe bloquearse por permisos/red.
    unawaited(NotificationService().init(widget.accountId));

    // Si la preferencia no se puede leer, se sigue sin ella: un error aquí no
    // puede dejar la app en el spinner.
    StorageService()
        .getLastSessionId()
        .then((id) => _lastUsed = id)
        .catchError((Object e) {
      debugPrint('[SessionDispatcher] Sin última sesión usada: $e');
      return null;
    }).whenComplete(() {
      _lastUsedLoaded = true;
      _resolve();
    });

    // Una sola suscripción por pantalla, nunca en build (ver CLAUDE.md, "Nunca
    // un .snapshots() dentro de build").
    _sessionsSubscription = AccountContextService()
        .visibleSessionsQuery(widget.accountId)
        .snapshots()
        .listen(
      (snap) {
        _sessions = visibleSessionOptions(snap.docs.map((d) => (id: d.id, data: d.data())));
        _resolve();
      },
      // Sin esto el fallo era mudo: caía a la bienvenida sin rastro. Si ya
      // había una lista, se conserva: un error de lectura no saca al operador
      // de la cuenta en la que está trabajando.
      onError: (Object e) {
        debugPrint('[SessionDispatcher] No se pudieron leer las sesiones: $e');
        _sessions ??= const [];
        _resolve();
      },
    );

    // Deep-link de cold-start (app abierta DESDE un tap a la notificación):
    // elegimos la sesión del push para el primer render, en vez de la última
    // sesión usada. El chat lo abre ChatsScreen vía initialTapReady.
    NotificationService().initialTapReady.then((push) {
      if (push != null && mounted) _applyDeepLink(push);
    });

    // Deep-link con la app viva (tap en background/foreground): mismo notifier
    // que consume ChatsScreen. Aquí solo cambiamos de sesión si hace falta.
    _pendingTap = NotificationService().pendingTap;
    _pendingTap!.addListener(_onPendingTap);
  }

  void _onPendingTap() {
    final push = _pendingTap?.value;
    if (push != null) _applyDeepLink(push);
  }

  // Lleva al usuario a la sesión del push. Si es la que ya se ve, sólo vuelve
  // a la raíz y ChatsScreen abre el chat; si es otra, la remonta y la nueva
  // ChatsScreen lee la intención en su initState.
  void _applyDeepLink(HumanAttentionPush push) {
    if (!mounted || !push.isValid) return;
    if (push.sessionPhone.isEmpty) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    _switchTo(push.sessionPhone);
  }

  // Cambiar de cuenta. Descarta lo apilado (Mis Cuentas, hojas, diálogos) para
  // que la ChatsScreen raíz vuelva a ser la visible.
  void _switchTo(String sessionId) {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _requestedId = sessionId;
    _resolve();
  }

  // El único lugar que decide qué sesión se ve. Las reglas viven en
  // pickRootSession.
  void _resolve() {
    final sessions = _sessions;
    if (!mounted || sessions == null || !_lastUsedLoaded) return;

    final requested = _requestedId;
    _requestedId = null;
    final previous = _rootId;
    final previousName = _rootName;
    final pick = pickRootSession(
      sessions: sessions,
      requested: requested,
      current: previous,
      lastUsed: _lastUsed,
    );
    final next = pick.sessionId;
    String? nameOf(String? id) {
      for (final s in sessions) {
        if (s.id == id) return s.name;
      }
      return null;
    }

    // Nunca se cambia de cuenta en silencio: el operador podría contestarle
    // al cliente de un negocio desde el número de otro.
    if (pick.requestRejected) {
      _noticeUnavailable(requested!);
    } else if (previous != null && next != previous && requested == null) {
      _noticeForcedSwitch(previousName ?? displayPhone(previous), nameOf(next));
    }

    setState(() {
      _rootId = next;
      _rootName = nameOf(next) ?? previousName;
    });
  }

  // Se pidió una sesión que ya no está (se eliminó o se perdió el acceso).
  // Si venía de un push, se descarta la intención para no reintentarla.
  void _noticeUnavailable(String sessionId) {
    final push = _pendingTap?.value;
    if (push != null && push.sessionPhone == sessionId) _pendingTap!.value = null;
    _showNotice('La sesión ${displayPhone(sessionId)} ya no está disponible.');
  }

  // La sesión que se veía desapareció sin que nadie la cambiara.
  void _noticeForcedSwitch(String previousName, String? nextName) {
    _showNotice(nextName == null
        ? '«$previousName» ya no está disponible.'
        : '«$previousName» ya no está disponible. Ahora estás en «$nextName».');
  }

  void _showNotice(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange.shade800,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  void dispose() {
    _sessionsSubscription?.cancel();
    _pendingTap?.removeListener(_onPendingTap);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Banner in-app para pushes en foreground (clave en web con la pestaña
    // enfocada, donde el SO no muestra notificación). Vive aquí, arriba de
    // ChatsScreen, por el mismo motivo que los init de Socket/Notification:
    // único ancestro garantizado post-login que conoce el accountId.
    return ForegroundPushHost(child: _buildRoot());
  }

  Widget _buildRoot() {
    final sessions = _sessions;
    if (sessions == null || !_lastUsedLoaded) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: primaryAqua),
        ),
      );
    }

    SessionOption? root;
    for (final s in sessions) {
      if (s.id == _rootId) root = s;
    }
    // Sin sesiones visibles: la bienvenida.
    if (root == null) {
      return ChatsScreen(accountId: widget.accountId, onSwitchSession: _switchTo);
    }

    return ChatsScreen(
      // El ValueKey por sesión fuerza el remonte al cambiar de sesión: la
      // nueva ChatsScreen corre initState y ahí lee la intención pendiente
      // (push) para abrir el chat.
      key: ValueKey(root.id),
      sessionId: root.id,
      // En vivo: tras re-vincular la sesión, la pantalla recibe el key nuevo.
      sessionKey: root.sessionKey,
      accountId: widget.accountId,
      sessions: sessions,
      onSwitchSession: _switchTo,
    );
  }
}

class WhatsAppHandshakeScreen extends StatefulWidget {
  const WhatsAppHandshakeScreen({super.key});

  @override
  State<WhatsAppHandshakeScreen> createState() => _WhatsAppHandshakeScreenState();
}

class _WhatsAppHandshakeScreenState extends State<WhatsAppHandshakeScreen> {
  late IO.Socket socket;
  String? qrCode;
  bool isConnected = false;
  String status = 'Desconectado';

  @override
  void initState() {
    super.initState();
    initSocket();
  }

  void initSocket() {
    print('[QRScreen] 🚀 Conectando a: $backendUrl (modo: ${kReleaseMode ? 'Release' : 'Debug'})');
    socket = IO.io(backendUrl, IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .build());

    socket.connect();

    socket.onConnect((_) {
      if (mounted) {
        setState(() {
          status = 'Esperando QR';
        });
      }
    });

    socket.on('qr', (data) {
      if (mounted) {
        setState(() {
          qrCode = data;
          status = 'Esperando QR';
          isConnected = false;
        });
      }
    });

    socket.on('ready', (_) {
      if (mounted) {
        setState(() {
          isConnected = true;
          qrCode = null;
          status = 'Conectado';
        });
      }
    });

    socket.on('status_update', (data) {
      if (data is Map && data['status'] == 'logged_out' && mounted) {
        setState(() {
          isConnected = false;
          qrCode = null;
          status = 'Sesión cerrada. Escanea el nuevo QR.';
        });
      }
    });

    socket.onDisconnect((_) {
      if (mounted) {
        setState(() {
          status = 'Desconectado';
          isConnected = false;
          qrCode = null;
        });
      }
    });
  }

  @override
  void dispose() {
    // Remove all socket listeners before disconnecting
    socket.off('connect');
    socket.off('qr');
    socket.off('ready');
    socket.off('status_update');
    socket.off('disconnect');
    socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo/Title
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: primaryAqua.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Center(
                  child: Text('🦸', style: TextStyle(fontSize: 48)),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'WhatHero',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tu gestor de WhatsApp profesional',
                style: TextStyle(
                  fontSize: 16,
                  color: lightText,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 56),
              // QR Code or Loading
              if (qrCode != null)
                Column(
                  children: [
                    const Text(
                      'Escanea el código QR',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primaryAqua.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: QrImageView(
                        data: qrCode!,
                        version: QrVersions.auto,
                        size: 260.0,
                      ),
                    ),
                  ],
                )
              else
                Column(
                  children: [
                    const SizedBox(
                      width: 60,
                      height: 60,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Conectando...',
                      style: TextStyle(
                        fontSize: 16,
                        color: white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

