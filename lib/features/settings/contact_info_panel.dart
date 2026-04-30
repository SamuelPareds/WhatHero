import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/chat/widgets/label_chip.dart';
import 'package:crm_whatsapp/features/chat/widgets/labels_selector_sheet.dart';

class ContactInfoPanel extends StatelessWidget {
  final String phoneNumber;
  final String sessionId;
  final String accountId;

  const ContactInfoPanel({
    required this.phoneNumber,
    required this.sessionId,
    required this.accountId,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection(accountsCollection)
            .doc(accountId)
            .collection('whatsapp_sessions')
            .doc(sessionId)
            .collection('chats')
            .doc(phoneNumber)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const SizedBox(
              height: 300,
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final chatData = snapshot.data!.data() as Map<String, dynamic>?;
          final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
          final lastMessageTime = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();
          final assignedIds = ((chatData?['labelIds'] as List?) ?? const [])
              .whereType<String>()
              .toList();

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(accountsCollection)
                .doc(accountId)
                .collection('whatsapp_sessions')
                .doc(sessionId)
                .collection('chats')
                .doc(phoneNumber)
                .collection('messages')
                .snapshots(),
            builder: (context, messagesSnapshot) {
              final messageCount = messagesSnapshot.data?.docs.length ?? 0;

              return SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Handle
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: lightText.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      // Avatar
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: primaryAqua.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Center(
                            child: Text(
                              phoneNumber.substring(0, 1).toUpperCase(),
                              style: const TextStyle(
                                color: primaryAqua,
                                fontWeight: FontWeight.w700,
                                fontSize: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Phone Number
                      Center(
                        child: GestureDetector(
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: phoneNumber));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text(
                                  'Número copiado al portapapeles',
                                  style: TextStyle(
                                    color: white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                backgroundColor: primaryAqua,
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 2),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 40,
                                  vertical: 20,
                                ),
                              ),
                            );
                          },
                          child: Column(
                            children: [
                              Text(
                                phoneNumber,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Contacto de WhatsApp',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: lightText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                      // Info Section
                      Container(
                        decoration: BoxDecoration(
                          color: darkBg.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: primaryAqua.withValues(alpha: 0.1),
                          ),
                        ),
                        padding: const EdgeInsets.all(20),
                          child: Column(
                          children: [
                            _InfoRow(
                              icon: Icons.message,
                              label: 'Mensajes',
                              value: messageCount.toString(),
                            ),
                            const Divider(color: Colors.transparent, height: 16),
                            _InfoRow(
                              icon: Icons.access_time,
                              label: 'Último mensaje',
                              value: lastMessageTime != null
                                  ? _formatLastMessageTime(lastMessageTime)
                                  : 'Sin mensajes',
                            ),
                            const Divider(color: Colors.transparent, height: 16),
                            _InfoRow(
                              icon: Icons.check_circle,
                              label: 'Estado',
                              value: 'Conectado',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Sección de etiquetas asignadas. Lee el catálogo de
                      // la sesión y resuelve los IDs guardados en el chat.
                      _LabelsSection(
                        accountId: accountId,
                        sessionId: sessionId,
                        phoneNumber: phoneNumber,
                        assignedIds: assignedIds,
                      ),
                      const SizedBox(height: 24),
                      // Last message preview
                      Container(
                        decoration: BoxDecoration(
                          color: darkBg.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: primaryAqua.withValues(alpha: 0.1),
                          ),
                        ),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Último mensaje',
                              style: TextStyle(
                                fontSize: 12,
                                color: lightText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              lastMessage,
                              style: const TextStyle(
                                fontSize: 14,
                                color: white,
                                height: 1.5,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
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

  String _formatLastMessageTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Hace unos segundos';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return 'Hace ${difference.inHours}h';
    } else if (difference.inDays < 7) {
      return 'Hace ${difference.inDays}d';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}

// Card con las etiquetas asignadas al chat + botón para abrir el selector.
// Si no hay catálogo creado en la sesión, muestra un CTA hacia Ajustes.
class _LabelsSection extends StatelessWidget {
  final String accountId;
  final String sessionId;
  final String phoneNumber;
  final List<String> assignedIds;

  const _LabelsSection({
    required this.accountId,
    required this.sessionId,
    required this.phoneNumber,
    required this.assignedIds,
  });

  void _openSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LabelsSelectorSheet(
        accountId: accountId,
        sessionId: sessionId,
        phoneNumber: phoneNumber,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: darkBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Etiquetas',
                  style: TextStyle(
                    fontSize: 12,
                    color: lightText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _openSelector(context),
                icon: const Icon(Icons.edit_outlined, size: 14, color: primaryAqua),
                label: const Text(
                  'Editar',
                  style: TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.bold),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(accountsCollection)
                .doc(accountId)
                .collection('whatsapp_sessions')
                .doc(sessionId)
                .collection('labels')
                .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const SizedBox(height: 30);
              }
              final catalog = {
                for (final d in snap.data!.docs) d.id: ChatLabel.fromDoc(d),
              };
              final resolved = assignedIds
                  .map((id) => catalog[id])
                  .whereType<ChatLabel>()
                  .toList();
              if (resolved.isEmpty) {
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openSelector(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Sin etiquetas asignadas. Toca "Editar" para asignar.',
                      style: TextStyle(
                        color: lightText.withValues(alpha: 0.7),
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                );
              }
              return LabelChipsRow(
                labelIds: assignedIds,
                catalog: catalog,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: primaryAqua, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: lightText,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  color: white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
