import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'messages_view.dart';

class ChatsScreen extends StatefulWidget {
  final IO.Socket socket;
  final String sessionId;
  final String sessionKey;
  final String accountId;

  const ChatsScreen({
    required this.socket,
    required this.sessionId,
    required this.sessionKey,
    required this.accountId,
    super.key,
  });

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String? selectedChatPhone;
  String searchQuery = '';
  final TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 📌 Listen for AI toggle confirmation from backend
    widget.socket.on('ai_toggle_result', (data) {
      if (mounted) {
        final success = data['success'] as bool? ?? false;
        final message = data['message'] as String? ?? '';
        final isActivating = message.toLowerCase() == 'ia activada'; // Explicit check for activation
        _showEtherealToast(success, message, isActivating: isActivating);
      }
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    widget.socket.off('ai_toggle_result');
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.manage_accounts_outlined, color: lightText),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Cuentas',
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WhatHero', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: white)),
            Text(
              widget.sessionId,
              style: const TextStyle(fontSize: 12, color: lightText, fontWeight: FontWeight.w400),
            ),
          ],
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
                sessionId: widget.sessionId,
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
            .collection('accounts')
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
                    return phoneNumber.toLowerCase().contains(searchQuery);
                  })
                  .toList();

          if (filteredChats.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    searchQuery.isEmpty ? 'Sin chats' : 'No se encontraron resultados',
                    style: const TextStyle(
                      fontSize: 16,
                      color: lightText,
                    ),
                  ),
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
              final lastMessage = chatData?['lastMessage'] ?? 'Sin mensajes';
              final timestamp = (chatData?['lastMessageTimestamp'] as Timestamp?)?.toDate();
              final needsHuman = chatData?['needs_human'] as bool? ?? false;

              return _ChatTile(
                phoneNumber: phoneNumber,
                lastMessage: lastMessage,
                timestamp: timestamp,
                isSelected: selectedChatPhone == phoneNumber,
                needsHuman: needsHuman,
                onTap: () {
                  setState(() {
                    selectedChatPhone = phoneNumber;
                  });
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMessageDetail() {
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
              .collection('accounts')
              .doc(widget.accountId)
              .collection('whatsapp_sessions')
              .doc(widget.sessionId)
              .collection('chats')
              .doc(selectedChatPhone)
              .snapshots(),
          builder: (context, snapshot) {
            final chatData = snapshot.data?.data() as Map<String, dynamic>?;
            final needsHuman = chatData?['needs_human'] as bool? ?? false;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedChatPhone ?? 'Chat',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (needsHuman) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.support_agent,
                    size: 20,
                    color: Color(0xFFF97316),
                  ),
                ],
              ],
            );
          },
        ),
        actions: [
          // 📌 AI Auto-Response Toggle (Activado=Aqua, Desactivado=Gris)
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('accounts')
                .doc(widget.accountId)
                .collection('whatsapp_sessions')
                .doc(widget.sessionId)
                .collection('chats')
                .doc(selectedChatPhone)
                .snapshots(),
            builder: (context, snapshot) {
              final aiAutoResponse = (snapshot.data?.data() as Map<String, dynamic>?)?['ai_auto_response'] as bool? ?? true;
              return IconButton(
                icon: Icon(
                  Icons.face_retouching_natural,
                  size: 20,
                  color: aiAutoResponse ? const Color(0xFF06B6D4) : const Color(0xFF9CA3AF),
                ),
                tooltip: aiAutoResponse ? 'Desactivar IA automática' : 'Activar IA automática',
                onPressed: () async {
                  try {
                    // Haptic feedback - sutil vibración
                    HapticFeedback.lightImpact();

                    // If disabling (turning false), cancel any pending buffer
                    if (aiAutoResponse) {
                      widget.socket.emit('cancel_ai_buffer', {
                        'sessionKey': widget.sessionKey,
                        'contactPhone': selectedChatPhone,
                      });
                      debugPrint('Emitted cancel_ai_buffer for $selectedChatPhone');
                    } else {
                      // If enabling, show success toast immediately (no buffer to cancel)
                      _showEtherealToast(true, 'IA activada', isActivating: true);
                    }

                    // Update Firestore
                    await FirebaseFirestore.instance
                        .collection('accounts')
                        .doc(widget.accountId)
                        .collection('whatsapp_sessions')
                        .doc(widget.sessionId)
                        .collection('chats')
                        .doc(selectedChatPhone)
                        .update({
                          'ai_auto_response': !aiAutoResponse,
                        });
                  } catch (e) {
                    debugPrint('Error toggling AI: $e');
                    // Show error toast
                    _showEtherealToast(false, 'Error al cambiar IA', isActivating: false);
                  }
                },
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
        sessionId: widget.sessionId,
        sessionKey: widget.sessionKey,
        accountId: widget.accountId,
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
        sessionId: widget.sessionId,
        accountId: widget.accountId,
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final String phoneNumber;
  final String lastMessage;
  final DateTime? timestamp;
  final bool isSelected;
  final bool needsHuman;
  final VoidCallback onTap;

  const _ChatTile({
    required this.phoneNumber,
    required this.lastMessage,
    required this.timestamp,
    required this.isSelected,
    required this.needsHuman,
    required this.onTap,
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
    return GestureDetector(
      onTap: onTap,
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
                  phoneNumber.substring(0, 1).toUpperCase(),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          phoneNumber,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (needsHuman)
                        const Icon(
                          Icons.support_agent,
                          size: 18,
                          color: Color(0xFFF97316),
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
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatTimestamp(timestamp),
              style: const TextStyle(
                fontSize: 11,
                color: lightText,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
