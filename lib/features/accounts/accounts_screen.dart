import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/auth.dart';
import 'package:crm_whatsapp/features/accounts/link_account_screen.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'package:crm_whatsapp/main.dart' show ChatsScreen;

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
    print('[AccountsScreen] 🚀 Conectando a: $backendUrl (modo: ${identical(true, const bool.fromEnvironment("dart.vm.product")) ? 'Release' : 'Debug'})');
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
