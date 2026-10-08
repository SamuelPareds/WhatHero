import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/internal_messages_service.dart';

/// Bandeja "Para ti": lo que el equipo te escribió en los chats de esta
/// sesión, del más nuevo al más viejo. Tocar uno abre el chat.
///
/// Una sola consulta (`recipientUids array-contains`): por eso los internos
/// viven en una colección plana de la sesión y no dentro de cada chat. Lo "sin
/// ver" no se guarda por mensaje: sale del contador `internal_unread` de cada
/// chat, el mismo del badge de la lista, que se apaga al abrir el chat.
class TeamInboxPanel extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String myUid;

  /// chatId → internos sin ver para mí. Viene de la lista de chats, que ya
  /// tiene esos docs en memoria.
  final ValueListenable<Map<String, int>> unreadByChat;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onClose;

  /// Flechita (barra de escritorio: pliega) o ✕ (panel flotante: cierra).
  final IconData closeIcon;

  const TeamInboxPanel({
    required this.accountId,
    required this.sessionId,
    required this.myUid,
    required this.unreadByChat,
    required this.onOpenChat,
    required this.onClose,
    required this.closeIcon,
    super.key,
  });

  @override
  State<TeamInboxPanel> createState() => _TeamInboxPanelState();
}

class _TeamInboxPanelState extends State<TeamInboxPanel> {
  // Una suscripción mientras el panel está abierto; plegado no escucha nada.
  late final Stream<QuerySnapshot> _stream = FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId)
      .collection('internal_messages')
      .where('recipientUids', arrayContains: widget.myUid)
      .orderBy('timestamp', descending: true)
      .limit(30)
      .snapshots();

  // Si un chat tiene N sin ver, son sus N internos más nuevos para mí.
  Set<String> _unseen(List<InternalMessage> items, Map<String, int> unread) {
    final left = Map<String, int>.of(unread);
    final unseen = <String>{};
    for (final m in items) {
      final n = left[m.chatId] ?? 0;
      if (n == 0) continue;
      unseen.add(m.id);
      left[m.chatId] = n - 1;
    }
    return unseen;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surfaceDark,
        border: Border(
          left: BorderSide(color: teamViolet.withValues(alpha: 0.2)),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
            child: Row(
              children: [
                const Icon(Icons.forum_rounded, size: 18, color: teamViolet),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Para ti',
                        style: TextStyle(
                          color: white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'Mensajes internos del equipo',
                        style: TextStyle(color: lightText, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(widget.closeIcon, size: 20),
                  color: lightText,
                  tooltip: widget.closeIcon == Icons.close ? 'Cerrar' : 'Ocultar',
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  debugPrint('[Interno] Bandeja: ${snapshot.error}');
                  return const _InboxEmpty(
                    icon: Icons.cloud_off,
                    title: 'No se pudo cargar',
                    subtitle: 'Revisa tu conexión',
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(teamViolet),
                    ),
                  );
                }
                final items = snapshot.data!.docs
                    .map(InternalMessage.fromDoc)
                    .nonNulls
                    .toList();
                if (items.isEmpty) {
                  return const _InboxEmpty(
                    icon: Icons.forum_outlined,
                    title: 'Nada del equipo por ahora',
                    subtitle:
                        'Cuando un compañero te escriba en un chat, aparece aquí.',
                  );
                }
                return ValueListenableBuilder<Map<String, int>>(
                  valueListenable: widget.unreadByChat,
                  builder: (context, unread, _) {
                    final unseen = _unseen(items, unread);
                    return ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.5,
                        color: white.withValues(alpha: 0.06),
                      ),
                      itemBuilder: (context, i) => _InboxTile(
                        message: items[i],
                        unseen: unseen.contains(items[i].id),
                        onTap: () => widget.onOpenChat(items[i].chatId),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  final InternalMessage message;
  final bool unseen;
  final VoidCallback onTap;

  const _InboxTile({
    required this.message,
    required this.unseen,
    required this.onTap,
  });

  String get _when {
    final t = message.timestamp;
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    return '${t.day}/${t.month}';
  }

  @override
  Widget build(BuildContext context) {
    final contact =
        message.contactName.isNotEmpty ? message.contactName : message.chatId;
    final initial = message.authorName.isEmpty
        ? '?'
        : message.authorName.characters.first.toUpperCase();
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: teamViolet.withValues(alpha: 0.2),
              child: Text(
                initial,
                style: const TextStyle(
                  color: teamViolet,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${message.authorName} · $contact',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: white,
                            fontSize: 13,
                            fontWeight:
                                unseen ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _when,
                        style: TextStyle(
                          color: unseen ? teamViolet : lightText,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: unseen ? white : lightText,
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (unseen)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 6),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: teamViolet,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InboxEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InboxEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: teamViolet.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(color: white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: lightText, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// La bandeja plegada (escritorio): franja de 48 px con el contador y la
/// flechita para desplegarla. Siempre visible: es lo que te avisa que alguien
/// del equipo te pidió algo.
class TeamInboxRail extends StatelessWidget {
  final ValueListenable<Map<String, int>> unreadByChat;
  final VoidCallback onExpand;

  const TeamInboxRail({
    required this.unreadByChat,
    required this.onExpand,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: surfaceDark,
      child: InkWell(
        onTap: onExpand,
        child: Container(
          width: 48,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: teamViolet.withValues(alpha: 0.2)),
            ),
          ),
          child: ValueListenableBuilder<Map<String, int>>(
            valueListenable: unreadByChat,
            builder: (context, unread, _) {
              final total = unread.values.fold(0, (a, b) => a + b);
              return Tooltip(
                message: total == 0
                    ? 'Mensajes del equipo'
                    : '$total del equipo para ti',
                child: Column(
                  children: [
                    const SizedBox(height: 14),
                    const Icon(Icons.chevron_left, color: lightText, size: 20),
                    const SizedBox(height: 10),
                    Badge(
                      isLabelVisible: total > 0,
                      backgroundColor: teamViolet,
                      label: Text('$total'),
                      child: Icon(
                        Icons.forum_rounded,
                        size: 22,
                        color: total > 0 ? teamViolet : lightText,
                      ),
                    ),
                    const SizedBox(height: 14),
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        'EQUIPO',
                        style: TextStyle(
                          color: lightText.withValues(alpha: 0.6),
                          fontSize: 10.5,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
