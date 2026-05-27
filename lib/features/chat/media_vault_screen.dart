// MediaVaultScreen — Galería de medios por sesión.
//
// Objetivo: vista única donde el operador puede ver todas las imágenes,
// videos (preview) y documentos enviados/recibidos en TODOS los chats de
// una sesión de WhatsApp, ordenados por fecha. Pensado para "encontrar
// el comprobante que mandó X cliente" cuando no escribió su nombre en
// el concepto.
//
// Fuente de datos: `whatsapp_sessions/{sid}/media_index/{messageId}`
// (denormalizado por sesión en el backend — ver writeMediaIndexEntry).
// Por eso paginamos con un solo `orderBy(timestamp)` sin barrer chats.
//
// Excluidos por contrato: audios, stickers, GIFs (el backend ya los filtra).

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

const int _pageSize = 30;

class MediaVaultScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String sessionAlias;

  // Callback: el operador eligió "Ver en chat" desde el viewer.
  // ChatsScreen lo usa para cerrar este vault y seleccionar el contacto.
  final void Function(String chatId)? onJumpToChat;

  const MediaVaultScreen({
    required this.accountId,
    required this.sessionId,
    required this.sessionAlias,
    this.onJumpToChat,
    super.key,
  });

  @override
  State<MediaVaultScreen> createState() => _MediaVaultScreenState();
}

enum _MediaFilter { all, images, videos, documents, sent, received }

class _MediaVaultScreenState extends State<MediaVaultScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  // Items cargados localmente (acumulamos lote a lote).
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _items = [];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _loading = false;
  bool _exhausted = false;

  _MediaFilter _filter = _MediaFilter.all;
  String _searchQuery = '';

  // Estado del backfill manual disparado desde el empty state.
  // - idle: aún no se intentó.
  // - running: el endpoint está corriendo (UI bloqueada con spinner).
  bool _backfilling = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Cargar más cuando faltan ~600px para llegar al final.
    if (!_loading &&
        !_exhausted &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  // Construye la query base. Los filtros por tipo/dirección se aplican en
  // memoria sobre el resultado: si los aplicáramos en la query, perderíamos
  // la paginación uniforme (ej. filtrar fromMe requeriría índice compuesto y
  // el lote de 30 quedaría disparejo según cuántos cumplan el filtro).
  Query<Map<String, dynamic>> _baseQuery() {
    return FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(widget.accountId)
        .collection('whatsapp_sessions')
        .doc(widget.sessionId)
        .collection('media_index')
        .orderBy('timestamp', descending: true)
        .limit(_pageSize);
  }

  Future<void> _loadMore() async {
    if (_loading || _exhausted) return;
    setState(() => _loading = true);
    try {
      Query<Map<String, dynamic>> q = _baseQuery();
      if (_cursor != null) q = q.startAfterDocument(_cursor!);
      final snap = await q.get();
      if (!mounted) return;
      setState(() {
        _items.addAll(snap.docs);
        if (snap.docs.isNotEmpty) _cursor = snap.docs.last;
        if (snap.docs.length < _pageSize) _exhausted = true;
      });
    } catch (e) {
      debugPrint('[MediaVault] Error cargando lote: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Filtra en memoria los items ya cargados según los chips + búsqueda.
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _visibleItems {
    final q = _searchQuery.trim().toLowerCase();
    return _items.where((doc) {
      final d = doc.data();
      final type = d['mediaType'] as String?;
      final fromMe = d['fromMe'] == true;

      // Filtros por chip.
      switch (_filter) {
        case _MediaFilter.images:
          if (type != 'image') return false;
          break;
        case _MediaFilter.videos:
          if (type != 'video') return false;
          break;
        case _MediaFilter.documents:
          if (type != 'document') return false;
          break;
        case _MediaFilter.sent:
          if (!fromMe) return false;
          break;
        case _MediaFilter.received:
          if (fromMe) return false;
          break;
        case _MediaFilter.all:
          break;
      }

      // Búsqueda libre: contacto, número, filename.
      if (q.isNotEmpty) {
        final name = (d['contactName'] as String? ?? '').toLowerCase();
        final chatId = (d['chatId'] as String? ?? '').toLowerCase();
        final file = (d['mediaFileName'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !chatId.contains(q) && !file.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    final crossAxisCount = isMobile ? 3 : 6;

    final visible = _visibleItems;
    final grouped = _groupByDate(visible);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: primaryAqua),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Galería de medios',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                color: white,
              ),
            ),
            Text(
              widget.sessionAlias,
              style: const TextStyle(
                fontSize: 12,
                color: lightText,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildFilterChips(),
          Expanded(
            child: visible.isEmpty && _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                    ? _buildEmptyState()
                    : CustomScrollView(
                        controller: _scrollController,
                        slivers: [
                          for (final group in grouped) ...[
                            SliverToBoxAdapter(
                              child: _buildDateHeader(group.label),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 4,
                                  mainAxisSpacing: 4,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (ctx, i) => _buildTile(group.items[i]),
                                  childCount: group.items.length,
                                ),
                              ),
                            ),
                          ],
                          if (_loading)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(20),
                                child: Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation(
                                          primaryAqua),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (_exhausted && visible.isNotEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: Text(
                                    'No hay más medios',
                                    style: TextStyle(
                                      color: lightText,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(color: white),
        decoration: InputDecoration(
          hintText: 'Buscar por contacto o archivo...',
          hintStyle: const TextStyle(color: lightText),
          prefixIcon: const Icon(Icons.search, color: lightText, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, color: lightText, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: surfaceDark.withValues(alpha: 0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    const chips = [
      (_MediaFilter.all, 'Todos', Icons.apps),
      (_MediaFilter.images, 'Imágenes', Icons.image_outlined),
      (_MediaFilter.videos, 'Videos', Icons.videocam_outlined),
      (_MediaFilter.documents, 'Documentos', Icons.description_outlined),
      (_MediaFilter.sent, 'Enviados', Icons.call_made),
      (_MediaFilter.received, 'Recibidos', Icons.call_received),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (value, label, icon) = chips[i];
          final selected = _filter == value;
          return FilterChip(
            avatar: Icon(icon,
                size: 16, color: selected ? darkBg : lightText),
            label: Text(label),
            selected: selected,
            onSelected: (_) => setState(() => _filter = value),
            selectedColor: primaryAqua,
            backgroundColor: surfaceDark.withValues(alpha: 0.6),
            labelStyle: TextStyle(
              color: selected ? darkBg : white,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: selected
                    ? primaryAqua
                    : surfaceDark.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
            showCheckmark: false,
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    // El botón "Indexar histórico" solo tiene sentido cuando:
    // - ya terminamos de paginar (_exhausted) → no es que falte cargar más;
    // - el usuario NO está filtrando ni buscando → si filtra y queda vacío
    //   es por el filtro, no por falta de índice;
    // - no estamos ya corriendo un backfill.
    final canBackfill = _exhausted &&
        _searchQuery.isEmpty &&
        _filter == _MediaFilter.all &&
        !_backfilling;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: primaryAqua.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            const Text(
              'Sin medios para mostrar',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty || _filter != _MediaFilter.all
                  ? 'Probá quitar filtros o ajustar la búsqueda.'
                  : 'Las imágenes, videos y documentos enviados o recibidos aparecerán aquí.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: lightText),
            ),
            if (canBackfill) ...[
              const SizedBox(height: 24),
              const Text(
                '¿Esta sesión ya tiene mensajes con imágenes?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: lightText),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _runBackfill,
                icon: const Icon(Icons.history, size: 18),
                label: const Text('Indexar histórico'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Recorre todos los chats y rellena la galería con\nlos medios ya recibidos. Puede tardar 1-2 minutos.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: lightText),
              ),
            ],
            if (_backfilling) ...[
              const SizedBox(height: 24),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(primaryAqua),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Indexando histórico...',
                style: TextStyle(fontSize: 13, color: lightText),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Dispara POST /backfill-media-index para esta sesión y, al volver,
  // reinicia la paginación para que la grilla se rellene con lo nuevo.
  Future<void> _runBackfill() async {
    setState(() => _backfilling = true);
    try {
      final resp = await http.post(
        Uri.parse('$backendUrl/backfill-media-index'),
        headers: await authHeaders(),
        body: jsonEncode({
          'accountId': widget.accountId,
          'sessionId': widget.sessionId,
        }),
      );

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final indexed = body['indexedCount'] ?? 0;
        final scanned = body['scannedChats'] ?? 0;
        _toast('$indexed medios indexados en $scanned chats');
        // Reiniciamos paginación: descartamos lo cargado y leemos desde 0
        // para que aparezca lo recién indexado.
        setState(() {
          _items.clear();
          _cursor = null;
          _exhausted = false;
        });
        await _loadMore();
      } else {
        _toast('Error ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      if (mounted) _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  Widget _buildDateHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: lightText,
          fontWeight: FontWeight.w600,
          fontSize: 13,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildTile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final type = d['mediaType'] as String?;
    final fromMe = d['fromMe'] == true;

    return GestureDetector(
      onTap: () => _openItem(d),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _buildTilePreview(d, type),
          ),
          // Badge tipo (video / documento) en esquina superior izquierda.
          if (type == 'video')
            Positioned(
              top: 6,
              left: 6,
              child: _badge(Icons.play_arrow, 'Video'),
            )
          else if (type == 'document')
            Positioned(
              top: 6,
              left: 6,
              child: _badge(Icons.description, _shortFileName(d)),
            ),
          // Dirección (enviado/recibido) en esquina inferior derecha.
          Positioned(
            bottom: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                fromMe ? Icons.call_made : Icons.call_received,
                size: 12,
                color: fromMe ? accentAqua : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 70),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Preview del tile. Prioridad:
  // 1. thumb base64 (Baileys jpegThumbnail) — instantáneo.
  // 2. mediaUrl si ya está ready (cubre el thumb encima sin saltos).
  // 3. Para documentos sin thumb: ícono + extensión.
  Widget _buildTilePreview(Map<String, dynamic> d, String? type) {
    final thumb64 = d['mediaThumbBase64'] as String?;
    final url = d['mediaUrl'] as String?;
    final status = d['mediaStatus'] as String?;

    // Documentos: card con ícono (no tienen thumb).
    if (type == 'document') {
      return Container(
        color: surfaceDark,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_iconForDoc(d['mediaFileName'] as String?),
                  size: 36, color: primaryAqua),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  _shortFileName(d),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: white,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final hasThumb = thumb64 != null && thumb64.isNotEmpty;
    final hasUrl = url != null && url.isNotEmpty && type == 'image';

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasThumb)
          Image.memory(
            base64Decode(thumb64),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          )
        else
          Container(color: surfaceDark),
        if (hasUrl)
          Image.network(
            url,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (_, child, p) =>
                p == null ? child : const SizedBox.shrink(),
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        if (status == 'failed')
          const Center(
            child: Icon(Icons.error_outline,
                color: Color(0xFFF87171), size: 24),
          ),
      ],
    );
  }

  IconData _iconForDoc(String? fileName) {
    final ext = (fileName ?? '').toLowerCase().split('.').last;
    if (ext == 'pdf') return Icons.picture_as_pdf;
    if (ext == 'doc' || ext == 'docx') return Icons.description;
    if (ext == 'xls' || ext == 'xlsx' || ext == 'csv') return Icons.table_chart;
    if (ext == 'zip' || ext == 'rar' || ext == '7z') return Icons.folder_zip;
    return Icons.insert_drive_file;
  }

  String _shortFileName(Map<String, dynamic> d) {
    final name = d['mediaFileName'] as String?;
    if (name == null || name.isEmpty) return 'Documento';
    return name;
  }

  // Acción al tocar un tile:
  // - imagen → fullscreen viewer in-app con botón "Ver en chat".
  // - video / documento → abrir en app externa (url_launcher).
  Future<void> _openItem(Map<String, dynamic> d) async {
    final type = d['mediaType'] as String?;
    final url = d['mediaUrl'] as String?;
    final status = d['mediaStatus'] as String?;

    if (type == 'image') {
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, __, ___) => _MediaFullscreenViewer(
            data: d,
            onJumpToChat: () {
              final chatId = d['chatId'] as String?;
              if (chatId == null) return;
              // Cerrar viewer + cerrar vault + delegar a ChatsScreen.
              Navigator.of(context).pop();
              Navigator.of(context).pop();
              widget.onJumpToChat?.call(chatId);
            },
          ),
        ),
      );
      return;
    }

    // Videos y documentos: necesitamos URL lista.
    if (url == null || url.isEmpty || status != 'ready') {
      _toast('Aún no se terminó de descargar. Probá de nuevo en un segundo.');
      return;
    }

    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _toast('No se pudo abrir el archivo');
    } catch (e) {
      _toast('Error al abrir: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: surfaceDark,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // Agrupa items por fecha con label legible (Hoy / Ayer / dd MMM yyyy).
  List<_DateGroup> _groupByDate(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> items) {
    final groups = <String, _DateGroup>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final doc in items) {
      final ts = doc.data()['timestamp'];
      if (ts is! Timestamp) continue;
      final dt = ts.toDate();
      final dayKey = DateTime(dt.year, dt.month, dt.day);
      final keyStr = dayKey.toIso8601String();

      String label;
      if (dayKey == today) {
        label = 'Hoy';
      } else if (dayKey == yesterday) {
        label = 'Ayer';
      } else {
        label = _formatDate(dayKey);
      }

      groups.putIfAbsent(keyStr, () => _DateGroup(label: label, items: []));
      groups[keyStr]!.items.add(doc);
    }

    // Mapa preserva orden de inserción; como los items ya vienen desc por
    // timestamp, los grupos también quedan desc → no hace falta re-sort.
    return groups.values.toList();
  }

  String _formatDate(DateTime d) {
    const months = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

class _DateGroup {
  final String label;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> items;
  _DateGroup({required this.label, required this.items});
}

// ============================================
// Visor fullscreen de imagen con botón "Ver en chat".
// Estilo WhatsApp: imagen con zoom + barra inferior con metadatos y CTA.
// ============================================
class _MediaFullscreenViewer extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onJumpToChat;

  const _MediaFullscreenViewer({
    required this.data,
    required this.onJumpToChat,
  });

  @override
  Widget build(BuildContext context) {
    final url = data['mediaUrl'] as String?;
    final thumb64 = data['mediaThumbBase64'] as String?;
    final contactName = data['contactName'] as String? ?? '';
    final chatId = data['chatId'] as String? ?? '';
    final fromMe = data['fromMe'] == true;
    final ts = data['timestamp'];
    final dateLabel = ts is Timestamp ? _formatFull(ts.toDate()) : '';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              contactName.isNotEmpty ? contactName : chatId,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${fromMe ? "Tú · " : ""}$dateLabel',
              style: const TextStyle(color: lightText, fontSize: 11),
            ),
          ],
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: url != null && url.isNotEmpty
              ? Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image,
                    color: lightText,
                    size: 48,
                  ),
                )
              : thumb64 != null && thumb64.isNotEmpty
                  ? Image.memory(base64Decode(thumb64), fit: BoxFit.contain)
                  : const Icon(Icons.broken_image,
                      color: lightText, size: 48),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton.icon(
            onPressed: onJumpToChat,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Ver en chat'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAqua,
              foregroundColor: darkBg,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatFull(DateTime d) {
    const months = [
      'ene', 'feb', 'mar', 'abr', 'may', 'jun',
      'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
    ];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year} · $h:$m';
  }
}
