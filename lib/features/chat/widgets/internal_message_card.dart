import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/internal_messages_service.dart';

/// Un mensaje interno del equipo dentro de la conversación.
///
/// Centrado y violeta a propósito: no es del cliente (izquierda) ni nuestro
/// hacia el cliente (derecha). Leerlo de un vistazo como "esto el cliente no
/// lo vio" es todo el punto.
class InternalMessageCard extends StatelessWidget {
  final InternalMessage message;
  final String? myUid;

  /// Tap en uno que no se pudo enviar → reintentar o descartar.
  final VoidCallback? onFailedTap;

  const InternalMessageCard({
    required this.message,
    required this.myUid,
    this.onFailedTap,
    super.key,
  });

  // "Tú → Mayra", "Samuel → ti, Ana", "Samuel · sólo equipo".
  String get _header {
    final author = message.authorUid == myUid ? 'Tú' : message.authorName;
    if (message.recipients.isEmpty) return '$author · sólo equipo';
    final to = [
      for (final r in message.recipients) r.uid == myUid ? 'ti' : r.name,
    ];
    return '$author → ${to.join(', ')}';
  }

  String get _time {
    final t = message.timestamp;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final failed = message.status == InternalSendStatus.failed;
    final accent = failed ? Colors.red.shade400 : teamViolet;
    return Align(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GestureDetector(
          onTap: failed ? onFailedTap : null,
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: message.text));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Copiado'),
              duration: Duration(seconds: 1),
            ));
          },
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: teamViolet.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock, size: 12, color: teamViolet),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        _header,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: teamViolet,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _time,
                      style: TextStyle(
                        color: lightText.withValues(alpha: 0.7),
                        fontSize: 10.5,
                      ),
                    ),
                    if (message.status == InternalSendStatus.sending) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.schedule,
                          size: 12, color: lightText.withValues(alpha: 0.7)),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  message.text,
                  style: const TextStyle(color: white, fontSize: 14, height: 1.35),
                ),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'No se envió · toca para reintentar',
                      style: TextStyle(color: Colors.red.shade400, fontSize: 11),
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
