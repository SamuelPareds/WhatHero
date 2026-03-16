import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';
import 'core.dart';
import 'features/auth.dart';

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
        onUserAuthenticated: (accountId) => AccountsScreen(accountId: accountId),
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

    socket.on('human_attention_required', (data) {
      print('[AccountsScreen] human_attention_required: $data');
      // Badge in chat list is enough visual feedback
      // No need for additional notification banner
    });

    socket.connect();
    print('[AccountsScreen] socket.connect() llamado');
  }

  @override
  void dispose() {
    // Remove all socket listeners before disconnecting
    socket.off('connect');
    socket.off('disconnect');
    socket.off('human_attention_required');
    socket.disconnect();
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
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined, color: lightText, size: 20),
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            backgroundColor: surfaceDark,
                            isScrollControlled: true,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                            ),
                            builder: (_) => SessionSettingsPanel(
                              sessionId: phoneNumber,
                              accountId: widget.accountId,
                            ),
                          );
                        },
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
                  .where((chatDoc) {
                    final chatData = chatDoc.data() as Map<String, dynamic>?;
                    final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
                    return phoneNumber.toLowerCase().contains(searchQuery);
                  })
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
              final chatDoc = filteredChats[index];
              final chatData = chatDoc.data() as Map<String, dynamic>?;

              final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
              final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
              final timestamp = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();
              final needsHuman = chatData?['needs_human'] as bool? ?? false;

              return _ChatTile(
                phoneNumber: phoneNumber,
                lastMessage: lastMessage,
                timestamp: timestamp,
                isSelected: selectedChatPhone == phoneNumber,
                needsHuman: needsHuman,
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
  final bool needsHuman;
  final VoidCallback onTap;

  const _ChatTile({
    required this.phoneNumber,
    required this.lastMessage,
    required this.timestamp,
    required this.isSelected,
    required this.needsHuman,
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
                if (needsHuman) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Requiere atención humana',
                    child: Icon(
                      Icons.support_agent,
                      size: 18,
                      color: Colors.orange,
                    ),
                  ),
                ],
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

class SessionSettingsPanel extends StatefulWidget {
  final String sessionId;
  final String accountId;

  const SessionSettingsPanel({
    required this.sessionId,
    required this.accountId,
    super.key,
  });

  @override
  State<SessionSettingsPanel> createState() => _SessionSettingsPanelState();
}

class _SessionSettingsPanelState extends State<SessionSettingsPanel> {
  late TextEditingController _apiKeyController;
  late TextEditingController _systemPromptController;
  late TextEditingController _discriminatorPromptController;
  bool _aiEnabled = false;
  String _selectedModel = 'gemini-2.5-flash';
  int _responseDelayMs = 15000; // Default: 15 seconds
  bool _activeHoursEnabled = false;
  String _activeHoursTimezone = 'America/Mexico_City';
  TimeOfDay _activeHoursStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _activeHoursEnd = const TimeOfDay(hour: 18, minute: 0);
  List<String> _optedOutContacts = [];
  List<Map<String, String>> _keywordRules = [];
  String _newKeyword = '';
  String _newKeywordResponse = '';
  bool _discriminatorEnabled = false;
  bool _isSaving = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController();
    _systemPromptController = TextEditingController();
    _discriminatorPromptController = TextEditingController();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('accounts')
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .get();

      if (doc.exists) {
        final data = doc.data() ?? {};
        setState(() {
          _aiEnabled = data['ai_enabled'] ?? false;
          _apiKeyController.text = data['ai_api_key'] ?? '';
          _systemPromptController.text =
              data['ai_system_prompt'] ?? 'Eres un asistente útil.';
          _selectedModel = data['ai_model'] ?? 'gemini-2.5-flash';
          _responseDelayMs = data['ai_response_delay_ms'] ?? 15000;

          // Active hours
          if (data['ai_active_hours'] is Map) {
            final hours = data['ai_active_hours'] as Map;
            _activeHoursEnabled = hours['enabled'] ?? false;
            _activeHoursTimezone = hours['timezone'] ?? 'America/Mexico_City';
            if (hours['start'] is String) {
              final parts = (hours['start'] as String).split(':');
              _activeHoursStart = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? 9,
                minute: int.tryParse(parts[1]) ?? 0,
              );
            }
            if (hours['end'] is String) {
              final parts = (hours['end'] as String).split(':');
              _activeHoursEnd = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? 18,
                minute: int.tryParse(parts[1]) ?? 0,
              );
            }
          }

          // Opted out contacts
          _optedOutContacts =
              List<String>.from(data['ai_opted_out_contacts'] ?? []);

          // Keyword rules
          if (data['ai_keyword_rules'] is List) {
            _keywordRules = List<Map<String, String>>.from(
              (data['ai_keyword_rules'] as List).map(
                (rule) => {
                  'keyword': rule['keyword'] as String? ?? '',
                  'response': rule['response'] as String? ?? '',
                },
              ),
            );
          }

          // Discriminator
          _discriminatorEnabled = data['ai_discriminator_enabled'] ?? false;
          _discriminatorPromptController.text =
              data['ai_discriminator_prompt'] ?? '';

          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance
          .collection('accounts')
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .update({
        'ai_enabled': _aiEnabled,
        'ai_api_key': _apiKeyController.text,
        'ai_system_prompt': _systemPromptController.text,
        'ai_model': _selectedModel,
        'ai_response_delay_ms': _responseDelayMs,
        'ai_active_hours': {
          'enabled': _activeHoursEnabled,
          'timezone': _activeHoursTimezone,
          'start': '${_activeHoursStart.hour.toString().padLeft(2, '0')}:${_activeHoursStart.minute.toString().padLeft(2, '0')}',
          'end': '${_activeHoursEnd.hour.toString().padLeft(2, '0')}:${_activeHoursEnd.minute.toString().padLeft(2, '0')}',
        },
        'ai_opted_out_contacts': _optedOutContacts,
        'ai_keyword_rules': _keywordRules,
        'ai_discriminator_enabled': _discriminatorEnabled,
        'ai_discriminator_prompt': _discriminatorPromptController.text.trim(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuración guardada')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _systemPromptController.dispose();
    _discriminatorPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 400,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
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
            const SizedBox(height: 24),
            // Title
            const Text(
              'Configuración IA',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: white,
              ),
            ),
            const SizedBox(height: 24),
            // Enable toggle
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryAqua.withValues(alpha: 0.1),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Activar Asistente IA',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: white,
                      ),
                    ),
                    Switch(
                      value: _aiEnabled,
                      onChanged: (value) {
                        setState(() => _aiEnabled = value);
                      },
                      activeThumbColor: primaryAqua,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Model selector
            const Text(
              'Modelo de IA',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryAqua.withValues(alpha: 0.2),
                ),
              ),
              child: DropdownButton<String>(
                value: _selectedModel,
                onChanged: (String? value) {
                  if (value != null) {
                    setState(() => _selectedModel = value);
                  }
                },
                isExpanded: true,
                underline: const SizedBox(),
                dropdownColor: surfaceDark,
                items: [
                  DropdownMenuItem(
                    value: 'gemini-2.5-flash',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash 2.5 (Recomendado)',
                        style: TextStyle(color: primaryAqua),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-3-flash',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash 3 (Más rápido)',
                        style: TextStyle(color: white),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-2.5-pro',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Pro 2.5 (Más preciso)',
                        style: TextStyle(color: white),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-2.5-flash-lite',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash Lite (Más barato)',
                        style: TextStyle(color: lightText),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // API Key field
            const Text(
              'Gemini API Key',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'sk-...',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryAqua.withValues(alpha: 0.2),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 20),
            // System prompt field
            const Text(
              'Instrucciones del Asistente',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _systemPromptController,
              maxLines: 4,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'Eres un asistente de ventas para nuestra empresa...',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryAqua.withValues(alpha: 0.2),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 24),
            // Message buffer wait time slider
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Espera entre mensajes',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: lightText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'El asistente espera este tiempo para recibir más mensajes antes de responder',
                  style: TextStyle(
                    fontSize: 12,
                    color: lightText.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: darkBg.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: primaryAqua.withValues(alpha: 0.1),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      Slider(
                        value: _responseDelayMs.toDouble(),
                        min: 8000,
                        max: 30000,
                        divisions: 22,
                        activeColor: primaryAqua,
                        onChanged: (value) {
                          setState(() => _responseDelayMs = value.toInt());
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${(_responseDelayMs / 1000).toStringAsFixed(1)}s',
                          style: const TextStyle(
                            fontSize: 12,
                            color: primaryAqua,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Discriminator section
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Discriminador de Intenciones',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: white,
                        ),
                      ),
                      Switch(
                        value: _discriminatorEnabled,
                        onChanged: (value) {
                          setState(() => _discriminatorEnabled = value);
                        },
                        activeThumbColor: primaryAqua,
                      ),
                    ],
                  ),
                  if (_discriminatorEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Define cuándo se requiere atención humana (lenguaje natural)',
                      style: TextStyle(
                        fontSize: 12,
                        color: lightText.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _discriminatorPromptController,
                      minLines: 4,
                      maxLines: 6,
                      style: const TextStyle(color: white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Ejemplo:\n\nPasa al humano si:\n- El cliente pregunta disponibilidad de fechas específicas\n- Quiere agendar una cita\n- Pregunta por saldo o historial personal\n\nDe lo contrario, responde tú mismo.',
                        hintStyle: TextStyle(
                          color: lightText.withValues(alpha: 0.3),
                          fontSize: 13,
                        ),
                        filled: true,
                        fillColor: darkBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: primaryAqua.withValues(alpha: 0.1),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: primaryAqua, width: 2),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Active hours section
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Horario de atención',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: white,
                        ),
                      ),
                      Switch(
                        value: _activeHoursEnabled,
                        onChanged: (v) => setState(() => _activeHoursEnabled = v),
                        activeThumbColor: primaryAqua,
                      ),
                    ],
                  ),
                  if (_activeHoursEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Zona horaria',
                      style: const TextStyle(
                        fontSize: 12,
                        color: lightText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      decoration: BoxDecoration(
                        color: darkBg.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButton<String>(
                        value: _activeHoursTimezone,
                        isExpanded: true,
                        underline: const SizedBox(),
                        dropdownColor: surfaceDark,
                        items: [
                          'America/Mexico_City',
                          'America/New_York',
                          'Europe/Madrid',
                          'Europe/London',
                          'America/Los_Angeles',
                        ].map((tz) => DropdownMenuItem(value: tz, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(tz, style: const TextStyle(color: white)),
                        ))).toList(),
                        onChanged: (v) => setState(() => _activeHoursTimezone = v ?? 'America/Mexico_City'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Inicio', style: const TextStyle(fontSize: 12, color: lightText)),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () async {
                                  final time = await showTimePicker(context: context, initialTime: _activeHoursStart);
                                  if (time != null) setState(() => _activeHoursStart = time);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: darkBg.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('${_activeHoursStart.hour.toString().padLeft(2, '0')}:${_activeHoursStart.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: primaryAqua)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Fin', style: const TextStyle(fontSize: 12, color: lightText)),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () async {
                                  final time = await showTimePicker(context: context, initialTime: _activeHoursEnd);
                                  if (time != null) setState(() => _activeHoursEnd = time);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: darkBg.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('${_activeHoursEnd.hour.toString().padLeft(2, '0')}:${_activeHoursEnd.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: primaryAqua)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Opted-out contacts
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Contactos bloqueados',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: white),
                  ),
                  const SizedBox(height: 12),
                  if (_optedOutContacts.isNotEmpty)
                    Column(
                      children: _optedOutContacts.map((phone) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(child: Text(phone, style: const TextStyle(color: lightText, fontSize: 13))),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                onPressed: () => setState(() => _optedOutContacts.remove(phone)),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: '+1234567890',
                            hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                            isDense: true,
                            filled: true,
                            fillColor: darkBg.withValues(alpha: 0.3),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          style: const TextStyle(color: white, fontSize: 13),
                          onChanged: (v) => setState(() {}),
                          onSubmitted: (phone) {
                            if (phone.trim().isNotEmpty && !_optedOutContacts.contains(phone)) {
                              setState(() {
                                _optedOutContacts.add(phone);
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 40,
                        child: ElevatedButton(
                          onPressed: () => {},
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryAqua.withValues(alpha: 0.3),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Agregar', style: TextStyle(fontSize: 12, color: primaryAqua)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Keyword rules
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Respuestas por palabra clave',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: white),
                  ),
                  const SizedBox(height: 12),
                  if (_keywordRules.isNotEmpty)
                    Column(
                      children: _keywordRules.asMap().entries.map((e) {
                        final idx = e.key;
                        final rule = e.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${rule['keyword']}', style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.w600)),
                                    Text('${rule['response']!.substring(0, (rule['response']!.length < 30 ? rule['response']!.length : 30))}...', style: const TextStyle(color: lightText, fontSize: 11)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                onPressed: () => setState(() => _keywordRules.removeAt(idx)),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  Column(
                    children: [
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Palabra clave',
                          isDense: true,
                          filled: true,
                          fillColor: darkBg.withValues(alpha: 0.3),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        style: const TextStyle(color: white, fontSize: 12),
                        onChanged: (v) => _newKeyword = v,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Respuesta',
                          isDense: true,
                          filled: true,
                          fillColor: darkBg.withValues(alpha: 0.3),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        maxLines: 2,
                        style: const TextStyle(color: white, fontSize: 12),
                        onChanged: (v) => _newKeywordResponse = v,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            if (_newKeyword.trim().isNotEmpty && _newKeywordResponse.trim().isNotEmpty) {
                              setState(() {
                                _keywordRules.add({'keyword': _newKeyword, 'response': _newKeywordResponse});
                                _newKeyword = '';
                                _newKeywordResponse = '';
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryAqua.withValues(alpha: 0.3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          child: const Text('Agregar regla', style: TextStyle(fontSize: 12, color: primaryAqua)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  disabledBackgroundColor: primaryAqua.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(darkBg),
                        ),
                      )
                    : const Text(
                        'Guardar',
                        style: TextStyle(
                          color: darkBg,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
  bool _isGenerating = false;

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
      // Dev command: Delete chat history with "elimhis"
      if (text.toLowerCase() == 'elimhis') {
        final response = await http.post(
          Uri.parse('$backendUrl/delete-chat-history'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'phoneNumber': widget.phoneNumber,
            'sessionKey': widget.sessionKey,
            'sessionId': widget.sessionId,
            'accountId': widget.accountId,
          }),
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Request timeout'),
        );

        if (response.statusCode == 200) {
          _messageController.clear();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✓ Historial eliminado'),
                duration: Duration(seconds: 2),
                backgroundColor: Color(0xFF06B6D4),
              ),
            );
          }
        } else {
          throw Exception('Failed to delete history');
        }
        return;
      }

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

        // Reset needs_human flag when operator responds
        try {
          await FirebaseFirestore.instance
              .collection('accounts')
              .doc(widget.accountId)
              .collection('whatsapp_sessions')
              .doc(widget.sessionId)
              .collection('chats')
              .doc(widget.phoneNumber)
              .update({'needs_human': false});
        } catch (e) {
          debugPrint('Error resetting needs_human: $e');
        }
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

  Future<void> _generateAIResponse() async {
    setState(() => _isGenerating = true);
    try {
      final response = await http.post(
        Uri.parse('$backendUrl/generate-ai-response'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chatPhone': widget.phoneNumber,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final text = data['suggestedText'] as String? ?? '';
        setState(() => _messageController.text = text);
        _messageController.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
      }
    } catch (e) {
      // Silent error - user can retry
      debugPrint('Error generating AI response: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
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
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        // Enter sin Shift: enviar mensaje
                        _sendMessage();
                        return KeyEventResult.handled;
                      }
                      // Shift+Enter o cualquier otra tecla: permitir procesamiento normal
                      return KeyEventResult.ignored;
                    },
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
                ),
                const SizedBox(width: 8),
                // Generate AI response button
                _isGenerating
                    ? const SizedBox(
                        width: 44,
                        height: 44,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF06B6D4)),
                          ),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.auto_awesome, size: 20),
                        tooltip: 'Generar respuesta con IA',
                        color: const Color(0xFF06B6D4),
                        onPressed: _generateAIResponse,
                      ),
                const SizedBox(width: 4),
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
