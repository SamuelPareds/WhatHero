import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';

/// Bottom sheet para asignar/desasignar etiquetas a un chat. Lee el catálogo
/// en realtime de la subcolección `labels` y persiste `labelIds` en el doc del
/// chat con merge:true para no pisar otros campos.
class LabelsSelectorSheet extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String phoneNumber;

  const LabelsSelectorSheet({
    required this.accountId,
    required this.sessionId,
    required this.phoneNumber,
    super.key,
  });

  @override
  State<LabelsSelectorSheet> createState() => _LabelsSelectorSheetState();
}

class _LabelsSelectorSheetState extends State<LabelsSelectorSheet> {
  Set<String>? _selected;
  bool _saving = false;

  CollectionReference<Map<String, dynamic>> get _labelsRef => FirebaseFirestore
      .instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId)
      .collection('labels');

  DocumentReference<Map<String, dynamic>> get _chatRef => FirebaseFirestore
      .instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId)
      .collection('chats')
      .doc(widget.phoneNumber);

  Future<void> _save() async {
    if (_selected == null) return;
    setState(() => _saving = true);
    try {
      await _chatRef.set(
        {'labelIds': _selected!.toList()},
        SetOptions(merge: true),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: lightText.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Icon(Icons.label_outline, color: primaryAqua),
                  SizedBox(width: 12),
                  Text(
                    'Etiquetas del chat',
                    style: TextStyle(
                      color: white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: StreamBuilder<DocumentSnapshot>(
                stream: _chatRef.snapshots(),
                builder: (context, chatSnap) {
                  // Inicializa la selección la primera vez que llega la data.
                  if (_selected == null && chatSnap.hasData) {
                    final data =
                        chatSnap.data!.data() as Map<String, dynamic>?;
                    _selected = ((data?['labelIds'] as List?) ?? const [])
                        .whereType<String>()
                        .toSet();
                  }

                  return StreamBuilder<QuerySnapshot>(
                    stream: _labelsRef.orderBy('order').snapshots(),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const SizedBox(
                          height: 200,
                          child: Center(
                            child: CircularProgressIndicator(
                                color: primaryAqua),
                          ),
                        );
                      }

                      final labels = snap.data!.docs
                          .map((d) => ChatLabel.fromDoc(d))
                          .toList();

                      if (labels.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            children: [
                              Icon(Icons.label_off_outlined,
                                  size: 48,
                                  color: lightText.withValues(alpha: 0.5)),
                              const SizedBox(height: 12),
                              const Text(
                                'Sin etiquetas creadas',
                                style: TextStyle(
                                  color: white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Crea etiquetas desde\nAjustes de Sesión › Etiquetas',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: lightText,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: labels.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 4),
                        itemBuilder: (_, i) {
                          final l = labels[i];
                          final on = _selected?.contains(l.id) ?? false;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(() {
                              final s = _selected ?? <String>{};
                              if (on) {
                                s.remove(l.id);
                              } else {
                                s.add(l.id);
                              }
                              _selected = s;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                              decoration: BoxDecoration(
                                color: on
                                    ? primaryAqua.withValues(alpha: 0.08)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: l.color,
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      l.name,
                                      style: const TextStyle(
                                        color: white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    on
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    color: on
                                        ? primaryAqua
                                        : lightText.withValues(alpha: 0.5),
                                    size: 22,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: lightText.withValues(alpha: 0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Cancelar',
                          style: TextStyle(color: lightText)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving || _selected == null ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryAqua,
                        foregroundColor: darkBg,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: darkBg,
                              ),
                            )
                          : const Text('Guardar',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

