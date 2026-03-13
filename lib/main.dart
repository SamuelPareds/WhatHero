import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

// Colors - Dark Mode with Aqua Accent (Apple-style)
const Color primaryAqua = Color(0xFF06B6D4); // Cyan/Verde Agua moderno
const Color darkBg = Color(0xFF0F172A); // Fondo muy oscuro (navy)
const Color surfaceDark = Color(0xFF1F2937); // Elementos oscuros (gris oscuro)
const Color white = Color(0xFFF3F4F6); // Texto blanco (no puro)
const Color lightText = Color(0xFFD1D5DB); // Gris claro secundario
const Color accentAqua = Color(0xFF10B981); // Verde más saturado para detalles

// Backend URL helper (Android emulator vs iOS/macOS vs Web)
String get backendUrl {
  if (kReleaseMode) {
    return 'https://whathero-production.up.railway.app';
  }

  if (kIsWeb) {
    return 'http://localhost:3000';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000';
  }
  return 'http://localhost:3000';
}

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
      title: 'WhatHero',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryAqua,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: surfaceDark,
          foregroundColor: white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        scaffoldBackgroundColor: darkBg,
      ),
      home: const AuthWrapper(),
    );
  }
}

// ============================================================================
// AUTH FLOW
// ============================================================================

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: primaryAqua),
            ),
          );
        }

        if (snapshot.hasData) {
          return AccountsScreen(accountId: snapshot.data!.uid);
        }

        return const WelcomeScreen();
      },
    );
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Hero icon container
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: primaryAqua.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Center(
                          child: Text(
                            '🦸',
                            style: TextStyle(fontSize: 56),
                          ),
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
                      const SizedBox(height: 12),
                      const Text(
                        'Tu gestor de WhatsApp profesional',
                        style: TextStyle(
                          fontSize: 16,
                          color: lightText,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryAqua,
                        foregroundColor: darkBg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LoginScreen(),
                          ),
                        );
                      },
                      child: const Text(
                        'Iniciar Sesión',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const RegisterScreen(),
                          ),
                        );
                      },
                      child: const Text(
                        'Crear cuenta',
                        style: TextStyle(
                          fontSize: 16,
                          color: primaryAqua,
                        ),
                      ),
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

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa todos los campos')),
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );
      // Pequeño delay para asegurar que Firebase haya actualizado el estado
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 500));
      // Pop esta pantalla - AuthWrapper mostrará AccountsScreen automáticamente
      if (mounted) Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_authErrorMessage(e.code))),
      );
      setState(() => isLoading = false);
    }
  }

  String _authErrorMessage(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email o contraseña incorrectos';
      case 'invalid-email':
        return 'Email inválido';
      case 'too-many-requests':
        return 'Demasiados intentos. Intenta más tarde';
      default:
        return 'Error al iniciar sesión';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: const Text('Iniciar Sesión'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: emailController,
              enabled: !isLoading,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              enabled: !isLoading,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Contraseña',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  disabledBackgroundColor: Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: isLoading ? null : _signIn,
                child: isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(darkBg),
                        ),
                      )
                    : const Text(
                        'Entrar',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(),
                        ),
                      );
                    },
              child: const Text(
                '¿No tienes cuenta? Regístrate',
                style: TextStyle(color: primaryAqua),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty ||
        confirmController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa todos los campos')),
      );
      return;
    }

    if (passwordController.text != confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Las contraseñas no coinciden')),
      );
      return;
    }

    if (passwordController.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La contraseña debe tener al menos 6 caracteres')),
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      // Crear documento de cuenta en Firestore inmediatamente
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
          .collection('accounts')
          .doc(user.uid)
          .set({
            'email': user.email,
            'createdAt': Timestamp.now(),
            'accountId': user.uid,
          }, SetOptions(merge: true));
      }

      // Pequeño delay para asegurar que Firebase haya actualizado el estado
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 500));
      // Pop esta pantalla - AuthWrapper mostrará AccountsScreen automáticamente
      if (mounted) Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_authErrorMessage(e.code))),
      );
      setState(() => isLoading = false);
    }
  }

  String _authErrorMessage(String code) {
    switch (code) {
      case 'weak-password':
        return 'Contraseña muy débil';
      case 'email-already-in-use':
        return 'Este email ya está registrado';
      case 'invalid-email':
        return 'Email inválido';
      default:
        return 'Error al registrarse';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: const Text('Crear Cuenta'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: emailController,
              enabled: !isLoading,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              enabled: !isLoading,
              obscureText: !showPassword,
              decoration: InputDecoration(
                hintText: 'Contraseña',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    showPassword ? Icons.visibility : Icons.visibility_off,
                    color: lightText,
                  ),
                  onPressed: !isLoading
                      ? () => setState(() => showPassword = !showPassword)
                      : null,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: confirmController,
              enabled: !isLoading,
              obscureText: !showConfirm,
              decoration: InputDecoration(
                hintText: 'Confirmar contraseña',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    showConfirm ? Icons.visibility : Icons.visibility_off,
                    color: lightText,
                  ),
                  onPressed: !isLoading
                      ? () => setState(() => showConfirm = !showConfirm)
                      : null,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  disabledBackgroundColor: Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: isLoading ? null : _register,
                child: isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(darkBg),
                        ),
                      )
                    : const Text(
                        'Registrarse',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LoginScreen(),
                        ),
                      );
                    },
              child: const Text(
                '¿Ya tienes cuenta? Inicia sesión',
                style: TextStyle(color: primaryAqua),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MAIN SCREENS
// ============================================================================


class AccountsScreen extends StatefulWidget {
  final String accountId;

  const AccountsScreen({required this.accountId, super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  late IO.Socket socket;
  bool _socketConnected = false;

  @override
  void initState() {
    super.initState();
    initSocket();
  }

  void initSocket() {
    print('[AccountsScreen] 🚀 Conectando a: $backendUrl (modo: ${kReleaseMode ? 'Release' : 'Debug'})');
    print('[AccountsScreen] Iniciando Socket.io con accountId: ${widget.accountId}');
    socket = IO.io(backendUrl, IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .setAuth({'accountId': widget.accountId})
      .build());

    // Listener para conexión exitosa
    socket.on('connect', (_) {
      print('[AccountsScreen] Socket conectado: ${socket.id}');
      if (mounted) {
        setState(() => _socketConnected = true);
      }
    });

    socket.on('disconnect', (_) {
      print('[AccountsScreen] Socket desconectado');
      if (mounted) {
        setState(() => _socketConnected = false);
      }
    });

    socket.connect();
    print('[AccountsScreen] socket.connect() llamado');
  }

  @override
  void dispose() {
    socket.disconnect();
    socket.dispose();
    super.dispose();
  }

  Future<void> _handleLogout() async {
    try {
      socket.disconnect();
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      print('[AccountsScreen] Error en logout: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al cerrar sesión: ${e.toString()}')),
      );
    }
  }

  Future<void> _startNewSession() async {
    // Esperar a que el socket esté conectado
    if (!_socketConnected) {
      print('[AccountsScreen] Socket no está conectado, esperando...');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conectando... intenta de nuevo')),
      );
      return;
    }

    try {
      print('[AccountsScreen] POST /start-session con accountId: ${widget.accountId}');
      final response = await http.post(
        Uri.parse('$backendUrl/start-session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'accountId': widget.accountId}),
      ).timeout(const Duration(seconds: 10));

      print('[AccountsScreen] Respuesta POST: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sessionKey = data['sessionKey'] as String;
        print('[AccountsScreen] sessionKey recibido: $sessionKey');

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LinkAccountScreen(
              sessionKey: sessionKey,
              socket: socket,
              accountId: widget.accountId,
            ),
          ),
        );
      }
    } catch (e) {
      print('[AccountsScreen] Error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis Cuentas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: white)),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: lightText),
            onPressed: _handleLogout,
            tooltip: 'Cerrar sesión',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startNewSession,
        backgroundColor: primaryAqua,
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('accounts')
            .doc(widget.accountId)
            .collection('whatsapp_sessions')
            .orderBy('connected_at', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final sessions = snapshot.data!.docs;

          if (sessions.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.smartphone, size: 48, color: primaryAqua),
                  const SizedBox(height: 16),
                  const Text(
                    'Sin cuentas vinculadas',
                    style: TextStyle(fontSize: 18, color: white, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Toca el + para vincular una cuenta',
                    style: TextStyle(fontSize: 14, color: lightText),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final sessionDoc = sessions[index];
              final phoneNumber = sessionDoc.id;
              final alias = sessionDoc['alias'] ?? phoneNumber;
              final status = sessionDoc['status'] ?? 'disconnected';
              final isConnected = status == 'connected';

              return GestureDetector(
                onTap: isConnected
                    ? () {
                        final sessionKey = sessionDoc['session_key'] as String?;
                        if (sessionKey != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatsScreen(
                                socket: socket,
                                sessionId: phoneNumber,
                                sessionKey: sessionKey,
                                accountId: widget.accountId,
                              ),
                            ),
                          );
                        }
                      }
                    : null,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: surfaceDark.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: primaryAqua.withValues(alpha: 0.2),
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: primaryAqua.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Text(
                            alias.substring(0, 1).toUpperCase(),
                            style: const TextStyle(
                              color: primaryAqua,
                              fontWeight: FontWeight.w700,
                              fontSize: 22,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alias,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              phoneNumber,
                              style: const TextStyle(
                                fontSize: 13,
                                color: lightText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isConnected ? accentAqua.withValues(alpha: 0.2) : Colors.red.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          isConnected ? 'Conectado' : 'Desconectado',
                          style: TextStyle(
                            fontSize: 12,
                            color: isConnected ? accentAqua : Colors.red.shade400,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class LinkAccountScreen extends StatefulWidget {
  final String sessionKey;
  final IO.Socket socket;
  final String accountId;

  const LinkAccountScreen({
    required this.sessionKey,
    required this.socket,
    required this.accountId,
    super.key,
  });

  @override
  State<LinkAccountScreen> createState() => _LinkAccountScreenState();
}

class _LinkAccountScreenState extends State<LinkAccountScreen> {
  String? qrCode;
  bool sessionConnected = false;
  String status = 'Iniciando sesión...';

  @override
  void initState() {
    super.initState();
    print('[LinkAccountScreen] initState - sessionKey: ${widget.sessionKey}, accountId: ${widget.accountId}');
    print('[LinkAccountScreen] Socket.id: ${widget.socket.id}, conectado: ${widget.socket.connected}');
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    print('[LinkAccountScreen] Configurando listeners de socket para sessionKey: ${widget.sessionKey}');

    widget.socket.on('qr', (data) {
      print('[LinkAccountScreen] Evento QR recibido: data=$data, sessionKey esperado=${widget.sessionKey}');
      if (data is Map && data['sessionKey'] == widget.sessionKey) {
        print('[LinkAccountScreen] QR coincide con sessionKey, mostrando QR');
        if (mounted) {
          setState(() {
            qrCode = data['qr'];
            status = 'Escanea el código QR';
          });
        }
      } else {
        print('[LinkAccountScreen] QR NO coincide: data[sessionKey]=${data is Map ? data['sessionKey'] : 'N/A'}');
      }
    });

    widget.socket.on('ready', (data) {
      print('[LinkAccountScreen] Evento READY recibido: data=$data');
      if (data is Map && data['sessionKey'] == widget.sessionKey) {
        print('[LinkAccountScreen] Cuenta conectada exitosamente, cerrando pantalla');
        if (mounted) {
          setState(() {
            sessionConnected = true;
            status = 'Conectado exitosamente ✅';
          });
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.pop(context);
          });
        }
      } else {
        print('[LinkAccountScreen] READY NO coincide: data[sessionKey]=${data is Map ? data['sessionKey'] : 'N/A'}');
      }
    });

    widget.socket.on('status_update', (data) {
      print('[LinkAccountScreen] Evento STATUS_UPDATE recibido: data=$data');
      if (data is Map && data['sessionKey'] == widget.sessionKey && data['status'] == 'logged_out') {
        print('[LinkAccountScreen] Sesión cerrada, mostrando error y cerrando');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sesión cerrada'), backgroundColor: Colors.red),
          );
          Navigator.pop(context);
        }
      }
    });

    // Listener para detectar desconexiones
    widget.socket.on('disconnect', (_) {
      print('[LinkAccountScreen] Socket desconectado inesperadamente');
      if (mounted) {
        setState(() => status = 'Desconectado - Reconectando...');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vincular Cuenta'),
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
              Text(
                status,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: white,
                ),
              ),
              const SizedBox(height: 48),
              if (qrCode != null)
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
                )
              else
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cancelSession() async {
    try {
      // Solo cancelar si la sesión NO se conectó exitosamente
      if (sessionConnected) {
        print('[LinkAccountScreen] Sesión ya conectada, no cancelar');
        return;
      }

      print('[LinkAccountScreen] Cancelando sesión: ${widget.sessionKey}');

      // Usar Socket.io para cancelar
      widget.socket.emit('cancel_session', {
        'sessionKey': widget.sessionKey,
      });
    } catch (error) {
      print('[LinkAccountScreen] Error cancelando sesión: $error');
    }
  }

  @override
  void dispose() {
    // Cancelar la sesión en el backend antes de desmontar
    _cancelSession();

    // Limpiar los listeners específicos para esta sesión
    widget.socket.off('qr');
    widget.socket.off('ready');
    widget.socket.off('status_update');
    widget.socket.off('disconnect');
    super.dispose();
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
      setState(() {
        status = 'Esperando QR';
      });
    });

    socket.on('qr', (data) {
      setState(() {
        qrCode = data;
        status = 'Esperando QR';
        isConnected = false;
      });
    });

    socket.on('ready', (_) {
      setState(() {
        isConnected = true;
        qrCode = null;
        status = 'Conectado';
      });
    });

    socket.on('status_update', (data) {
      if (data is Map && data['status'] == 'logged_out') {
        setState(() {
          isConnected = false;
          qrCode = null;
          status = 'Sesión cerrada. Escanea el nuevo QR.';
        });
      }
    });

    socket.onDisconnect((_) {
      setState(() {
        status = 'Desconectado';
        isConnected = false;
        qrCode = null;
      });
    });
  }

  @override
  void dispose() {
    socket.dispose();
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

class ChatsScreen extends StatefulWidget {
  final IO.Socket socket;
  final String sessionId;
  final String sessionKey;
  final String accountId;

  const ChatsScreen({
    required this.socket,
    required this.sessionId,
    required this.sessionKey,
    required this.accountId,
    super.key,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String? selectedChatPhone;
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return selectedChatPhone == null
          ? _buildChatsList()
          : _buildMessageDetail();
    }

    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 400, child: _buildChatsList()),
          Expanded(
            child: selectedChatPhone != null
                ? _buildMessageDetail()
                : Container(
                    color: darkBg,
                    child: const Center(
                      child: Text(
                        'Selecciona un chat para empezar',
                        style: TextStyle(
                          fontSize: 18,
                          color: lightText,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatsList() {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WhatHero', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: white)),
            Text(
              widget.sessionId,
              style: const TextStyle(fontSize: 12, color: lightText, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: TextField(
              controller: searchController,
              onChanged: (value) {
                setState(() {
                  searchQuery = value.toLowerCase();
                });
              },
              style: const TextStyle(color: white),
              decoration: InputDecoration(
                hintText: 'Buscar contacto...',
                hintStyle: const TextStyle(color: lightText),
                prefixIcon: const Icon(Icons.search, color: lightText, size: 20),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: lightText, size: 20),
                        onPressed: () {
                          searchController.clear();
                          setState(() {
                            searchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: surfaceDark.withValues(alpha: 0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              ),
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('accounts')
            .doc(widget.accountId)
            .collection('whatsapp_sessions')
            .doc(widget.sessionId)
            .collection('chats')
            .orderBy('lastMessageTimestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final allChats = snapshot.data!.docs;
          final filteredChats = searchQuery.isEmpty
              ? allChats
              : allChats
                  .where((chat) => (chat['phoneNumber'] as String)
                      .toLowerCase()
                      .contains(searchQuery))
                  .toList();

          if (filteredChats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    searchQuery.isEmpty ? 'Sin chats' : 'No se encontraron resultados',
                    style: const TextStyle(
                      fontSize: 16,
                      color: lightText,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: filteredChats.length,
            itemBuilder: (context, index) {
              final chat = filteredChats[index];
              final phoneNumber = chat['phoneNumber'] as String;
              final lastMessage = chat['lastMessage'] ?? 'Sin mensajes';
              final timestamp = (chat['lastMessageTimestamp'] as Timestamp?)?.toDate();

              return _ChatTile(
                phoneNumber: phoneNumber,
                lastMessage: lastMessage,
                timestamp: timestamp,
                isSelected: selectedChatPhone == phoneNumber,
                onTap: () {
                  setState(() {
                    selectedChatPhone = phoneNumber;
                  });
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMessageDetail() {
    return Scaffold(
      appBar: AppBar(
        leading: MediaQuery.of(context).size.width < 600
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    selectedChatPhone = null;
                  });
                },
              )
            : null,
        title: Text(
          selectedChatPhone ?? 'Chat',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: () {
              _showContactInfo(selectedChatPhone!);
            },
          ),
        ],
        elevation: 0,
      ),
      body: MessagesView(
        phoneNumber: selectedChatPhone!,
        sessionId: widget.sessionId,
        sessionKey: widget.sessionKey,
        accountId: widget.accountId,
      ),
    );
  }

  void _showContactInfo(String phoneNumber) {
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ContactInfoPanel(
        phoneNumber: phoneNumber,
        sessionId: widget.sessionId,
        accountId: widget.accountId,
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final String phoneNumber;
  final String lastMessage;
  final DateTime? timestamp;
  final bool isSelected;
  final VoidCallback onTap;

  const _ChatTile({
    required this.phoneNumber,
    required this.lastMessage,
    required this.timestamp,
    required this.isSelected,
    required this.onTap,
  });

  String _formatTimeShort(DateTime? dateTime) {
    if (dateTime == null) return '';
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Ahora';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d';
    } else {
      return '${dateTime.day}/${dateTime.month}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: isSelected ? surfaceDark.withValues(alpha: 0.8) : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: primaryAqua.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      phoneNumber.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        color: primaryAqua,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        phoneNumber,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        lastMessage,
                        style: const TextStyle(
                          color: lightText,
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Time
                Text(
                  _formatTimeShort(timestamp),
                  style: const TextStyle(
                    color: lightText,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ContactInfoPanel extends StatelessWidget {
  final String phoneNumber;
  final String sessionId;
  final String accountId;

  const ContactInfoPanel({
    required this.phoneNumber,
    required this.sessionId,
    required this.accountId,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('accounts')
          .doc(accountId)
          .collection('whatsapp_sessions')
          .doc(sessionId)
          .collection('chats')
          .doc(phoneNumber)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 300,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final chatData = snapshot.data!.data() as Map<String, dynamic>?;
        final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
        final lastMessageTime = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('accounts')
              .doc(accountId)
              .collection('whatsapp_sessions')
              .doc(sessionId)
              .collection('chats')
              .doc(phoneNumber)
              .collection('messages')
              .snapshots(),
          builder: (context, messagesSnapshot) {
            final messageCount = messagesSnapshot.data?.docs.length ?? 0;

            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: lightText.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Avatar
                    Center(
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: primaryAqua.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Center(
                          child: Text(
                            phoneNumber.substring(0, 1).toUpperCase(),
                            style: const TextStyle(
                              color: primaryAqua,
                              fontWeight: FontWeight.w700,
                              fontSize: 36,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Phone Number
                    Center(
                      child: Column(
                        children: [
                          Text(
                            phoneNumber,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Contacto de WhatsApp',
                            style: TextStyle(
                              fontSize: 13,
                              color: lightText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Info Section
                    Container(
                      decoration: BoxDecoration(
                        color: darkBg.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primaryAqua.withValues(alpha: 0.1),
                        ),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          _InfoRow(
                            icon: Icons.message,
                            label: 'Mensajes',
                            value: messageCount.toString(),
                          ),
                          const Divider(color: Colors.transparent, height: 16),
                          _InfoRow(
                            icon: Icons.access_time,
                            label: 'Último mensaje',
                            value: lastMessageTime != null
                                ? _formatLastMessageTime(lastMessageTime)
                                : 'Sin mensajes',
                          ),
                          const Divider(color: Colors.transparent, height: 16),
                          _InfoRow(
                            icon: Icons.check_circle,
                            label: 'Estado',
                            value: 'Conectado',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Last message preview
                    Container(
                      decoration: BoxDecoration(
                        color: darkBg.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: primaryAqua.withValues(alpha: 0.1),
                        ),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Último mensaje',
                            style: TextStyle(
                              fontSize: 12,
                              color: lightText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            lastMessage,
                            style: const TextStyle(
                              fontSize: 14,
                              color: white,
                              height: 1.5,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatLastMessageTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Hace unos segundos';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return 'Hace ${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return 'Hace ${difference.inDays}d';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: primaryAqua, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: lightText,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  color: white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class MessagesView extends StatefulWidget {
  final String phoneNumber;
  final String sessionId;
  final String sessionKey;
  final String accountId;

  const MessagesView({
    required this.phoneNumber,
    required this.sessionId,
    required this.sessionKey,
    required this.accountId,
    super.key,
  });

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }


  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
    });

    try {
      // Send message to backend
      final response = await http.post(
        Uri.parse('$backendUrl/send-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'to': widget.phoneNumber,
          'text': text,
          'sessionKey': widget.sessionKey,
        }),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Request timeout'),
      );

      if (response.statusCode == 200) {
        // Message sent successfully - just clear the input
        // The message will appear in the chat via Firestore stream
        _messageController.clear();
      } else {
        final error = response.body;
        throw Exception('Failed to send: $error');
      }
    } catch (e) {
      // Only show error if still mounted
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo enviar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Messages
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('accounts')
                .doc(widget.accountId)
                .collection('whatsapp_sessions')
                .doc(widget.sessionId)
                .collection('chats')
                .doc(widget.phoneNumber)
                .collection('messages')
                .orderBy('timestamp', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
                  ),
                );
              }

              final messages = snapshot.data!.docs;

              if (messages.isEmpty) {
                return const Center(
                  child: Text(
                    'Sin mensajes',
                    style: TextStyle(color: lightText, fontSize: 16),
                  ),
                );
              }

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                itemCount: messages.length,
                reverse: true,
                itemBuilder: (context, index) {
                  final msg = messages[index];
                  final text = msg['text'] ?? '';
                  final fromMe = msg['fromMe'] ?? false;
                  final timestamp = msg['timestamp'] as Timestamp;

                  return _MessageBubble(
                    text: text,
                    fromMe: fromMe,
                    timestamp: timestamp.toDate(),
                  );
                },
              );
            },
          ),
        ),
        // Input Area
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: surfaceDark,
            border: Border(
              top: BorderSide(color: primaryAqua.withValues(alpha: 0.1), width: 1),
            ),
          ),
          child: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    maxLines: null,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(color: white, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Escribe un mensaje...',
                      hintStyle: const TextStyle(color: lightText),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: darkBg.withValues(alpha: 0.8),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: primaryAqua,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(darkBg),
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
                    color: darkBg,
                    onPressed: _isSending ? null : _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String text;
  final bool fromMe;
  final DateTime timestamp;

  const _MessageBubble({
    required this.text,
    required this.fromMe,
    required this.timestamp,
  });

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              decoration: BoxDecoration(
                color: fromMe ? primaryAqua : surfaceDark.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(14),
                border: fromMe
                    ? null
                    : Border.all(
                        color: primaryAqua.withValues(alpha: 0.15),
                        width: 1,
                      ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                text,
                style: TextStyle(
                  color: fromMe ? darkBg : white,
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _formatTime(timestamp),
                style: const TextStyle(
                  color: lightText,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
