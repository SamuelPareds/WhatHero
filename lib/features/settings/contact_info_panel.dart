import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/chat/widgets/label_chip.dart';
import 'package:crm_whatsapp/features/chat/widgets/labels_selector_sheet.dart';
import 'package:crm_whatsapp/features/chat/widgets/note_editor_dialog.dart';

// Info del contacto. Ocupa toda la altura: en móvil como hoja a pantalla
// completa y en escritorio como panel a la derecha del chat (o encima de él si
// no cabe al lado). Quien lo abre decide cómo se cierra, igual que la bandeja
// del equipo.
class ContactInfoPanel extends StatelessWidget {
  final String phoneNumber;
  final String sessionId;
  final String accountId;
  final VoidCallback onClose;
  final IconData closeIcon;

  const ContactInfoPanel({
    required this.phoneNumber,
    required this.sessionId,
    required this.accountId,
    required this.onClose,
    required this.closeIcon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // Scaffold propio para que el aviso "Número copiado" se vea: un SnackBar
    // sólo se pinta en los Scaffold raíz, y en móvil el de la pantalla del
    // chat queda tapado por esta hoja a pantalla completa.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: surfaceDark,
          border: Border(
            left: BorderSide(color: primaryAqua.withValues(alpha: 0.1)),
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(closeIcon, size: 20),
                    color: lightText,
                    tooltip: 'Cerrar',
                    onPressed: onClose,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Info. del contacto',
                    style: TextStyle(
                      color: white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<DocumentSnapshot>(
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
                    return const Center(child: CircularProgressIndicator());
                  }

                  final chatData =
                      snapshot.data!.data() as Map<String, dynamic>?;
                  // Nombre de agenda: el backend sólo guarda `contact.name`,
                  // nunca el pushName. Vacío si no lo tenemos agregado.
                  final contactName =
                      (chatData?['contactName'] as String? ?? '').trim();
                  final assignedIds =
                      ((chatData?['labelIds'] as List?) ?? const [])
                          .whereType<String>()
                          .toList();
                  final note = (chatData?['note'] as String? ?? '').trim();

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    children: [
                      _ContactHeader(
                        phoneNumber: phoneNumber,
                        contactName: contactName,
                      ),
                      const SizedBox(height: 32),
                      // Nota y etiquetas van arriba: es lo que se viene a
                      // editar aquí sin tener que volver a la lista.
                      _NoteSection(
                        accountId: accountId,
                        sessionId: sessionId,
                        phoneNumber: phoneNumber,
                        note: note,
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
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Avatar + nombre de agenda (si lo hay) + número. Tocar el nombre o el número
// copia el número.
class _ContactHeader extends StatelessWidget {
  final String phoneNumber;
  final String contactName;

  const _ContactHeader({required this.phoneNumber, required this.contactName});

  void _copyPhone(BuildContext context) {
    // Copia solo los últimos 10 dígitos (número local sin lada de país ni
    // sufijos de WhatsApp).
    final digits = phoneNumber.replaceAll(RegExp(r'\D'), '');
    final last10 = digits.length > 10
        ? digits.substring(digits.length - 10)
        : digits;
    Clipboard.setData(ClipboardData(text: last10));
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasName = contactName.isNotEmpty;
    final initial = hasName
        ? contactName.characters.first.toUpperCase()
        : (phoneNumber.isEmpty ? '?' : phoneNumber.substring(0, 1));

    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: primaryAqua.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Text(
              initial,
              style: const TextStyle(
                color: primaryAqua,
                fontWeight: FontWeight.w700,
                fontSize: 36,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () => _copyPhone(context),
          child: Column(
            children: [
              if (hasName) ...[
                Text(
                  contactName,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: white,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                phoneNumber,
                style: hasName
                    ? const TextStyle(fontSize: 15, color: lightText)
                    : const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: white,
                      ),
              ),
              if (!hasName) ...[
                const SizedBox(height: 8),
                const Text(
                  'Contacto de WhatsApp',
                  style: TextStyle(fontSize: 13, color: lightText),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// Card con la nota del chat + botón para añadirla o editarla. La nota llega del
// doc del chat que el panel ya escucha, así que se refresca sola al guardar.
class _NoteSection extends StatelessWidget {
  final String accountId;
  final String sessionId;
  final String phoneNumber;
  final String note;

  static const Color _amber = Color(0xFFF59E0B);

  const _NoteSection({
    required this.accountId,
    required this.sessionId,
    required this.phoneNumber,
    required this.note,
  });

  void _openEditor(BuildContext context) {
    showChatNoteEditor(
      context: context,
      accountId: accountId,
      sessionId: sessionId,
      phoneNumber: phoneNumber,
      currentNote: note,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasNote = note.isNotEmpty;

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
                  'Nota',
                  style: TextStyle(
                    fontSize: 12,
                    color: lightText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _openEditor(context),
                icon: Icon(hasNote ? Icons.edit_outlined : Icons.add,
                    size: 14, color: primaryAqua),
                label: Text(
                  hasNote ? 'Editar' : 'Añadir',
                  style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.bold),
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
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openEditor(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: hasNote
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.sticky_note_2_outlined, size: 16, color: _amber),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            note,
                            style: const TextStyle(
                              color: _amber,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Text(
                      'Sin nota. Toca "Añadir" para escribir una.',
                      style: TextStyle(
                        color: lightText.withValues(alpha: 0.7),
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
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
      // Con muchas etiquetas la hoja crece: que no se meta bajo la barra
      // de estado.
      useSafeArea: true,
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
