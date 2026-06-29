import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

import 'edit_member_name_dialog.dart';

/// Panel de permisos por sesión de un miembro (Fase 1).
///
/// El owner decide a qué sesiones de WhatsApp tiene acceso un sub-user:
/// - "Acceso total": ve todas las sesiones (presentes y futuras).
/// - Selección por sesión: solo las marcadas.
///
/// Guarda vía `PATCH /accounts/members/:uid/access`, que persiste el `access`
/// en el member doc y mantiene `allowedUids` en cada session doc para que el
/// cliente del miembro pueda listar solo sus sesiones de forma segura.
class MemberAccessScreen extends StatefulWidget {
  final String accountId;
  final String memberUid;
  final String memberLabel; // nombre o email para el título

  const MemberAccessScreen({
    required this.accountId,
    required this.memberUid,
    required this.memberLabel,
    super.key,
  });

  @override
  State<MemberAccessScreen> createState() => _MemberAccessScreenState();
}

class _MemberAccessScreenState extends State<MemberAccessScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  bool _allSessions = false;
  final Set<String> _granted = {};

  // Datos del miembro para el header (editables desde esta misma pantalla).
  String? _displayName;
  String _email = '';

  /// Sesiones de la cuenta: [phone, alias].
  List<MapEntry<String, String>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final accountRef = FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId);

      final results = await Future.wait([
        accountRef.collection('whatsapp_sessions').get(),
        accountRef.collection('members').doc(widget.memberUid).get(),
      ]);

      final sessionsSnap = results[0] as QuerySnapshot;
      final memberSnap = results[1] as DocumentSnapshot;

      _sessions = sessionsSnap.docs.map((d) {
        final data = d.data() as Map<String, dynamic>?;
        final alias = (data?['alias'] as String?)?.trim();
        return MapEntry(d.id, (alias != null && alias.isNotEmpty) ? alias : d.id);
      }).toList()
        ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));

      final memberData = memberSnap.data() as Map<String, dynamic>?;
      _displayName = memberData?['displayName'] as String?;
      _email = memberData?['email'] as String? ?? '';

      final access = memberData?['access'] as Map<String, dynamic>?;
      if (access != null) {
        _allSessions = access['allSessions'] == true;
        final sessions = access['sessions'] as Map<String, dynamic>?;
        if (sessions != null) _granted.addAll(sessions.keys);
      } else {
        // Miembro legacy sin permisos: hoy ve todo. Reflejamos eso como
        // "acceso total" para que el owner vea el estado real antes de tocar.
        _allSessions = true;
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
    });
    try {
      final sessionsMap = <String, dynamic>{
        for (final phone in _granted) phone: {'allChats': true},
      };
      final res = await http
          .patch(
            Uri.parse(
                '$backendUrl/accounts/members/${widget.memberUid}/access'),
            headers: await authHeaders(),
            body: jsonEncode({
              'accountId': widget.accountId,
              'access': {
                'allSessions': _allSessions,
                'sessions': _allSessions ? <String, dynamic>{} : sessionsMap,
              },
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Permisos actualizados'),
            backgroundColor: primaryAqua,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        _showError(body['error'] as String? ?? 'Error inesperado');
        setState(() => _saving = false);
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Error de red: $e');
      setState(() => _saving = false);
    }
  }

  Future<void> _editName() async {
    final newName = await showEditMemberNameDialog(
      context,
      accountId: widget.accountId,
      uid: widget.memberUid,
      currentName: _displayName ?? '',
    );
    if (newName != null && mounted) {
      setState(() => _displayName = newName);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red.shade400,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: Text(
          'Permisos · ${widget.memberLabel}',
          style: const TextStyle(fontWeight: FontWeight.bold, color: white),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: primaryAqua))
          : _loadError != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No se pudieron cargar los permisos:\n$_loadError',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: lightText),
                    ),
                  ),
                )
              : _buildBody(),
      bottomNavigationBar: (_loading || _loadError != null)
          ? null
          : SafeArea(
              minimum: const EdgeInsets.all(16),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(darkBg),
                        ),
                      )
                    : const Text(
                        'Guardar permisos',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
              ),
            ),
    );
  }

  Widget _buildBody() {
    final hasName = _displayName != null && _displayName!.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // Identidad del miembro + edición de nombre (integrada aquí para que
        // la pantalla de "Miembros" tenga un solo gesto por fila).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: surfaceDark,
                child: Text(
                  (hasName ? _displayName! : _email).characters.first
                      .toUpperCase(),
                  style: const TextStyle(
                    color: primaryAqua,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasName ? _displayName! : 'Sin nombre',
                      style: const TextStyle(
                        color: white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _email,
                      style: const TextStyle(color: lightText, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _editName,
                icon: const Icon(Icons.edit_outlined, size: 18, color: primaryAqua),
                label: const Text(
                  'Nombre',
                  style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const Divider(color: surfaceDark, height: 1),
        const SizedBox(height: 8),
        SwitchListTile(
          value: _allSessions,
          activeColor: primaryAqua,
          onChanged: _saving
              ? null
              : (v) => setState(() => _allSessions = v),
          title: const Text(
            'Acceso total',
            style: TextStyle(color: white, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Ve todas las sesiones, incluidas las que vincules en el futuro.',
            style: TextStyle(color: lightText, fontSize: 12.5, height: 1.3),
          ),
        ),
        const Divider(color: surfaceDark, height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Text(
            _allSessions ? 'SESIONES (todas activas)' : 'SESIONES PERMITIDAS',
            style: TextStyle(
              color: lightText.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (_sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Text(
              'Esta cuenta aún no tiene sesiones de WhatsApp vinculadas.',
              style: TextStyle(color: lightText, fontSize: 13),
            ),
          )
        else
          ..._sessions.map((s) {
            final phone = s.key;
            final alias = s.value;
            final selected = _allSessions || _granted.contains(phone);
            return SwitchListTile(
              value: selected,
              activeColor: primaryAqua,
              // Cuando hay acceso total, las sesiones individuales se ven
              // activas pero no editables (el master switch manda).
              onChanged: (_allSessions || _saving)
                  ? null
                  : (v) => setState(() {
                        if (v) {
                          _granted.add(phone);
                        } else {
                          _granted.remove(phone);
                        }
                      }),
              title: Text(
                alias,
                style: const TextStyle(color: white, fontWeight: FontWeight.w600),
              ),
              subtitle: alias != phone
                  ? Text(
                      phone,
                      style: const TextStyle(color: lightText, fontSize: 12),
                    )
                  : null,
              secondary: CircleAvatar(
                backgroundColor: primaryAqua.withValues(alpha: 0.15),
                child: Text(
                  alias.characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: primaryAqua,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          }),
        const SizedBox(height: 8),
      ],
    );
  }
}
