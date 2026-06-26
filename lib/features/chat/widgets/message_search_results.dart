import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// Normaliza texto para búsqueda: minúsculas + sin acentos (gemelo del helper
/// `normalizeForSearch` del backend). "Está" → "esta", "niño" → "nino". Así el
/// query del usuario y los tokens indexados se comparan con el mismo criterio.
String normalizeForSearch(String text) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final lower = text.toLowerCase();
  final buf = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    buf.write(i >= 0 ? to[i] : ch);
  }
  return buf.toString();
}

/// Extrae las palabras buscables del query (mín. 2 chars), mismo criterio que
/// `buildSearchTokens` del backend. Devuelve [] si no hay nada indexable.
List<String> _queryTokens(String query) {
  final normalized = normalizeForSearch(query);
  return normalized
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length >= 2)
      .toList();
}

/// Sección "Mensajes" del buscador: consulta `message_index` por palabra
/// (`array-contains`) y refina frases en cliente. Se renderiza embebida dentro
/// del scroll del buscador en ChatsScreen.
///
/// Debounce interno: solo dispara la query a Firestore cuando el texto deja de
/// cambiar (~350ms) y es distinto al último buscado. Un rebuild del padre con
/// el mismo `query` NO re-consulta.
class MessageSearchResults extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String query;

  /// Abre el chat del resultado tocado (lo resuelve el padre: setea
  /// selectedChatPhone y colapsa el buscador). Si se toca una fila de mensaje
  /// concreta, pasa `messageId`+`timestamp` para que el chat salte a esa burbuja
  /// y la resalte; el header del grupo abre el chat sin objetivo.
  final void Function(String chatId, {String? messageId, DateTime? timestamp})
      onOpenChat;

  const MessageSearchResults({
    required this.accountId,
    required this.sessionId,
    required this.query,
    required this.onOpenChat,
    super.key,
  });

  @override
  State<MessageSearchResults> createState() => _MessageSearchResultsState();
}

class _MessageSearchResultsState extends State<MessageSearchResults> {
  static const _resultLimit = 50;

  Timer? _debounce;
  String _lastSearched = '';
  bool _loading = false;
  bool _backfilling = false;
  // Una vez que el histórico se indexó (flag en el doc de sesión), los mensajes
  // nuevos se indexan solos → ocultamos el botón de backfill. null = aún no
  // sabemos (no leído); false = falta indexar; true = ya está.
  bool _backfilled = false;
  String? _error;
  List<_MessageHit> _hits = const [];

  @override
  void initState() {
    super.initState();
    _loadBackfillFlag();
    _scheduleSearch(widget.query);
  }

  // Lee una sola vez si esta sesión ya corrió el backfill completo.
  Future<void> _loadBackfillFlag() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .get();
      final done = snap.data()?['message_index_backfilled_at'] != null;
      if (mounted && done) setState(() => _backfilled = true);
    } catch (_) {
      // Si falla la lectura, dejamos el botón visible (fail-safe: mejor
      // ofrecerlo de más que esconder una acción útil).
    }
  }

  @override
  void didUpdateWidget(MessageSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _scheduleSearch(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleSearch(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(query));
  }

  Future<void> _run(String query) async {
    final tokens = _queryTokens(query);
    if (tokens.isEmpty) {
      if (mounted) setState(() {
        _hits = const [];
        _loading = false;
        _lastSearched = query;
      });
      return;
    }
    if (query == _lastSearched && _hits.isNotEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    // Ancla = token más largo (más selectivo → menos lecturas). El resto del
    // query se aplica como filtro de frase en cliente sobre `text`.
    final anchor =
        tokens.reduce((a, b) => b.length > a.length ? b : a);
    final phrase = normalizeForSearch(query.trim());

    try {
      final snap = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('message_index')
          .where('searchTokens', arrayContains: anchor)
          .orderBy('timestamp', descending: true)
          .limit(_resultLimit)
          .get();

      final hits = <_MessageHit>[];
      for (final doc in snap.docs) {
        final d = doc.data();
        final text = (d['text'] as String?) ?? '';
        // Refinamiento de frase: el texto normalizado debe contener el query
        // completo. Para una sola palabra esto siempre pasa (el ancla ya
        // garantizó el match); para frases exige adyacencia, como WhatsApp.
        if (!normalizeForSearch(text).contains(phrase)) continue;
        hits.add(_MessageHit(
          chatId: (d['chatId'] as String?) ?? doc.id,
          // El doc del índice usa el messageId como id (y lo duplica en el
          // campo); con él el chat puede saltar a la burbuja exacta.
          messageId: (d['messageId'] as String?) ?? doc.id,
          text: text,
          contactName: d['contactName'] as String?,
          fromMe: d['fromMe'] as bool? ?? false,
          timestamp: (d['timestamp'] as Timestamp?)?.toDate(),
        ));
      }

      if (mounted) setState(() {
        _hits = hits;
        _loading = false;
        _lastSearched = query;
      });
    } catch (e) {
      // No ocultamos el fallo: el caso más común en el primer uso es que falta
      // desplegar el índice compuesto de Firestore (FAILED_PRECONDITION con una
      // URL para crearlo). Mostrarlo evita el falso "sin coincidencias".
      final msg = e.toString();
      if (mounted) setState(() {
        _hits = const [];
        _loading = false;
        _lastSearched = query;
        _error = msg.contains('failed-precondition') || msg.contains('index')
            ? 'Falta desplegar el índice de Firestore.\n'
                'Ejecuta: firebase deploy --only firestore:indexes'
            : 'Error al buscar: $msg';
      });
    }
  }

  // Indexa el histórico previo a la feature. Mismo patrón que el media vault.
  // Es de un solo uso por sesión: al terminar marca _backfilled y el botón se
  // oculta (los mensajes nuevos ya se indexan solos al llegar).
  Future<void> _runBackfill() async {
    setState(() => _backfilling = true);
    final messenger = ScaffoldMessenger.of(context);
    // Aviso de arranque: el backfill recorre todo el histórico y puede tardar
    // (decenas de segundos en sesiones grandes). Sin esto parece colgado.
    messenger.showSnackBar(const SnackBar(
      content: Text('Indexando historial, puede tardar un momento...'),
      duration: Duration(seconds: 3),
    ));
    try {
      final resp = await http.post(
        Uri.parse('$backendUrl/backfill-message-index'),
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
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(
          content: Text('$indexed mensajes indexados'),
          backgroundColor: accentAqua,
        ));
        // El histórico quedó indexado → ocultamos el botón a partir de ahora.
        setState(() => _backfilled = true);
        _lastSearched = ''; // forzar re-consulta
        await _run(widget.query);
      } else {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text('Error ${resp.statusCode}')),
        );
      }
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_queryTokens(widget.query).isEmpty) {
      return _hint('Escribe al menos 2 letras para buscar en mensajes');
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: primaryAqua),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFF59E0B), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!,
                  style: const TextStyle(
                      color: Color(0xFFF59E0B), fontSize: 12)),
            ),
          ],
        ),
      );
    }
    if (_hits.isEmpty) {
      return Column(
        children: [
          _hint('Sin coincidencias en mensajes'),
          _backfillButton(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._groupHits().map((g) => _ChatHitGroup(
              group: g,
              query: widget.query,
              onOpenChat: widget.onOpenChat,
            )),
        _backfillButton(),
      ],
    );
  }

  // Agrupa los hits por chat preservando el orden. Como `_hits` ya viene
  // ordenado por fecha desc, el primer hit que vemos de cada chat fija su
  // posición → los chats quedan ordenados por su coincidencia más reciente, y
  // dentro de cada uno los mensajes mantienen el orden desc. Así un mismo
  // contacto que repitió una palabra aparece una sola vez, con sus mensajes
  // listados debajo (en vez de una fila por mensaje).
  List<_ChatGroup> _groupHits() {
    final groups = <String, _ChatGroup>{};
    for (final h in _hits) {
      groups.putIfAbsent(
        h.chatId,
        () => _ChatGroup(
          chatId: h.chatId,
          contactName: h.contactName,
          hits: [],
        ),
      ).hits.add(h);
    }
    return groups.values.toList();
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: lightText, fontSize: 13),
        ),
      );

  // CTA discreto para indexar mensajes viejos que aún no están en el índice.
  // Se oculta una vez que el histórico ya se indexó (salvo que esté corriendo
  // ahora mismo, para no hacer desaparecer el spinner a mitad de camino).
  Widget _backfillButton() {
    if (_backfilled && !_backfilling) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: TextButton.icon(
          onPressed: _backfilling ? null : _runBackfill,
          icon: _backfilling
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: primaryAqua),
                )
              : const Icon(Icons.history, size: 16),
          label: Text(
            _backfilling
                ? 'Indexando historial...'
                : '¿Falta un mensaje antiguo? Indexar historial',
            style: const TextStyle(fontSize: 12),
          ),
          style: TextButton.styleFrom(foregroundColor: lightText),
        ),
      );
  }
}

class _MessageHit {
  final String chatId;
  final String messageId;
  final String text;
  final String? contactName;
  final bool fromMe;
  final DateTime? timestamp;

  const _MessageHit({
    required this.chatId,
    required this.messageId,
    required this.text,
    required this.contactName,
    required this.fromMe,
    required this.timestamp,
  });
}

// Todos los hits de un mismo chat, en el orden desc en que llegaron de `_hits`.
class _ChatGroup {
  final String chatId;
  final String? contactName;
  final List<_MessageHit> hits;

  _ChatGroup({
    required this.chatId,
    required this.contactName,
    required this.hits,
  });
}

// Un contacto con sus mensajes coincidentes anidados: header (avatar + nombre)
// una sola vez, y debajo cada match con su fecha tras una guía vertical aqua.
// Tanto el header como cada fila abren el chat.
class _ChatHitGroup extends StatelessWidget {
  final _ChatGroup group;
  final String query;
  final void Function(String chatId, {String? messageId, DateTime? timestamp})
      onOpenChat;

  const _ChatHitGroup({
    required this.group,
    required this.query,
    required this.onOpenChat,
  });

  @override
  Widget build(BuildContext context) {
    final title = (group.contactName?.trim().isNotEmpty ?? false)
        ? group.contactName!.trim()
        : group.chatId;
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => onOpenChat(group.chatId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: primaryAqua.withValues(alpha: 0.2),
                  child: Text(initial,
                      style: const TextStyle(
                          color: primaryAqua, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
        // Guía vertical aqua alineada bajo el avatar para comunicar la jerarquía
        // de los mensajes respecto al contacto.
        Padding(
          padding: const EdgeInsets.only(left: 35, bottom: 4),
          // IntrinsicHeight acota la guía vertical a la altura de la columna de
          // mensajes; sin esto, el `stretch` pide altura infinita dentro del
          // ListView (no acotado verticalmente) y revienta el layout.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 2,
                  margin: const EdgeInsets.only(top: 4, bottom: 4),
                  color: primaryAqua.withValues(alpha: 0.25),
                ),
                Expanded(
                  child: Column(
                    children: group.hits
                        .map((h) => _MessageHitRow(
                              hit: h,
                              query: query,
                              onTap: () => onOpenChat(h.chatId,
                                  messageId: h.messageId,
                                  timestamp: h.timestamp),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageHitRow extends StatelessWidget {
  final _MessageHit hit;
  final String query;
  final VoidCallback onTap;

  const _MessageHitRow({
    required this.hit,
    required this.query,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _snippet()),
            if (hit.timestamp != null) ...[
              const SizedBox(width: 8),
              Text(_formatDate(hit.timestamp!),
                  style: const TextStyle(color: lightText, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }

  // Snippet centrado en la coincidencia con el término resaltado en aqua.
  // El match se busca por substring case-insensitive sobre el texto tal cual
  // (sin quitar acentos): cubre el caso común de que lo mostrado coincida con
  // lo tecleado. Si no encuentra match exacto, muestra el inicio sin resaltar.
  Widget _snippet() {
    final prefix = hit.fromMe ? 'Tú: ' : '';
    final text = hit.text.replaceAll('\n', ' ').trim();
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase().trim();

    final idx = lowerQuery.isEmpty ? -1 : lowerText.indexOf(lowerQuery);

    // Ventana: ~30 chars antes del match para dar contexto.
    final start = idx > 30 ? idx - 30 : 0;
    final shown = text.substring(start,
        (start + 140).clamp(0, text.length));
    final ellipsisL = start > 0 ? '…' : '';
    final ellipsisR = start + 140 < text.length ? '…' : '';

    final spans = <TextSpan>[
      TextSpan(text: '$prefix$ellipsisL'),
    ];

    if (idx < 0 || lowerQuery.isEmpty) {
      spans.add(TextSpan(text: shown));
    } else {
      // Resaltar todas las ocurrencias del query dentro del fragmento mostrado.
      final lowerShown = shown.toLowerCase();
      var cursor = 0;
      while (true) {
        final m = lowerShown.indexOf(lowerQuery, cursor);
        if (m < 0) {
          spans.add(TextSpan(text: shown.substring(cursor)));
          break;
        }
        if (m > cursor) {
          spans.add(TextSpan(text: shown.substring(cursor, m)));
        }
        spans.add(TextSpan(
          text: shown.substring(m, m + lowerQuery.length),
          style: const TextStyle(
              color: primaryAqua, fontWeight: FontWeight.w600),
        ));
        cursor = m + lowerQuery.length;
      }
    }
    spans.add(TextSpan(text: ellipsisR));

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(color: lightText, fontSize: 13),
        children: spans,
      ),
    );
  }

  static String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return 'Ayer';
    if (diff < 7) {
      const dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
      return dias[d.weekday - 1];
    }
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year % 100}';
  }
}
