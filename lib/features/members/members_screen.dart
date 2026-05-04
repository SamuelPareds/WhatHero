import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';

import 'add_member_modal.dart';

/// Pantalla "Miembros del equipo".
///
/// Lista los usuarios que tienen acceso a la cuenta del owner: el owner
/// mismo (siempre arriba) + los miembros invitados (subcollection
/// `accounts/{accountId}/members`).
///
/// Por ahora solo el owner puede invitar (FAB visible si isOwner). Acciones
/// de revocar/editar quedan para una fase posterior.
class MembersScreen extends StatelessWidget {
  final String accountId;

  const MembersScreen({required this.accountId, super.key});

  @override
  Widget build(BuildContext context) {
    final ctx = AccountContextService();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Miembros del equipo',
          style: TextStyle(fontWeight: FontWeight.bold, color: white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Owner siempre primero, fijado arriba para que se entienda
          // "esta es tu cuenta". Lo leemos del propio AccountContextService
          // para no hacer un read extra.
          _OwnerTile(
            email: '—',
            uid: ctx.currentUid ?? '',
          ),
          const Divider(color: surfaceDark, height: 1),
          // Lista de miembros invitados
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection(accountsCollection)
                .doc(accountId)
                .collection('members')
                .orderBy('addedAt', descending: false)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(
                    child: CircularProgressIndicator(color: primaryAqua),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Error cargando miembros: ${snap.error}',
                    style: const TextStyle(color: lightText),
                  ),
                );
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const _EmptyState();
              }
              return Column(
                children: docs.map((d) {
                  final data = d.data() as Map<String, dynamic>;
                  return _MemberTile(
                    email: data['email'] as String? ?? '—',
                    displayName: data['displayName'] as String?,
                    addedAt: data['addedAt'] as Timestamp?,
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
      floatingActionButton: ctx.isOwner
          ? FloatingActionButton.extended(
              backgroundColor: primaryAqua,
              foregroundColor: darkBg,
              icon: const Icon(Icons.person_add),
              label: const Text(
                'Agregar miembro',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: () => showAddMemberFlow(context, accountId),
            )
          : null,
    );
  }
}

class _OwnerTile extends StatelessWidget {
  final String email;
  final String uid;

  const _OwnerTile({required this.email, required this.uid});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: primaryAqua.withValues(alpha: 0.2),
        child: const Icon(Icons.shield_outlined, color: primaryAqua),
      ),
      title: const Text(
        'Tú (Owner)',
        style: TextStyle(color: white, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        uid.isEmpty ? '' : 'uid: ${uid.substring(0, 8)}…',
        style: const TextStyle(color: lightText, fontSize: 12),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: primaryAqua.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Owner',
          style: TextStyle(
            color: primaryAqua,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  final String email;
  final String? displayName;
  final Timestamp? addedAt;

  const _MemberTile({
    required this.email,
    this.displayName,
    this.addedAt,
  });

  String _initial() {
    final src = (displayName?.isNotEmpty ?? false) ? displayName! : email;
    return src.isEmpty ? '?' : src.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: surfaceDark,
        child: Text(
          _initial(),
          style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.w700),
        ),
      ),
      title: Text(
        displayName ?? email,
        style: const TextStyle(color: white, fontWeight: FontWeight.w500),
      ),
      subtitle: displayName == null
          ? null
          : Text(email, style: const TextStyle(color: lightText, fontSize: 12)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: surfaceDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: lightText.withValues(alpha: 0.2)),
        ),
        child: const Text(
          'Miembro',
          style: TextStyle(
            color: lightText,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
      child: Column(
        children: [
          Icon(
            Icons.group_outlined,
            color: lightText.withValues(alpha: 0.5),
            size: 56,
          ),
          const SizedBox(height: 16),
          const Text(
            'Aún no has invitado a nadie',
            style: TextStyle(color: white, fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Toca "Agregar miembro" para crear un acceso adicional a tu cuenta. '
            'El nuevo miembro verá las mismas sesiones y chats que tú.',
            textAlign: TextAlign.center,
            style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}
