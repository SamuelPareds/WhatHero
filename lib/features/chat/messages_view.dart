import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'widgets/message_bubble.dart';

class MessagesView extends StatefulWidget {
  final String phoneNumber;
  final String sessionId;
  final String? sessionKey;
  final String accountId;

  const MessagesView({
    required this.phoneNumber,
    required this.sessionId,
    this.sessionKey,
    required this.accountId,
    super.key,
  });

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // 📌 Paginación / Infinite Scroll
  int _messageLimit = 30;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  bool _isSending = false;
  bool _isGenerating = false;
  String _quickResponseFilter = '';
  OverlayEntry? _quickResponseOverlay;

  @override
  void initState() {
    super.initState();
    // Escuchar el scroll para cargar más mensajes
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _messageController.dispose();
    _scrollController.dispose();
    _quickResponseOverlay?.remove();
    super.dispose();
  }

  void _scrollListener() {
    // En una lista 'reverse: true', el final (maxScrollExtent) es la parte SUPERIOR (mensajes viejos)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _hasMore) {
        _loadMoreMessages();
      }
    }
  }

  void _loadMoreMessages() {
    print('[MessagesView] Cargando más mensajes... Límite actual: $_messageLimit');
    setState(() {
      _isLoadingMore = true;
      _messageLimit += 30;
    });
    
    // Pequeño delay artificial para UX y dar tiempo a Firestore
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    });
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
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          _messageController.clear();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('✓ Historial eliminado'), backgroundColor: Color(0xFF06B6D4)),
            );
          }
        }
        return;
      }

      final messageData = {
        'to': widget.phoneNumber,
        'text': text,
        'sessionKey': widget.sessionKey,
        'accountId': widget.accountId,
        'tempId': DateTime.now().millisecondsSinceEpoch.toString(),
      };

      // INTELIGENTE: Si el socket está conectado, enviar por ahí (Velocidad Rayo)
      if (SocketService().isConnected) {
        print('[MessagesView] Enviando vía WebSocket...');
        SocketService().sendMessage(messageData);
        _messageController.clear();
        _resetNeedsHuman();
      } else {
        // FALLBACK: Si no hay socket, usar HTTP (Seguridad)
        print('[MessagesView] Socket desconectado, usando fallback HTTP...');
        final response = await http.post(
          Uri.parse('$backendUrl/send-message'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(messageData),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          _messageController.clear();
          _resetNeedsHuman();
        } else {
          throw Exception('Fallback HTTP falló: ${response.body}');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red.shade600),
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

  Future<void> _resetNeedsHuman() async {
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
      debugPrint('Error generating AI response: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  void _handleQuickResponseInput(String value) {
    if (value.startsWith('/')) {
      final filter = value.substring(1).toLowerCase();
      setState(() => _quickResponseFilter = filter);
      _showQuickResponsesOverlay();
    } else {
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

      final filtered = allResponses
          .where((qr) {
            final title = (qr['title'] as String? ?? '').toLowerCase();
            return title.contains(_quickResponseFilter);
          })
          .toList();

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
                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 2)),
                ],
              ),
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1, indent: 8, endIndent: 8),
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
                                Text(title, style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.w600, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                if (text.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(text.substring(0, (text.length < 40 ? text.length : 40)), style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
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

    _quickResponseOverlay?.remove();
    _quickResponseOverlay = null;

    if (imageUrl.isNotEmpty) {
      _showImageConfirmationDialog(title, text, imageUrl);
    } else {
      setState(() => _messageController.text = text);
      _messageController.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
    }
  }

  void _showImageConfirmationDialog(String title, String caption, String imageUrl) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text(title, style: const TextStyle(color: white, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(imageUrl, height: 150, fit: BoxFit.cover),
              ),
              if (caption.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(caption, style: const TextStyle(color: white, fontSize: 13))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6)))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: primaryAqua),
            onPressed: () {
              Navigator.pop(context);
              _sendQuickResponse({'text': caption, 'imageUrl': imageUrl});
            },
            child: const Text('Enviar', style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
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
      final messageData = {
        'to': widget.phoneNumber,
        'text': text,
        'imageUrl': imageUrl,
        'sessionKey': widget.sessionKey,
        'accountId': widget.accountId,
      };

      if (SocketService().isConnected) {
        print('[MessagesView] Enviando respuesta rápida vía WebSocket...');
        SocketService().sendMessage(messageData);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✓ Respuesta enviada'), duration: Duration(seconds: 2), backgroundColor: Color(0xFF06B6D4)),
          );
        }
      } else {
        print('[MessagesView] Socket desconectado, usando fallback HTTP para respuesta rápida...');
        final response = await http.post(
          Uri.parse('$backendUrl/send-message'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(messageData),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) throw Exception(response.body);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al enviar: ${e.toString()}'), backgroundColor: Colors.red.shade600),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
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
                .limit(_messageLimit) // 📌 Aplicar límite dinámico
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)));
              
              final messages = snapshot.data!.docs;
              
              // Si nos devuelven menos de lo que pedimos, es que ya no hay más mensajes en el servidor
              if (messages.length < _messageLimit) {
                _hasMore = false;
              }

              if (messages.isEmpty) return const Center(child: Text('Sin mensajes', style: TextStyle(color: lightText, fontSize: 16)));

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                itemCount: messages.length + (_hasMore ? 1 : 0),
                reverse: true, // Importante: el índice 0 es el mensaje más nuevo (abajo)
                itemBuilder: (context, index) {
                  // Si es el último elemento y hay más, mostrar spinner de carga
                  if (index == messages.length) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)),
                        ),
                      ),
                    );
                  }

                  final msg = messages[index];
                  return MessageBubble(
                    key: ValueKey(msg.id),
                    text: msg['text'] ?? '',
                    fromMe: msg['fromMe'] ?? false,
                    timestamp: (msg['timestamp'] as Timestamp).toDate(),
                    messageId: msg.id,
                    chatPhone: widget.phoneNumber,
                    sessionKey: widget.sessionKey,
                    accountId: widget.accountId,
                  );
                },
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: surfaceDark, 
            border: Border(top: BorderSide(color: primaryAqua.withValues(alpha: 0.1), width: 1))
          ),
          child: SafeArea(
            child: Builder(
              builder: (context) {
                final sKey = widget.sessionKey;
                final bool isDisconnected = sKey == null || sKey == 'disconnected';
                
                if (isDisconnected) {
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    width: double.infinity,
                    child: const Text(
                      'Cuenta desvinculada. Re-vincula para enviar mensajes.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  );
                }
                
                return Row(
                  children: [
                    Expanded(
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed && event is KeyDownEvent) {
                            _sendMessage();
                            return KeyEventResult.handled;
                          }
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
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                            filled: true,
                            fillColor: darkBg.withValues(alpha: 0.8),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _isGenerating
                        ? const SizedBox(width: 44, height: 44, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF06B6D4)))))
                        : IconButton(icon: const Icon(Icons.auto_awesome, size: 20), tooltip: 'Generar respuesta con IA', color: const Color(0xFF06B6D4), onPressed: _generateAIResponse),
                    const SizedBox(width: 4),
                    Container(
                      decoration: BoxDecoration(color: primaryAqua, borderRadius: BorderRadius.circular(12)),
                      child: IconButton(
                        icon: _isSending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(darkBg))) : const Icon(Icons.send_rounded, size: 20),
                        color: darkBg,
                        onPressed: _isSending ? null : _sendMessage,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
