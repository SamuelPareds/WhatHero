import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';
import 'core.dart';
import 'features/auth.dart';
import 'features/accounts.dart';
import 'features/settings.dart';

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
