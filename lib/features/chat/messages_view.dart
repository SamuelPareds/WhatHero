import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'widgets/message_bubble.dart';

// Draft de "responder a este mensaje". Vive en MessagesView mientras el
// usuario está componiendo la respuesta — al enviar (o cancelar) se limpia.
// El bubble dispara su set vía callback; el composer renderiza la franja
// de preview y manda los campos al backend al enviar.
class ReplyDraft {
  final String messageId;
  final String text;
  final bool fromMe;
  const ReplyDraft({required this.messageId, required this.text, required this.fromMe});
}

class MessagesView extends StatefulWidget {
  final String phoneNumber;
  final String sessionId;
  final String? sessionKey;
  final String accountId;
  // Master switch del auto-responder a nivel sesión (`ai_enabled` en Firestore).
  // Distinto de `sessionAiHasCredentials`: el asistente puede estar configurado
  // (con API key válida) pero apagado a propósito para no responder solo.
  final bool sessionAiEnabled;
  // Hay API key cargada para el provider activo. Habilita el "modo copiloto":
  // el operador puede Sugerir respuesta con IAs manuales aunque el auto-responder
  // esté apagado. Si es false, el botón queda en estado "sin config" y guía
  // al usuario a SessionSettingsPanel.
  final bool sessionAiHasCredentials;

  // Salto a un mensaje concreto (deep-link desde el buscador). Con el timestamp
  // se calcula cuánto historial cargar para incluirlo; null = abrir normal.
  final String? jumpToMessageId;
  final DateTime? jumpToTimestamp;
  // Aviso al padre de que el salto ya se resolvió (encontrado o no) para que
  // limpie su estado y un re-toque del mismo resultado vuelva a disparar.
  final VoidCallback? onJumpConsumed;

  const MessagesView({
    required this.phoneNumber,
    required this.sessionId,
    this.sessionKey,
    required this.accountId,
    required this.sessionAiEnabled,
    required this.sessionAiHasCredentials,
    this.jumpToMessageId,
    this.jumpToTimestamp,
    this.onJumpConsumed,
    super.key,
  });

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // 📌 Paginación / Infinite Scroll
  int _messageLimit = 30;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  // Flecha flotante para volver al mensaje más reciente; visible solo cuando el
  // usuario se aleja del fondo revisando el historial.
  bool _showScrollToBottom = false;

  // 🎯 Salto a un mensaje (deep-link desde el buscador).
  // _pendingJumpId: objetivo aún no localizado en la lista cargada.
  // _highlightId: burbuja resaltándose ahora (tinte aqua que se desvanece).
  // _jumpKey: ancla para Scrollable.ensureVisible sobre la burbuja objetivo.
  // _jumpPreparing: evita relanzar el count() mientras una preparación corre.
  String? _pendingJumpId;
  String? _highlightId;
  final GlobalKey _jumpKey = GlobalKey();
  bool _jumpPreparing = false;
  // Verdadero mientras hacemos el scroll programático hacia el objetivo, para
  // que _scrollListener no confunda el salto con "el usuario llegó arriba" y
  // dispare paginación de más.
  bool _jumpScrolling = false;
  Timer? _highlightTimer;

  bool _isSending = false;
  bool _isGenerating = false;
  String _quickResponseFilter = '';
  OverlayEntry? _quickResponseOverlay;
  // Rango del token "/filtro" activo en el composer (para reemplazarlo en su
  // sitio al insertar, sin pisar el resto del texto). Se guarda al escribir
  // porque al tocar el overlay el TextField puede perder el foco/selección.
  TextRange? _activeTokenRange;

  // Seguimiento de ventas: si este chat fue encolado por el agente, al abrirlo
  // pre-llenamos el composer con el borrador y mostramos un cintillo. true
  // mientras el borrador sigue "vivo" (no enviado ni descartado). ValueNotifier
  // para rebuildar solo el cintillo, no todo el composer.
  final ValueNotifier<bool> _isFollowupChat = ValueNotifier(false);
  // Guard para pre-llenar el borrador una sola vez por apertura del chat.
  bool _followupChecked = false;

  // Draft de cita activo. null = no estamos respondiendo a nada → composer
  // normal. ValueNotifier (en lugar de setState) para que solo se rebuilden
  // las partes que escuchan: la franja del composer y el TextField.
  final ValueNotifier<ReplyDraft?> _replyDraft = ValueNotifier(null);
  // FocusNode del input → al activar un draft hacemos focus para que el
  // teclado salte automáticamente, sin requerir tap extra.
  final FocusNode _inputFocusNode = FocusNode();

  void _setReplyDraft(ReplyDraft draft) {
    _replyDraft.value = draft;
    _inputFocusNode.requestFocus();
  }

  void _clearReplyDraft() {
    _replyDraft.value = null;
  }

  // Cabecera de día estilo WhatsApp: 'Hoy' / 'Ayer' / 'DD-MM-YYYY'.
  // Compara por year/month/day para evitar el bug clásico de "23h ≠ ayer"
  // cuando la diferencia horaria cae al otro lado de medianoche.
  String _formatDaySeparator(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);
    final diffDays = today.difference(messageDay).inDays;
    if (diffDays == 0) return 'Hoy';
    if (diffDays == 1) return 'Ayer';
    final dd = date.day.toString().padLeft(2, '0');
    final mm = date.month.toString().padLeft(2, '0');
    return '$dd-$mm-${date.year}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // Texto de preview del mensaje cuando lo citamos en el composer. Si el
  // mensaje tiene texto, ese; si es media sin caption, usamos el mismo prefijo
  // con icono que el backend usa en lastMessage / quotedText (para que el
  // operador vea el mismo formato que verá luego en el bubble).
  String _previewForDraft(String text, String? mediaType) {
    if (text.isNotEmpty && mediaType == null) return text;
    String? icon;
    String? label;
    switch (mediaType) {
      case 'image':
        icon = '📷';
        label = 'Imagen';
        break;
      case 'video':
        icon = '🎥';
        label = 'Video';
        break;
      case 'audio':
        icon = '🎤';
        label = 'Audio';
        break;
      case 'sticker':
        icon = '🏷️';
        label = 'Sticker';
        break;
      case 'document':
        icon = '📄';
        label = 'Documento';
        break;
    }
    if (icon == null) return text;
    return text.isEmpty ? '$icon $label' : '$icon $text';
  }

  @override
  void initState() {
    super.initState();
    // Escuchar el scroll para cargar más mensajes
    _scrollController.addListener(_scrollListener);
    // Si entramos directo a un mensaje (deep-link del buscador), preparamos el
    // salto: cargar suficiente historial para incluirlo.
    if (widget.jumpToMessageId != null) {
      _pendingJumpId = widget.jumpToMessageId;
      _prepareJump(widget.jumpToMessageId!, widget.jumpToTimestamp);
    }
    // Si el agente de seguimiento dejó un borrador para este chat, lo cargamos.
    _loadFollowupDraft();
  }

  @override
  void didUpdateWidget(MessagesView old) {
    super.didUpdateWidget(old);
    // Nuevo objetivo de salto mientras el chat ya está abierto (p. ej. tocar
    // otro resultado del buscador en el mismo contacto).
    if (widget.jumpToMessageId != null &&
        widget.jumpToMessageId != old.jumpToMessageId) {
      _pendingJumpId = widget.jumpToMessageId;
      _prepareJump(widget.jumpToMessageId!, widget.jumpToTimestamp);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _highlightTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _quickResponseOverlay?.remove();
    _replyDraft.dispose();
    _isFollowupChat.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // Prepara el salto en dos pasos, ambos independientes del stream paginado
  // (que reentrega caché vieja al cambiar el límite y daría falsos negativos):
  //   1. `.get()` directo al doc → autoridad sobre si el mensaje existe. Si no,
  //      avisamos aquí y soltamos el salto (única fuente del "no encontrado").
  //   2. `count()` de cuántos mensajes hay MÁS NUEVOS que él → su posición desde
  //      arriba (orden desc); subimos el límite a ese número + buffer para que
  //      entre en la ventana cargada de una sola vez.
  Future<void> _prepareJump(String messageId, DateTime? ts) async {
    if (_jumpPreparing) return;
    _jumpPreparing = true;
    final messagesRef = FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(widget.accountId)
        .collection('whatsapp_sessions')
        .doc(widget.sessionId)
        .collection('chats')
        .doc(widget.phoneNumber)
        .collection('messages');
    try {
      // 1. ¿Existe? (resuelve el "no encontrado" sin depender del stream).
      final doc = await messagesRef.doc(messageId).get();
      if (!mounted) return;
      if (!doc.exists) {
        _pendingJumpId = null;
        widget.onJumpConsumed?.call();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se encontró el mensaje en este chat'),
        ));
        return;
      }
      // 2. ¿Cuánto historial cargar para incluirlo?
      if (ts != null) {
        final agg = await messagesRef
            .where('timestamp', isGreaterThan: Timestamp.fromDate(ts))
            .count()
            .get();
        final needed = (agg.count ?? 0) + 5; // buffer por timestamps empatados
        if (mounted && needed > _messageLimit) {
          setState(() {
            _messageLimit = needed;
            _hasMore = true;
          });
        }
      }
    } catch (_) {
      // Si falla el count, no abortamos: _resolveJump aún puede localizar el
      // mensaje en lo cargado y, si falta, crecer por paginación.
    } finally {
      _jumpPreparing = false;
    }
  }

  // Llamado tras cada snapshot mientras hay un salto pendiente. El mensaje YA se
  // confirmó existente en _prepareJump, así que aquí solo: si está cargado →
  // scroll + resalte; si la página está llena (falta cargarlo) → crece; si no,
  // esperamos el siguiente snapshot. Nunca declara "no encontrado" (eso lo
  // resolvió el .get() directo, inmune a la caché vieja del StreamBuilder).
  void _resolveJump(List<QueryDocumentSnapshot> messages) {
    final id = _pendingJumpId;
    if (id == null) return;
    final idx = messages.indexWhere((d) => d.id == id);
    if (idx >= 0) {
      _jumpScrolling = true;
      setState(() {
        _highlightId = id;
        _pendingJumpId = null;
      });
      widget.onJumpConsumed?.call();
      // Tras pintar la burbuja resaltada, llevamos el scroll hasta ella. Como
      // los ítems fuera del viewport no se construyen, primero saltamos a la
      // región del objetivo (offset proporcional a su índice en la lista
      // reverse) para forzar su build, y luego ensureVisible lo centra.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          _jumpScrolling = false;
          return;
        }
        final max = _scrollController.position.maxScrollExtent;
        final frac = messages.length <= 1 ? 0.0 : idx / (messages.length - 1);
        _scrollController.jumpTo((frac * max).clamp(0.0, max));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _jumpKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx,
                alignment: 0.4,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut);
          }
          // Libera el guard tras la animación de ensureVisible (~400ms).
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _jumpScrolling = false;
          });
          _highlightTimer?.cancel();
          _highlightTimer = Timer(const Duration(milliseconds: 2500), () {
            if (mounted) setState(() => _highlightId = null);
          });
        });
      });
    } else if (messages.length >= _messageLimit && !_jumpPreparing) {
      // Página llena y el objetivo no está aún → hay más historial arriba:
      // crece y reintenta en el próximo snapshot. (Un snapshot viejo nunca está
      // "lleno" respecto al límite recién ampliado, así que no entra basura.)
      setState(() => _messageLimit += 60);
    }
    // else: página incompleta → es el snapshot viejo aún sin reflejar el límite
    // nuevo, o el fin del historial. En ambos casos esperamos: como el mensaje
    // existe (confirmado en _prepareJump), un snapshot mayor terminará por
    // traerlo. No avisamos aquí para no producir falsos "no encontrado".
  }

  void _scrollListener() {
    if (!_scrollController.hasClients) return;
    final pixels = _scrollController.position.pixels;

    // Flecha "bajar a lo más reciente": en reverse:true, el fondo (mensajes
    // nuevos) es pixels≈0; al alejarnos del fondo la mostramos.
    final shouldShow = pixels > 300;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }

    // Durante un salto programático no paginamos: el jumpTo puede aterrizar
    // cerca del tope y se confundiría con scroll manual del usuario.
    if (_jumpScrolling) return;
    // En una lista 'reverse: true', el final (maxScrollExtent) es la parte SUPERIOR (mensajes viejos)
    if (pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _hasMore) {
        _loadMoreMessages();
      }
    }
  }

  // Baja al mensaje más reciente (fondo de la lista reverse → offset 0).
  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // Flecha flotante, sutil, abajo-derecha. Aparece/desaparece con un fade+scale
  // y queda inerte (IgnorePointer) cuando está oculta para no robar taps.
  Widget _scrollToBottomButton() {
    return IgnorePointer(
      ignoring: !_showScrollToBottom,
      child: AnimatedOpacity(
        opacity: _showScrollToBottom ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedScale(
          scale: _showScrollToBottom ? 1 : 0.8,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: Material(
            color: surfaceDark.withValues(alpha: 0.95),
            elevation: 4,
            shape: CircleBorder(
              side: BorderSide(color: primaryAqua.withValues(alpha: 0.3)),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _scrollToBottom,
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.keyboard_arrow_down,
                    color: primaryAqua, size: 24),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _loadMoreMessages() {
    print('[MessagesView] Cargando más mensajes... Límite actual: $_messageLimit');
    setState(() {
      _isLoadingMore = true;
      _messageLimit += 30;
    });
    
    // Pequeño delay artificial para UX y dar tiempo a Firestore
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    });
  }

  // Referencia al doc del chat (donde viven los campos followup_*).
  DocumentReference<Map<String, dynamic>> get _chatDocRef =>
      FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('chats')
          .doc(widget.phoneNumber);

  // Doc de la cola de seguimiento de este chat (id = phoneNumber del contacto).
  DocumentReference<Map<String, dynamic>> get _followupQueueRef =>
      FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('followup_queue')
          .doc(widget.phoneNumber);

  // Al abrir el chat: si el agente dejó un borrador encolado, lo pre-cargamos
  // en el composer (editable) y encendemos el cintillo. Una sola vez por
  // apertura. No pisa lo que el usuario ya haya escrito.
  Future<void> _loadFollowupDraft() async {
    if (_followupChecked) return;
    _followupChecked = true;
    // Si entramos por un deep-link a un mensaje, no secuestramos el composer.
    if (widget.jumpToMessageId != null) return;
    try {
      final snap = await _followupQueueRef.get();
      final data = snap.data();
      if (!mounted || data == null) return;
      if ((data['status'] as String?) != 'pending') return;
      final draft = (data['draftMessage'] as String?)?.trim() ?? '';
      if (draft.isEmpty) return;
      if (_messageController.text.trim().isNotEmpty) return; // respeta lo ya escrito
      _messageController.text = draft;
      _isFollowupChat.value = true;
    } catch (e) {
      // Silencioso: el seguimiento es una ayuda, su fallo no debe romper el chat.
      print('[Followup] No se pudo cargar el borrador: $e');
    }
  }

  // El operador envió el seguimiento: lo marcamos como enviado para que salga
  // del filtro "Seguimiento" y no se vuelva a elegir mañana.
  Future<void> _markFollowupSent() async {
    _isFollowupChat.value = false;
    try {
      await _chatDocRef.set({
        'followup_status': 'sent',
        'followup_count': FieldValue.increment(1),
        'followup_last_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _followupQueueRef.set({'status': 'sent'}, SetOptions(merge: true));
    } catch (e) {
      print('[Followup] No se pudo marcar como enviado: $e');
    }
  }

  // El operador descarta el borrador sin enviarlo: limpia el composer y saca el
  // chat del filtro (lo dejamos en paz, como un "no dar seguimiento" puntual).
  Future<void> _dismissFollowupDraft() async {
    _isFollowupChat.value = false;
    _messageController.clear();
    try {
      await _chatDocRef.set({
        'followup_status': 'dismissed',
        'followup_last_reason': 'Descartado por el operador',
      }, SetOptions(merge: true));
      await _followupQueueRef.set({'status': 'cancelled'}, SetOptions(merge: true));
    } catch (e) {
      print('[Followup] No se pudo descartar: $e');
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
    });

    try {
      // Snapshot del draft al momento del envío. Si el usuario cancela durante
      // el await, queremos enviar lo que estaba activo cuando tocó "enviar".
      final draft = _replyDraft.value;
      // ¿Este envío cierra un seguimiento del agente? Lo capturamos antes de
      // limpiar para marcarlo como enviado tras el éxito.
      final wasFollowup = _isFollowupChat.value;

      final messageData = {
        'to': widget.phoneNumber,
        'text': text,
        'sessionKey': widget.sessionKey,
        'accountId': widget.accountId,
        'tempId': DateTime.now().millisecondsSinceEpoch.toString(),
        if (draft != null) ...{
          'quotedMessageId': draft.messageId,
          'quotedText': draft.text,
          'quotedFromMe': draft.fromMe,
        },
      };

      // INTELIGENTE: Si el socket está conectado, enviar por ahí (Velocidad Rayo)
      // (El backend resetea unresponded_count al detectar fromMe en messages.upsert)
      if (SocketService().isConnected) {
        print('[MessagesView] Enviando vía WebSocket...');
        SocketService().sendMessage(messageData);
        _messageController.clear();
        _clearReplyDraft();
        if (wasFollowup) _markFollowupSent();
      } else {
        // FALLBACK: Si no hay socket, usar HTTP (Seguridad)
        print('[MessagesView] Socket desconectado, usando fallback HTTP...');
        final response = await http.post(
          Uri.parse('$backendUrl/send-message'),
          headers: await authHeaders(),
          body: jsonEncode(messageData),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          _messageController.clear();
          _clearReplyDraft();
          if (wasFollowup) _markFollowupSent();
        } else {
          throw Exception('Fallback HTTP falló: ${response.body}');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red.shade600),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  // ─── Adjuntos: imagen / video / documento ──────────────────────────────
  // Flujo: elegir archivo (local, instantáneo) → preview + caption opcional →
  // subir a Storage en la carpeta temporal `outgoing/` → mandar la URL al
  // backend, que la descarga, la reenvía por WhatsApp y borra el temporal.
  // La burbuja final la pinta el eco de `messages.upsert` por el mismo
  // pipeline que los mensajes entrantes — no construimos render local.

  // Límites por tipo, alineados con lo que WhatsApp acepta.
  static const int _maxImageBytes = 16 * 1024 * 1024;
  static const int _maxVideoBytes = 64 * 1024 * 1024;
  static const int _maxDocBytes = 100 * 1024 * 1024;

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: primaryAqua),
              title: const Text('Galería (foto o video)', style: TextStyle(color: white)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined, color: primaryAqua),
              title: const Text('Documento', style: TextStyle(color: white)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickDocument();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    try {
      final XFile? file = await ImagePicker().pickMedia();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final ext = _extOf(file.name);
      // pickMedia sólo devuelve imagen o video; si no lo reconocemos por
      // extensión, lo enviamos como documento para no fallar.
      await _confirmAndSendAttachment(
        bytes: bytes,
        fileName: file.name,
        ext: ext,
        kind: _kindForExt(ext),
      );
    } catch (e) {
      _showAttachmentError(e);
    }
  }

  Future<void> _pickDocument() async {
    try {
      // withData: necesitamos los bytes en memoria (también en Web, donde no
      // hay path de filesystem accesible).
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        _showAttachmentError('No se pudo leer el archivo');
        return;
      }
      // Desde "Documento" siempre enviamos como archivo descargable, aunque
      // sea una imagen: el usuario quiere el original sin recomprimir.
      await _confirmAndSendAttachment(
        bytes: bytes,
        fileName: f.name,
        ext: (f.extension ?? _extOf(f.name)).toLowerCase(),
        kind: 'document',
      );
    } catch (e) {
      _showAttachmentError(e);
    }
  }

  // Valida tamaño, muestra preview + caption y, si el usuario confirma, sube
  // y envía. El diálogo devuelve null al cancelar, o el caption (posiblemente
  // vacío) al enviar.
  Future<void> _confirmAndSendAttachment({
    required Uint8List bytes,
    required String fileName,
    required String ext,
    required String kind,
  }) async {
    final limit = kind == 'image'
        ? _maxImageBytes
        : kind == 'video'
            ? _maxVideoBytes
            : _maxDocBytes;
    if (bytes.length > limit) {
      _showAttachmentError('El archivo supera el límite de ${(limit / (1024 * 1024)).round()} MB');
      return;
    }

    final caption = await showDialog<String>(
      context: context,
      builder: (_) => _AttachmentPreviewDialog(bytes: bytes, fileName: fileName, kind: kind),
    );
    if (caption == null) return; // cancelado

    await _uploadAndSendAttachment(
      bytes: bytes,
      fileName: fileName,
      ext: ext,
      kind: kind,
      caption: caption,
    );
  }

  Future<void> _uploadAndSendAttachment({
    required Uint8List bytes,
    required String fileName,
    required String ext,
    required String kind,
    required String caption,
  }) async {
    setState(() => _isSending = true);
    try {
      final mime = _mimeFor(ext, kind);
      // Path temporal único en `outgoing/`. El backend lo borra tras enviar
      // (cleanupAfterSend); la copia canónica la re-guarda el eco en `media/`.
      final unique = '${DateTime.now().millisecondsSinceEpoch}_${bytes.length}';
      final path =
          '$accountsCollection/${widget.accountId}/whatsapp_sessions/${widget.sessionId}/outgoing/$unique${ext.isNotEmpty ? '.$ext' : ''}';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putData(bytes, SettableMetadata(contentType: mime));
      final url = await ref.getDownloadURL();

      final messageData = <String, dynamic>{
        'to': widget.phoneNumber,
        'text': caption,
        'sessionKey': widget.sessionKey,
        'accountId': widget.accountId,
        'mimetype': mime,
        'cleanupAfterSend': true,
      };
      if (kind == 'image') {
        messageData['imageUrl'] = url;
      } else if (kind == 'video') {
        messageData['videoUrl'] = url;
      } else {
        messageData['documentUrl'] = url;
        messageData['documentName'] = fileName;
      }

      if (SocketService().isConnected) {
        SocketService().sendMessage(messageData);
      } else {
        final response = await http
            .post(
              Uri.parse('$backendUrl/send-message'),
              headers: await authHeaders(),
              body: jsonEncode(messageData),
            )
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) throw Exception(response.body);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Archivo enviado'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF06B6D4),
          ),
        );
      }
    } catch (e) {
      _showAttachmentError(e);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return (i > 0 && i < name.length - 1) ? name.substring(i + 1).toLowerCase() : '';
  }

  String _kindForExt(String ext) {
    const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp'};
    const videos = {'mp4', 'mov', '3gp', 'webm', 'mkv', 'avi', 'm4v'};
    if (images.contains(ext)) return 'image';
    if (videos.contains(ext)) return 'video';
    return 'document';
  }

  String _mimeFor(String ext, String kind) {
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
      'heif': 'image/heif', 'bmp': 'image/bmp',
      'mp4': 'video/mp4', 'mov': 'video/quicktime', '3gp': 'video/3gpp',
      'webm': 'video/webm', 'mkv': 'video/x-matroska', 'm4v': 'video/x-m4v',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain', 'csv': 'text/csv', 'zip': 'application/zip',
      'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
      'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'm4a': 'audio/mp4',
      'wav': 'audio/wav', 'aac': 'audio/aac',
    };
    return map[ext] ??
        (kind == 'image'
            ? 'image/jpeg'
            : kind == 'video'
                ? 'video/mp4'
                : 'application/octet-stream');
  }

  void _showAttachmentError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red.shade600),
    );
  }

  // Abre el panel de configuración de sesión como bottom sheet. Se usa cuando
  // el asistente IA aún no está habilitado: en lugar de bloquear al usuario,
  // lo llevamos directo al lugar donde puede activarlo.
  void _openSessionSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SessionSettingsPanel(
        sessionId: widget.sessionId,
        accountId: widget.accountId,
      ),
    );
  }

  // Genera una sugerencia de IA y la vuelca al composer. Si `operatorInstruction`
  // viene con texto, se manda al backend como instrucción puntual de máxima
  // prioridad para guiar ESTA respuesta (modo copiloto con dirección humana).
  Future<void> _generateAIResponse({String? operatorInstruction}) async {
    setState(() => _isGenerating = true);
    try {
      final instruction = operatorInstruction?.trim() ?? '';
      final response = await http.post(
        Uri.parse('$backendUrl/generate-ai-response'),
        headers: await authHeaders(),
        body: jsonEncode({
          'chatPhone': widget.phoneNumber,
          'sessionKey': widget.sessionKey,
          'accountId': widget.accountId,
          if (instruction.isNotEmpty) 'operatorInstruction': instruction,
        }),
      ).timeout(const Duration(seconds: 45)); // > 25s del timeout backend

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final text = (data['suggestedText'] as String? ?? '').trim();
        if (text.isEmpty) {
          // Caso raro: 200 pero sin texto. Avisamos en vez de quedarnos mudos.
          _showAiError('La IA no devolvió texto. Reintenta.', operatorInstruction: operatorInstruction);
          return;
        }
        setState(() => _messageController.text = text);
        _messageController.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
      } else {
        // El backend manda `{ error, code }`. Traducimos el code a un mensaje claro.
        String? code;
        String? backendMsg;
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          code = body['code'] as String?;
          backendMsg = body['error'] as String?;
        } catch (_) {/* cuerpo no-JSON: usamos el status */}
        _showAiError(
          _friendlyAiError(code, backendMsg, response.statusCode),
          operatorInstruction: operatorInstruction,
        );
      }
    } on TimeoutException {
      if (mounted) {
        _showAiError('La IA tardó demasiado en responder. Reintenta.', operatorInstruction: operatorInstruction);
      }
    } catch (e) {
      debugPrint('Error generating AI response: $e');
      if (mounted) {
        _showAiError('No se pudo conectar para generar la respuesta.', operatorInstruction: operatorInstruction);
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  // Traduce el `code` del backend a un mensaje accionable para el operador.
  // Si no hay code conocido, cae al mensaje del backend o al status HTTP.
  String _friendlyAiError(String? code, String? backendMsg, int status) {
    switch (code) {
      case 'timeout':
        return 'La IA tardó demasiado en responder. Reintenta.';
      case 'rate_limit':
        return 'El proveedor de IA está saturado o llegaste al límite. Espera unos segundos y reintenta.';
      case 'auth':
        return 'Las credenciales del proveedor de IA no son válidas. Revísalas en ajustes.';
      case 'provider_down':
        return 'El proveedor de IA tuvo un error. Reintenta en un momento.';
      case 'safety_block':
        return 'La respuesta fue bloqueada por los filtros del modelo. Reformula con una instrucción.';
      case 'empty_response':
        return 'La IA no devolvió texto. Reintenta.';
      case 'empty_history':
        return 'No hay mensajes suficientes para generar una respuesta.';
      default:
        return (backendMsg != null && backendMsg.isNotEmpty)
            ? backendMsg
            : 'No se pudo generar la respuesta (error $status).';
    }
  }

  // SnackBar de error rojo con acción "Reintentar" que reusa la misma instrucción
  // del operador. Solo aplica al modo manual (botón auto_awesome) — el
  // auto-responder no pasa por aquí.
  void _showAiError(String message, {String? operatorInstruction}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade600,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Reintentar',
          textColor: Colors.white,
          onPressed: () => _generateAIResponse(operatorInstruction: operatorInstruction),
        ),
      ),
    );
  }

  // Abre un cuadro para que el operador escriba una instrucción puntual antes de
  // generar (ej: "dale info de cejas HD", "hazlo más amistoso"). Se dispara con
  // long-press sobre el botón auto_awesome. Vacío = no se envía nada (equivale al
  // tap normal). La instrucción NO se persiste: guía solo esta generación.
  void _promptOperatorInstruction() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        // Padding que sube el sheet por encima del teclado.
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, color: primaryAqua, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Instrucción para la IA',
                    style: TextStyle(color: white, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Ej: "dale info de cejas HD" · "hazlo más amistoso" · "explícale por qué el precio es tan bajo"',
                style: TextStyle(color: lightText, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: white, fontSize: 15),
                cursorColor: primaryAqua,
                decoration: InputDecoration(
                  hintText: 'Escribe qué debe hacer la IA en esta respuesta…',
                  hintStyle: TextStyle(color: lightText.withValues(alpha: 0.6)),
                  filled: true,
                  fillColor: darkBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.25)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: primaryAqua, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Cancelar', style: TextStyle(color: lightText)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryAqua,
                      foregroundColor: darkBg,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                    onPressed: () {
                      final instruction = controller.text.trim();
                      Navigator.pop(sheetContext);
                      if (instruction.isNotEmpty) {
                        _generateAIResponse(operatorInstruction: instruction);
                      }
                    },
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('Generar', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      // Diferimos el dispose al siguiente frame: al cerrar el sheet, el TextField
      // todavía usa el controller durante su teardown (foco/teclado) en este mismo
      // frame. Si lo disponemos ya, revienta con "used after being disposed".
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    });
  }

  // Detecta el token "/filtro" justo antes del cursor. El "/" es válido si
  // está al inicio del texto o precedido por un espacio/salto de línea (así
  // "http://" o "y/o" no disparan el selector). Devuelve [inicio, cursor) o
  // null si no hay token activo.
  TextRange? _activeSlashToken(String text, int cursor) {
    if (cursor < 0 || cursor > text.length) return null;
    var i = cursor - 1;
    while (i >= 0) {
      final ch = text[i];
      if (ch == ' ' || ch == '\n') return null; // espacio antes del "/" → corta
      if (ch == '/') {
        final prevOk = i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n';
        return prevOk ? TextRange(start: i, end: cursor) : null;
      }
      i--;
    }
    return null;
  }

  void _handleQuickResponseInput(String value) {
    final sel = _messageController.selection;
    final cursor = sel.isValid ? sel.baseOffset : value.length;
    final token = _activeSlashToken(value, cursor);

    if (token == null) {
      _activeTokenRange = null;
      _quickResponseOverlay?.remove();
      _quickResponseOverlay = null;
      return;
    }

    _activeTokenRange = token;
    final filter = value.substring(token.start + 1, token.end).toLowerCase();
    setState(() => _quickResponseFilter = filter);
    _showQuickResponsesOverlay();
  }

  void _showQuickResponsesOverlay() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('quick_responses')
          .orderBy('order', descending: false)
          .get();

      if (!mounted) return;

      final allResponses = snapshot.docs
          .map((doc) => {...doc.data(), 'id': doc.id})
          .toList();

      final filtered = allResponses
          .where((qr) {
            final title = (qr['title'] as String? ?? '').toLowerCase();
            return title.contains(_quickResponseFilter);
          })
          .toList();

      _quickResponseOverlay?.remove();

      if (filtered.isEmpty) {
        _quickResponseOverlay = null;
        return;
      }

      _quickResponseOverlay = OverlayEntry(
        builder: (context) => Positioned(
          bottom: MediaQuery.of(context).viewInsets.bottom + 140,
          left: 12,
          right: 12,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: surfaceDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 2)),
                ],
              ),
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1, indent: 8, endIndent: 8),
                itemBuilder: (_, idx) {
                  final qr = filtered[idx];
                  final title = qr['title'] as String? ?? '';
                  final text = qr['text'] as String? ?? '';
                  final imageUrl = qr['imageUrl'] as String? ?? '';

                  return InkWell(
                    onTap: () => _selectQuickResponse(qr),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.w600, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                if (text.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(text.substring(0, (text.length < 40 ? text.length : 40)), style: TextStyle(color: lightText.withValues(alpha: 0.5), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                            ),
                          ),
                          if (imageUrl.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.image, size: 14, color: primaryAqua.withValues(alpha: 0.6)),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      Overlay.of(context).insert(_quickResponseOverlay!);
    } catch (e) {
      debugPrint('Error loading quick responses: $e');
    }
  }

  void _selectQuickResponse(Map<String, dynamic> template) {
    final text = template['text'] as String? ?? '';
    final imageUrl = template['imageUrl'] as String? ?? '';
    final title = template['title'] as String? ?? '';

    _quickResponseOverlay?.remove();
    _quickResponseOverlay = null;

    if (imageUrl.isNotEmpty) {
      _showImageConfirmationDialog(title, text, imageUrl);
    } else {
      _insertAtToken(text);
    }
  }

  // Reemplaza el token "/filtro" por el texto de la respuesta, conservando lo
  // que haya antes y después, y deja el cursor justo al final de lo insertado.
  void _insertAtToken(String insert) {
    final value = _messageController.text;
    // Usar el token guardado al escribir; si no hay, caer al cursor/fin actual
    final sel = _messageController.selection;
    final cursor = sel.isValid ? sel.baseOffset : value.length;
    final token = _activeTokenRange ?? _activeSlashToken(value, cursor);
    final start = token?.start ?? cursor;
    final end = token?.end ?? cursor;

    final newText = value.replaceRange(start, end, insert);
    final newCursor = start + insert.length;

    setState(() => _messageController.text = newText);
    _messageController.selection =
        TextSelection.fromPosition(TextPosition(offset: newCursor));
    _activeTokenRange = null;
    // Devolver el foco al composer para seguir escribiendo sin tocar nada
    _inputFocusNode.requestFocus();
  }

  void _showImageConfirmationDialog(String title, String caption, String imageUrl) {
    // El diálogo es un widget con estado propio para que el controller del
    // caption se libere en su dispose() (evita "used after dispose")
    showDialog(
      context: context,
      builder: (_) => _ImageCaptionDialog(
        title: title,
        caption: caption,
        imageUrl: imageUrl,
        // Enviar con el texto editado (puede quedar vacío → imagen sola)
        onSend: (editedCaption) =>
            _sendQuickResponse({'text': editedCaption, 'imageUrl': imageUrl}),
      ),
    );
  }

  Future<void> _sendQuickResponse(Map<String, dynamic> template) async {
    final text = template['text'] as String? ?? '';
    final imageUrl = template['imageUrl'] as String? ?? '';

    if (imageUrl.isEmpty) return;

    setState(() => _isSending = true);

    try {
      final messageData = {
        'to': widget.phoneNumber,
        'text': text,
        'imageUrl': imageUrl,
        'sessionKey': widget.sessionKey,
        'accountId': widget.accountId,
      };

      if (SocketService().isConnected) {
        print('[MessagesView] Enviando respuesta rápida vía WebSocket...');
        SocketService().sendMessage(messageData);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✓ Respuesta enviada'), duration: Duration(seconds: 2), backgroundColor: Color(0xFF06B6D4)),
          );
        }
      } else {
        print('[MessagesView] Socket desconectado, usando fallback HTTP para respuesta rápida...');
        final response = await http.post(
          Uri.parse('$backendUrl/send-message'),
          headers: await authHeaders(),
          body: jsonEncode(messageData),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) throw Exception(response.body);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al enviar: ${e.toString()}'), backgroundColor: Colors.red.shade600),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Messages
        Expanded(
          child: Stack(
            children: [
              StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(accountsCollection)
                .doc(widget.accountId)
                .collection('whatsapp_sessions')
                .doc(widget.sessionId)
                .collection('chats')
                .doc(widget.phoneNumber)
                .collection('messages')
                .orderBy('timestamp', descending: true)
                .limit(_messageLimit) // 📌 Aplicar límite dinámico
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)));
              
              final messages = snapshot.data!.docs;
              
              // Si nos devuelven menos de lo que pedimos, es que ya no hay más mensajes en el servidor
              if (messages.length < _messageLimit) {
                _hasMore = false;
              }

              // Salto pendiente: tras pintar este set intentamos localizar el
              // mensaje objetivo (post-frame para no llamar setState en build).
              if (_pendingJumpId != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _resolveJump(messages);
                });
              }

              if (messages.isEmpty) return const Center(child: Text('Sin mensajes', style: TextStyle(color: lightText, fontSize: 16)));

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                itemCount: messages.length + (_hasMore ? 1 : 0),
                reverse: true, // Importante: el índice 0 es el mensaje más nuevo (abajo)
                itemBuilder: (context, index) {
                  // Si es el último elemento y hay más, mostrar spinner de carga
                  if (index == messages.length) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)),
                        ),
                      ),
                    );
                  }

                  final msg = messages[index];
                  final data = msg.data() as Map<String, dynamic>;
                  // Snapshot para el draft: el preview en la franja del composer
                  // muestra el texto del mensaje (o un fallback si era media sin
                  // caption — usamos el mismo prefijo del backend, ej. "📷 Imagen").
                  final msgText = (data['text'] as String?) ?? '';
                  final msgMediaType = data['mediaType'] as String?;
                  final draftPreview = _previewForDraft(msgText, msgMediaType);
                  final msgDate = (data['timestamp'] as Timestamp).toDate();

                  // Separador de día: en lista reverse:true, index mayor = más
                  // viejo. Mostramos cabecera arriba de este bubble si es el
                  // mensaje más viejo de su día en el set cargado (older==null)
                  // o si el mensaje inmediatamente más viejo es de otro día.
                  final olderDoc = (index + 1 < messages.length) ? messages[index + 1] : null;
                  bool showSeparator = false;
                  if (olderDoc == null) {
                    showSeparator = true;
                  } else {
                    final olderData = olderDoc.data() as Map<String, dynamic>;
                    final olderDate = (olderData['timestamp'] as Timestamp).toDate();
                    showSeparator = !_isSameDay(msgDate, olderDate);
                  }

                  final bubble = MessageBubble(
                    key: ValueKey(msg.id),
                    text: msgText,
                    fromMe: (data['fromMe'] as bool?) ?? false,
                    timestamp: msgDate,
                    messageId: msg.id,
                    chatPhone: widget.phoneNumber,
                    sessionKey: widget.sessionKey,
                    accountId: widget.accountId,
                    sessionPhone: widget.sessionId,
                    senderType: data['senderType'] as String?,
                    senderName: data['senderName'] as String?,
                    mediaType: msgMediaType,
                    mediaThumbBase64: data['mediaThumbBase64'] as String?,
                    mediaWidth: (data['mediaWidth'] as num?)?.toDouble(),
                    mediaHeight: (data['mediaHeight'] as num?)?.toDouble(),
                    mediaUrl: data['mediaUrl'] as String?,
                    mediaStatus: data['mediaStatus'] as String?,
                    mediaFileName: data['mediaFileName'] as String?,
                    mediaSize: (data['mediaSize'] as num?)?.toInt(),
                    mediaIsPtt: data['mediaIsPtt'] as bool?,
                    mediaDuration: (data['mediaDuration'] as num?)?.toInt(),
                    mediaIsGif: data['mediaIsGif'] as bool?,
                    reactions: data['reactions'] as Map<String, dynamic>?,
                    edited: data['edited'] as bool?,
                    revoked: data['revoked'] as bool?,
                    quotedMessageId: data['quotedMessageId'] as String?,
                    quotedText: data['quotedText'] as String?,
                    quotedFromMe: data['quotedFromMe'] as bool?,
                    onReplyTap: () => _setReplyDraft(ReplyDraft(
                      messageId: msg.id,
                      text: draftPreview,
                      fromMe: (data['fromMe'] as bool?) ?? false,
                    )),
                  );

                  // El Column NO se reversea internamente — el listview sólo
                  // invierte el orden de items, no su contenido. Por eso el
                  // separador va como PRIMER hijo: queda visualmente arriba
                  // del primer mensaje del día (igual que en WhatsApp).
                  final Widget item = showSeparator
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _DateSeparator(_formatDaySeparator(msgDate)),
                            bubble,
                          ],
                        )
                      : bubble;

                  // Burbuja objetivo del salto: ancla para ensureVisible + tinte
                  // aqua que se desvanece (~2.5s) para señalar el resultado.
                  if (msg.id == _highlightId) {
                    return _JumpHighlight(key: _jumpKey, child: item);
                  }
                  return item;
                },
              );
            },
          ),
              Positioned(
                right: 16,
                bottom: 16,
                child: _scrollToBottomButton(),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: surfaceDark,
            border: Border(top: BorderSide(color: primaryAqua.withValues(alpha: 0.1), width: 1))
          ),
          child: SafeArea(
            child: Builder(
              builder: (context) {
                final sKey = widget.sessionKey;
                final bool isDisconnected = sKey == null || sKey == 'disconnected';
                
                if (isDisconnected) {
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    width: double.infinity,
                    child: const Text(
                      'Cuenta desvinculada. Re-vincula para enviar mensajes.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  );
                }
                
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Cintillo del agente de seguimiento: aparece cuando el chat
                    // trae un borrador encolado. Comunica que el texto del
                    // composer es una propuesta editable, y ofrece descartarla.
                    ValueListenableBuilder<bool>(
                      valueListenable: _isFollowupChat,
                      builder: (context, isFollowup, _) {
                        if (!isFollowup) return const SizedBox.shrink();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                          decoration: BoxDecoration(
                            color: primaryAqua.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(left: BorderSide(color: primaryAqua, width: 3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.auto_awesome, size: 16, color: primaryAqua),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Borrador del agente · edítalo y envía',
                                  style: TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                              TextButton(
                                onPressed: _dismissFollowupDraft,
                                style: TextButton.styleFrom(
                                  foregroundColor: lightText,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  minimumSize: const Size(0, 32),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('Descartar', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    // Franja de "respondiendo a..." arriba del input. Se muestra
                    // sólo cuando hay un draft activo. ValueListenableBuilder
                    // evita rebuilds del Row de input cuando cambia el draft.
                    ValueListenableBuilder<ReplyDraft?>(
                      valueListenable: _replyDraft,
                      builder: (context, draft, _) {
                        if (draft == null) return const SizedBox.shrink();
                        final accent = draft.fromMe ? primaryAqua : const Color(0xFF10B981);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                          decoration: BoxDecoration(
                            color: darkBg.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(left: BorderSide(color: accent, width: 3)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      draft.fromMe ? 'Respondiéndote' : 'Respondiendo al cliente',
                                      style: TextStyle(
                                        color: accent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      draft.text.isEmpty ? '(sin contenido)' : draft.text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: lightText,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                color: lightText,
                                tooltip: 'Cancelar respuesta',
                                onPressed: _clearReplyDraft,
                                splashRadius: 18,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file_rounded, size: 22),
                      color: lightText,
                      tooltip: 'Adjuntar archivo',
                      onPressed: _isSending ? null : _showAttachmentMenu,
                    ),
                    Expanded(
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed && event is KeyDownEvent) {
                            _sendMessage();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: _messageController,
                          focusNode: _inputFocusNode,
                          // Auto-crece de 1 a 6 líneas y, a partir de ahí,
                          // scrollea internamente en vez de crecer sin tope.
                          // Así una respuesta de IA larga nunca queda detrás
                          // del teclado: el final siempre es alcanzable.
                          minLines: 1,
                          maxLines: 6,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: white, fontSize: 15),
                          onChanged: _handleQuickResponseInput,
                          decoration: InputDecoration(
                            hintText: '',
                            hintStyle: const TextStyle(color: lightText),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                            filled: true,
                            fillColor: darkBg.withValues(alpha: 0.8),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _isGenerating
                        ? const SizedBox(width: 44, height: 44, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF06B6D4)))))
                        : Builder(
                            builder: (_) {
                              // Tri-estado del botón "Sugerir respuesta con IA":
                              //  1. Sin credenciales → gris, lleva a settings.
                              //  2. Credenciales + auto-responder ON → aqua sólido.
                              //  3. Credenciales + auto-responder OFF (copiloto) →
                              //     aqua atenuado para indicar "IA disponible pero
                              //     apagada, te sugiere sin enviar nada solo".
                              final hasCreds = widget.sessionAiHasCredentials;
                              final autoOn = widget.sessionAiEnabled;
                              final String tooltip;
                              final Color color;
                              final VoidCallback onPressed;
                              if (!hasCreds) {
                                tooltip = 'Configura el asistente IA primero';
                                color = const Color(0xFF9CA3AF).withValues(alpha: 0.4);
                                onPressed = _openSessionSettings;
                              } else if (autoOn) {
                                tooltip = 'Generar respuesta con IA · mantén pulsado para dar una instrucción';
                                color = const Color(0xFF06B6D4);
                                onPressed = () => _generateAIResponse();
                              } else {
                                tooltip = 'Sugerir respuesta con IA (asistente apagado) · mantén pulsado para dar una instrucción';
                                color = const Color(0xFF06B6D4).withValues(alpha: 0.6);
                                onPressed = () => _generateAIResponse();
                              }
                              // Con credenciales el long-press abre el cuadro de
                              // instrucción; sin ellas, igual que el tap, lleva a
                              // configurar el asistente.
                              //
                              // Ojo: NO usamos el `tooltip` del IconButton. En
                              // móvil ese tooltip se dispara con long-press y, al
                              // estar más adentro del árbol, gana la arena de
                              // gestos y roba nuestro long-press. Por eso el hint
                              // va en un Tooltip externo en modo `manual` (sigue
                              // apareciendo al pasar el mouse en web/desktop, pero
                              // no registra un recognizer de long-press que compita)
                              // y el long-press lo maneja el GestureDetector.
                              return Tooltip(
                                message: tooltip,
                                triggerMode: TooltipTriggerMode.manual,
                                child: GestureDetector(
                                  onLongPress: hasCreds
                                      ? _promptOperatorInstruction
                                      : _openSessionSettings,
                                  child: IconButton(
                                    icon: const Icon(Icons.auto_awesome, size: 20),
                                    color: color,
                                    onPressed: onPressed,
                                  ),
                                ),
                              );
                            },
                          ),
                    const SizedBox(width: 4),
                    Container(
                      decoration: BoxDecoration(color: primaryAqua, borderRadius: BorderRadius.circular(12)),
                      child: IconButton(
                        icon: _isSending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(darkBg))) : const Icon(Icons.send_rounded, size: 20),
                        color: darkBg,
                        onPressed: _isSending ? null : _sendMessage,
                      ),
                    ),
                  ],
                ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// Chip centrado de cabecera de día, estilo WhatsApp/Apple dark. Translúcido
// sobre el fondo del chat con borde aqua sutil para que respire sin gritar.
// Resalte temporal de la burbuja a la que saltó el buscador: un tinte aqua que
// aparece y se desvanece en ~2.5s (TweenAnimationBuilder de 1→0). El padre
// retira el wrapper al terminar limpiando `_highlightId`. La GlobalKey vive en
// el wrapper externo para que Scrollable.ensureVisible tenga el ancla.
class _JumpHighlight extends StatelessWidget {
  final Widget child;
  const _JumpHighlight({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(milliseconds: 2500),
      curve: Curves.easeOut,
      builder: (_, t, inner) => Container(
        decoration: BoxDecoration(
          color: primaryAqua.withValues(alpha: 0.22 * t),
          borderRadius: BorderRadius.circular(12),
        ),
        child: inner,
      ),
      child: child,
    );
  }
}

class _DateSeparator extends StatelessWidget {
  final String label;
  const _DateSeparator(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: darkBg.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: primaryAqua.withValues(alpha: 0.15)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: lightText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// Diálogo de confirmación para respuestas con imagen, con caption editable.
// Es StatefulWidget para que el controller se libere en dispose() de forma
// segura (sin "used after dispose" al cerrar el diálogo).
class _ImageCaptionDialog extends StatefulWidget {
  final String title;
  final String caption;
  final String imageUrl;
  final void Function(String editedCaption) onSend;

  const _ImageCaptionDialog({
    required this.title,
    required this.caption,
    required this.imageUrl,
    required this.onSend,
  });

  @override
  State<_ImageCaptionDialog> createState() => _ImageCaptionDialogState();
}

class _ImageCaptionDialogState extends State<_ImageCaptionDialog> {
  late final TextEditingController _captionController;

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.caption);
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      title: Text(widget.title, style: const TextStyle(color: white, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(widget.imageUrl, height: 150, fit: BoxFit.cover),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              maxLines: 4,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Añade un texto (opcional)',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: primaryAqua),
          onPressed: () {
            // Capturar el texto antes de cerrar (el controller se libera al pop)
            final edited = _captionController.text.trim();
            Navigator.pop(context);
            widget.onSend(edited);
          },
          child: const Text('Enviar', style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

// Preview de un adjunto recién elegido (imagen / video / documento) con caption
// opcional, antes de subirlo. Devuelve el caption al enviar (pop con String) o
// null al cancelar. Trabaja con los bytes en memoria — sin red hasta confirmar.
class _AttachmentPreviewDialog extends StatefulWidget {
  final Uint8List bytes;
  final String fileName;
  final String kind; // image | video | document

  const _AttachmentPreviewDialog({
    required this.bytes,
    required this.fileName,
    required this.kind,
  });

  @override
  State<_AttachmentPreviewDialog> createState() => _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<_AttachmentPreviewDialog> {
  final TextEditingController _captionController = TextEditingController();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
        'image' => 'Enviar imagen',
        'video' => 'Enviar video',
        _ => 'Enviar documento',
      };

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _preview() {
    if (widget.kind == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(widget.bytes, height: 160, fit: BoxFit.cover),
      );
    }
    // Video y documento: tarjeta con icono + nombre + tamaño (no decodificamos
    // el video acá; el render real lo hace la burbuja tras enviar).
    final icon = widget.kind == 'video'
        ? Icons.videocam_rounded
        : Icons.insert_drive_file_rounded;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: darkBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: primaryAqua, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: white, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  _humanSize(widget.bytes.length),
                  style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      title: Text(_title, style: const TextStyle(color: white, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _preview(),
            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              maxLines: 4,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Añade un texto (opcional)',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancelar', style: TextStyle(color: lightText.withValues(alpha: 0.6))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: primaryAqua),
          onPressed: () => Navigator.pop(context, _captionController.text.trim()),
          child: const Text('Enviar', style: TextStyle(color: darkBg, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
