import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/core/services/storage_service.dart';
import 'package:crm_whatsapp/core/services/version_service.dart';
import 'package:crm_whatsapp/features/auth.dart';
import 'package:crm_whatsapp/features/accounts/link_account_screen.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'package:crm_whatsapp/features/chat.dart';

class AccountsScreen extends StatefulWidget {
  final String accountId;

  const AccountsScreen({required this.accountId, super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  String _appVersion = '0.0.0+0';

  @override
  void initState() {
    super.initState();
    SocketService().init(widget.accountId);
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final version = await VersionService.getVersion();
    if (mounted) {
      setState(() {
        _appVersion = version;
      });
    }
  }

  Future<void> _handleLogout() async {
    try {
      // Limpiar preferencia de última sesión
      await StorageService().clearLastSessionId();
      // El dispose del socket se encarga de cerrar la conexión
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
    // Verificar conexión del socket centralizado
    if (!SocketService().isConnected) {
      print('[AccountsScreen] Socket no está conectado, esperando...');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Conectando al servidor... intenta de nuevo')),
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'WhatHero v$_appVersion',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: lightText.withValues(alpha: 0.45),
            ),
          ),
        ),
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
              final isReconnecting = status == 'reconnecting';

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: surfaceDark.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isConnected
                        ? primaryAqua.withValues(alpha: 0.2)
                        : isReconnecting
                            ? Colors.orange.withValues(alpha: 0.2)
                            : Colors.red.withValues(alpha: 0.2),
                  ),
                ),
                child: InkWell(
                  onTap: () {
                    final sessionKey = sessionDoc['session_key'] as String?;
                    // Permitimos entrar aunque no haya sessionKey (será modo lectura)
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatsScreen(
                          sessionId: phoneNumber,
                          sessionKey: sessionKey ?? 'disconnected',
                          accountId: widget.accountId,
                          initialAlias: alias,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? primaryAqua.withValues(alpha: 0.2)
                                : isReconnecting
                                    ? Colors.orange.withValues(alpha: 0.15)
                                    : Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: Text(
                              alias.substring(0, 1).toUpperCase(),
                              style: TextStyle(
                                color: isConnected
                                    ? primaryAqua
                                    : isReconnecting
                                        ? Colors.orange.shade400
                                        : Colors.red.shade400,
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
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isConnected
                                    ? accentAqua.withValues(alpha: 0.2)
                                    : isReconnecting
                                        ? Colors.orange.withValues(alpha: 0.2)
                                        : Colors.red.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isReconnecting)
                                    SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.orange.shade400,
                                        ),
                                      ),
                                    ),
                                  if (isReconnecting) const SizedBox(width: 4),
                                  Text(
                                    isConnected
                                        ? 'Conectado'
                                        : isReconnecting
                                            ? 'Reconectando...'
                                            : 'Desvinculado',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isConnected
                                          ? accentAqua
                                          : isReconnecting
                                              ? Colors.orange.shade400
                                              : Colors.red.shade400,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isConnected && !isReconnecting)
                              IconButton(
                                icon: const Icon(Icons.sync, color: primaryAqua, size: 22),
                                onPressed: _startNewSession,
                                tooltip: 'Re-vincular cuenta',
                              ),
                          ],
                        ),
                        const SizedBox(width: 4),
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}
