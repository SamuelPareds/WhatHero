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
  String _quickResponseFilter = '';
  OverlayEntry? _quickResponseOverlay;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _quickResponseOverlay?.remove();
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
          'accountId': widget.accountId,
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

  void _handleQuickResponseInput(String value) {
    // Check if "/" is at the beginning of the text
    if (value.startsWith('/')) {
      // Extract the filter text after "/"
      final filter = value.substring(1).toLowerCase();
      setState(() => _quickResponseFilter = filter);
      _showQuickResponsesOverlay();
    } else {
      // If "/" was removed, close the overlay
      _quickResponseOverlay?.remove();
      _quickResponseOverlay = null;
    }
  }

  void _showQuickResponsesOverlay() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('accounts')
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses')
          .orderBy('order', descending: false)
          .get();

      if (!mounted) return;

      final allResponses = snapshot.docs
          .map((doc) => {...doc.data(), 'id': doc.id})
          .toList();

      // Filter responses based on current filter text
      final filtered = allResponses
          .where((qr) {
            final title = (qr['title'] as String? ?? '').toLowerCase();
            return title.contains(_quickResponseFilter);
          })
          .toList();

      // Remove old overlay if exists
      _quickResponseOverlay?.remove();

      if (filtered.isEmpty) {
        _quickResponseOverlay = null;
        return;
      }

      _quickResponseOverlay = OverlayEntry(
        builder: (context) => Positioned(
          bottom: MediaQuery.of(context).viewInsets.bottom + 140,
          left: 12,
          right: 12,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: surfaceDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => Divider(
                  color: primaryAqua.withValues(alpha: 0.1),
                  height: 1,
                  indent: 8,
                  endIndent: 8,
                ),
                itemBuilder: (_, idx) {
                  final qr = filtered[idx];
                  final title = qr['title'] as String? ?? '';
                  final text = qr['text'] as String? ?? '';
                  final imageUrl = qr['imageUrl'] as String? ?? '';

                  return InkWell(
                    onTap: () => _selectQuickResponse(qr),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    color: primaryAqua,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (text.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      text.substring(0, (text.length < 40 ? text.length : 40)),
                                      style: TextStyle(
                                        color: lightText.withValues(alpha: 0.5),
                                        fontSize: 10,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (imageUrl.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.image, size: 14, color: primaryAqua.withValues(alpha: 0.6)),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      Overlay.of(context).insert(_quickResponseOverlay!);
    } catch (e) {
      debugPrint('Error loading quick responses: $e');
    }
  }

  void _selectQuickResponse(Map<String, dynamic> template) {
    final text = template['text'] as String? ?? '';
    final imageUrl = template['imageUrl'] as String? ?? '';
    final title = template['title'] as String? ?? '';

    // Remove overlay
    _quickResponseOverlay?.remove();
    _quickResponseOverlay = null;

    if (imageUrl.isNotEmpty) {
      // Show confirmation dialog for image responses
      _showImageConfirmationDialog(title, text, imageUrl);
    } else {
      // Fill text field if text-only (remove the "/" prefix)
      setState(() => _messageController.text = text);
      _messageController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
    }
  }

  void _showImageConfirmationDialog(String title, String caption, String imageUrl) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        title: Text(
          title,
          style: const TextStyle(color: white, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Image preview
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 150,
                    width: double.maxFinite,
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        decoration: BoxDecoration(
                          color: darkBg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.broken_image, color: lightText, size: 32),
                            SizedBox(height: 8),
                            Text('Error cargando imagen', style: TextStyle(color: lightText, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (caption.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Mensaje:',
                    style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: darkBg.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
                    ),
                    child: Text(
                      caption,
                      style: const TextStyle(color: white, fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancelar',
              style: TextStyle(color: lightText.withValues(alpha: 0.6)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAqua,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            onPressed: () {
              Navigator.pop(context);
              _sendQuickResponse({'text': caption, 'imageUrl': imageUrl});
            },
            child: const Text(
              'Enviar',
              style: TextStyle(color: darkBg, fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendQuickResponse(Map<String, dynamic> template) async {
    final text = template['text'] as String? ?? '';
    final imageUrl = template['imageUrl'] as String? ?? '';

    if (imageUrl.isEmpty) return;

    setState(() => _isSending = true);

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/send-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'to': widget.phoneNumber,
          'text': text,
          'imageUrl': imageUrl,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Request timeout'),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✓ Respuesta enviada'),
              duration: Duration(seconds: 2),
              backgroundColor: Color(0xFF06B6D4),
            ),
          );
        }
      } else {
        throw Exception('Failed to send: ${response.body}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
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
                  final messageId = msg.id;

                  return MessageBubble(
                    key: ValueKey(messageId),
                    text: text,
                    fromMe: fromMe,
                    timestamp: timestamp.toDate(),
                    messageId: messageId,
                    chatPhone: widget.phoneNumber,
                    sessionKey: widget.sessionKey,
                    accountId: widget.accountId,
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
                      onChanged: _handleQuickResponseInput,
                      decoration: InputDecoration(
                        hintText: '',
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
