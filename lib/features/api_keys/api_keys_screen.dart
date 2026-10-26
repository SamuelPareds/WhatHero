import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';

import 'api_keys_api.dart';

const _errorRed = Color(0xFFF87171);
const _green = Color(0xFF10B981);

/// "Llaves de API": con una llave, otro sistema (AgendaCool, el de un cliente)
/// envía plantillas aprobadas desde las sesiones de WhatsApp Cloud API de la
/// cuenta. Sólo el owner entra aquí. La llave completa se ve UNA vez, al
/// crearla; después sólo su pista. Ver CLAUDE.md, "🔑 API pública".
class ApiKeysScreen extends StatefulWidget {
  final String accountId;

  const ApiKeysScreen({required this.accountId, super.key});

  @override
  State<ApiKeysScreen> createState() => _ApiKeysScreenState();
}

/// Una sesión Cloud API viva, para elegirla y para nombrarla en la lista.
class _CloudSession {
  final String id;
  final String label;

  const _CloudSession(this.id, this.label);
}

class _ApiKeysScreenState extends State<ApiKeysScreen> {
  bool _loading = true;
  String? _error;
  List<ApiKeySummary> _keys = const [];
  List<_CloudSession> _cloudSessions = const [];
  String? _revokingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        fetchApiKeys(accountId: widget.accountId),
        _loadCloudSessions(),
      ]);
      if (!mounted) return;
      setState(() {
        _keys = results[0] as List<ApiKeySummary>;
        _cloudSessions = results[1] as List<_CloudSession>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // El API sólo envía por Cloud API: las sesiones QR ni se ofrecen.
  Future<List<_CloudSession>> _loadCloudSessions() async {
    final snap = await AccountContextService().visibleSessionsQuery(widget.accountId).get();
    final sessions = <_CloudSession>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['provider'] != 'cloud_api' || data['deleting_at'] != null) continue;
      sessions.add(_CloudSession(doc.id, _sessionLabel(doc)));
    }
    sessions.sort((a, b) => a.label.compareTo(b.label));
    return sessions;
  }

  static String _sessionLabel(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final phone = displayPhone(sessionPhone(data, doc.id));
    for (final field in ['alias', 'cloud_api_verified_name']) {
      final name = data[field];
      if (name is String && name.trim().isNotEmpty) return '${name.trim()} · $phone';
    }
    return phone;
  }

  Future<void> _create() async {
    final created = await showDialog<({String key, ApiKeySummary summary})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreateKeyDialog(accountId: widget.accountId, cloudSessions: _cloudSessions),
    );
    if (created == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RevealKeyDialog(name: created.summary.name, apiKey: created.key),
    );
    _load();
  }

  Future<void> _confirmRevoke(ApiKeySummary k) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text('¿Revocar "${k.name}"?', style: const TextStyle(color: white, fontSize: 17)),
        content: const Text(
          'Deja de funcionar de inmediato: los sistemas que la usan ya no podrán enviar. '
          'No se puede deshacer; si la necesitas otra vez, crea una nueva.',
          style: TextStyle(color: lightText, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revocar', style: TextStyle(color: _errorRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _revokingId = k.keyId);
    try {
      await revokeApiKey(accountId: widget.accountId, keyId: k.keyId);
      messenger.showSnackBar(SnackBar(content: Text('"${k.name}" revocada')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(backgroundColor: _errorRed, content: Text('$e')));
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: const Text('Llaves de API'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
          ),
        ],
      ),
      floatingActionButton: !_loading && _error == null
          ? FloatingActionButton.extended(
              onPressed: _create,
              backgroundColor: primaryAqua,
              foregroundColor: darkBg,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva llave', style: TextStyle(fontWeight: FontWeight.w700)),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _content(),
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: primaryAqua));
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: _errorRed)),
            const SizedBox(height: 12),
            TextButton(onPressed: _load, child: const Text('Reintentar', style: TextStyle(color: primaryAqua))),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: primaryAqua,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          const Text(
            'Con una llave, otro sistema (por ejemplo AgendaCool) envía plantillas aprobadas por Meta '
            'desde tus sesiones de WhatsApp Cloud API. Los mensajes aparecen en el chat con el nombre de la llave. '
            'Sólo tú, como owner, ves esta pantalla.',
            style: TextStyle(color: lightText, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 8),
          SelectableText(
            'POST $publicApiSendUrl',
            style: const TextStyle(color: lightText, fontSize: 11.5, fontFamily: 'monospace'),
          ),
          if (_cloudSessions.isEmpty) ...[
            const SizedBox(height: 12),
            _line(
              Icons.info_outline_rounded,
              collisionAmber,
              'Todavía no tienes sesiones de WhatsApp Cloud API. El API sólo envía desde ésas, nunca por QR.',
            ),
          ],
          const SizedBox(height: 16),
          if (_keys.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Todavía no hay llaves.', style: TextStyle(color: lightText)),
              ),
            ),
          for (final k in _keys) _keyCard(k),
        ],
      ),
    );
  }

  String _scopeLabel(ApiKeySummary k) {
    if (k.allSessions) return 'Todas las sesiones de Cloud API';
    if (k.sessionIds.isEmpty) return 'Sin sesiones: las que tenía se eliminaron';
    final labels = {for (final s in _cloudSessions) s.id: s.label};
    return k.sessionIds.map((id) => labels[id] ?? displayPhone(id)).join(', ');
  }

  Widget _keyCard(ApiKeySummary k) {
    final revoking = _revokingId == k.keyId;
    final dim = k.isRevoked ? 0.5 : 1.0;
    final used = k.lastUsedAt == null ? 'Nunca usada' : 'Último uso ${_ago(k.lastUsedAt!)}';
    final dates = [
      if (k.createdAt != null) 'Creada el ${_date(k.createdAt!)}',
      if (k.isRevoked) 'Revocada el ${_date(k.revokedAt!)}' else used,
    ].join(' · ');

    return Opacity(
      opacity: dim,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: surfaceDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(k.name, style: const TextStyle(color: white, fontWeight: FontWeight.w700, fontSize: 14)),
                      _chip(k.isRevoked ? 'Revocada' : 'Activa', k.isRevoked ? _errorRed : _green),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(k.hint, style: const TextStyle(color: lightText, fontSize: 12.5, fontFamily: 'monospace')),
                  _line(Icons.phone_iphone_rounded, lightText, _scopeLabel(k)),
                  _line(Icons.schedule_rounded, lightText, dates),
                ],
              ),
            ),
            if (!k.isRevoked)
              revoking
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      onPressed: _revokingId != null ? null : () => _confirmRevoke(k),
                      icon: const Icon(Icons.block_rounded, color: lightText, size: 20),
                      tooltip: 'Revocar llave',
                    ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}

Widget _line(IconData icon, Color color, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12, height: 1.35))),
        ],
      ),
    );

const _months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

String _date(DateTime d) {
  final local = d.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

String _ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'hace un momento';
  if (diff.inHours < 1) return 'hace ${diff.inMinutes} min';
  if (diff.inDays < 1) return 'hace ${diff.inHours} h';
  if (diff.inDays < 30) return 'hace ${diff.inDays} ${diff.inDays == 1 ? 'día' : 'días'}';
  return 'el ${_date(d)}';
}

/// Nombre y sesiones de una llave nueva. Crea la llave aquí mismo para mostrar
/// el error sin perder lo escrito, y devuelve la llave completa.
class _CreateKeyDialog extends StatefulWidget {
  final String accountId;
  final List<_CloudSession> cloudSessions;

  const _CreateKeyDialog({required this.accountId, required this.cloudSessions});

  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  final _name = TextEditingController();
  bool _allSessions = true;
  final Set<String> _selected = {};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving && _name.text.trim().isNotEmpty && (_allSessions || _selected.isNotEmpty);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await createApiKey(
        accountId: widget.accountId,
        name: _name.text.trim(),
        allSessions: _allSessions,
        sessionIds: _allSessions ? const [] : _selected.toList(),
      );
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      title: const Text('Nueva llave de API', style: TextStyle(color: white, fontSize: 17)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                maxLength: 60,
                enabled: !_saving,
                style: const TextStyle(color: white),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'AgendaCool',
                  helperText: 'Así aparece en el chat: "AgendaCool (API)".',
                ),
              ),
              const SizedBox(height: 12),
              const Text('Puede enviar desde', style: TextStyle(color: lightText, fontSize: 12.5)),
              RadioGroup<bool>(
                groupValue: _allSessions,
                onChanged: (v) {
                  if (!_saving && v != null) setState(() => _allSessions = v);
                },
                child: Column(
                  children: [
                    const RadioListTile<bool>(
                      value: true,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('Todas las sesiones de Cloud API', style: TextStyle(color: white)),
                      subtitle: Text('También las que conectes después.', style: TextStyle(color: lightText)),
                    ),
                    RadioListTile<bool>(
                      value: false,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      enabled: widget.cloudSessions.isNotEmpty,
                      title: const Text('Sólo estas', style: TextStyle(color: white)),
                    ),
                  ],
                ),
              ),
              if (!_allSessions)
                for (final s in widget.cloudSessions)
                  CheckboxListTile(
                    value: _selected.contains(s.id),
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 24),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(s.label, style: const TextStyle(color: white)),
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => v == true ? _selected.add(s.id) : _selected.remove(s.id)),
                  ),
              if (_error != null) _line(Icons.error_outline_rounded, _errorRed, _error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: lightText)),
        ),
        TextButton(
          onPressed: _canSave ? _save : null,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Crear llave', style: TextStyle(color: primaryAqua)),
        ),
      ],
    );
  }
}

/// La única vez que se ve la llave completa.
class _RevealKeyDialog extends StatelessWidget {
  final String name;
  final String apiKey;

  const _RevealKeyDialog({required this.name, required this.apiKey});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceDark,
      title: Text('Llave "$name" creada', style: const TextStyle(color: white, fontSize: 17)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cópiala y guárdala en el sistema que la va a usar. Es la única vez que la verás: '
              'WhatHero no la guarda.',
              style: TextStyle(color: lightText, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: darkBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: SelectableText(
                apiKey,
                style: const TextStyle(color: white, fontSize: 12.5, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: apiKey));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Llave copiada')));
                },
                icon: const Icon(Icons.copy_rounded, size: 16, color: primaryAqua),
                label: const Text('Copiar llave', style: TextStyle(color: primaryAqua)),
              ),
            ),
            _line(
              Icons.lock_outline_rounded,
              collisionAmber,
              'Quien tenga esta llave puede enviar plantillas en nombre de tu negocio. '
              'No la pegues en una app o página web: sólo en un servidor.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Ya la guardé', style: TextStyle(color: primaryAqua)),
        ),
      ],
    );
  }
}
