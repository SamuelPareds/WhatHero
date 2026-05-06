import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

// Player global compartido: solo un audio suena a la vez (estilo WhatsApp).
// Cada burbuja se identifica por messageId; al darle play a otra burbuja, la
// anterior se pausa automáticamente porque cambia el activeMessageId.
class _AudioPlaybackController {
  static final _AudioPlaybackController instance = _AudioPlaybackController._();
  _AudioPlaybackController._() {
    // Autoloop: cuando el audio termina vuelve a empezar. Se rompe sólo
    // cuando el operador pausa o le da play a otra burbuja (que llama stop).
    player.setLoopMode(LoopMode.one);
  }

  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<String?> activeMessageId = ValueNotifier(null);

  Future<void> playUrl(String url, String messageId) async {
    if (activeMessageId.value != messageId) {
      await player.stop();
      await player.setUrl(url);
      activeMessageId.value = messageId;
    }
    await player.play();
  }

  Future<void> pause() => player.pause();
  Future<void> seek(Duration pos) => player.seek(pos);
}

class MessageBubble extends StatefulWidget {
  final String text;
  final bool fromMe;
  final DateTime timestamp;
  final String messageId;
  final String chatPhone;
  final String? sessionKey;
  final String accountId;
  // Identidad de quien envió este mensaje saliente. Sólo se muestra cuando
  // fromMe == true. Los entrantes nunca llevan etiqueta (es el cliente).
  //   - senderType: 'human' | 'ai' | 'bot' (controla el ícono asociado).
  //   - senderName: snapshot del nombre al momento del envío
  //                 (ej. 'Samuel', 'ai', 'bot', 'WhatsApp').
  // Mensajes legacy sin estos campos no muestran etiqueta (UI intacta).
  final String? senderType;
  final String? senderName;
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
  // Audio (Fase 3b): mediaIsPtt distingue nota de voz (true) de adjunto.
  // mediaDuration en segundos lo manda Baileys; se usa para mostrar 0:00 / 0:23
  // sin tener que descargar el audio.
  final bool? mediaIsPtt;
  final int? mediaDuration;
  // Video (Fase 3c): mediaIsGif marca los "GIFs" de WhatsApp (mp4 mute loop).
  final bool? mediaIsGif;
  // Reacciones (emojis nativos de WhatsApp). Map con keys 'me' / 'them' para
  // chats 1:1, valor `{ emoji: String, timestamp: Timestamp }`. El backend
  // mergea las entries; acá sólo renderizamos un chip flotante en la esquina.
  final Map<String, dynamic>? reactions;

  const MessageBubble({
    super.key,
    required this.text,
    required this.fromMe,
    required this.timestamp,
    required this.messageId,
    required this.chatPhone,
    this.sessionKey,
    required this.accountId,
    this.senderType,
    this.senderName,
    this.mediaType,
    this.mediaThumbBase64,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaUrl,
    this.mediaStatus,
    this.mediaFileName,
    this.mediaSize,
    this.mediaIsPtt,
    this.mediaDuration,
    this.mediaIsGif,
    this.reactions,
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

  // Etiqueta de autor sobre el bubble (sólo mensajes salientes con senderName).
  // 11px, gris claro, alineada a la derecha. Para 'ai' y 'bot' añade un
  // mini-icono distintivo. Para humano (incluye 'WhatsApp') va sin icono
  // para no saturar el chat con respuestas hechas a mano.
  Widget _buildSenderLabel() {
    if (!widget.fromMe) return const SizedBox.shrink();
    final name = widget.senderName;
    if (name == null || name.isEmpty) return const SizedBox.shrink();

    IconData? icon;
    Color color = lightText.withValues(alpha: 0.65);
    if (widget.senderType == 'ai') {
      icon = Icons.auto_awesome;
      color = primaryAqua.withValues(alpha: 0.75);
    } else if (widget.senderType == 'bot') {
      icon = Icons.smart_toy_outlined;
    }

    return Padding(
      padding: const EdgeInsets.only(right: 12, bottom: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            name,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
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
            _buildSenderLabel(),
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ============================================
  // Audio (Fase 3b): notas de voz y adjuntos. Player único compartido —
  // ver _AudioPlaybackController. Mientras no esté ready, mostramos spinner
  // pequeño. Una vez listo, play/pause + slider con posición/duración live.
  // ============================================
  Widget _buildAudioBubble() {
    final url = widget.mediaUrl;
    final isReady = url != null && url.isNotEmpty && widget.mediaStatus == 'ready';
    final isFailed = widget.mediaStatus == 'failed';
    final isPtt = widget.mediaIsPtt ?? false;
    final totalDuration = Duration(seconds: widget.mediaDuration ?? 0);
    final color = widget.fromMe ? darkBg : white;
    final dimColor = color.withValues(alpha: 0.7);

    Widget content;
    if (!isReady) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isPtt ? Icons.mic : Icons.audiotrack, size: 22, color: dimColor),
          const SizedBox(width: 10),
          if (isFailed)
            Text('No disponible',
                style: TextStyle(color: dimColor, fontSize: 13))
          else
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(dimColor),
              ),
            ),
          const SizedBox(width: 10),
          if (totalDuration.inSeconds > 0)
            Text(_formatDuration(totalDuration),
                style: TextStyle(color: dimColor, fontSize: 12)),
        ],
      );
    } else {
      content = ValueListenableBuilder<String?>(
        valueListenable: _AudioPlaybackController.instance.activeMessageId,
        builder: (context, activeId, _) {
          final isActive = activeId == widget.messageId;
          final player = _AudioPlaybackController.instance.player;

          return StreamBuilder<PlayerState>(
            stream: isActive ? player.playerStateStream : null,
            builder: (context, stateSnap) {
              final isPlaying = isActive && (stateSnap.data?.playing ?? false);
              return StreamBuilder<Duration>(
                stream: isActive ? player.positionStream : null,
                builder: (context, posSnap) {
                  final live = isActive ? player.duration : null;
                  final dur = (live != null && live.inMilliseconds > 0)
                      ? live
                      : totalDuration;
                  final pos = isActive ? (posSnap.data ?? Duration.zero) : Duration.zero;
                  final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
                  final value =
                      pos.inMilliseconds.clamp(0, maxMs).toDouble();

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isPtt ? Icons.mic : Icons.audiotrack,
                          size: 20, color: dimColor),
                      const SizedBox(width: 4),
                      InkResponse(
                        radius: 22,
                        onTap: () {
                          if (isPlaying) {
                            _AudioPlaybackController.instance.pause();
                          } else {
                            _AudioPlaybackController.instance
                                .playUrl(url, widget.messageId);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                            size: 32,
                            color: color,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 140,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2.5,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                            activeTrackColor: color,
                            inactiveTrackColor: dimColor.withValues(alpha: 0.3),
                            thumbColor: color,
                            overlayColor: color.withValues(alpha: 0.15),
                          ),
                          child: Slider(
                            min: 0,
                            max: maxMs.toDouble(),
                            value: value,
                            onChanged: isActive
                                ? (v) {
                                    _AudioPlaybackController.instance
                                        .seek(Duration(milliseconds: v.toInt()));
                                  }
                                : (v) {
                                    // Iniciar reproducción al tocar el slider
                                    // de una burbuja inactiva.
                                    _AudioPlaybackController.instance
                                        .playUrl(url, widget.messageId);
                                  },
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(isActive ? pos : dur),
                        style: TextStyle(color: dimColor, fontSize: 11),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      );
    }

    return GestureDetector(
      onLongPress: _showMessageOptions,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: content,
      ),
    );
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

  // ============================================
  // Video (Fase 3c): poster (jpegThumbnail) instantáneo + overlay de play.
  // Tap → abre _FullscreenVideo. Mientras no esté ready en Storage muestra
  // un spinner pequeño sobre el poster y desactiva el tap.
  // ============================================
  Widget _buildVideoBubble() {
    final thumbB64 = widget.mediaThumbBase64;
    final url = widget.mediaUrl;
    final isReady = url != null && url.isNotEmpty && widget.mediaStatus == 'ready';
    final isFailed = widget.mediaStatus == 'failed';
    final isGif = widget.mediaIsGif ?? false;
    final w = widget.mediaWidth ?? 0;
    final h = widget.mediaHeight ?? 0;
    final aspectRatio = (w > 0 && h > 0) ? (w / h) : 16 / 9;
    final dur = Duration(seconds: widget.mediaDuration ?? 0);

    return GestureDetector(
      onTap: isReady ? () => _openFullscreenVideo(url) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumbB64 != null && thumbB64.isNotEmpty)
                Image.memory(
                  base64Decode(thumbB64),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                )
              else
                Container(color: Colors.black54),
              // Velo oscuro para que el play resalte.
              Container(color: Colors.black.withValues(alpha: 0.25)),
              Center(
                child: isReady
                    ? const Icon(Icons.play_circle_fill,
                        color: Colors.white, size: 56)
                    : isFailed
                        ? const Icon(Icons.error_outline,
                            color: Color(0xFFF87171), size: 40)
                        : const SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          ),
              ),
              // Chip con duración / etiqueta GIF.
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isGif ? Icons.gif_box : Icons.videocam,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 3),
                      Text(
                        isGif
                            ? 'GIF'
                            : (dur.inSeconds > 0 ? _formatDuration(dur) : 'Video'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openFullscreenVideo(String url) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            _FullscreenVideo(url: url, loop: widget.mediaIsGif ?? false),
      ),
    );
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
        headers: await authHeaders(),
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
        headers: await authHeaders(),
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

  // Construye el chip de reacciones que flota en la esquina inferior del bubble.
  // Devuelve null si no hay reacciones — así el caller decide si dejar margen
  // extra o no. Agrupamos por emoji para mostrar contador cuando ambos lados
  // reaccionan con el mismo (👍 + 👍 → "👍 2").
  Widget? _buildReactionsChip() {
    final reactions = widget.reactions;
    if (reactions == null || reactions.isEmpty) return null;

    final emojiCounts = <String, int>{};
    for (final entry in reactions.values) {
      if (entry is! Map) continue;
      final emoji = entry['emoji'] as String?;
      if (emoji == null || emoji.isEmpty) continue;
      emojiCounts[emoji] = (emojiCounts[emoji] ?? 0) + 1;
    }
    if (emojiCounts.isEmpty) return null;

    final label = emojiCounts.entries
        .map((e) => e.value > 1 ? '${e.key} ${e.value}' : e.key)
        .join(' ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: surfaceDark,
        borderRadius: BorderRadius.circular(20),
        // Borde del color del fondo de pantalla → look "cortado" del bubble.
        border: Border.all(color: darkBg, width: 2),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13, color: white)),
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
    final isAudio = widget.mediaType == 'audio';
    final isVideo = widget.mediaType == 'video';
    final hasCaption = widget.text.isNotEmpty;
    final reactionsChip = _buildReactionsChip();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: widget.fromMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: widget.fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            _buildSenderLabel(),
            // Stack permite que el chip de reacciones flote en la esquina
            // inferior del bubble, overlapping unos píxeles para look estilo
            // WhatsApp. Clip.none deja que el chip salga del bounding box.
            Stack(
              clipBehavior: Clip.none,
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
                padding: (hasImage || isDocument || isAudio || isVideo)
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: isAudio
                    ? _buildAudioBubble()
                    : isVideo
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildVideoBubble(),
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
                    : hasImage
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
                if (reactionsChip != null)
                  Positioned(
                    // Overflow ~12px hacia abajo: el chip "abraza" la esquina
                    // inferior del bubble. Lado derecho para fromMe (queda hacia
                    // afuera del centro), izquierdo para entrantes.
                    bottom: -12,
                    right: widget.fromMe ? null : 8,
                    left: widget.fromMe ? 8 : null,
                    child: reactionsChip,
                  ),
              ],
            ),
            // Reservamos espacio extra cuando hay chip de reacciones para que
            // no choque con el timestamp (chip flota -12px abajo).
            SizedBox(height: reactionsChip != null ? 18 : 6),
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

// Visor fullscreen de video con controles propios (sin chewie).
// Autoplay al abrir, dispose al cerrar para evitar audio remanente.
class _FullscreenVideo extends StatefulWidget {
  final String url;
  final bool loop;
  const _FullscreenVideo({required this.url, required this.loop});

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.setLooping(widget.loop);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _initialized = true);
      _controller.play();
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    });
    _controller.addListener(_onPlayerUpdate);
  }

  void _onPlayerUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlayerUpdate);
    _controller.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _error != null
          ? Center(
              child: Text('No se pudo cargar el video',
                  style: const TextStyle(color: Colors.white70)),
            )
          : !_initialized
              ? const Center(
                  child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        padding: EdgeInsets.fromLTRB(
                            12, 24, 12, 16 + MediaQuery.of(context).padding.bottom),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                _controller.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                              onPressed: () {
                                if (_controller.value.isPlaying) {
                                  _controller.pause();
                                } else {
                                  _controller.play();
                                }
                              },
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: const SliderThemeData(
                                  trackHeight: 2.5,
                                  thumbShape: RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                  activeTrackColor: primaryAqua,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: primaryAqua,
                                ),
                                child: Slider(
                                  min: 0,
                                  max: _controller.value.duration.inMilliseconds
                                      .toDouble()
                                      .clamp(1, double.infinity),
                                  value: _controller.value.position.inMilliseconds
                                      .clamp(
                                          0,
                                          _controller.value.duration.inMilliseconds)
                                      .toDouble(),
                                  onChanged: (v) {
                                    _controller
                                        .seekTo(Duration(milliseconds: v.toInt()));
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${_fmt(_controller.value.position)} / ${_fmt(_controller.value.duration)}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
