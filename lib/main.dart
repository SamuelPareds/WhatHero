import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'core.dart';
import 'core/services/socket_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/storage_service.dart';
import 'core/widgets/foreground_push_host.dart';
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

class SessionDispatcher extends StatefulWidget {
  final String accountId;

  const SessionDispatcher({required this.accountId, super.key});

  @override
  State<SessionDispatcher> createState() => _SessionDispatcherState();
}

class _SessionDispatcherState extends State<SessionDispatcher> {
  // Sesión elegida por un deep-link de notificación. Tiene prioridad sobre la
  // "última sesión usada": cuando el operador toca un push de otra sesión,
  // saltamos a ESA. Persiste para que se quede ahí donde lo llevó la notif.
  String? _overrideSessionId;

  // Cacheada para no re-pedir SharedPreferences en cada rebuild (un setState
  // por deep-link reconstruiría el FutureBuilder y parpadearía el spinner).
  late final Future<String?> _lastSessionFuture =
      StorageService().getLastSessionId();

  // Intención de deep-link compartida con ChatsScreen. Aquí solo decidimos la
  // SESIÓN; la apertura del chat la hace ChatsScreen.
  ValueNotifier<HumanAttentionPush?>? _pendingTap;

  // Sesión sobre la que ya avisamos "desconectada" en este episodio de
  // deep-link. Evita repetir el aviso en cada rebuild del StreamBuilder. Se
  // resetea con cada tap nuevo (_applyDeepLink) para poder volver a avisar.
  String? _disconnectedNoticeFor;

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

    // NotificationService.init sigue el MISMO patrón canónico: vive aquí, no
    // dentro de pantallas hijas. Si el día de mañana se agrega una pantalla
    // raíz post-login, el init de FCM tiene que estar arriba de ella —
    // de otro modo en cold-start con sesión guardada el token nunca se
    // registraría hasta que el usuario navegara manualmente.
    // Es async pero no esperamos: la UI no debe bloquearse por permisos/red.
    unawaited(NotificationService().init(widget.accountId));

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

  // Lleva al usuario a la sesión del push. Dos cosas:
  //  1. Descarta rutas apiladas (AccountsScreen, o una ChatsScreen de otra
  //     sesión abierta a mano) para que la ChatsScreen raíz vuelva a ser la
  //     visible.
  //  2. Si el push apunta a otra sesión, la fija como override → el build
  //     resuelve esa sesión y, gracias al ValueKey, remonta la ChatsScreen
  //     correcta, cuya initState lee la intención y abre el chat.
  void _applyDeepLink(HumanAttentionPush push) {
    if (!mounted || !push.isValid) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    // Tap nuevo: permitimos volver a avisar si la sesión sigue desconectada.
    _disconnectedNoticeFor = null;
    if (push.sessionPhone.isNotEmpty &&
        push.sessionPhone != _overrideSessionId) {
      setState(() => _overrideSessionId = push.sessionPhone);
    }
  }

  // Deep-link a una sesión que no está entre las conectadas (p. ej. se
  // desvinculó). En vez de fallar callado cayendo a otra sesión, avisamos qué
  // pasó y limpiamos override + intención para no quedarnos reintentando.
  // Se llama desde build cuando el override no aparece en los docs conectados;
  // por eso el efecto (snackbar + setState) va en un post-frame callback.
  void _noticeDisconnectedSession(String sessionId) {
    if (_disconnectedNoticeFor == sessionId) return;
    _disconnectedNoticeFor = sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NotificationService().pendingTap.value = null;
      setState(() => _overrideSessionId = null);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'La sesión $sessionId está desconectada. '
            'Vuelve a vincularla para abrir ese chat.',
          ),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  @override
  void dispose() {
    _pendingTap?.removeListener(_onPendingTap);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Banner in-app para pushes en foreground (clave en web con la pestaña
    // enfocada, donde el SO no muestra notificación). Vive aquí, arriba de
    // ChatsScreen, por el mismo motivo que los init de Socket/Notification:
    // único ancestro garantizado post-login que conoce el accountId.
    return ForegroundPushHost(
      child: FutureBuilder<String?>(
        future: _lastSessionFuture,
      builder: (context, lastSessionSnapshot) {
        if (lastSessionSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: primaryAqua),
            ),
          );
        }

        final lastSessionId = lastSessionSnapshot.data;

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection(accountsCollection)
              .doc(widget.accountId)
              .collection('whatsapp_sessions')
              .where('status', isEqualTo: 'connected')
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(color: primaryAqua),
                ),
              );
            }

            final docs = snapshot.data?.docs ?? [];

            if (docs.isNotEmpty) {
              // Preferencia de sesión: el deep-link de una notificación manda
              // sobre la última sesión usada. Si ninguna coincide entre las
              // conectadas (p. ej. el push apunta a una sesión desvinculada),
              // caemos a la primera disponible.
              final overrideId = _overrideSessionId;
              final preferredSessionId = overrideId ?? lastSessionId;
              DocumentSnapshot? targetDoc;
              if (preferredSessionId != null) {
                for (final doc in docs) {
                  if (doc.id == preferredSessionId) {
                    targetDoc = doc;
                    break;
                  }
                }
              }

              // Deep-link a una sesión desconectada: no está entre los docs
              // conectados → avisamos (Fase 3, opción "solo avisar") y caemos a
              // la primera disponible para no dejar al usuario en pantalla vacía.
              if (overrideId != null && targetDoc == null) {
                _noticeDisconnectedSession(overrideId);
              }
              targetDoc ??= docs.first;

              final sessionId = targetDoc.id;
              final sessionKey = targetDoc['session_key'] as String?;
              final alias = targetDoc['alias'] as String?;

              if (sessionKey != null) {
                return ChatsScreen(
                  // El ValueKey por sesión fuerza el remonte al cambiar de
                  // sesión (deep-link): la nueva ChatsScreen corre initState y
                  // ahí lee la intención pendiente para abrir el chat.
                  key: ValueKey(sessionId),
                  sessionId: sessionId,
                  sessionKey: sessionKey,
                  accountId: widget.accountId,
                  initialAlias: alias,
                );
              }
            }

            // If no connected session, go to ChatsScreen anyway but with null session
            return ChatsScreen(accountId: widget.accountId);
          },
        );
        },
      ),
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

