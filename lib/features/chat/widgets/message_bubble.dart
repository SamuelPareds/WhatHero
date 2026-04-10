import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';

class MessageBubble extends StatefulWidget {
  final String text;
  final bool fromMe;
  final DateTime timestamp;
  final String messageId;
  final String chatPhone;
  final String? sessionKey;
  final String accountId;

  const MessageBubble({
    super.key,
    required this.text,
    required this.fromMe,
    required this.timestamp,
    required this.messageId,
    required this.chatPhone,
    this.sessionKey,
    required this.accountId,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.text);
  }

  @override
  void didUpdateWidget(MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _editController.text = widget.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copiado'),
          duration: Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
        ),
      );
    }
  }

  Future<void> _editMessage() async {
    final newText = _editController.text.trim();
    if (newText.isEmpty || newText == widget.text) {
      setState(() => _isEditing = false);
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/edit-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messageId': widget.messageId,
          'chatPhone': widget.chatPhone,
          'newText': newText,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && mounted) {
        setState(() => _isEditing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mensaje editado'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al editar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  Future<void> _deleteMessage() async {
    try {
      final response = await http.post(
        Uri.parse('$backendUrl/delete-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messageId': widget.messageId,
          'chatPhone': widget.chatPhone,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mensaje eliminado'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  void _showMessageOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: primaryAqua.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy, size: 20, color: primaryAqua),
              title: const Text('Copiar', style: TextStyle(color: white)),
              onTap: () {
                Navigator.pop(context);
                _copyToClipboard();
              },
            ),
            if (widget.fromMe) ...[
              ListTile(
                leading: const Icon(Icons.edit, size: 20, color: Color(0xFF10B981)),
                title: const Text('Editar', style: TextStyle(color: white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _isEditing = true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, size: 20, color: Color(0xFFF87171)),
                title: const Text('Eliminar', style: TextStyle(color: white)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteConfirmation();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('Eliminar mensaje', style: TextStyle(color: white)),
        content: const Text(
          '¿Estás seguro de que deseas eliminar este mensaje para todos?',
          style: TextStyle(color: lightText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFFF87171)),
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage();
            },
            child: const Text('Eliminar', style: TextStyle(color: white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Column(
                  children: [
                    TextField(
                      controller: _editController,
                      maxLines: null,
                      autofocus: true,
                      style: const TextStyle(color: white, fontSize: 15),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: primaryAqua),
                        ),
                        filled: true,
                        fillColor: darkBg.withValues(alpha: 0.8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _isEditing = false),
                          child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: primaryAqua),
                          onPressed: _editMessage,
                          child: const Text('Guardar', style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: widget.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: widget.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: _showMessageOptions,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                decoration: BoxDecoration(
                  color: widget.fromMe ? primaryAqua : surfaceDark.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(14),
                  border: widget.fromMe
                      ? null
                      : Border.all(
                          color: primaryAqua.withValues(alpha: 0.15),
                          width: 1,
                        ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(
                  widget.text,
                  style: TextStyle(
                    color: widget.fromMe ? darkBg : white,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _formatTime(widget.timestamp),
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
