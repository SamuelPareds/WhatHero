import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:crm_whatsapp/core.dart';

class MessageBubble extends StatefulWidget {
  final String text;
  final bool fromMe;
  final DateTime timestamp;
  final String messageId;
  final String chatPhone;
  final String? sessionKey;
  final String accountId;
  // Campos de media.
  // - mediaThumbBase64: jpegThumbnail inline de Baileys (Fase 1, render instantáneo).
  // - mediaUrl: URL final en Firebase Storage (Fase 2, full-res sobre la miniatura).
  // - mediaStatus: 'thumb_only' | 'ready' | 'failed'.
  final String? mediaType;
  final String? mediaThumbBase64;
  final double? mediaWidth;
  final double? mediaHeight;
  final String? mediaUrl;
  final String? mediaStatus;
  final String? mediaFileName;
  final int? mediaSize;

  const MessageBubble({
    super.key,
    required this.text,
    required this.fromMe,
    required this.timestamp,
    required this.messageId,
    required this.chatPhone,
    this.sessionKey,
    required this.accountId,
    this.mediaType,
    this.mediaThumbBase64,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaUrl,
    this.mediaStatus,
    this.mediaFileName,
    this.mediaSize,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.text);
  }

  @override
  void didUpdateWidget(MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _editController.text = widget.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  // Renderiza la imagen del mensaje. El thumbnail base64 (Baileys) actúa como
  // placeholder instantáneo; cuando llega `mediaUrl` desde Storage se monta
  // el full-res encima sin saltos de layout. Tap → visor con zoom.
  Widget _buildImageThumb() {
    final bytes = base64Decode(widget.mediaThumbBase64!);
    final w = widget.mediaWidth ?? 0;
    final h = widget.mediaHeight ?? 0;
    final aspectRatio = (w > 0 && h > 0) ? (w / h) : 1.0;

    final hasFullRes = widget.mediaUrl != null && widget.mediaUrl!.isNotEmpty;
    final isFailed = widget.mediaStatus == 'failed';

    return GestureDetector(
      onTap: hasFullRes ? () => _openFullscreen(widget.mediaUrl!) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Placeholder de Fase 1: siempre visible debajo.
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
              // Full-res cuando ya está en Storage. Mientras carga, dejamos el
              // thumb visible (loadingBuilder devuelve SizedBox transparente).
              if (hasFullRes)
                Image.network(
                  widget.mediaUrl!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const SizedBox.shrink();
                  },
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              if (isFailed)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.error_outline, size: 14, color: Color(0xFFF87171)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openFullscreen(String url) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => _FullscreenImage(url: url),
      ),
    );
  }

  // ============================================
  // Stickers (Fase 3a): render sin burbuja, tamaño fijo estilo WhatsApp.
  // ============================================
  Widget _buildStickerBubble() {
    final url = widget.mediaUrl;
    final isReady = url != null && url.isNotEmpty;
    final isFailed = widget.mediaStatus == 'failed';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: widget.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
              widget.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: _showMessageOptions,
              onTap: isReady ? () => _openFullscreen(url) : null,
              child: SizedBox(
                width: 140,
                height: 140,
                child: isReady
                    ? Image.network(
                        url,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image,
                          color: lightText,
                          size: 32,
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: surfaceDark.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: isFailed
                              ? const Icon(Icons.error_outline,
                                  color: Color(0xFFF87171), size: 24)
                              : const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor:
                                        AlwaysStoppedAnimation(primaryAqua),
                                  ),
                                ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _formatTime(widget.timestamp),
                style: const TextStyle(
                    color: lightText,
                    fontSize: 12,
                    fontWeight: FontWeight.w400),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================
  // Documentos (Fase 3a): card con icono + nombre + tamaño. Tap → abrir
  // en navegador externo / app de PDF nativa via url_launcher.
  // ============================================
  Widget _buildDocumentCard() {
    final fileName = widget.mediaFileName ?? 'Documento';
    final size = widget.mediaSize;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    IconData icon;
    if (ext == 'pdf') {
      icon = Icons.picture_as_pdf;
    } else if (ext == 'doc' || ext == 'docx') {
      icon = Icons.description;
    } else if (ext == 'xls' || ext == 'xlsx' || ext == 'csv') {
      icon = Icons.table_chart;
    } else if (ext == 'zip' || ext == 'rar' || ext == '7z') {
      icon = Icons.folder_zip;
    } else {
      icon = Icons.insert_drive_file;
    }

    final url = widget.mediaUrl;
    final canOpen =
        url != null && url.isNotEmpty && widget.mediaStatus == 'ready';
    final isFailed = widget.mediaStatus == 'failed';
    final color = widget.fromMe ? darkBg : white;
    final dimColor = color.withValues(alpha: 0.7);

    return InkWell(
      onTap: canOpen ? () => _openDocument(url) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      isFailed
                          ? 'No disponible'
                          : (size != null ? _formatSize(size) : ''),
                      style: TextStyle(color: dimColor, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            if (!canOpen && !isFailed)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(dimColor),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _openDocument(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo abrir el documento: $e'),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copiado'),
          duration: Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
        ),
      );
    }
  }

  Future<void> _editMessage() async {
    final newText = _editController.text.trim();
    if (newText.isEmpty || newText == widget.text) {
      setState(() => _isEditing = false);
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/edit-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messageId': widget.messageId,
          'chatPhone': widget.chatPhone,
          'newText': newText,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && mounted) {
        setState(() => _isEditing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mensaje editado'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al editar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  Future<void> _deleteMessage() async {
    try {
      final response = await http.post(
        Uri.parse('$backendUrl/delete-message'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messageId': widget.messageId,
          'chatPhone': widget.chatPhone,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mensaje eliminado'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 20, left: 20, right: 20),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    }
  }

  void _showMessageOptions() {
    // En mensajes con media no tiene sentido editar texto; copiar solo si hay caption.
    final hasMedia = widget.mediaType != null;
    final canCopy = widget.text.isNotEmpty;
    final canEdit = widget.fromMe && !hasMedia;

    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: primaryAqua.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy, size: 20, color: primaryAqua),
                title: const Text('Copiar', style: TextStyle(color: white)),
                onTap: () {
                  Navigator.pop(context);
                  _copyToClipboard();
                },
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit, size: 20, color: Color(0xFF10B981)),
                title: const Text('Editar', style: TextStyle(color: white)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _isEditing = true);
                },
              ),
            if (widget.fromMe)
              ListTile(
                leading: const Icon(Icons.delete, size: 20, color: Color(0xFFF87171)),
                title: const Text('Eliminar', style: TextStyle(color: white)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteConfirmation();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('Eliminar mensaje', style: TextStyle(color: white)),
        content: const Text(
          '¿Estás seguro de que deseas eliminar este mensaje para todos?',
          style: TextStyle(color: lightText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFFF87171)),
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage();
            },
            child: const Text('Eliminar', style: TextStyle(color: white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Column(
                  children: [
                    TextField(
                      controller: _editController,
                      maxLines: null,
                      autofocus: true,
                      style: const TextStyle(color: white, fontSize: 15),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: primaryAqua),
                        ),
                        filled: true,
                        fillColor: darkBg.withValues(alpha: 0.8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _isEditing = false),
                          child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: primaryAqua),
                          onPressed: _editMessage,
                          child: const Text('Guardar', style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Sticker: render alternativo sin Container de burbuja, tamaño fijo.
    if (widget.mediaType == 'sticker') {
      return _buildStickerBubble();
    }

    final hasImage = widget.mediaType == 'image' && widget.mediaThumbBase64 != null;
    final isDocument = widget.mediaType == 'document';
    final hasCaption = widget.text.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: widget.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: widget.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: _showMessageOptions,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                decoration: BoxDecoration(
                  color: widget.fromMe ? primaryAqua : surfaceDark.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(14),
                  border: widget.fromMe
                      ? null
                      : Border.all(
                          color: primaryAqua.withValues(alpha: 0.15),
                          width: 1,
                        ),
                ),
                padding: (hasImage || isDocument)
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: hasImage
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildImageThumb(),
                          if (hasCaption)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                              child: Text(
                                widget.text,
                                style: TextStyle(
                                  color: widget.fromMe ? darkBg : white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w400,
                                  height: 1.4,
                                ),
                              ),
                            ),
                        ],
                      )
                    : isDocument
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDocumentCard(),
                              if (hasCaption)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                                  child: Text(
                                    widget.text,
                                    style: TextStyle(
                                      color: widget.fromMe ? darkBg : white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w400,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : Text(
                            widget.text,
                            style: TextStyle(
                              color: widget.fromMe ? darkBg : white,
                              fontSize: 15,
                              fontWeight: FontWeight.w400,
                              height: 1.4,
                            ),
                          ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _formatTime(widget.timestamp),
                style: const TextStyle(
                  color: lightText,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Visor fullscreen con zoom/pan. Sin deps extra: usamos el InteractiveViewer
// que ya viene en Flutter.
class _FullscreenImage extends StatelessWidget {
  final String url;
  const _FullscreenImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
              );
            },
            errorBuilder: (_, __, ___) => const Text(
              'No se pudo cargar la imagen',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}
