import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/utils/media_mime.dart';
import 'package:crm_whatsapp/core/utils/quick_response_attachment.dart';
import 'package:crm_whatsapp/features/chat/widgets/fullscreen_video.dart';

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
  QrAttachment _origAttach = QrAttachment.none;
  // El doc crudo que se está editando. Se guarda entero porque al salvar hay
  // que saber qué objetos de Storage tenía antes para borrar los que sobran.
  Map<String, dynamic> _origDoc = const {};

  // El adjunto del editor: imagen O video O documento, nunca dos.
  //
  // La exclusividad no necesita lógica de cruce porque hay un solo slot:
  // elegir cualquier cosa pisa lo que hubiera. Es la misma regla de WhatsApp
  // (un media por mensaje) y la del backend, que manda el primero de
  // `documentUrl > videoUrl > imageUrl` y descarta el resto en silencio.
  //
  // - `_attach.url` vacía + `_pickedBytes` != null → recién elegido, sin subir
  // - `_attach.url` con valor → ya persistido en Storage
  QrAttachment _attach = QrAttachment.none;
  Uint8List? _pickedBytes;
  String _pickedName = '';

  final ImagePicker _picker = ImagePicker();

  // Topes por tipo. El de video es el límite documentado de WhatsApp para
  // video; los otros dos venían de antes.
  static const int _maxImageBytes = 10 * 1024 * 1024;
  static const int _maxVideoBytes = 16 * 1024 * 1024;
  static const int _maxDocumentBytes = 10 * 1024 * 1024;

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
      _editingId = qr?['id'] as String?;
      _origTitle = qr?['title'] as String? ?? '';
      _origText = qr?['text'] as String? ?? '';
      _origDoc = qr ?? const {};
      // Un doc legacy puede traer imagen Y documento a la vez. attachmentFromDoc
      // resuelve cuál es "el" adjunto con la misma prioridad que usaría el
      // backend al enviarlo, para que el editor muestre lo que realmente sale.
      _origAttach = attachmentFromDoc(_origDoc);

      _titleController.text = _origTitle;
      _textController.text = _origText;
      _attach = _origAttach;
      _pickedBytes = null;
      _pickedName = '';
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
      _origDoc = const {};
      _origAttach = QrAttachment.none;
      _attach = QrAttachment.none;
      _pickedBytes = null;
      _pickedName = '';
    });
  }

  // Guardar habilitado solo si es válido y (al editar) hay cambios reales.
  // Así "si no hay cambios, no pasa nada" → el botón queda inactivo.
  bool get _canSave {
    final title = _titleController.text.trim();
    final text = _textController.text.trim();
    final isValid = title.isNotEmpty && (text.isNotEmpty || _attach.isNotEmpty);
    if (!isValid) return false;
    if (_editingId == null) return true; // crear: cualquier contenido válido
    // editar: exige al menos un cambio real respecto al original
    final attachChanged = _pickedBytes != null ||
        _attach.kind != _origAttach.kind ||
        _attach.url != _origAttach.url;
    return title != _origTitle || text != _origText || attachChanged;
  }

  // Path determinista en Storage: un archivo por respuesta (reemplazar =
  // sobrescribir, sin huérfanos). Usa accountsCollection para respetar las
  // storage.rules (accounts/... en prod, accounts_dev/... en desarrollo).
  //
  // La extensión es la del archivo real: si fuera fija, un png subido desde la
  // web quedaría servido como .jpg y un video como un archivo sin tipo.
  Reference _attachRef(String docId, String ext) => FirebaseStorage.instance.ref(
        '$accountsCollection/${widget.accountId}/whatsapp_sessions/'
        '${widget.sessionId}/quick_responses/$docId.${ext.isNotEmpty ? ext : 'bin'}',
      );

  // El nombre a mostrar del adjunto: el del archivo recién elegido, o el que
  // quedó guardado al subirlo.
  String get _attachDisplayName =>
      _pickedName.isNotEmpty ? _pickedName : _attach.name;

  String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Rechaza lo que no entra, diciendo cuánto pesa y cuánto cabe: con sólo el
  // límite el operador no sabe si le sobra un poco o si eligió el archivo
  // equivocado.
  bool _fits(int size, int limit, String what) {
    if (size <= limit) return true;
    _toast('$what pesa ${_megabytes(size)} MB y el límite es '
        '${limit ~/ (1024 * 1024)} MB');
    return false;
  }

  // Deja el adjunto elegido pendiente de subir, pisando el que hubiera.
  void _setPicked(QrAttachKind kind, Uint8List bytes, String name) {
    if (!mounted) return;
    setState(() {
      _attach = QrAttachment(kind: kind);
      _pickedBytes = bytes;
      _pickedName = name;
    });
  }

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
      // Red de seguridad: el picker recomprime, pero un original enorme puede
      // seguir pasándose.
      if (!_fits(bytes.length, _maxImageBytes, 'La imagen')) return;

      _setPicked(QrAttachKind.image, bytes, picked.name);
    } catch (e) {
      _toast('No se pudo cargar la imagen: $e');
    }
  }

  // Elige un video de la galería.
  //
  // Va SIN `maxDuration` y sin recomprimir a propósito: Baileys sube a
  // WhatsApp exactamente los bytes que le damos, así que no tocar el archivo
  // es lo que hace que el cliente reciba el video en su calidad original. No
  // hay un flag "HD" que activar — hay un original que no hay que estropear.
  Future<void> _pickVideo() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!_fits(bytes.length, _maxVideoBytes, 'El video')) return;

      _setPicked(QrAttachKind.video, bytes, picked.name);
    } catch (e) {
      _toast('No se pudo cargar el video: $e');
    }
  }

  // Validación de seguridad: rechazar tipos peligrosos
  bool _isSafeFileType(String ext) {
    final dangerous = {'exe', 'bat', 'cmd', 'com', 'scr', 'vbs', 'js', 'jar', 'app', 'deb', 'rpm'};
    return !dangerous.contains(ext.toLowerCase());
  }

  Future<void> _pickDocument() async {
    try {
      final f = await FilePicker.pickFile();
      if (f == null) return;

      final bytes = await f.readAsBytes();
      if (!_fits(bytes.length, _maxDocumentBytes, 'El documento')) return;

      final ext = fileExtension(f.name);
      if (!_isSafeFileType(ext)) {
        _toast('Tipo de archivo no permitido: .$ext');
        return;
      }

      _setPicked(QrAttachKind.document, bytes, f.name);
    } catch (e) {
      _toast('Error al cargar documento: $e');
    }
  }

  // Quita el adjunto del editor (se aplica al guardar)
  void _removeAttachment() {
    setState(() {
      _attach = QrAttachment.none;
      _pickedBytes = null;
      _pickedName = '';
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

      // Subir el adjunto recién elegido, si lo hay. Si no, lo que esté en
      // `_attach` ya está en Storage (o no hay adjunto).
      var attach = _attach;
      String? uploadedPath;
      if (_pickedBytes != null) {
        final ext = fileExtension(_pickedName);
        final mime = mimeForExtension(ext, fallback: _defaultMime(attach.kind));
        final ref = _attachRef(docId, ext);
        await ref.putData(_pickedBytes!, SettableMetadata(contentType: mime));
        uploadedPath = ref.fullPath;
        attach = QrAttachment(
          kind: attach.kind,
          url: await ref.getDownloadURL(),
          name: _pickedName,
          mimeType: mime,
        );
      }

      final data = {
        'title': title,
        'text': text,
        ...attachmentFields(attach),
      };
      if (isEditing) {
        await docRef.update(data);
      } else {
        await docRef.set({
          ...data,
          'id': docId,
          'order': _quickResponses.length,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // Recién con el doc ya escrito: si el borrado falla, lo peor que queda
      // es un archivo de más, no una respuesta apuntando a un archivo muerto.
      await _deleteStorageObjects(
        orphanAttachmentUrls(_origDoc, attach),
        keepPath: uploadedPath,
      );

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

  // Borra objetos de Storage por su URL de descarga. Nunca es crítico: un
  // archivo huérfano no rompe nada, y frenar el guardado por eso sí.
  //
  // [keepPath] protege lo que se acaba de subir. Sobrescribir un path regenera
  // el token de descarga, así que la URL vieja del doc y la nueva son
  // distintas aunque apunten al mismo objeto — sin este guard, reemplazar una
  // imagen por otra imagen borraría la que se acaba de subir.
  Future<void> _deleteStorageObjects(
    Iterable<String> urls, {
    String? keepPath,
  }) async {
    for (final url in urls) {
      try {
        final ref = FirebaseStorage.instance.refFromURL(url);
        if (ref.fullPath == keepPath) continue;
        await ref.delete();
      } catch (_) {
        // URL externa legacy (no es de nuestro bucket), archivo ya borrado o
        // sin permiso → seguimos.
      }
    }
  }

  // El MIME con el que subir cuando la extensión no está en la tabla. Importa
  // sobre todo para el video: con el genérico, WhatsApp lo trataría como
  // archivo adjunto en vez de reproducirlo.
  String _defaultMime(QrAttachKind kind) => switch (kind) {
        QrAttachKind.image => 'image/jpeg',
        QrAttachKind.video => 'video/mp4',
        QrAttachKind.document || QrAttachKind.none => 'application/octet-stream',
      };

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
      // Borrar también el adjunto en Storage. Antes sólo se limpiaba la
      // imagen, así que cada respuesta con documento dejaba un huérfano.
      await _deleteStorageObjects(
        orphanAttachmentUrls(_origDoc, QrAttachment.none),
      );
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
      // El nombre del archivo adjunto, sea documento o video: buscar
      // "catalogo.pdf" o "demo.mp4" tiene que encontrar su respuesta.
      final fileName = attachmentFromDoc(qr).name.toLowerCase();
      return title.contains(_searchQuery) ||
          text.contains(_searchQuery) ||
          fileName.contains(_searchQuery);
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
    final attach = attachmentFromDoc(qr);

    // Preview: el texto si existe, si no el tipo de adjunto
    final preview = text.isNotEmpty ? text : _attachLabel(attach.kind);

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
                  if (preview.isNotEmpty || attach.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        children: [
                          if (attach.isNotEmpty) ...[
                            Icon(_attachIcon(attach.kind, outlined: true),
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
                  hint: 'Mensaje o caption del adjunto',
                  maxLines: 4,
                ),
                const SizedBox(height: 20),
                _fieldLabel('Adjunto (opcional)'),
                _attachmentField(),
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

  String _attachLabel(QrAttachKind kind) => switch (kind) {
        QrAttachKind.image => 'Imagen',
        QrAttachKind.video => 'Video',
        QrAttachKind.document => 'Documento',
        QrAttachKind.none => '',
      };

  IconData _attachIcon(QrAttachKind kind, {bool outlined = false}) =>
      switch (kind) {
        QrAttachKind.image =>
          outlined ? Icons.image_outlined : Icons.image_rounded,
        QrAttachKind.video =>
          outlined ? Icons.videocam_outlined : Icons.videocam_rounded,
        QrAttachKind.document =>
          outlined ? Icons.description_outlined : Icons.description,
        QrAttachKind.none => Icons.attach_file,
      };

  // La sección de adjunto: un solo slot.
  //
  // Sin adjunto se ven las tres opciones; con uno elegido se ve sólo ése. Esa
  // es toda la explicación de la exclusividad — no hace falta un texto que
  // diga "sólo puedes elegir uno" si nunca hay dos casillas abiertas.
  Widget _attachmentField() =>
      _attach.isEmpty ? _attachmentChooser() : _attachmentPreview();

  Widget _attachmentChooser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _attachOption(
                icon: Icons.add_photo_alternate_outlined,
                label: 'Imagen',
                onTap: _pickImage,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _attachOption(
                icon: Icons.video_call_outlined,
                label: 'Video',
                onTap: _pickVideo,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _attachOption(
                icon: Icons.upload_file_outlined,
                label: 'Documento',
                onTap: _pickDocument,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            // El video es el único que se manda tal cual, y conviene decirlo:
            // es lo que hace que llegue en la calidad original.
            'Imagen y documento hasta 10 MB · Video hasta 16 MB, '
            'se envía sin recomprimir',
            style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _attachOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: darkBg.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 26, color: primaryAqua.withValues(alpha: 0.7)),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: primaryAqua,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachmentPreview() {
    // "Cambiar" reabre el picker del mismo tipo; para cambiar de tipo se quita
    // primero y vuelven a aparecer las tres opciones.
    final repick = switch (_attach.kind) {
      QrAttachKind.image => _pickImage,
      QrAttachKind.video => _pickVideo,
      QrAttachKind.document || QrAttachKind.none => _pickDocument,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_attach.kind == QrAttachKind.image) _imagePreview() else _fileCard(),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: repick,
              icon: const Icon(Icons.swap_horiz, size: 18, color: primaryAqua),
              label: const Text('Cambiar', style: TextStyle(color: primaryAqua)),
            ),
            TextButton.icon(
              onPressed: _removeAttachment,
              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              label: const Text('Quitar', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _imagePreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: double.infinity,
        height: 180,
        child: _pickedBytes != null
            ? Image.memory(_pickedBytes!, fit: BoxFit.cover)
            : Image.network(
                _attach.url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: surfaceDark,
                  child: Icon(Icons.broken_image_outlined,
                      color: lightText.withValues(alpha: 0.5), size: 40),
                ),
              ),
      ),
    );
  }

  // Tarjeta para video y documento: icono, nombre y tamaño.
  //
  // Un video ya guardado se reproduce con un tap. Es la única forma de
  // confirmar que la plantilla es el video correcto: el nombre del archivo no
  // alcanza cuando son "IMG_4821.mov" e "IMG_4822.mov".
  Widget _fileCard() {
    final playable = _attach.kind == QrAttachKind.video && _attach.url.isNotEmpty;
    final subtitle = _pickedBytes != null
        ? '${_megabytes(_pickedBytes!.length)} MB'
        : (playable ? 'Toca para reproducir' : _attachLabel(_attach.kind));

    return InkWell(
      onTap: playable ? _playAttachedVideo : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: surfaceDark.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(_attachIcon(_attach.kind),
                size: 24, color: primaryAqua.withValues(alpha: 0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _attachDisplayName.isNotEmpty
                        ? _attachDisplayName
                        : _attachLabel(_attach.kind),
                    style: const TextStyle(
                        color: white, fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: lightText.withValues(alpha: 0.6), fontSize: 11),
                  ),
                ],
              ),
            ),
            if (playable)
              Icon(Icons.play_circle_outline,
                  size: 26, color: primaryAqua.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }

  void _playAttachedVideo() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => FullscreenVideo(url: _attach.url, loop: false),
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
