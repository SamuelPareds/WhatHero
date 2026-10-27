import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/chat/widgets/unread_badge.dart';

/// Badge de chats pendientes de una sesión (estilo ícono de app de iOS), en
/// la tarjeta de Mis Cuentas y en cada fila del selector de cuenta.
///
/// El stream nace en initState y no en build: la lista de sesiones rebuildea
/// con cada cambio de estado de cualquier sesión, y un `.snapshots()` creado
/// ahí re-suscribía (y en web volvía a leer) los pendientes de todas las
/// tarjetas.
///
/// Cuenta sólo `unresponded_count > 0` (no `marked_pending`), así que puede
/// diferir del contador de Pendientes de la lista.
class PendingChatsBadge extends StatefulWidget {
  final String accountId;
  final String sessionId;
  // El color de lo que hay detrás: el borde recorta el badge del avatar.
  final Color borderColor;

  const PendingChatsBadge({
    required this.accountId,
    required this.sessionId,
    this.borderColor = darkBg,
    super.key,
  });

  @override
  State<PendingChatsBadge> createState() => _PendingChatsBadgeState();
}

class _PendingChatsBadgeState extends State<PendingChatsBadge> {
  late Stream<QuerySnapshot> _pending = _query();

  Stream<QuerySnapshot> _query() => FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId)
      .collection('chats')
      .where('unresponded_count', isGreaterThan: 0)
      .snapshots();

  @override
  void didUpdateWidget(PendingChatsBadge old) {
    super.didUpdateWidget(old);
    // La tarjeta puede reusarse para otra sesión si la lista se reordena.
    if (old.sessionId != widget.sessionId || old.accountId != widget.accountId) {
      _pending = _query();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _pending,
      builder: (context, snap) {
        final count = snap.data?.docs.length ?? 0;
        if (count <= 0) return const SizedBox.shrink();
        // Borde para separar visualmente del avatar
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.borderColor, width: 2),
          ),
          child: UnrespondedBadge(count: count),
        );
      },
    );
  }
}
