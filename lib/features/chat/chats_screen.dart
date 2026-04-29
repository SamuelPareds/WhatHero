import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:http/http.dart' as http;
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/core/services/storage_service.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'package:crm_whatsapp/features/accounts.dart';
import 'messages_view.dart';
import 'widgets/unread_badge.dart';

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
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  StreamSubscription? _statusSubscription;
  StreamSubscription? _humanAttentionSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.sessionId != null && widget.sessionKey != null) {
      _setupSocketListeners();
      // Guardar esta sesión como la última activa
      StorageService().saveLastSessionId(widget.sessionId!);
    }
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
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    if (isMobile) {
      return selectedChatPhone == null
          ? _buildChatsList()
          : _buildMessageDetail();
    }

    return Scaffold(
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
        title: StreamBuilder<DocumentSnapshot>(
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
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, size: 20),
            tooltip: 'Respuestas rápidas',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => QuickResponsesPanel(
                sessionId: widget.sessionId!,
                accountId: widget.accountId,
              ),

            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: TextField(
              controller: searchController,
              onChanged: (value) {
                setState(() {
                  searchQuery = value.toLowerCase();
                });
              },
              style: const TextStyle(color: white),
              decoration: InputDecoration(
                hintText: 'Buscar contacto...',
                hintStyle: const TextStyle(color: lightText),
                prefixIcon: const Icon(Icons.search, color: lightText, size: 20),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, color: lightText, size: 20),
                        onPressed: () {
                          searchController.clear();
                          setState(() {
                            searchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: surfaceDark.withValues(alpha: 0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              ),
            ),
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
          final filteredChats = searchQuery.isEmpty
              ? allChats
              : allChats
                  .where((chatDoc) {
                    final chatData = chatDoc.data() as Map<String, dynamic>?;
                    final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
                    final contactName = chatData?['contactName'] as String? ?? '';
                    return phoneNumber.toLowerCase().contains(searchQuery) || 
                           contactName.toLowerCase().contains(searchQuery);
                  })
                  .toList();

          if (filteredChats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    searchQuery.isEmpty ? Icons.chat_bubble_outline : Icons.search_off,
                    size: 48,
                    color: primaryAqua.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    searchQuery.isEmpty ? 'Sin chats' : 'No se encontraron resultados',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    searchQuery.isEmpty
                        ? 'Los chats aparecerán aquí cuando recibas mensajes'
                        : 'Intenta con otro contacto o número',
                    style: const TextStyle(
                      fontSize: 14,
                      color: lightText,
                    ),
                  ),
                  if (searchQuery.isEmpty) ...[
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
            );
          }

          return ListView.builder(
            itemCount: filteredChats.length,
            itemBuilder: (context, index) {
              final chatDoc = filteredChats[index];
              final chatData = chatDoc.data() as Map<String, dynamic>?;

              final phoneNumber = chatData?['phoneNumber'] as String? ?? '';
              final contactName = chatData?['contactName'] as String? ?? '';
              final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
              final timestamp = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();
              final unrespondedCount = (chatData?['unresponded_count'] as num?)?.toInt() ?? 0;

              final tile = _ChatTile(
                phoneNumber: phoneNumber,
                contactName: contactName,
                lastMessage: lastMessage,
                timestamp: timestamp,
                isSelected: selectedChatPhone == phoneNumber,
                unrespondedCount: unrespondedCount,
                onTap: () {
                  setState(() {
                    selectedChatPhone = phoneNumber;
                  });
                },
                onLongPress: () => _showChatOptions(phoneNumber, contactName),
              );

              // Sin pendientes: nada que cerrar, no envolvemos en Slidable
              if (unrespondedCount == 0) return tile;

              return Slidable(
                key: ValueKey('chat_$phoneNumber'),
                groupTag: 'chats',
                endActionPane: ActionPane(
                  motion: const DrawerMotion(),
                  extentRatio: 0.25,
                  children: [
                    SlidableAction(
                      onPressed: (_) => _markAsResponded(phoneNumber),
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                      icon: Icons.mark_chat_read,
                      label: 'Listo',
                    ),
                  ],
                ),
                child: tile,
              );
            },
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

      // Si desactivamos, cancelar cualquier buffer pendiente
      if (currentValue) {
        SocketService().sendMessage({
          'event': 'cancel_ai_buffer',
          'data': {
            'sessionKey': widget.sessionKey,
            'contactPhone': selectedChatPhone,
          }
        });
        debugPrint('Emitted cancel_ai_buffer for $selectedChatPhone via SocketService');
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
            title: StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection(accountsCollection)
                  .doc(widget.accountId)
                  .collection('whatsapp_sessions')
                  .doc(widget.sessionId)
                  .collection('chats')
                  .doc(selectedChatPhone)
                  .snapshots(),
              builder: (context, snapshot) {
                final chatData = snapshot.data?.data() as Map<String, dynamic>?;
                final contactName = chatData?['contactName'] as String? ?? '';

                final displayName = contactName.isNotEmpty ? contactName : (selectedChatPhone ?? 'Chat');

                return Text(
                  displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                );
              },
            ),
            actions: [
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection(accountsCollection)
                    .doc(widget.accountId)
                    .collection('whatsapp_sessions')
                    .doc(widget.sessionId)
                    .collection('chats')
                    .doc(selectedChatPhone)
                    .snapshots(),
                builder: (context, snapshot) {
                  final data = snapshot.data?.data() as Map<String, dynamic>?;
                  final aiAutoResponse = data?['ai_auto_response'] as bool? ?? true;

                  // Tres estados:
                  // 1) Asistente sin configurar → gris tenue, tap abre settings.
                  // 2) Configurado y activo en este chat → verde, tap lo apaga.
                  // 3) Configurado pero pausado en este chat → gris, tap lo enciende.
                  final Color iconColor;
                  final String tooltip;
                  final VoidCallback onPressed;
                  if (!sessionAiEnabled) {
                    iconColor = const Color(0xFF9CA3AF).withValues(alpha: 0.4);
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
                    icon: Icon(Icons.face_retouching_natural, size: 20, color: iconColor),
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
            elevation: 0,
          ),
          body: MessagesView(
            phoneNumber: selectedChatPhone!,
            sessionId: widget.sessionId!,
            sessionKey: widget.sessionKey,
            accountId: widget.accountId,
            sessionAiEnabled: sessionAiEnabled,
          ),
        );
      },
    );
  }

  // Bottom sheet de opciones al pulsar largo un chat. Mismo patrón visual que
  // el menú de opciones de mensajes (message_bubble.dart). Aquí irán futuras
  // acciones: archivar, marcar como listo, etc.
  void _showChatOptions(String phoneNumber, String contactName) {
    HapticFeedback.mediumImpact();
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
        headers: {'Content-Type': 'application/json'},
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
          .set({'unresponded_count': 0}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error marking chat as responded: $e');
      if (mounted) {
        _showEtherealToast(false, 'Error al marcar', isActivating: false);
      }
    }
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

class _ChatTile extends StatelessWidget {
  final String phoneNumber;
  final String contactName;
  final String lastMessage;
  final DateTime? timestamp;
  final bool isSelected;
  final int unrespondedCount;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatTile({
    required this.phoneNumber,
    required this.contactName,
    required this.lastMessage,
    required this.timestamp,
    required this.isSelected,
    required this.unrespondedCount,
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

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected ? surfaceDark.withValues(alpha: 0.8) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: primaryAqua.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
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
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: white,
                    ),
                    overflow: TextOverflow.ellipsis,
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
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Timestamp arriba, badge abajo (estilo WhatsApp)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _formatTimestamp(timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: unrespondedCount > 0 ? const Color(0xFFF97316) : lightText,
                    fontWeight: unrespondedCount > 0 ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 6),
                UnrespondedBadge(count: unrespondedCount),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
