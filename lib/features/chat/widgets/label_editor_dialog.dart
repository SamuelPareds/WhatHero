import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';

/// Diálogo compartido para crear/editar una etiqueta. Lo usan tanto la pestaña
/// "Etiquetas" de Ajustes de Sesión como el selector de etiquetas del chat, así
/// la paleta y la lógica de guardado viven en un solo lugar.
///
/// Devuelve el ID de la etiqueta creada/editada, o `null` si el usuario cancela.
/// El selector lo usa para auto-seleccionar la etiqueta recién creada.
Future<String?> showLabelEditorDialog({
  required BuildContext context,
  required CollectionReference<Map<String, dynamic>> labelsRef,
  ChatLabel? existing,
  int nextOrder = 0,
}) async {
  final controller = TextEditingController(text: existing?.name ?? '');
  String selectedHex = existing?.colorHex ?? kLabelPalette.first.hex;

  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => Dialog(
        backgroundColor: surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existing == null ? 'Nueva etiqueta' : 'Editar etiqueta',
                style: const TextStyle(
                  color: white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: white, fontSize: 14),
                maxLength: 24,
                decoration: InputDecoration(
                  hintText: 'Ej: VIP, Urgente, Seguimiento...',
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
              const SizedBox(height: 12),
              const Text(
                'COLOR',
                style: TextStyle(
                  color: primaryAqua,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kLabelPalette.map((c) {
                  final isOn = c.hex.toUpperCase() == selectedHex.toUpperCase();
                  return GestureDetector(
                    onTap: () => setSt(() => selectedHex = c.hex),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.color,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isOn ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: isOn
                            ? [
                                BoxShadow(
                                  color: c.color.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                      child: isOn
                          ? const Icon(Icons.check,
                              color: Colors.white, size: 18)
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: lightText.withValues(alpha: 0.3)),
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
                      onPressed: () async {
                        final name = controller.text.trim();
                        if (name.isEmpty) return;
                        String resultId;
                        if (existing == null) {
                          final ref = await labelsRef.add({
                            'name': name,
                            'color': selectedHex,
                            'order': nextOrder,
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                          resultId = ref.id;
                        } else {
                          await labelsRef.doc(existing.id).update({
                            'name': name,
                            'color': selectedHex,
                          });
                          resultId = existing.id;
                        }
                        if (ctx.mounted) Navigator.pop(ctx, resultId);
                      },
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
    ),
  );
}
