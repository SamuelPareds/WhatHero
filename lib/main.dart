import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
      home: AuthWrapper(
        onUserAuthenticated: (accountId) => SessionDispatcher(accountId: accountId),
      ),
    );
  }
}

class SessionDispatcher extends StatefulWidget {
  final String accountId;

  const SessionDispatcher({required this.accountId, super.key});

  @override
  State<SessionDispatcher> createState() => _SessionDispatcherState();
}

class _SessionDispatcherState extends State<SessionDispatcher> {
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
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: StorageService().getLastSessionId(),
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
              // 1. Intentar encontrar la última sesión guardada que esté conectada
              DocumentSnapshot? targetDoc;
              if (lastSessionId != null) {
                try {
                  targetDoc = docs.firstWhere((doc) => doc.id == lastSessionId);
                } catch (_) {
                  // Si no se encuentra, targetDoc sigue siendo null
                }
              }

              // 2. Si no hay guardada o ya no está conectada, usar la primera disponible
              targetDoc ??= docs.first;

              final sessionId = targetDoc.id;
              final sessionKey = targetDoc['session_key'] as String?;
              final alias = targetDoc['alias'] as String?;

              if (sessionKey != null) {
                return ChatsScreen(
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

