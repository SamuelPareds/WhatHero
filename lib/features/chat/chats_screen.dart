import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/active_chat_tracker.dart';
import 'package:crm_whatsapp/core/services/ai_state_service.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/services/notification_service.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/core/services/storage_service.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'package:crm_whatsapp/features/accounts.dart';
import 'messages_view.dart';
import 'media_vault_screen.dart';
import 'widgets/ai_state_indicator.dart';
import 'widgets/message_search_results.dart';
import 'widgets/unread_badge.dart';
import 'widgets/label_chip.dart';
import 'widgets/labels_selector_sheet.dart';

// Filtros rápidos de la lista de chats (estilo chips de WhatsApp).
// todos / no respondidos / con notas son fijos; `etiqueta` filtra por una
// etiqueta concreta del catálogo (su id va en `_activeLabelId`).
enum ChatFilter { todos, seguimiento, noRespondidos, conNotas, etiqueta }

class ChatsScreen extends StatefulWidget {
  final String? sessionId;
  final String? sessionKey;
  final String accountId;
  final String? initialAlias;

  const ChatsScreen({
    this.sessionId,
    this.sessionKey,
    required this.accountId,
    this.initialAlias,
    super.key,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String? selectedChatPhone;
  // Salto a un mensaje concreto al abrir un chat desde el buscador. Lo consume
  // MessagesView (carga hasta él + scroll + resalte) y avisa con onJumpConsumed
  // para limpiarlo, de modo que volver a tocar el mismo resultado re-dispare.
  String? _jumpToMessageId;
  DateTime? _jumpToTimestamp;
  String searchQuery = '';
  // Búsqueda expandible: colapsada muestra solo el icono 🔍 junto al nombre de
  // la sesión; al expandir, el campo tapa nombre+número para escribir cómodo.
  bool _searchExpanded = false;
  // Filtro rápido activo. Se aplica en memoria sobre los chats ya descargados
  // por el StreamBuilder, antes del filtro de búsqueda — cero lecturas extra.
  ChatFilter _activeFilter = ChatFilter.todos;
  // Etiqueta activa cuando `_activeFilter == ChatFilter.etiqueta`. Es el id del
  // doc en el catálogo; null en cualquier otro filtro.
  String? _activeLabelId;
  // Contadores por filtro. Los chips viven en el AppBar (fuera del StreamBuilder
  // del body), así que el body los publica aquí y los chips se suscriben sin
  // rebuildar toda la pantalla.
  final ValueNotifier<({int unresponded, int notes, int followups})> _filterCounts =
      ValueNotifier((unresponded: 0, notes: 0, followups: 0));
  final TextEditingController searchController = TextEditingController();

  StreamSubscription? _statusSubscription;
  StreamSubscription? _humanAttentionSubscription;
  StreamSubscription? _labelsSubscription;
  // Intención de deep-link compartida con SessionDispatcher. Esta pantalla solo
  // abre chats de SU sesión; el cambio de sesión lo orquesta el dispatcher.
  ValueNotifier<HumanAttentionPush?>? _pendingTap;

  // Cache del catálogo de etiquetas de la sesión actual. Se mantiene en
  // memoria para que cada `_ChatTile` resuelva sus chips sin abrir su propio
  // StreamBuilder (catálogo pequeño, lookups frecuentes).
  Map<String, ChatLabel> _labelsCatalog = const {};

  // Flash efímero "cancelado": cuando el usuario apaga la IA durante un ciclo
  // activo, marcamos este chat por ~3s para mostrar feedback en subtítulo+barra.
  // Pasados esos segundos volvemos al estado natural (sin etiquetas), porque
  // con la IA off en este chat ya no aplica "tu turno" — responde el humano.
  String? _cancelledChatPhone;
  Timer? _cancelledTimer;

  // Galería de medios como capa (no como ruta): así queda viva Offstage debajo
  // de un chat abierto desde ella, y el back regresa a la galería con su scroll
  // y filtros intactos — mismo patrón que la persistencia del buscador.
  bool _showMediaVault = false;

  @override
  void initState() {
    super.initState();
    if (widget.sessionId != null && widget.sessionKey != null) {
      _setupSocketListeners();
      // Guardar esta sesión como la última activa
      StorageService().saveLastSessionId(widget.sessionId!);
    }
    if (widget.sessionId != null) {
      _subscribeToLabels();
    }

    // Cold-start: la app abrió por un tap a una notificación push.
    // Future-based: NotificationService completa el Future cuando terminó de
    // chequear getInitialMessage. Así no importa si esto resuelve antes o
    // después de que ChatsScreen se montó — la race condition desaparece.
    NotificationService().initialTapReady.then((push) {
      if (push != null) _handlePushTap(push);
    });

    // Tap a notif con app viva (background/foreground): intención compartida.
    // La leemos al montar (clave: si el dispatcher acaba de remontar esta
    // pantalla por un cambio de sesión, el valor ya está puesto y debemos
    // consumirlo aquí) y también escuchamos cambios en vivo.
    _pendingTap = NotificationService().pendingTap;
    _pendingTap!.addListener(_onPendingTap);
    if (_pendingTap!.value != null) _handlePushTap(_pendingTap!.value!);
  }

  void _onPendingTap() {
    final push = _pendingTap?.value;
    if (push != null) _handlePushTap(push);
  }

  // Abre el chat indicado por el push. Validaciones:
  // - widget aún montado
  // - payload válido (accountId + chatId)
  // - existe sessionId actual (sin él, _buildMessageDetail renderiza vacío y
  //   el usuario vería pantalla en negro; mejor no navegar)
  // - el push apunta a ESTA sesión. Si apunta a otra, NO es nuestro trabajo:
  //   SessionDispatcher remonta la ChatsScreen de la sesión correcta y esa
  //   instancia entra aquí con la sesión ya coincidente. Por eso NO consumimos
  //   la intención cuando no es nuestra — la deja viva para esa otra pantalla.
  void _handlePushTap(HumanAttentionPush push) {
    if (!mounted) return;
    if (!push.isValid) return;
    if (widget.sessionId == null) return;
    if (push.sessionPhone.isNotEmpty &&
        push.sessionPhone != widget.sessionId) {
      return;
    }
    debugPrint('[ChatsScreen] Deep-link a chat ${push.chatId}');
    setState(() => selectedChatPhone = push.chatId);
    // Consumimos la intención (si vino del notifier compartido) para que no se
    // re-dispare en rebuilds. El cold-start llega por initialTapReady, donde
    // pendingTap es null, así que el guard `== push` evita limpiar de más.
    if (_pendingTap?.value == push) _pendingTap!.value = null;
  }

  void _subscribeToLabels() {
    _labelsSubscription = FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(widget.accountId)
        .collection('whatsapp_sessions')
        .doc(widget.sessionId)
        .collection('labels')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _labelsCatalog = {
          for (final d in snap.docs) d.id: ChatLabel.fromDoc(d),
        };
      });
    });
  }

  void _setupSocketListeners() {
    if (widget.sessionKey == null) return;
    
    // Escuchar el estado de la sesión
    _statusSubscription = SocketService().statusStream.listen((event) {
      if (event.sessionKey == widget.sessionKey) {
        if (event.status == 'logged_out' || event.status == 'disconnected') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sesión ${widget.sessionId} desconectada'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    });

    // Escuchar alertas de atención humana
    _humanAttentionSubscription = SocketService().humanAttentionStream.listen((data) {
      if (data['sessionKey'] == widget.sessionKey) {
        debugPrint('[ChatsScreen] Atención humana requerida para: ${data['contactPhone']}');
      }
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    _statusSubscription?.cancel();
    _humanAttentionSubscription?.cancel();
    _labelsSubscription?.cancel();
    _pendingTap?.removeListener(_onPendingTap);
    _cancelledTimer?.cancel();
    _filterCounts.dispose();
    ActiveChatTracker.instance.clear();
    super.dispose();
  }

  // Marca este chat como "recién cancelado" durante ~3s. Reinicia el timer si
  // se apaga repetidamente, así no se acumulan ventanas zombies.
  void _markChatCancelled(String chatPhone) {
    _cancelledTimer?.cancel();
    setState(() => _cancelledChatPhone = chatPhone);
    _cancelledTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _cancelledChatPhone = null);
      }
    });
  }

  // 📌 Ethereal Bubble Notification with face_retouching_natural icon
  void _showEtherealToast(bool success, String message, {bool isActivating = true}) {
    final overlayState = Overlay.of(context);
    late OverlayEntry overlayEntry;

    // Determine colors based on explicit isActivating parameter (not message content)
    final primaryColor = isActivating ? const Color(0xFF10B981) : const Color(0xFF9CA3AF);

    overlayEntry = OverlayEntry(
      builder: (context) => Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 400),
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.scale(
                scale: 0.8 + (value * 0.2),
                child: child,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.12),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.25),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: 0.15),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                    // Icon with dynamic indicator
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.face_retouching_natural,
                          size: 48,
                          color: primaryColor.withValues(alpha: 0.7),
                        ),
                        // Dynamic check/indicator
                        Positioned(
                          bottom: -4,
                          right: -4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: isActivating ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: (isActivating ? const Color(0xFF10B981) : const Color(0xFF9CA3AF))
                                      .withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Icon(
                              isActivating ? Icons.check : Icons.close,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      softWrap: true,
                      style: TextStyle(
                        color: primaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    );

    overlayState.insert(overlayEntry);

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        overlayEntry.remove();
      }
    });
  }

  // Abre la galería de medios de la sesión actual. En vez de empujar una ruta,
  // levantamos una capa dentro de esta pantalla (ver build): así, al saltar a un
  // chat desde la galería, ésta sobrevive Offstage y el back vuelve a ella.
  void _openMediaVault() {
    if (widget.sessionId == null) return;
    setState(() => _showMediaVault = true);
  }

  // "Ver en chat" desde la galería. Móvil: dejamos la galería viva (Offstage)
  // debajo del chat para volver a ella con el back. Desktop: la cerramos y el
  // chat aparece en el split view (comportamiento previo de la ruta).
  void _onMediaJumpToChat(String chatId) {
    if (!mounted) return;
    // La galería sobrevive montada al saltar; soltamos el foco de su buscador
    // para que su teclado no quede sobre el detalle del chat.
    FocusScope.of(context).unfocus();
    final isMobile = MediaQuery.of(context).size.width < 600;
    setState(() {
      selectedChatPhone = chatId;
      if (!isMobile) _showMediaVault = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Reportamos al rastreador qué chat está abierto, para que el banner de
    // push se suprima si llega un aviso del chat que ya estás viendo. Es un
    // contenedor de valores sin listeners → no provoca rebuilds.
    ActiveChatTracker.instance.update(
      sessionPhone: widget.sessionId,
      chatId: selectedChatPhone,
    );

    final isMobile = MediaQuery.of(context).size.width < 600;

    final Widget content = isMobile
        // Mantenemos la lista SIEMPRE montada (Offstage cuando hay un chat
        // abierto) en vez de reemplazarla por el detalle. Así el journey
        // búsqueda→chat→back es instantáneo: al volver, MessageSearchResults
        // conserva sus hits (cero re-lecturas, sin spinner) y la lista su scroll.
        // El detalle se dibuja encima solo cuando hace falta, así MessagesView
        // (pesada) no se construye mientras estás en la lista.
        ? Stack(
            children: [
              Offstage(
                offstage: selectedChatPhone != null,
                child: _buildChatsList(),
              ),
              if (selectedChatPhone != null) _buildMessageDetail(),
            ],
          )
        : Scaffold(
            body: Row(
              children: [
                SizedBox(width: 400, child: _buildChatsList()),
                Expanded(
                  child: selectedChatPhone != null
                      ? _buildMessageDetail()
                      : Container(
                          color: darkBg,
                          child: const Center(
                            child: Text(
                              'Selecciona un chat para empezar',
                              style: TextStyle(
                                fontSize: 18,
                                color: lightText,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          );

    if (!_showMediaVault) return content;

    // Galería de medios como capa superior. En móvil queda viva Offstage cuando
    // hay un chat abierto desde ella, para que el back regrese a la galería con
    // su estado intacto (mismo patrón que el buscador). En desktop se muestra
    // full-screen y se cierra al saltar a un chat (ver _onMediaJumpToChat).
    return Stack(
      children: [
        content,
        Offstage(
          offstage: isMobile && selectedChatPhone != null,
          child: MediaVaultScreen(
            accountId: widget.accountId,
            sessionId: widget.sessionId!,
            sessionAlias: widget.initialAlias ?? widget.sessionId!,
            onClose: () => setState(() => _showMediaVault = false),
            onJumpToChat: _onMediaJumpToChat,
          ),
        ),
      ],
    );
  }

  Widget _buildChatsList() {
    if (widget.sessionId == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('WhatHero', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: white)),
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.smartphone,
                  size: 64,
                  color: primaryAqua.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Bienvenido a WhatHero',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Para comenzar a gestionar tus chats, vincula una cuenta de WhatsApp.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: lightText,
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) => 
                            AccountsScreen(accountId: widget.accountId),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: Tween<double>(begin: 0.98, end: 1.0).animate(
                                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                              ),
                              child: child,
                            ),
                          );
                        },
                        transitionDuration: const Duration(milliseconds: 400),
                      ),
                    );
                  },
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: const Text('Gestionar Cuentas'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAqua,
                    foregroundColor: darkBg,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.manage_accounts_outlined, color: primaryAqua),
          onPressed: () {
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) => 
                    AccountsScreen(accountId: widget.accountId),
                transitionsBuilder: (context, animation, secondaryAnimation, child) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.98, end: 1.0).animate(
                        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                      ),
                      child: child,
                    ),
                  );
                },
                transitionDuration: const Duration(milliseconds: 400),
              ),
            );
          },
          tooltip: 'Gestionar Cuentas',
        ),
        title: _searchExpanded
            ? _buildSearchField()
            : StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection(accountsCollection)
              .doc(widget.accountId)
              .collection('whatsapp_sessions')
              .doc(widget.sessionId)
              .snapshots(),
          builder: (context, snapshot) {
            String title = widget.initialAlias ?? 'WhatHero';
            if (snapshot.hasData && snapshot.data!.exists) {
              title = snapshot.data!.get('alias') ?? widget.sessionId ?? title;
            }
            
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.sessionId!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: lightText,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            );
          },
        ),
        elevation: 0,
        // Expandido: solo la ✕ para cerrar (máximo ancho al campo). Colapsado:
        // 🔍 junto al nombre + galería y respuestas rápidas.
        actions: _searchExpanded
            ? [
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Cerrar búsqueda',
                  onPressed: _toggleSearch,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.search, size: 20),
                  tooltip: 'Buscar contacto o mensaje',
                  onPressed: _toggleSearch,
                ),
                // La galería de medios ya no vive aquí: al abrir la búsqueda
                // surge como atajo dentro del cuerpo (estilo WhatsApp), así
                // este slot del AppBar queda libre. Ver _buildMediaGalleryEntry.
                IconButton(
                  icon: const Icon(Icons.flash_on, size: 20),
                  tooltip: 'Respuestas rápidas',
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => QuickResponsesPanel(
                      sessionId: widget.sessionId!,
                      accountId: widget.accountId,
                    ),
                  ),
                ),
              ],
        bottom: PreferredSize(
          // Solo la fila de chips: la búsqueda ahora vive en el AppBar.
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _buildFilterChips(),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection(accountsCollection)
            .doc(widget.accountId)
            .collection('whatsapp_sessions')
            .doc(widget.sessionId)
            .collection('chats')
            .orderBy('lastMessageTimestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final allChats = snapshot.data!.docs;

          // Publicamos los totales por filtro para que los chips del AppBar
          // muestren su badge. Post-frame para no notificar durante el build.
          // Un chat cuenta como "pendiente" si tiene mensajes sin responder
          // (contador automático) O si fue marcado a mano (marked_pending).
          // Así el chip y el filtro unifican ambas señales bajo un concepto.
          final unrespondedTotal = allChats.where((d) {
            final m = d.data() as Map<String, dynamic>?;
            final count = (m?['unresponded_count'] as num?)?.toInt() ?? 0;
            final markedPending = m?['marked_pending'] as bool? ?? false;
            return count > 0 || markedPending;
          }).length;
          final notesTotal = allChats.where((d) {
            final m = d.data() as Map<String, dynamic>?;
            return ((m?['note'] as String?) ?? '').trim().isNotEmpty;
          }).length;
          // Chats que el agente de seguimiento dejó encolados (con borrador listo).
          final followupsTotal = allChats.where((d) {
            final m = d.data() as Map<String, dynamic>?;
            return (m?['followup_status'] as String?) == 'queued';
          }).length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final next = (unresponded: unrespondedTotal, notes: notesTotal, followups: followupsTotal);
            if (mounted && _filterCounts.value != next) {
              _filterCounts.value = next;
            }
            // Si vaciaron la cola estando en el filtro "Seguimiento", el chip se
            // oculta; degradamos a "Todos" para no dejar al usuario mirando vacío.
            if (mounted &&
                followupsTotal == 0 &&
                _activeFilter == ChatFilter.seguimiento) {
              setState(() => _activeFilter = ChatFilter.todos);
            }
          });

          // 1) Filtro rápido (chip activo). 2) Búsqueda. Se encadenan: puedes
          // buscar dentro de un filtro.
          final filteredChats = allChats.where((chatDoc) {
            final chatData = chatDoc.data() as Map<String, dynamic>?;

            // Filtro rápido
            switch (_activeFilter) {
              case ChatFilter.todos:
                break;
              case ChatFilter.seguimiento:
                if ((chatData?['followup_status'] as String?) != 'queued') {
                  return false;
                }
              case ChatFilter.noRespondidos:
                final count =
                    (chatData?['unresponded_count'] as num?)?.toInt() ?? 0;
                final markedPending =
                    chatData?['marked_pending'] as bool? ?? false;
                if (count == 0 && !markedPending) {
                  return false;
                }
              case ChatFilter.conNotas:
                if (((chatData?['note'] as String?) ?? '').trim().isEmpty) {
                  return false;
                }
              case ChatFilter.etiqueta:
                // Si la etiqueta activa fue eliminada del catálogo, degradamos
                // a "todos" (no ocultamos chats por un id huérfano).
                if (_activeLabelId != null &&
                    _labelsCatalog.containsKey(_activeLabelId)) {
                  final ids = ((chatData?['labelIds'] as List?) ?? const [])
                      .whereType<String>();
                  if (!ids.contains(_activeLabelId)) return false;
                }
            }

            // Búsqueda (vacía = pasa todo). La nota también es buscable:
            // ej. "hombre" encuentra el chat anotado "Quiere masaje pero es
            // hombre".
            if (searchQuery.isEmpty) return true;
            final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
            final contactName = chatData?['contactName'] as String? ?? '';
            final note = chatData?['note'] as String? ?? '';
            return phoneNumber.toLowerCase().contains(searchQuery) ||
                contactName.toLowerCase().contains(searchQuery) ||
                note.toLowerCase().contains(searchQuery);
          }).toList();

          // El empty-state grande solo aplica SIN búsqueda. Al buscar, aunque
          // ningún chat coincida por nombre, _buildSearchBody igual muestra la
          // sección "Mensajes" (el caso más valioso de la búsqueda de texto).
          if (filteredChats.isEmpty && searchQuery.isEmpty) {
            // Empty state contextual: filtro activo > bandeja vacía. Así el
            // copy explica por qué no hay nada a la vista.
            final IconData emptyIcon;
            final String emptyTitle;
            final String emptySubtitle;
            if (_activeFilter == ChatFilter.seguimiento) {
              emptyIcon = Icons.campaign_outlined;
              emptyTitle = 'Sin seguimientos pendientes';
              emptySubtitle = 'El agente dejará aquí los chats listos para reactivar';
            } else if (_activeFilter == ChatFilter.noRespondidos) {
              emptyIcon = Icons.mark_chat_read_outlined;
              emptyTitle = 'Todo respondido';
              emptySubtitle = 'No tienes mensajes pendientes por responder';
            } else if (_activeFilter == ChatFilter.conNotas) {
              emptyIcon = Icons.sticky_note_2_outlined;
              emptyTitle = 'Sin notas';
              emptySubtitle = 'Ningún chat tiene una nota todavía';
            } else if (_activeFilter == ChatFilter.etiqueta) {
              final labelName = _labelsCatalog[_activeLabelId]?.name ?? '';
              emptyIcon = Icons.label_off_outlined;
              emptyTitle = 'Sin chats con esta etiqueta';
              emptySubtitle = labelName.isEmpty
                  ? 'Ningún chat tiene esta etiqueta'
                  : 'Ningún chat tiene la etiqueta "$labelName"';
            } else {
              emptyIcon = Icons.chat_bubble_outline;
              emptyTitle = 'Sin chats';
              emptySubtitle =
                  'Los chats aparecerán aquí cuando recibas mensajes';
            }
            // El botón "Ir a Mis Cuentas" solo tiene sentido en la bandeja
            // realmente vacía, no cuando un filtro no arroja nada.
            final showAccountsCta = _activeFilter == ChatFilter.todos;
            return _withMediaShortcut(Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    emptyIcon,
                    size: 48,
                    color: primaryAqua.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    emptyTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    emptySubtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: lightText,
                    ),
                  ),
                  if (showAccountsCta) ...[
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.manage_accounts_outlined),
                      label: const Text('Ir a Mis Cuentas'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryAqua,
                        foregroundColor: darkBg,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ],
              ),
            ));
          }

          // Al buscar mostramos dos secciones (estilo WhatsApp): "Chats"
          // (match en memoria por nombre/teléfono/nota) y "Mensajes" (hits del
          // message_index por contenido). Sin búsqueda, lista normal.
          if (searchQuery.isNotEmpty) {
            return _buildSearchBody(filteredChats);
          }

          return _withMediaShortcut(ListView.separated(
            itemCount: filteredChats.length,
            // Divisor sutil entre chats, indentado para arrancar tras el avatar.
            separatorBuilder: (_, __) => Padding(
              padding: const EdgeInsets.only(left: 76),
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: white.withValues(alpha: 0.06),
              ),
            ),
            itemBuilder: (context, index) => _buildChatTile(filteredChats[index]),
          ));
        },
      ),
    );
  }

  // Construye el tile de un chat (con su swipe). Reutilizado por la lista normal
  // y por la sección "Chats" del buscador.
  Widget _buildChatTile(QueryDocumentSnapshot chatDoc) {
    final chatData = chatDoc.data() as Map<String, dynamic>?;

    final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
    final contactName = chatData?['contactName'] as String? ?? '';
    final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
    final timestamp = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();
    final unrespondedCount = (chatData?['unresponded_count'] as num?)?.toInt() ?? 0;
    final markedPending = chatData?['marked_pending'] as bool? ?? false;
    // Un chat está "pendiente" por la señal automática o por la marca
    // manual de seguimiento. Ambas pintan naranja y abren el swipe.
    final isPending = unrespondedCount > 0 || markedPending;
    final labelIds = ((chatData?['labelIds'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    final note = chatData?['note'] as String? ?? '';

    final tile = _ChatTile(
      phoneNumber: phoneNumber,
      contactName: contactName,
      lastMessage: lastMessage,
      timestamp: timestamp,
      isSelected: selectedChatPhone == phoneNumber,
      unrespondedCount: unrespondedCount,
      markedPending: markedPending,
      sessionKey: widget.sessionKey,
      labelIds: labelIds,
      labelsCatalog: _labelsCatalog,
      note: note,
      onTap: () {
        // La lista ahora sobrevive Offstage al abrir el chat; si el campo de
        // búsqueda estaba enfocado, su teclado quedaría montado sobre el
        // detalle. Soltamos el foco explícitamente (antes lo resolvía el
        // desmontaje de la lista).
        FocusScope.of(context).unfocus();
        setState(() {
          selectedChatPhone = phoneNumber;
        });
      },
      onLongPress: () => _showChatOptions(
          phoneNumber, contactName, labelIds, note, isPending),
    );

    // Swipe simétrico estilo WhatsApp: si el chat está pendiente,
    // la acción lo cierra ("Listo"); si no, lo marca a mano
    // ("Pendiente") para darle seguimiento aunque no haya pendientes.
    return Slidable(
      key: ValueKey('chat_$phoneNumber'),
      groupTag: 'chats',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.25,
        children: [
          if (isPending)
            SlidableAction(
              onPressed: (_) => _markAsResponded(phoneNumber),
              backgroundColor: const Color(0xFFF97316),
              foregroundColor: Colors.white,
              icon: Icons.mark_chat_read,
              label: 'Listo',
            )
          else
            SlidableAction(
              onPressed: (_) => _markAsPending(phoneNumber),
              backgroundColor: const Color(0xFFF97316),
              foregroundColor: Colors.white,
              icon: Icons.mark_chat_unread,
              label: 'Pendiente',
            ),
        ],
      ),
      child: tile,
    );
  }

  // Antepone el atajo a la galería de medios cuando la búsqueda está abierta
  // pero aún no escribes nada (campo vacío). Es el reemplazo del icono que vivía
  // en el AppBar: estilo WhatsApp, los medios surgen dentro de la vista de
  // búsqueda. Mientras escribes (searchQuery con texto) no aparece, para no
  // ensuciar los resultados de "Chats" y "Mensajes".
  Widget _withMediaShortcut(Widget child) {
    if (!_searchExpanded || searchQuery.isNotEmpty) return child;
    return Column(
      children: [
        _buildMediaGalleryEntry(),
        Divider(
          height: 1,
          thickness: 0.5,
          color: white.withValues(alpha: 0.06),
        ),
        Expanded(child: child),
      ],
    );
  }

  // Fila tappable que abre la galería de medios de la sesión. Mismo lenguaje
  // visual que un avatar de chat (cuadro aqua al 20%) para que se sienta nativa.
  Widget _buildMediaGalleryEntry() {
    return InkWell(
      onTap: _openMediaVault,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: primaryAqua.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.photo_library_outlined,
                color: primaryAqua,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Text(
                'Galería de medios',
                style: TextStyle(
                  color: white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: lightText, size: 20),
          ],
        ),
      ),
    );
  }

  // Cuerpo del buscador: sección "Chats" (en memoria) + sección "Mensajes"
  // (asíncrona, contra message_index). La sección Mensajes ignora el chip de
  // filtro activo: busca contenido en toda la sesión.
  Widget _buildSearchBody(List<QueryDocumentSnapshot> filteredChats) {
    return ListView(
      children: [
        if (filteredChats.isNotEmpty) ...[
          _searchSectionHeader('Chats'),
          ...filteredChats.map(_buildChatTile),
        ],
        _searchSectionHeader('Mensajes'),
        MessageSearchResults(
          accountId: widget.accountId,
          sessionId: widget.sessionId!,
          query: searchQuery,
          onOpenChat: (chatId, {messageId, timestamp}) {
            // Soltamos el foco del campo de búsqueda: con la lista viva Offstage,
            // su teclado quedaría montado sobre el detalle si no lo cerramos.
            FocusScope.of(context).unfocus();
            setState(() {
              selectedChatPhone = chatId;
              // Objetivo de salto: si se tocó una fila de mensaje, MessagesView
              // cargará hasta él y lo resaltará. El header del grupo no manda
              // messageId → abre el chat normal (abajo).
              _jumpToMessageId = messageId;
              _jumpToTimestamp = timestamp;
              // A diferencia de WhatsApp, NO colapsamos ni limpiamos la búsqueda
              // al saltar al chat: el estado (searchQuery/controller/expanded)
              // vive en el State, así que al volver con back reaparece la misma
              // búsqueda con sus resultados. Journey clave: evaluar cómo responde
              // el asistente a varios clientes que escribieron lo mismo, sin
              // retipear entre chat y chat. La sección "Chats" ya se comportaba
              // así; esto la alinea. Para salir de la búsqueda queda la ✕ del
              // campo (_toggleSearch).
            });
          },
        ),
      ],
    );
  }

  Widget _searchSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: primaryAqua.withValues(alpha: 0.8),
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // Alterna la búsqueda expandible. Al cerrar limpia el término para no dejar
  // la lista filtrada de forma invisible (sin el campo a la vista).
  void _toggleSearch() {
    setState(() {
      _searchExpanded = !_searchExpanded;
      if (!_searchExpanded) {
        searchController.clear();
        searchQuery = '';
      }
    });
  }

  // Campo de búsqueda que ocupa el slot del título cuando está expandido.
  // Autofocus para que el teclado aparezca apenas se toca el icono.
  Widget _buildSearchField() {
    return TextField(
      controller: searchController,
      autofocus: true,
      onChanged: (value) => setState(() => searchQuery = value.toLowerCase()),
      style: const TextStyle(color: white, fontSize: 18),
      cursorColor: primaryAqua,
      decoration: const InputDecoration(
        hintText: 'Buscar contacto o mensaje...',
        hintStyle: TextStyle(color: lightText, fontSize: 18),
        border: InputBorder.none,
        isCollapsed: true,
      ),
    );
  }

  // Fila horizontal de chips de filtro rápido (estilo WhatsApp). Vive en el
  // AppBar, así que lee los contadores vía ValueListenableBuilder para que su
  // badge se actualice sin rebuildar toda la pantalla.
  Widget _buildFilterChips() {
    // Etiquetas del catálogo ordenadas, para pintar un chip por cada una.
    final labels = _labelsCatalog.values.toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    return SizedBox(
      height: 36,
      child: ValueListenableBuilder<({int unresponded, int notes, int followups})>(
        valueListenable: _filterCounts,
        builder: (context, counts, _) {
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _FilterChip(
                label: 'Todos',
                selected: _activeFilter == ChatFilter.todos,
                onTap: () => setState(() {
                  _activeFilter = ChatFilter.todos;
                  _activeLabelId = null;
                }),
              ),
              // Chip del agente de seguimiento: solo aparece cuando hay chats
              // encolados, justo después de "Todos" para máxima visibilidad.
              if (counts.followups > 0) ...[
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Seguimiento',
                  count: counts.followups,
                  selected: _activeFilter == ChatFilter.seguimiento,
                  onTap: () => setState(() {
                    _activeFilter = ChatFilter.seguimiento;
                    _activeLabelId = null;
                  }),
                ),
              ],
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Pendientes',
                count: counts.unresponded,
                selected: _activeFilter == ChatFilter.noRespondidos,
                onTap: () => setState(() {
                  _activeFilter = ChatFilter.noRespondidos;
                  _activeLabelId = null;
                }),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Con notas',
                count: counts.notes,
                selected: _activeFilter == ChatFilter.conNotas,
                onTap: () => setState(() {
                  _activeFilter = ChatFilter.conNotas;
                  _activeLabelId = null;
                }),
              ),
              // Un chip por etiqueta del catálogo, con su propio color. Tocar
              // filtra los chats que la tengan asignada.
              for (final label in labels) ...[
                const SizedBox(width: 8),
                _LabelFilterChip(
                  label: label,
                  selected: _activeFilter == ChatFilter.etiqueta &&
                      _activeLabelId == label.id,
                  onTap: () => setState(() {
                    _activeFilter = ChatFilter.etiqueta;
                    _activeLabelId = label.id;
                  }),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  // Abre el panel de configuración de la sesión como bottom sheet. Lo usamos
  // cuando los iconos de IA están en estado "no configurado": en lugar de
  // mostrar un botón muerto, llevamos al usuario directo a activar el asistente.
  void _openSessionSettings() {
    if (widget.sessionId == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SessionSettingsPanel(
        sessionId: widget.sessionId!,
        accountId: widget.accountId,
      ),
    );
  }

  Future<void> _toggleAiAutoResponse(bool currentValue) async {
    try {
      HapticFeedback.lightImpact();

      if (currentValue) {
        // Apagando IA en este chat. Capturamos si había un ciclo IA activo
        // ANTES de emitir el cancel: solo entonces vale la pena mostrar el
        // flash "cancelado". Si la IA estaba ociosa, basta con el toast.
        final wasAiActive = widget.sessionKey != null &&
                selectedChatPhone != null
            ? AiStateService()
                .isActiveFor(widget.sessionKey!, selectedChatPhone!)
            : false;

        // Cortar el buffer pendiente en el backend. Usamos emit() directo:
        // sendMessage() emite 'send_message_socket' (handler de mensajes
        // WhatsApp) y rompía con "Unauthorized accountId" porque el backend
        // intentaba leer 'to' y 'accountId' del payload de cancelación.
        SocketService().emit('cancel_ai_buffer', {
          'sessionKey': widget.sessionKey,
          'contactPhone': selectedChatPhone,
        });
        debugPrint(
            'Emitted cancel_ai_buffer for $selectedChatPhone via SocketService');

        if (wasAiActive && selectedChatPhone != null) {
          _markChatCancelled(selectedChatPhone!);
        }
        _showEtherealToast(true, 'IA desactivada', isActivating: false);
      } else {
        _showEtherealToast(true, 'IA activada', isActivating: true);
      }

      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('chats')
          .doc(selectedChatPhone)
          .update({'ai_auto_response': !currentValue});
    } catch (e) {
      debugPrint('Error toggling AI: $e');
      _showEtherealToast(false, 'Error al cambiar IA', isActivating: false);
    }
  }

  Widget _buildMessageDetail() {
    // StreamBuilder externo: escucha el documento de la sesión para conocer
    // si el asistente IA fue configurado (ai_enabled). Ese estado lo necesitan
    // tanto el toggle del AppBar como el botón "generar respuesta" dentro
    // de MessagesView, así que lo leemos una sola vez aquí y lo propagamos.
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .snapshots(),
      builder: (context, sessionSnapshot) {
        final sessionData = sessionSnapshot.data?.data() as Map<String, dynamic>?;
        final sessionAiEnabled = sessionData?['ai_enabled'] as bool? ?? false;
        // Credenciales del provider activo. Sirve para habilitar el modo
        // "copiloto" del botón "generar respuesta": el operador puede pedirle
        // sugerencias a la IA aunque el master switch (`ai_enabled`) esté off.
        final aiProvider = sessionData?['ai_provider'] as String? ?? 'gemini';
        final aiApiKeyField = aiProvider == 'openai'
            ? 'ai_openai_api_key'
            : aiProvider == 'deepseek'
                ? 'ai_deepseek_api_key'
                : 'ai_api_key';
        final sessionAiHasCredentials =
            ((sessionData?[aiApiKeyField] as String?) ?? '').trim().isNotEmpty;

        // Stream del documento del chat: lo levantamos al nivel del Scaffold
        // para que título, acciones y franja inferior compartan los mismos
        // datos (sin abrir tres suscripciones a la misma ruta).
        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection(accountsCollection)
              .doc(widget.accountId)
              .collection('whatsapp_sessions')
              .doc(widget.sessionId)
              .collection('chats')
              .doc(selectedChatPhone)
              .snapshots(),
          builder: (context, chatSnapshot) {
            final chatData =
                chatSnapshot.data?.data() as Map<String, dynamic>?;
            final contactName = chatData?['contactName'] as String? ?? '';
            final aiAutoResponse =
                chatData?['ai_auto_response'] as bool? ?? true;
            final unrespondedCount =
                (chatData?['unresponded_count'] as num?)?.toInt() ?? 0;
            final detailLabelIds =
                ((chatData?['labelIds'] as List?) ?? const [])
                    .whereType<String>()
                    .toList();
            final detailNote = (chatData?['note'] as String? ?? '').trim();
            final displayName = contactName.isNotEmpty
                ? contactName
                : (selectedChatPhone ?? 'Chat');
            // Señal ambiental "tu turno": IA configurada y auto-on, pero hay
            // mensajes pendientes (discriminador derivó al humano u otro flujo
            // dejó cosas sin contestar). En vez de un badge clickable que
            // engaña, lo mostramos como franja ámbar inferior + subtítulo.
            final needsHuman =
                sessionAiEnabled && aiAutoResponse && unrespondedCount > 0;

            return Scaffold(
              appBar: AppBar(
                leading: MediaQuery.of(context).size.width < 600
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () {
                          setState(() {
                            selectedChatPhone = null;
                          });
                        },
                      )
                    : null,
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    // Subtítulo con prioridad:
                    //   cancelado (3s) > ciclo IA > "tu turno" > vacío.
                    // El flash de cancelación gana siempre durante su ventana
                    // para dar feedback claro al usuario que acaba de apagar
                    // el toggle. Mientras hay ciclo IA, manda la IA. Sin IA y
                    // con pendientes, "tu turno" para el humano.
                    ListenableBuilder(
                      listenable: AiStateService(),
                      builder: (context, _) {
                        final aiStatus = widget.sessionKey == null
                            ? null
                            : AiStateService().statusFor(
                                widget.sessionKey!,
                                selectedChatPhone!,
                              );
                        final aiActive = aiStatus != null &&
                            aiStatus.state != AiChatState.idle;
                        final showCancelled =
                            _cancelledChatPhone == selectedChatPhone;

                        Widget child;
                        if (showCancelled) {
                          child = const Padding(
                            key: ValueKey('appbar-subtitle-cancelled'),
                            padding: EdgeInsets.only(top: 1),
                            child: Text(
                              'cancelado',
                              style: TextStyle(
                                color: Color(0xFF9CA3AF),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                letterSpacing: 0.2,
                              ),
                            ),
                          );
                        } else if (aiActive) {
                          child = Padding(
                            key: ValueKey(
                                'appbar-subtitle-ai-${aiStatus.state.name}'),
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              _aiStateLabel(aiStatus.state),
                              style: const TextStyle(
                                color: primaryAqua,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                letterSpacing: 0.2,
                              ),
                            ),
                          );
                        } else if (needsHuman) {
                          child = const Padding(
                            key: ValueKey('appbar-subtitle-needs-human'),
                            padding: EdgeInsets.only(top: 1),
                            child: Text(
                              'tu turno',
                              style: TextStyle(
                                color: Color(0xFFF59E0B),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                                letterSpacing: 0.2,
                              ),
                            ),
                          );
                        } else {
                          child = const SizedBox.shrink(
                            key: ValueKey('appbar-subtitle-empty'),
                          );
                        }

                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: child,
                        );
                      },
                    ),
                  ],
                ),
                actions: [
                  // Toggle puro de 2 estados: activar/desactivar IA en este
                  // chat. Ya no muta a spinner durante el ciclo IA — la
                  // actividad se comunica vía subtítulo + barra de carga.
                  Builder(
                    builder: (context) {
                      final Color iconColor;
                      final String tooltip;
                      final VoidCallback onPressed;
                      if (!sessionAiEnabled) {
                        iconColor =
                            const Color(0xFF9CA3AF).withValues(alpha: 0.4);
                        tooltip = 'Configura el asistente IA primero';
                        onPressed = _openSessionSettings;
                      } else if (aiAutoResponse) {
                        iconColor = const Color(0xFF10B981);
                        tooltip = 'Desactivar IA automática';
                        onPressed = () => _toggleAiAutoResponse(true);
                      } else {
                        iconColor = const Color(0xFF9CA3AF);
                        tooltip = 'Activar IA automática';
                        onPressed = () => _toggleAiAutoResponse(false);
                      }

                      return IconButton(
                        icon: Icon(Icons.face_retouching_natural,
                            size: 20, color: iconColor),
                        tooltip: tooltip,
                        onPressed: onPressed,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    onPressed: () {
                      _showContactInfo(selectedChatPhone!);
                    },
                  ),
                ],
                // Franja inferior 2px con cuatro modos (misma prioridad que
                // el subtítulo para mantenerlos sincronizados):
                // - cancelado  → gris sólida (3s).
                // - ciclo IA   → barra de carga aqua (LinearProgressIndicator
                //                indeterminado — efecto deslizante nativo).
                // - tu turno   → ámbar sólida.
                // - en reposo  → invisible.
                // Altura constante para no saltar el AppBar al alternar.
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: ListenableBuilder(
                    listenable: AiStateService(),
                    builder: (context, _) {
                      final aiStatus = widget.sessionKey == null
                          ? null
                          : AiStateService().statusFor(
                              widget.sessionKey!,
                              selectedChatPhone!,
                            );
                      final aiActive = aiStatus != null &&
                          aiStatus.state != AiChatState.idle;
                      final showCancelled =
                          _cancelledChatPhone == selectedChatPhone;

                      Widget child;
                      if (showCancelled) {
                        child = Container(
                          key: const ValueKey('appbar-bar-cancelled'),
                          height: 2,
                          color: const Color(0xFF9CA3AF),
                        );
                      } else if (aiActive) {
                        child = const SizedBox(
                          key: ValueKey('appbar-bar-ai'),
                          height: 2,
                          child: LinearProgressIndicator(
                            minHeight: 2,
                            backgroundColor: Colors.transparent,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(primaryAqua),
                          ),
                        );
                      } else if (needsHuman) {
                        child = Container(
                          key: const ValueKey('appbar-bar-human'),
                          height: 2,
                          color: const Color(0xFFF59E0B),
                        );
                      } else {
                        child = const SizedBox(
                          key: ValueKey('appbar-bar-empty'),
                          height: 2,
                        );
                      }

                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: child,
                      );
                    },
                  ),
                ),
                elevation: 0,
              ),
              body: Column(
                children: [
                  // Strip de nota del chat. Contexto rápido al abrir; tap →
                  // editor de nota. Solo se renderiza si hay nota.
                  if (detailNote.isNotEmpty)
                    _MessagesNoteStrip(
                      note: detailNote,
                      onTap: () => _editNote(selectedChatPhone!, detailNote),
                    ),
                  // Strip de etiquetas asignadas al chat. Si no hay, no
                  // reserva altura. Tap → abre el selector (atajo a Fase 2).
                  if (detailLabelIds.isNotEmpty)
                    _MessagesLabelsStrip(
                      labelIds: detailLabelIds,
                      catalog: _labelsCatalog,
                      onTap: () => _openLabelsSelector(selectedChatPhone!),
                    ),
                  Expanded(
                    child: MessagesView(
                      // Key por chat: cada conversación arranca con su propio
                      // estado (límite de paginación, scroll) en vez de heredar
                      // el del chat previo.
                      key: ValueKey('msgview_$selectedChatPhone'),
                      phoneNumber: selectedChatPhone!,
                      sessionId: widget.sessionId!,
                      sessionKey: widget.sessionKey,
                      accountId: widget.accountId,
                      sessionAiEnabled: sessionAiEnabled,
                      sessionAiHasCredentials: sessionAiHasCredentials,
                      jumpToMessageId: _jumpToMessageId,
                      jumpToTimestamp: _jumpToTimestamp,
                      onJumpConsumed: () {
                        if (_jumpToMessageId != null) {
                          setState(() {
                            _jumpToMessageId = null;
                            _jumpToTimestamp = null;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Bottom sheet de opciones al pulsar largo un chat. Mismo patrón visual que
  // el menú de opciones de mensajes (message_bubble.dart). Aquí irán futuras
  // acciones: archivar, marcar como listo, etc.
  void _showChatOptions(
    String phoneNumber,
    String contactName,
    List<String> labelIds,
    String note,
    bool isPending,
  ) {
    HapticFeedback.mediumImpact();
    // Si el chat ya tiene etiquetas asignadas la acción es "administrar";
    // si no, invitamos a "añadir" la primera. Mismo destino (el selector),
    // distinto copy según el contexto.
    final hasLabels = labelIds.isNotEmpty;
    final hasNote = note.trim().isNotEmpty;
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => Padding(
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
            ListTile(
              leading: Icon(
                hasNote
                    ? Icons.sticky_note_2
                    : Icons.sticky_note_2_outlined,
                size: 20,
                color: const Color(0xFFF59E0B),
              ),
              title: Text(
                hasNote ? 'Editar nota' : 'Añadir nota',
                style: const TextStyle(color: white),
              ),
              // Vista previa de la nota actual como contexto.
              subtitle: hasNote
                  ? Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        note.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: lightText,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.pop(sheetCtx);
                _editNote(phoneNumber, note);
              },
            ),
            ListTile(
              leading: Icon(
                hasLabels ? Icons.label : Icons.label_outline,
                size: 20,
                color: primaryAqua,
              ),
              title: Text(
                hasLabels ? 'Administrar etiquetas' : 'Añadir etiqueta',
                style: const TextStyle(color: white),
              ),
              // Chips actuales como contexto cuando ya hay etiquetas asignadas.
              subtitle: hasLabels
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LabelChipsRow(
                        labelIds: labelIds,
                        catalog: _labelsCatalog,
                        compact: true,
                        maxVisible: 4,
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.pop(sheetCtx);
                _openLabelsSelector(phoneNumber);
              },
            ),
            // Toggle de pendiente manual. Si ya está pendiente, lo cierra
            // ("Listo"); si no, lo marca para darle seguimiento.
            ListTile(
              leading: Icon(
                isPending ? Icons.mark_chat_read : Icons.mark_chat_unread,
                size: 20,
                color: const Color(0xFFF97316),
              ),
              title: Text(
                isPending ? 'Quitar pendiente' : 'Marcar como pendiente',
                style: const TextStyle(color: white),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                if (isPending) {
                  _markAsResponded(phoneNumber);
                } else {
                  _markAsPending(phoneNumber);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, size: 20, color: Color(0xFFF87171)),
              title: const Text('Eliminar chat', style: TextStyle(color: white)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDeleteChat(phoneNumber, contactName);
              },
            ),
          ],
        ),
      ),
    );
  }

  // Hard-delete del chat: borra Storage + mensajes + chat doc en el backend.
  // Acción irreversible: la UI exige que el usuario confirme en el AlertDialog.
  Future<void> _confirmDeleteChat(String phoneNumber, String contactName) async {
    final displayName = contactName.isNotEmpty ? contactName : phoneNumber;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '¿Eliminar chat?',
          style: TextStyle(color: white, fontWeight: FontWeight.bold),
        ),
        content: RichText(
          text: TextSpan(
            style: const TextStyle(color: lightText, fontSize: 14, height: 1.4),
            children: [
              const TextSpan(text: 'Se eliminarán '),
              const TextSpan(
                text: 'todos los mensajes y archivos',
                style: TextStyle(fontWeight: FontWeight.bold, color: white),
              ),
              const TextSpan(text: ' del chat con '),
              TextSpan(
                text: displayName,
                style: const TextStyle(fontWeight: FontWeight.bold, color: white),
              ),
              const TextSpan(text: '.\n\n'),
              const TextSpan(
                text: 'Esta acción no se puede deshacer.',
                style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/delete-chat'),
        headers: await authHeaders(),
        body: jsonEncode({
          'phoneNumber': phoneNumber,
          'sessionKey': widget.sessionKey,
          'sessionId': widget.sessionId,
          'accountId': widget.accountId,
        }),
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;

      if (response.statusCode == 200) {
        // Si el chat eliminado estaba abierto en split-view, cerramos el panel.
        if (selectedChatPhone == phoneNumber) {
          setState(() => selectedChatPhone = null);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Chat con $displayName eliminado'),
            backgroundColor: primaryAqua,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al eliminar (${response.statusCode})'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error deleting chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error de conexión al eliminar el chat'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  // "Listo": cierra el pendiente por completo. Limpia el contador automático
  // y también la marca manual de seguimiento, para que el chat salga del filtro
  // "Pendientes" y vuelva a su estado neutro.
  Future<void> _markAsResponded(String contactPhone) async {
    HapticFeedback.lightImpact();
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('chats')
          .doc(contactPhone)
          .set(
            {'unresponded_count': 0, 'marked_pending': false},
            SetOptions(merge: true),
          );
    } catch (e) {
      debugPrint('Error marking chat as responded: $e');
      if (mounted) {
        _showEtherealToast(false, 'Error al marcar', isActivating: false);
      }
    }
  }

  // Marca manual de seguimiento (estilo "marcar como no leído" de WhatsApp).
  // Escribe directo a Firestore: el backend nunca toca este campo, así que la
  // marca sobrevive hasta que respondas (el backend la limpia en
  // resetUnrespondedCount) o la quites con "Listo".
  Future<void> _markAsPending(String contactPhone) async {
    HapticFeedback.lightImpact();
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .collection('chats')
          .doc(contactPhone)
          .set({'marked_pending': true}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error marking chat as pending: $e');
      if (mounted) {
        _showEtherealToast(false, 'Error al marcar', isActivating: false);
      }
    }
  }

  // Etiqueta corta del ciclo IA — se muestra en el subtítulo del AppBar
  // mientras la IA está activa (mismo slot que "tu turno", con prioridad).
  String _aiStateLabel(AiChatState state) {
    switch (state) {
      case AiChatState.buffering:
        return 'esperando…';
      case AiChatState.thinking:
        return 'pensando…';
      case AiChatState.responding:
        return 'respondiendo…';
      case AiChatState.idle:
        return '';
    }
  }

  // Editor de la nota/comentario del chat. Diálogo simple con TextField
  // multilínea; persiste en el campo `note` del doc del chat con merge:true.
  // Nota vacía → borra el campo para que no aparezca el chip ni cuente en
  // búsqueda.
  Future<void> _editNote(String phoneNumber, String currentNote) async {
    final controller = TextEditingController(text: currentNote);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.sticky_note_2_outlined,
                      color: Color(0xFFF59E0B), size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Nota del chat',
                    style: TextStyle(
                      color: white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 4,
                maxLength: 200,
                style: const TextStyle(color: white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Ej: El masajes es para dos personas',
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
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
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
                      onPressed: () => Navigator.pop(ctx, true),
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
    );

    if (saved != true || widget.sessionId == null) return;

    final trimmed = controller.text.trim();
    final chatRef = FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(widget.accountId)
        .collection('whatsapp_sessions')
        .doc(widget.sessionId)
        .collection('chats')
        .doc(phoneNumber);

    await chatRef.set(
      {'note': trimmed.isEmpty ? FieldValue.delete() : trimmed},
      SetOptions(merge: true),
    );
  }

  void _openLabelsSelector(String phoneNumber) {
    if (widget.sessionId == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LabelsSelectorSheet(
        accountId: widget.accountId,
        sessionId: widget.sessionId!,
        phoneNumber: phoneNumber,
      ),
    );
  }

  void _showContactInfo(String phoneNumber) {
    showModalBottomSheet(
      context: context,
      backgroundColor: surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ContactInfoPanel(
        phoneNumber: phoneNumber,
        sessionId: widget.sessionId!,
        accountId: widget.accountId,
      ),
    );
  }
}

// Franja horizontal scrollable de etiquetas que aparece justo bajo el AppBar
// del MessagesView. Solo se renderiza si el chat tiene al menos una etiqueta.
class _MessagesLabelsStrip extends StatelessWidget {
  final List<String> labelIds;
  final Map<String, ChatLabel> catalog;
  final VoidCallback onTap;

  const _MessagesLabelsStrip({
    required this.labelIds,
    required this.catalog,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = labelIds
        .map((id) => catalog[id])
        .whereType<ChatLabel>()
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    if (resolved.isEmpty) return const SizedBox.shrink();

    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: surfaceDark,
          border: Border(
            bottom: BorderSide(color: white.withValues(alpha: 0.05)),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Icon(Icons.label_outline, size: 14, color: lightText),
              const SizedBox(width: 6),
              ...resolved.map((l) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: LabelChip(label: l),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// Franja de nota/comentario bajo el AppBar del chat abierto. Mismo lenguaje
// visual que _MessagesLabelsStrip pero en ámbar para diferenciar la anotación
// del usuario de las etiquetas. Tap → editor de nota.
class _MessagesNoteStrip extends StatelessWidget {
  final String note;
  final VoidCallback onTap;

  static const Color _amber = Color(0xFFF59E0B);

  const _MessagesNoteStrip({required this.note, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _amber.withValues(alpha: 0.08),
          border: Border(
            bottom: BorderSide(color: white.withValues(alpha: 0.05)),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.sticky_note_2_outlined, size: 16, color: _amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _amber,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Pill seleccionable de la barra de filtros rápidos. Activo: relleno aqua con
// texto oscuro. Inactivo: superficie tenue con borde sutil. Opcionalmente
// muestra un badge con el conteo (en `badgeColor`) cuando hay elementos.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = selected ? primaryAqua : surfaceDark.withValues(alpha: 0.6);
    final Color fg = selected ? darkBg : lightText;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                // Badge de conteo neutro: mismo color que el texto del chip,
                // sobre un pill tenue del mismo tono. Sin color propio para no
                // recargar la barra de filtros visualmente.
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: selected ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: fg,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Chip de filtro por etiqueta. Usa el color propio de la etiqueta: seleccionado
// va relleno (texto por luminancia para contraste); sin seleccionar muestra un
// tinte tenue con punto de color y texto coloreado, para diferenciarse de los
// chips fijos sin perder identidad visual.
class _LabelFilterChip extends StatelessWidget {
  final ChatLabel label;
  final bool selected;
  final VoidCallback onTap;

  const _LabelFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = label.color;
    final fgSelected =
        color.computeLuminance() > 0.55 ? darkBg : Colors.white;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color:
                  selected ? color : color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : color.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Punto de color solo cuando no está seleccionado (al estar
                // seleccionado el relleno ya es el color de la etiqueta).
                if (!selected) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label.name,
                  style: TextStyle(
                    color: selected ? fgSelected : color,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final String phoneNumber;
  final String contactName;
  final String lastMessage;
  final DateTime? timestamp;
  final bool isSelected;
  final int unrespondedCount;
  // Marca manual de seguimiento (sin número). Pinta un punto naranja en el
  // avatar cuando no hay contador automático visible.
  final bool markedPending;
  // Necesario para consultar AiStateService (clave: sessionKey:contactPhone).
  // Puede ser null si la sesión está desconectada — en ese caso nunca habrá
  // estado de IA activo y el tile cae al render normal con el badge.
  final String? sessionKey;
  final List<String> labelIds;
  final Map<String, ChatLabel> labelsCatalog;
  final String note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatTile({
    required this.phoneNumber,
    required this.contactName,
    required this.lastMessage,
    required this.timestamp,
    required this.isSelected,
    required this.unrespondedCount,
    required this.markedPending,
    required this.sessionKey,
    required this.labelIds,
    required this.labelsCatalog,
    required this.note,
    required this.onTap,
    this.onLongPress,
  });

  String _formatTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Ahora';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes}m';
    } else if (difference.inHours < 24) {
      return 'Hace ${difference.inHours}h';
    } else if (difference.inDays == 1) {
      return 'Ayer';
    } else if (difference.inDays < 7) {
      return 'Hace ${difference.inDays}d';
    } else {
      return '${dateTime.day}/${dateTime.month}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayName = contactName.isNotEmpty ? contactName : phoneNumber;
    final avatarLetter = displayName.substring(0, 1).toUpperCase();
    // Pendiente = señal automática (con número) o marca manual (sin número).
    final isPending = unrespondedCount > 0 || markedPending;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected ? surfaceDark.withValues(alpha: 0.8) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // Row exterior con avatar centrado verticalmente respecto a todo el
        // contenido (nombre + mensaje + chips). El bloque de texto va en un
        // Expanded para que la fila de chips ocupe el ancho completo hasta el
        // borde derecho.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Avatar circular con badge de pendientes superpuesto (estilo iOS
            // app icon, igual que la pantalla "Mis cuentas").
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: primaryAqua.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      avatarLetter,
                      style: const TextStyle(
                        color: primaryAqua,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                if (unrespondedCount > 0)
                  Positioned(
                    top: -4,
                    right: -4,
                    // Borde del color de fondo para separar del avatar.
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: darkBg, width: 2),
                      ),
                      child: UnrespondedBadge(count: unrespondedCount),
                    ),
                  )
                // Sin contador automático pero marcado a mano: punto naranja
                // sólido (sin número), igual que "marcar como no leído".
                else if (markedPending)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF97316),
                        shape: BoxShape.circle,
                        border: Border.all(color: darkBg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Nombre + (hora / indicador de IA) en la misma fila.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _formatTimestamp(timestamp),
                            style: TextStyle(
                              fontSize: 11,
                              color: isPending
                                  ? const Color(0xFFF97316)
                                  : lightText,
                              fontWeight: isPending
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          // Indicador de IA solo cuando hay ciclo activo.
                          ListenableBuilder(
                            listenable: AiStateService(),
                            builder: (context, _) {
                              final aiStatus = sessionKey == null
                                  ? null
                                  : AiStateService()
                                      .statusFor(sessionKey!, phoneNumber);
                              final aiActive = aiStatus != null &&
                                  aiStatus.state != AiChatState.idle;

                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                child: aiActive
                                    ? Padding(
                                        padding:
                                            const EdgeInsets.only(top: 6),
                                        child: AiStateIndicator(
                                          key: const ValueKey('ai-indicator'),
                                          state: aiStatus.state,
                                          compact: true,
                                        ),
                                      )
                                    : const SizedBox(
                                        key: ValueKey('ai-idle'), height: 0),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lastMessage,
                    style: const TextStyle(
                      fontSize: 12,
                      color: lightText,
                      height: 1.4,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Etiquetas + nota en UNA línea a lo ancho del Expanded.
                  // Las etiquetas toman su ancho (acotado al 50% para no
                  // desbordar) y la nota ocupa el resto completo con Expanded;
                  // el Align evita que el chip se estire vacío si es corta.
                  if (labelIds.isNotEmpty || note.isNotEmpty)
                    LayoutBuilder(
                      builder: (context, constraints) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            if (labelIds.isNotEmpty)
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: note.isNotEmpty
                                      ? constraints.maxWidth * 0.5
                                      : constraints.maxWidth,
                                ),
                                child: LabelChipsRow(
                                  labelIds: labelIds,
                                  catalog: labelsCatalog,
                                  compact: true,
                                  maxVisible: note.isNotEmpty ? 2 : 3,
                                ),
                              ),
                            if (labelIds.isNotEmpty && note.isNotEmpty)
                              const SizedBox(width: 6),
                            if (note.isNotEmpty)
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: NoteChip(
                                    note: note,
                                    compact: true,
                                    maxWidth: double.infinity,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

