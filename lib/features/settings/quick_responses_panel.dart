import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';

class QuickResponsesPanel extends StatefulWidget {
  final String sessionId;
  final String accountId;

  const QuickResponsesPanel({
    required this.sessionId,
    required this.accountId,
    super.key,
  });

  @override
  State<QuickResponsesPanel> createState() => _QuickResponsesPanelState();
}

class _QuickResponsesPanelState extends State<QuickResponsesPanel> {
  late TextEditingController _titleController;
  late TextEditingController _textController;
  late TextEditingController _imageUrlController;
  List<Map<String, dynamic>> _quickResponses = [];
  bool _isSaving = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _textController = TextEditingController();
    _imageUrlController = TextEditingController();
    _loadQuickResponses();
  }

  Future<void> _loadQuickResponses() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses')
          .orderBy('order', descending: false)
          .get();

      setState(() {
        _quickResponses = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading quick responses: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addQuickResponse() async {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();
    final imageUrl = _imageUrlController.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El título es obligatorio')),
      );
      return;
    }

    if (text.isEmpty && imageUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Debes agregar texto o una imagen')),
      );
      return;
    }

    // Validate URL format if provided
    if (imageUrl.isNotEmpty) {
      try {
        Uri.parse(imageUrl);
        if (!imageUrl.startsWith('http://') && !imageUrl.startsWith('https://')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('La URL debe comenzar con http:// o https://')),
            );
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('URL de imagen inválida')),
          );
        }
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      final docRef = FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses')
          .doc();

      await docRef.set({
        'id': docRef.id,
        'title': title,
        'text': text,
        'imageUrl': imageUrl,
        'order': _quickResponses.length,
        'createdAt': FieldValue.serverTimestamp(),
      });

      _titleController.clear();
      _textController.clear();
      _imageUrlController.clear();

      await _loadQuickResponses();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Respuesta rápida agregada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _deleteQuickResponse(String id) async {
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses')
          .doc(id)
          .delete();

      await _loadQuickResponses();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Respuesta rápida eliminada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    _imageUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 400,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
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
            const SizedBox(height: 24),
            // Title Row with Close Button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Respuestas Rápidas',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: white,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: lightText),
                  tooltip: 'Cerrar',
                ),
              ],
            ),
            const SizedBox(height: 24),
            // List of existing quick responses
            if (_quickResponses.isNotEmpty) ...[
              const Text(
                'Respuestas existentes',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: lightText,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: darkBg.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  separatorBuilder: (_, __) => Divider(
                    color: primaryAqua.withValues(alpha: 0.1),
                    height: 1,
                    indent: 12,
                    endIndent: 12,
                  ),
                  itemCount: _quickResponses.length,
                  itemBuilder: (_, idx) {
                    final qr = _quickResponses[idx];
                    final hasImage = (qr['imageUrl'] as String?)?.isNotEmpty ?? false;
                    final title = qr['title'] as String? ?? '';
                    final text = qr['text'] as String? ?? '';

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    color: primaryAqua,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (text.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      text.substring(0, (text.length < 60 ? text.length : 60)),
                                      style: TextStyle(
                                        color: lightText.withValues(alpha: 0.7),
                                        fontSize: 11,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                if (hasImage)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.image,
                                          size: 14,
                                          color: primaryAqua.withValues(alpha: 0.6),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Con imagen',
                                          style: TextStyle(
                                            color: primaryAqua.withValues(alpha: 0.6),
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                            onPressed: () => _deleteQuickResponse(qr['id']),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
            ],
            // New quick response form
            const Text(
              'Crear nueva respuesta',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 12),
            // Title field
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: 'Título *',
                hintText: 'Ej: Menú de servicios',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                labelStyle: const TextStyle(color: lightText),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 12),
            // Text field
            TextField(
              controller: _textController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Texto (opcional)',
                hintText: 'Mensaje o caption para la imagen',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                labelStyle: const TextStyle(color: lightText),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 12),
            // Image URL field
            TextField(
              controller: _imageUrlController,
              decoration: InputDecoration(
                labelText: 'URL de imagen (opcional)',
                hintText: 'https://example.com/image.jpg',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                labelStyle: const TextStyle(color: lightText),
              ),
              style: const TextStyle(color: white),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '⚠️ Asegúrate de que la URL sea accesible públicamente (no requiere login)',
                style: TextStyle(
                  color: lightText.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Add button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _addQuickResponse,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  disabledBackgroundColor: primaryAqua.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(darkBg),
                        ),
                      )
                    : const Text(
                        'Agregar respuesta',
                        style: TextStyle(
                          color: darkBg,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
