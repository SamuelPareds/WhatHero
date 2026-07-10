import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
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
  late TextEditingController _searchController;
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
  String _origDocumentUrl = '';
  String _origDocumentName = '';

  // Estado de imagen del editor:
  // - _imageUrl: URL ya persistida (Storage o externa legacy)
  // - _pickedBytes: imagen recién elegida pendiente de subir (preview en memoria)
  String _imageUrl = '';
  Uint8List? _pickedBytes;
  final ImagePicker _picker = ImagePicker();
  static const int _maxImageBytes = 10 * 1024 * 1024; // tope de seguridad: 10 MB

  // Estado de documento del editor:
  // - _documentUrl: URL ya persistida
  // - _pickedDocumentBytes: documento recién elegido pendiente de subir
  String _documentUrl = '';
  String _documentName = '';
  String _documentMimeType = '';
  Uint8List? _pickedDocumentBytes;
  String _pickedDocumentName = '';
  static const int _maxDocumentBytes = 10 * 1024 * 1024; // 10 MB

  // Búsqueda en la lista
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _textController = TextEditingController();
    _searchController = TextEditingController();
    // Recalcular el estado de "Guardar" mientras se edita
    _titleController.addListener(_onFieldChanged);
    _textController.addListener(_onFieldChanged);
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });
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
        _origDocumentUrl = '';
        _origDocumentName = '';
      } else {
        _editingId = qr['id'] as String;
        _origTitle = qr['title'] as String? ?? '';
        _origText = qr['text'] as String? ?? '';
        _origImageUrl = qr['imageUrl'] as String? ?? '';
        _origDocumentUrl = qr['documentUrl'] as String? ?? '';
        _origDocumentName = qr['documentName'] as String? ?? '';
      }
      _titleController.text = _origTitle;
      _textController.text = _origText;
      _imageUrl = _origImageUrl;
      _pickedBytes = null;
      _documentUrl = _origDocumentUrl;
      _documentName = _origDocumentName;
      _documentMimeType = qr?['documentMimeType'] as String? ?? '';
      _pickedDocumentBytes = null;
      _pickedDocumentName = '';
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
      _imageUrl = '';
      _pickedBytes = null;
      _documentUrl = '';
      _documentName = '';
      _documentMimeType = '';
      _pickedDocumentBytes = null;
      _pickedDocumentName = '';
    });
  }

  // Hay imagen si hay una recién elegida (en memoria) o una URL ya persistida
  bool get _hasImage => _pickedBytes != null || _imageUrl.isNotEmpty;

  // Hay documento si hay uno recién elegido o una URL ya persistida
  bool get _hasDocument => _pickedDocumentBytes != null || _documentUrl.isNotEmpty;

  // Guardar habilitado solo si es válido y (al editar) hay cambios reales.
  // Así "si no hay cambios, no pasa nada" → el botón queda inactivo.
  bool get _canSave {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();
    final isValid = title.isNotEmpty && (text.isNotEmpty || _hasImage || _hasDocument);
    if (!isValid) return false;
    if (_editingId == null) return true; // crear: cualquier contenido válido
    // editar: exige al menos un cambio (texto, imagen o documento) respecto al original
    final imageChanged = _pickedBytes != null || _imageUrl != _origImageUrl;
    final documentChanged = _pickedDocumentBytes != null || _documentUrl != _origDocumentUrl;
    return title != _origTitle || text != _origText || imageChanged || documentChanged;
  }

  // Path determinista en Storage: un archivo por respuesta (reemplazar =
  // sobrescribir, sin huérfanos). Usa accountsCollection para respetar las
  // storage.rules (accounts/... en prod, accounts_dev/... en desarrollo).
  Reference _imageRef(String docId) => FirebaseStorage.instance.ref(
        '$accountsCollection/${widget.accountId}/whatsapp_sessions/'
        '${widget.sessionId}/quick_responses/$docId.jpg',
      );

  // Document reference: preserva extensión original para integridad
  Reference _documentRef(String docId, String ext) => FirebaseStorage.instance.ref(
        '$accountsCollection/${widget.accountId}/whatsapp_sessions/'
        '${widget.sessionId}/quick_responses/$docId.${ext.isNotEmpty ? ext.replaceFirst(RegExp(r'^\.'), '') : 'bin'}',
      );

  // Elige una imagen de la galería. image_picker ya redimensiona y recomprime
  // (maxWidth 1600 / quality 80) → archivo liviano sin librería extra.
  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      // Red de seguridad: rechazar si aún supera el tope de 10 MB
      if (bytes.length > _maxImageBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('La imagen supera el límite de 10 MB')),
          );
        }
        return;
      }

      if (mounted) setState(() => _pickedBytes = bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cargar la imagen: $e')),
        );
      }
    }
  }

  // Quita la imagen del editor (se aplica al guardar)
  void _removeImage() {
    setState(() {
      _pickedBytes = null;
      _imageUrl = '';
    });
  }

  // Validación de seguridad: rechazar tipos peligrosos
  bool _isSafeFileType(String ext) {
    final dangerous = {'exe', 'bat', 'cmd', 'com', 'scr', 'vbs', 'js', 'jar', 'app', 'deb', 'rpm'};
    return !dangerous.contains(ext.toLowerCase());
  }

  Future<void> _pickDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final f = result.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo leer el archivo')),
          );
        }
        return;
      }

      if (bytes.length > _maxDocumentBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('El documento supera el límite de 10 MB')),
          );
        }
        return;
      }

      final ext = (f.extension ?? '').toLowerCase();
      if (!_isSafeFileType(ext)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Tipo de archivo no permitido: .$ext')),
          );
        }
        return;
      }

      if (mounted) {
        setState(() {
          _pickedDocumentBytes = bytes;
          _pickedDocumentName = f.name;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar documento: $e')),
        );
      }
    }
  }

  void _removeDocument() {
    setState(() {
      _pickedDocumentBytes = null;
      _pickedDocumentName = '';
      _documentUrl = '';
      _documentName = '';
      _documentMimeType = '';
    });
  }

  Future<void> _saveQuickResponse() async {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();

    setState(() => _isSaving = true);

    try {
      final isEditing = _editingId != null;
      // Para crear necesitamos el id antes de subir archivos (path determinista)
      final docRef = isEditing ? _collectionRef.doc(_editingId) : _collectionRef.doc();
      final docId = docRef.id;

      // Resolver URL final de la imagen
      String imageUrl = _imageUrl;
      if (_pickedBytes != null) {
        final ref = _imageRef(docId);
        await ref.putData(
          _pickedBytes!,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        imageUrl = await ref.getDownloadURL();
      } else if (imageUrl.isEmpty && _origImageUrl.isNotEmpty) {
        await _deleteImageObject(docId);
      }

      // Resolver URL final del documento
      String documentUrl = _documentUrl;
      String documentName = _documentName;
      String documentMimeType = _documentMimeType;
      if (_pickedDocumentBytes != null) {
        final ext = _pickedDocumentName.contains('.')
            ? _pickedDocumentName.split('.').last
            : 'bin';
        final ref = _documentRef(docId, ext);
        await ref.putData(
          _pickedDocumentBytes!,
          SettableMetadata(contentType: 'application/octet-stream'),
        );
        documentUrl = await ref.getDownloadURL();
        documentName = _pickedDocumentName;
        documentMimeType = _getMimeType(ext);
      } else if (documentUrl.isEmpty && _origDocumentUrl.isNotEmpty) {
        await _deleteDocumentObject(docId);
      }

      if (isEditing) {
        await docRef.update({
          'title': title,
          'text': text,
          'imageUrl': imageUrl,
          'documentUrl': documentUrl,
          'documentName': documentName,
          'documentMimeType': documentMimeType,
        });
      } else {
        await docRef.set({
          'id': docId,
          'title': title,
          'text': text,
          'imageUrl': imageUrl,
          'documentUrl': documentUrl,
          'documentName': documentName,
          'documentMimeType': documentMimeType,
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

  // Borra el objeto de imagen en Storage; ignora si no existe (p.ej. respuestas
  // legacy con URL externa, que no tienen archivo en nuestro bucket).
  Future<void> _deleteImageObject(String docId) async {
    try {
      await _imageRef(docId).delete();
    } catch (_) {
      // Sin archivo o sin permiso → no es crítico, seguimos
    }
  }

  // Borra el documento en Storage; ignora si no existe
  Future<void> _deleteDocumentObject(String docId) async {
    try {
      // Intentar con extensiones comunes
      final exts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'zip', 'bin'];
      for (final ext in exts) {
        try {
          await _documentRef(docId, ext).delete();
          return;
        } catch (_) {
          // Continuar con la siguiente
        }
      }
    } catch (_) {
      // Sin archivo o sin permiso → no es crítico
    }
  }

  // Detectar MIME type basado en extensión
  String _getMimeType(String ext) {
    final mimeMap = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'csv': 'text/csv',
      'zip': 'application/zip',
    };
    return mimeMap[ext.toLowerCase()] ?? 'application/octet-stream';
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
      // Borrar también la imagen asociada en Storage (limpieza)
      await _deleteImageObject(id);
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
    _searchController.dispose();
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
                        _searchBar(),
                        ..._buildResponseTiles(),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: white),
        decoration: InputDecoration(
          hintText: 'Buscar respuestas...',
          hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
          prefixIcon: Icon(Icons.search, color: lightText.withValues(alpha: 0.5)),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: lightText.withValues(alpha: 0.5)),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: surfaceDark.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.1)),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
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

  // Construye las filas con separadores entre ellas, filtrando por búsqueda
  List<Widget> _buildResponseTiles() {
    final filtered = _quickResponses.where((qr) {
      final title = (qr['title'] as String? ?? '').toLowerCase();
      final text = (qr['text'] as String? ?? '').toLowerCase();
      final docName = (qr['documentName'] as String? ?? '').toLowerCase();
      return title.contains(_searchQuery) ||
          text.contains(_searchQuery) ||
          docName.contains(_searchQuery);
    }).toList();

    if (filtered.isEmpty && _searchQuery.isNotEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 40, color: primaryAqua.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text(
                'No se encontraron respuestas',
                style: TextStyle(color: lightText.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
      ];
    }

    final tiles = <Widget>[];
    for (var i = 0; i < filtered.length; i++) {
      if (i > 0) {
        tiles.add(Divider(
          color: primaryAqua.withValues(alpha: 0.08),
          height: 1,
          indent: 20,
          endIndent: 20,
        ));
      }
      tiles.add(_responseTile(filtered[i]));
    }
    return tiles;
  }

  Widget _responseTile(Map<String, dynamic> qr) {
    final title = qr['title'] as String? ?? '';
    final text = qr['text'] as String? ?? '';
    final hasImage = (qr['imageUrl'] as String?)?.isNotEmpty ?? false;
    final documentName = qr['documentName'] as String? ?? '';
    final hasDocument = documentName.isNotEmpty;

    // Preview: el texto si existe, si no un indicio de imagen/documento
    final preview = text.isNotEmpty ? text : (hasImage ? 'Imagen' : (hasDocument ? 'Documento' : ''));

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
                  if (preview.isNotEmpty || hasImage || hasDocument)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          if (hasImage) ...[
                            Icon(Icons.image_outlined,
                                size: 13, color: lightText.withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                          ],
                          if (hasDocument) ...[
                            Icon(Icons.description_outlined,
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
                  hint: 'Mensaje o caption para la imagen/documento',
                  maxLines: 4,
                ),
                const SizedBox(height: 20),
                _fieldLabel('Imagen (opcional)'),
                _imagePickerField(),
                const SizedBox(height: 20),
                _fieldLabel('Documento (opcional)'),
                _documentPickerField(),
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

  // Selector de imagen: muestra preview (bytes recién elegidos o URL persistida)
  // con opción de cambiar/quitar, o un área para agregar si no hay ninguna.
  Widget _imagePickerField() {
    if (_hasImage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: double.infinity,
              height: 180,
              child: _pickedBytes != null
                  ? Image.memory(_pickedBytes!, fit: BoxFit.cover)
                  : Image.network(
                      _imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: surfaceDark,
                        child: Icon(Icons.broken_image_outlined,
                            color: lightText.withValues(alpha: 0.5), size: 40),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.swap_horiz, size: 18, color: primaryAqua),
                label: const Text('Cambiar', style: TextStyle(color: primaryAqua)),
              ),
              TextButton.icon(
                onPressed: _removeImage,
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                label: const Text('Quitar', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      );
    }

    // Sin imagen: área tappable para agregar
    return InkWell(
      onTap: _pickImage,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          color: darkBg.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: 32, color: primaryAqua.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            const Text('Agregar imagen',
                style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Se optimiza automáticamente (máx. 10 MB)',
              style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  // Selector de documento: muestra nombre y tamaño si está cargado, o área para agregar
  Widget _documentPickerField() {
    if (_hasDocument) {
      final displayName = _pickedDocumentName.isNotEmpty ? _pickedDocumentName : _documentName;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: surfaceDark.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.description, size: 24, color: primaryAqua.withValues(alpha: 0.7)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(color: white, fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        (_pickedDocumentBytes?.length ?? 0) > 0
                            ? '${((_pickedDocumentBytes!.length) / (1024 * 1024)).toStringAsFixed(2)} MB'
                            : 'Documento',
                        style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _pickDocument,
                icon: const Icon(Icons.swap_horiz, size: 18, color: primaryAqua),
                label: const Text('Cambiar', style: TextStyle(color: primaryAqua)),
              ),
              TextButton.icon(
                onPressed: _removeDocument,
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                label: const Text('Quitar', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      );
    }

    // Sin documento: área tappable para agregar
    return InkWell(
      onTap: _pickDocument,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          color: darkBg.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(Icons.upload_file_outlined,
                size: 32, color: primaryAqua.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            const Text('Agregar documento',
                style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'PDF, Word, Excel, etc. (máx. 10 MB)',
              style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

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
