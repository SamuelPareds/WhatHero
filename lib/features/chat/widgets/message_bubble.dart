import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crm_whatsapp/core.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final bool fromMe;
  final DateTime timestamp;

  const MessageBubble({
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
            GestureDetector(
              onLongPress: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copiado'),
                      duration: Duration(milliseconds: 1500),
                      behavior: SnackBarBehavior.floating,
                      margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
                    ),
                  );
                }
              },
              child: Container(
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
