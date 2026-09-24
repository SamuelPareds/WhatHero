import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/team_presence_service.dart';

import '../reply_collision.dart';

/// Franja de una línea sobre el composer: lo que conviene saber JUSTO antes de
/// escribir. Prioridad estricta:
///   1. choque (ámbar): alguien respondió mientras escribías;
///   2. respondiendo (violeta): un compañero tiene texto en este chat;
///   3. en el chat (violeta tenue): un compañero lo tiene abierto.
///
/// Va sobre el composer y no en el AppBar a propósito: ahí es donde se decide
/// escribir o no, sigue a la vista aunque subas a leer el historial, y el
/// AppBar ya tiene su propio sistema de cuatro modos (IA / tu turno).
class TeamPresenceBanner extends StatelessWidget {
  final ReplyCollision? collision;
  final VoidCallback? onDismissCollision;

  /// Quienes están en el chat, ya sin esta pestaña.
  final List<TeamViewer> viewers;
  final String? myUid;

  const TeamPresenceBanner({
    required this.viewers,
    required this.myUid,
    this.collision,
    this.onDismissCollision,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final Widget child;
    final collision = this.collision;
    final presence = describeTeamPresence(viewers, myUid: myUid);

    if (collision != null) {
      child = _Strip(
        key: const ValueKey('presence-collision'),
        color: collisionAmber,
        icon: Icons.warning_amber_rounded,
        text: '${collision.headline} · revisa antes de enviar',
        onClose: onDismissCollision,
      );
    } else if (presence != null) {
      child = _Strip(
        key: ValueKey('presence-${presence.composing}'),
        color: teamViolet,
        icon: presence.composing
            ? Icons.edit_note_rounded
            : Icons.visibility_outlined,
        text: presence.text,
        subtle: !presence.composing,
      );
    } else {
      child = const SizedBox(key: ValueKey('presence-none'), width: double.infinity);
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: child,
      ),
    );
  }
}

/// Frase para la franja y el tile. null = no hay nadie.
({String text, bool composing})? describeTeamPresence(
  List<TeamViewer> viewers, {
  required String? myUid,
}) {
  if (viewers.isEmpty) return null;

  // Una persona con dos pestañas abiertas es una sola persona. Mi propio
  // usuario en otro dispositivo cuenta como uno más, con su rótulo.
  final byUid = <String, ({String label, bool composing})>{};
  for (final v in viewers) {
    final label = v.uid == myUid ? 'Tu usuario en otro dispositivo' : v.name;
    final prev = byUid[v.uid];
    byUid[v.uid] = (label: label, composing: (prev?.composing ?? false) || v.composing);
  }

  final composing = [for (final p in byUid.values) if (p.composing) p.label];
  if (composing.isNotEmpty) {
    final verb = composing.length == 1 ? 'está' : 'están';
    return (text: '${_joinNames(composing)} $verb respondiendo…', composing: true);
  }
  final present = [for (final p in byUid.values) p.label];
  final verb = present.length == 1 ? 'está' : 'están';
  return (text: '${_joinNames(present)} también $verb en este chat', composing: false);
}

String _joinNames(List<String> names) {
  if (names.length == 1) return names.first;
  if (names.length == 2) return '${names[0]} y ${names[1]}';
  return '${names[0]}, ${names[1]} y ${names.length - 2} más';
}

class _Strip extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  final bool subtle;
  final VoidCallback? onClose;

  const _Strip({
    required this.color,
    required this.icon,
    required this.text,
    this.subtle = false,
    this.onClose,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.fromLTRB(10, 7, onClose != null ? 4 : 10, 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: subtle ? 0.06 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: color.withValues(alpha: subtle ? 0.6 : 1), width: 3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subtle ? lightText : color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: lightText,
              tooltip: 'Entendido',
              onPressed: onClose,
              splashRadius: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
        ],
      ),
    );
  }
}
