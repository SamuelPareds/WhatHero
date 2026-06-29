import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';

import 'add_member_modal.dart';
import 'edit_member_name_dialog.dart';
import 'member_access_screen.dart';

/// Pantalla "Miembros del equipo".
///
/// Lista los usuarios que tienen acceso a la cuenta del owner: el owner
/// mismo (siempre arriba, leído desde users/{uid} para mostrar su nombre
/// real) + los miembros invitados (subcollection
/// `accounts/{accountId}/members`).
///
/// Edición de displayName: cualquier tile es clickeable. El owner puede
/// editar el nombre de cualquier miembro; los sub-users sólo pueden editar
/// el suyo. La regla la valida el backend (PATCH /accounts/members/:uid).
class MembersScreen extends StatelessWidget {
  final String accountId;

  const MembersScreen({required this.accountId, super.key});

  @override
  Widget build(BuildContext context) {
    final ctx = AccountContextService();
    final currentUid = ctx.currentUid ?? '';
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
          // Owner: leemos su propio doc users/{uid} para mostrar el
          // displayName real (puede ser editado por él mismo o por nadie más,
          // así que con un read tenemos suficiente).
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(currentUid)
                .snapshots(),
            builder: (context, snap) {
              final data = snap.data?.data() as Map<String, dynamic>?;
              return _PersonTile(
                accountId: accountId,
                uid: currentUid,
                email: data?['email'] as String? ?? '—',
                displayName: data?['displayName'] as String?,
                isOwnerTile: true,
                canEdit: true, // siempre puedes editar tu propio nombre
                canManageAccess: false, // el owner siempre tiene acceso total
              );
            },
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
                  // canEdit: el owner edita a cualquiera; un sub-user que se
                  // ve a sí mismo en la lista (no debería pasar hoy, pero
                  // futuro) podría editar su tile.
                  final memberUid = d.id;
                  final canEdit = ctx.isOwner || memberUid == currentUid;
                  return _PersonTile(
                    accountId: accountId,
                    uid: memberUid,
                    email: data['email'] as String? ?? '—',
                    displayName: data['displayName'] as String?,
                    isOwnerTile: false,
                    canEdit: canEdit,
                    // Solo el owner administra permisos de sus sub-users.
                    canManageAccess: ctx.isOwner,
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

/// Tile genérico para una persona (owner o miembro). Encapsula la lógica de
/// avatar, badge y tap → editar.
class _PersonTile extends StatelessWidget {
  final String accountId;
  final String uid;
  final String email;
  final String? displayName;
  final bool isOwnerTile;
  final bool canEdit;
  // El owner puede administrar permisos por sesión de un sub-user.
  final bool canManageAccess;

  const _PersonTile({
    required this.accountId,
    required this.uid,
    required this.email,
    required this.displayName,
    required this.isOwnerTile,
    required this.canEdit,
    required this.canManageAccess,
  });

  String _initial() {
    final src = (displayName?.isNotEmpty ?? false) ? displayName! : email;
    return src.isEmpty ? '?' : src.characters.first.toUpperCase();
  }

  void _openAccess(BuildContext context) {
    final label = (displayName?.isNotEmpty ?? false) ? displayName! : email;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MemberAccessScreen(
          accountId: accountId,
          memberUid: uid,
          memberLabel: label,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasName = displayName != null && displayName!.isNotEmpty;
    return ListTile(
      // Un solo gesto por fila. Para un sub-user administrable, el tap abre su
      // panel (permisos + edición de nombre adentro). Para el owner/self, que
      // no tienen panel de permisos, el tap edita su propio nombre.
      onTap: canManageAccess
          ? () => _openAccess(context)
          : canEdit
              ? () => showEditMemberNameDialog(
                    context,
                    accountId: accountId,
                    uid: uid,
                    currentName: displayName ?? '',
                  )
              : null,
      leading: CircleAvatar(
        backgroundColor: isOwnerTile
            ? primaryAqua.withValues(alpha: 0.2)
            : surfaceDark,
        child: isOwnerTile
            ? const Icon(Icons.shield_outlined, color: primaryAqua)
            : Text(
                _initial(),
                style: const TextStyle(
                    color: primaryAqua, fontWeight: FontWeight.w700),
              ),
      ),
      title: Text(
        hasName ? displayName! : (isOwnerTile ? 'Sin nombre' : email),
        style: const TextStyle(color: white, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        isOwnerTile
            ? (hasName ? 'Owner • Tú' : 'Owner • Tú · toca para ponerte nombre')
            : canManageAccess
                ? '$email · toca para gestionar permisos'
                : email,
        style: const TextStyle(color: lightText, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isOwnerTile
                  ? primaryAqua.withValues(alpha: 0.15)
                  : surfaceDark,
              borderRadius: BorderRadius.circular(12),
              border: isOwnerTile
                  ? null
                  : Border.all(color: lightText.withValues(alpha: 0.2)),
            ),
            child: Text(
              isOwnerTile ? 'Owner' : 'Miembro',
              style: TextStyle(
                color: isOwnerTile ? primaryAqua : lightText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (canManageAccess)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.chevron_right, color: lightText, size: 20),
            ),
        ],
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
