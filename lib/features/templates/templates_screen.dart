import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';

import 'meta_template.dart';
import 'template_editor_screen.dart';
import 'template_text.dart';
import 'templates_api.dart';

const _errorRed = Color(0xFFF87171);
const _green = Color(0xFF10B981);

/// Las plantillas de Meta de una sesión Cloud API: estado de revisión, motivo
/// de rechazo y calidad. El owner crea y elimina; el resto del equipo mira.
/// Siempre se leen de Meta (no hay copia en Firestore que se desincronice).
class MetaTemplatesScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;

  /// El número real de la sesión (puede no ser el id tras un cambio de
  /// número). Decide el idioma con el que abre el editor.
  final String? sessionPhone;

  const MetaTemplatesScreen({
    required this.accountId,
    required this.sessionId,
    this.sessionPhone,
    super.key,
  });

  @override
  State<MetaTemplatesScreen> createState() => _MetaTemplatesScreenState();
}

class _MetaTemplatesScreenState extends State<MetaTemplatesScreen> {
  bool _loading = true;
  String? _error;
  List<MetaTemplateModel> _templates = const [];
  String? _deletingId;

  bool get _isOwner => AccountContextService().isOwner;

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
      final list = await fetchMetaTemplates(accountId: widget.accountId, sessionId: widget.sessionId);
      list.sort((a, b) {
        final byStatus = _statusRank(a).compareTo(_statusRank(b));
        return byStatus != 0 ? byStatus : a.name.compareTo(b.name);
      });
      if (!mounted) return;
      setState(() {
        _templates = list;
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

  // Lo que pide atención primero: en revisión, rechazadas, con problemas.
  static int _statusRank(MetaTemplateModel t) => switch (t.status) {
        'PENDING' || 'IN_APPEAL' => 0,
        'REJECTED' => 1,
        'PAUSED' || 'DISABLED' || 'FLAGGED' || 'LIMIT_EXCEEDED' => 2,
        'APPROVED' => 3,
        _ => 4,
      };

  Future<void> _openEditor() async {
    final messenger = ScaffoldMessenger.of(context);
    final created = await Navigator.of(context).push<CreatedTemplate>(
      MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(
          accountId: widget.accountId,
          sessionId: widget.sessionId,
          defaultLanguage: defaultTemplateLanguage(widget.sessionPhone ?? widget.sessionId),
          existingKeys: {for (final t in _templates) '${t.name}|${t.language}'},
        ),
      ),
    );
    if (created == null) return;
    final outcome = switch (created.status) {
      'APPROVED' => 'Meta la aprobó al instante: ya puedes enviarla.',
      'REJECTED' => 'Meta la rechazó al recibirla. Mira el motivo en la lista.',
      _ => 'Enviada a revisión. Aparecerá al enviar cuando Meta la apruebe.',
    };
    // Meta la reclasifica sola si el contenido es promocional: mejor saberlo
    // ahora que en la factura.
    final recategorized = created.wasRecategorized && created.category == 'MARKETING'
        ? '\nMeta la clasificó como Marketing: se cobra por cada mensaje entregado.'
        : '';
    messenger.showSnackBar(SnackBar(
      backgroundColor: created.status == 'REJECTED' ? _errorRed : _green,
      duration: Duration(seconds: recategorized.isEmpty ? 4 : 8),
      content: Text('$outcome$recategorized'),
    ));
    _load();
  }

  Future<void> _confirmDelete(MetaTemplateModel t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text('¿Eliminar ${t.name}?', style: const TextStyle(color: white, fontSize: 17)),
        content: Text(
          'Se elimina en Meta (sólo ${t.language}) y ya no se podrá enviar.'
          '${t.isApproved ? '\n\nMeta no deja crear otra con el mismo nombre durante 30 días.' : ''}',
          style: const TextStyle(color: lightText, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: _errorRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deletingId = t.id);
    try {
      await deleteMetaTemplate(accountId: widget.accountId, sessionId: widget.sessionId, template: t);
      messenger.showSnackBar(SnackBar(content: Text('${t.name} eliminada')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(backgroundColor: _errorRed, content: Text('$e')));
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: const Text('Plantillas de WhatsApp'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar desde Meta',
          ),
        ],
      ),
      floatingActionButton: _isOwner && !_loading && _error == null
          ? FloatingActionButton.extended(
              onPressed: _openEditor,
              backgroundColor: primaryAqua,
              foregroundColor: darkBg,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva plantilla', style: TextStyle(fontWeight: FontWeight.w700)),
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
          Text(
            _isOwner
                ? 'Las plantillas sirven para escribirle a un cliente que no te ha escrito en 24 h. '
                    'Meta revisa cada una antes de que se pueda usar.'
                : 'Sólo el owner puede crear o eliminar plantillas. Aquí ves en qué estado está cada una.',
            style: const TextStyle(color: lightText, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (_templates.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Todavía no hay plantillas en esta cuenta de Meta.', style: TextStyle(color: lightText)),
              ),
            ),
          for (final t in _templates) _templateCard(t),
        ],
      ),
    );
  }

  Widget _templateCard(MetaTemplateModel t) {
    final (statusLabel, statusColor) = switch (t.status) {
      'APPROVED' => ('Aprobada', _green),
      'PENDING' => ('En revisión', collisionAmber),
      'IN_APPEAL' => ('En apelación', collisionAmber),
      'REJECTED' => ('Rechazada', _errorRed),
      'PAUSED' => ('Pausada', collisionAmber),
      'DISABLED' => ('Desactivada', _errorRed),
      'FLAGGED' => ('Calidad baja', collisionAmber),
      _ => (t.status, lightText),
    };
    final rejection = t.status == 'REJECTED' ? describeRejectedReason(t.rejectedReason) : null;
    final cannotSend = t.isApproved ? t.unsupportedReason : null;
    final quality = switch (t.qualityScore?.toUpperCase()) {
      'GREEN' => 'Calidad alta',
      'YELLOW' => 'Calidad media: los clientes la están bloqueando o reportando',
      'RED' => 'Calidad baja: Meta puede pausarla',
      _ => null,
    };
    final deleting = _deletingId == t.id;

    return Container(
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
                    Text(t.name, style: const TextStyle(color: white, fontWeight: FontWeight.w700, fontSize: 14)),
                    _chip(statusLabel, statusColor),
                    _chip(t.category == 'MARKETING' ? 'Marketing' : t.category == 'UTILITY' ? 'Utilidad' : t.category,
                        lightText),
                    _chip(t.language, lightText),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  t.bodyText,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: lightText, fontSize: 12.5, height: 1.35),
                ),
                if (rejection != null) _line(Icons.error_outline_rounded, _errorRed, rejection),
                if (t.status == 'REJECTED')
                  _line(Icons.lightbulb_outline_rounded, lightText,
                      'Corrígela creando una nueva con otro nombre, o apélala en WhatsApp Manager.'),
                if (cannotSend != null) _line(Icons.block_rounded, collisionAmber, cannotSend),
                if (quality != null && t.isApproved)
                  _line(Icons.insights_rounded, t.qualityScore == 'GREEN' ? _green : collisionAmber, quality),
              ],
            ),
          ),
          if (_isOwner)
            deleting
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    onPressed: _deletingId != null ? null : () => _confirmDelete(t),
                    icon: const Icon(Icons.delete_outline_rounded, color: lightText, size: 20),
                    tooltip: 'Eliminar plantilla',
                  ),
        ],
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
}
