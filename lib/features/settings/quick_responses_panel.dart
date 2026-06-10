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

  // Vista activa: false = lista, true = editor (estilo WhatsApp iOS)
  bool _showEditor = false;
  // Si es null → estamos creando; si tiene id → editando esa respuesta
  String? _editingId;
  // Snapshot de los valores originales para detectar cambios (habilita Guardar)
  String _origTitle = '';
  String _origText = '';
  String _origImageUrl = '';

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _textController = TextEditingController();
    _imageUrlController = TextEditingController();
    // Recalcular el estado de "Guardar" mientras se edita
    _titleController.addListener(_onFieldChanged);
    _textController.addListener(_onFieldChanged);
    _imageUrlController.addListener(_onFieldChanged);
    _loadQuickResponses();
  }

  void _onFieldChanged() {
    if (_showEditor && mounted) setState(() {});
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

  // Referencia a la colección de respuestas rápidas de esta sesión
  CollectionReference<Map<String, dynamic>> get _collectionRef =>
      FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses');

  // Abre el editor: con qr=null crea una nueva; con qr edita la existente
  void _openEditor([Map<String, dynamic>? qr]) {
    setState(() {
      if (qr == null) {
        _editingId = null;
        _origTitle = '';
        _origText = '';
        _origImageUrl = '';
      } else {
        _editingId = qr['id'] as String;
        _origTitle = qr['title'] as String? ?? '';
        _origText = qr['text'] as String? ?? '';
        _origImageUrl = qr['imageUrl'] as String? ?? '';
      }
      _titleController.text = _origTitle;
      _textController.text = _origText;
      _imageUrlController.text = _origImageUrl;
      _showEditor = true;
    });
  }

  // Vuelve a la lista descartando el estado del editor
  void _closeEditor() {
    setState(() {
      _showEditor = false;
      _editingId = null;
      _titleController.clear();
      _textController.clear();
      _imageUrlController.clear();
    });
  }

  // Guardar habilitado solo si es válido y (al editar) hay cambios reales.
  // Así "si no hay cambios, no pasa nada" → el botón queda inactivo.
  bool get _canSave {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();
    final imageUrl = _imageUrlController.text.trim();
    final isValid = title.isNotEmpty && (text.isNotEmpty || imageUrl.isNotEmpty);
    if (!isValid) return false;
    if (_editingId == null) return true; // crear: cualquier contenido válido
    // editar: exige al menos un cambio respecto al original
    return title != _origTitle || text != _origText || imageUrl != _origImageUrl;
  }

  Future<void> _saveQuickResponse() async {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();
    final imageUrl = _imageUrlController.text.trim();

    // Validar formato de URL si se proporcionó
    if (imageUrl.isNotEmpty) {
      final validScheme =
          imageUrl.startsWith('http://') || imageUrl.startsWith('https://');
      if (!validScheme || Uri.tryParse(imageUrl) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La URL debe comenzar con http:// o https://')),
        );
        return;
      }
    }

    setState(() => _isSaving = true);

    try {
      final isEditing = _editingId != null;

      if (isEditing) {
        // Editar: solo campos editables, preservando 'order' y 'createdAt'
        await _collectionRef.doc(_editingId).update({
          'title': title,
          'text': text,
          'imageUrl': imageUrl,
        });
      } else {
        // Crear: doc nuevo con order al final y timestamp del servidor
        final docRef = _collectionRef.doc();
        await docRef.set({
          'id': docRef.id,
          'title': title,
          'text': text,
          'imageUrl': imageUrl,
          'order': _quickResponses.length,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      await _loadQuickResponses();

      if (mounted) {
        _closeEditor();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isEditing ? 'Respuesta rápida actualizada' : 'Respuesta rápida agregada',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // Confirma antes de borrar (acción destructiva, estilo WhatsApp)
  Future<void> _confirmDelete() async {
    final id = _editingId;
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('Eliminar respuesta', style: TextStyle(color: white)),
        content: const Text(
          '¿Seguro que quieres eliminar esta respuesta rápida? Esta acción no se puede deshacer.',
          style: TextStyle(color: lightText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _collectionRef.doc(id).delete();
      await _loadQuickResponses();
      if (mounted) {
        _closeEditor();
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
    // Sheet alto para sensación full-screen estilo iOS, con la identidad
    // visual de WhatHero (fondo navy, no el negro por defecto del sheet)
    final height = MediaQuery.of(context).size.height * 0.9;
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: darkBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _showEditor ? _buildEditor() : _buildList(),
      ),
    );
  }

  // ────────────────────────────── Vista lista ──────────────────────────────
  Widget _buildList() {
    return Column(
      key: const ValueKey('list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabHandle(),
        // Header: cerrar · título · botón "+" sutil para crear
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: lightText),
                tooltip: 'Cerrar',
              ),
              const Expanded(
                child: Text(
                  'Respuestas rápidas',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: white,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add, color: primaryAqua),
                tooltip: 'Crear respuesta',
              ),
            ],
          ),
        ),
        Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _quickResponses.isEmpty
                  ? _emptyState()
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        _instructions(),
                        ..._buildResponseTiles(),
                      ],
                    ),
        ),
      ],
    );
  }

  // Bloque de instrucciones de uso (cómo disparar una respuesta rápida)
  Widget _instructions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: primaryAqua.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.15)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lightbulb_outline, size: 18, color: primaryAqua.withValues(alpha: 0.8)),
            const SizedBox(width: 10),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: TextStyle(
                    color: lightText.withValues(alpha: 0.85),
                    fontSize: 13,
                    height: 1.4,
                  ),
                  children: const [
                    TextSpan(text: 'Para usar una respuesta, escribe '),
                    TextSpan(
                      text: '"/"',
                      style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' en el chat y elige una de la lista. '
                        'Toca cualquier respuesta de abajo para editarla, o '),
                    TextSpan(
                      text: '"+"',
                      style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' para crear una nueva.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Construye las filas con separadores entre ellas
  List<Widget> _buildResponseTiles() {
    final tiles = <Widget>[];
    for (var i = 0; i < _quickResponses.length; i++) {
      if (i > 0) {
        tiles.add(Divider(
          color: primaryAqua.withValues(alpha: 0.08),
          height: 1,
          indent: 20,
          endIndent: 20,
        ));
      }
      tiles.add(_responseTile(_quickResponses[i]));
    }
    return tiles;
  }

  Widget _responseTile(Map<String, dynamic> qr) {
    final title = qr['title'] as String? ?? '';
    final text = qr['text'] as String? ?? '';
    final hasImage = (qr['imageUrl'] as String?)?.isNotEmpty ?? false;
    // Preview: el texto si existe, si no un indicio de imagen
    final preview = text.isNotEmpty ? text : (hasImage ? 'Imagen' : '');

    return InkWell(
      onTap: () => _openEditor(qr),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (preview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          // Mini-glifo de imagen: único indicador que sí informa
                          if (hasImage) ...[
                            Icon(Icons.image_outlined,
                                size: 13, color: lightText.withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              preview,
                              style: TextStyle(
                                color: lightText.withValues(alpha: 0.7),
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: lightText.withValues(alpha: 0.4), size: 22),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flash_on, size: 48, color: primaryAqua.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            const Text(
              'Aún no tienes respuestas rápidas',
              textAlign: TextAlign.center,
              style: TextStyle(color: white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Crea plantillas reutilizables para responder más rápido. Úsalas escribiendo "/" en el chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, color: darkBg, size: 20),
              label: const Text('Crear respuesta',
                  style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryAqua,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────── Vista editor ─────────────────────────────
  Widget _buildEditor() {
    final isEditing = _editingId != null;
    return Column(
      key: const ValueKey('editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabHandle(),
        // Header iOS: Cancelar · título · Guardar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              TextButton(
                onPressed: _isSaving ? null : _closeEditor,
                child: const Text('Cancelar', style: TextStyle(color: lightText)),
              ),
              Expanded(
                child: Text(
                  isEditing ? 'Editar respuesta' : 'Nueva respuesta',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: white,
                  ),
                ),
              ),
              TextButton(
                onPressed: (_canSave && !_isSaving) ? _saveQuickResponse : null,
                child: _isSaving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: primaryAqua),
                      )
                    : Text(
                        'Guardar',
                        style: TextStyle(
                          color: _canSave ? primaryAqua : lightText.withValues(alpha: 0.4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
        Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _fieldLabel('Título'),
                _textField(
                  controller: _titleController,
                  hint: 'Ej: Menú de servicios',
                ),
                const SizedBox(height: 20),
                _fieldLabel('Mensaje'),
                _textField(
                  controller: _textController,
                  hint: 'Mensaje o caption para la imagen',
                  maxLines: 4,
                ),
                const SizedBox(height: 20),
                _fieldLabel('URL de imagen (opcional)'),
                _textField(
                  controller: _imageUrlController,
                  hint: 'https://example.com/image.jpg',
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '⚠️ La URL debe ser accesible públicamente (sin login).',
                    style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 11),
                  ),
                ),
                // Eliminar solo tiene sentido al editar una existente
                if (isEditing) ...[
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _confirmDelete,
                      icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      label: const Text('Eliminar',
                          style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ────────────────────────────── Helpers UI ───────────────────────────────
  Widget _grabHandle() => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: lightText.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: lightText,
          ),
        ),
      );

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
        filled: true,
        fillColor: darkBg.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
