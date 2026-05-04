import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

import 'add_member_modal.dart';

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

  const _PersonTile({
    required this.accountId,
    required this.uid,
    required this.email,
    required this.displayName,
    required this.isOwnerTile,
    required this.canEdit,
  });

  String _initial() {
    final src = (displayName?.isNotEmpty ?? false) ? displayName! : email;
    return src.isEmpty ? '?' : src.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final hasName = displayName != null && displayName!.isNotEmpty;
    return ListTile(
      onTap: canEdit
          ? () => _showEditDialog(
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
            : email,
        style: const TextStyle(color: lightText, fontSize: 12),
      ),
      trailing: Container(
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
    );
  }
}

/// Diálogo de edición: input + Guardar. Llama al PATCH y muestra error
/// inline si el backend rechaza (ej. permisos, nombre vacío).
Future<void> _showEditDialog(
  BuildContext context, {
  required String accountId,
  required String uid,
  required String currentName,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => _EditNameDialog(
      accountId: accountId,
      uid: uid,
      currentName: currentName,
    ),
  );
}

class _EditNameDialog extends StatefulWidget {
  final String accountId;
  final String uid;
  final String currentName;

  const _EditNameDialog({
    required this.accountId,
    required this.uid,
    required this.currentName,
  });

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  bool _saving = false;
  String? _error;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newName = _controller.text.trim();
    if (newName.isEmpty) {
      setState(() => _error = 'El nombre no puede estar vacío');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await http
          .patch(
            Uri.parse('$backendUrl/accounts/members/${widget.uid}'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'displayName': newName,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nombre actualizado'),
            backgroundColor: primaryAqua,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _error = body['error'] as String? ?? 'Error inesperado';
          _saving = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error de red: $e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Editar nombre',
        style: TextStyle(color: white, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Este nombre aparece arriba de cada mensaje saliente para identificar quién respondió.',
            style: TextStyle(color: lightText, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_saving,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            keyboardType: TextInputType.name,
            style: const TextStyle(color: white),
            decoration: InputDecoration(
              hintText: 'Nombre completo',
              hintStyle: const TextStyle(color: lightText),
              filled: true,
              fillColor: darkBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Cancelar',
            style: TextStyle(color: lightText.withValues(alpha: 0.7)),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAqua,
            foregroundColor: darkBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(darkBg),
                  ),
                )
              : const Text(
                  'Guardar',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
      ],
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
