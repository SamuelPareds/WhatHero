import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'widgets/message_bubble.dart';

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

                  return MessageBubble(
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
