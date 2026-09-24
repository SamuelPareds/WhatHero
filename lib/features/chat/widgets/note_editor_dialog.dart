import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';

/// Editor de la nota/comentario del chat. Lo usan el long-press de la lista de
/// chats, la franja ámbar del chat abierto y el panel de info del contacto, así
/// el diálogo y la escritura viven en un solo lugar.
///
/// Persiste en el campo `note` del doc del chat con merge:true. Nota vacía →
/// borra el campo para que no aparezca el chip ni cuente en búsqueda.
Future<void> showChatNoteEditor({
  required BuildContext context,
  required String accountId,
  required String sessionId,
  required String phoneNumber,
  required String currentNote,
}) async {
  final controller = TextEditingController(text: currentNote);

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.sticky_note_2_outlined,
                    color: Color(0xFFF59E0B), size: 20),
                SizedBox(width: 8),
                Text(
                  'Nota del chat',
                  style: TextStyle(
                    color: white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              maxLength: 200,
              style: const TextStyle(color: white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Ej: El masajes es para dos personas',
                hintStyle: TextStyle(color: white.withValues(alpha: 0.3)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.4),
                counterStyle: const TextStyle(color: lightText, fontSize: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: lightText.withValues(alpha: 0.3)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Cancelar',
                        style: TextStyle(color: lightText)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryAqua,
                      foregroundColor: darkBg,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    child: const Text('Guardar',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (saved != true) return;

  final trimmed = controller.text.trim();
  final chatRef = FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(accountId)
      .collection('whatsapp_sessions')
      .doc(sessionId)
      .collection('chats')
      .doc(phoneNumber);

  await chatRef.set(
    {'note': trimmed.isEmpty ? FieldValue.delete() : trimmed},
    SetOptions(merge: true),
  );
}
