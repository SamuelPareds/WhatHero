import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

import 'followup_api.dart';
import 'followup_message.dart';
import 'followup_models.dart';

const errorRed = Color(0xFFF87171);
const sentGreen = Color(0xFF10B981);

BoxDecoration cardDecoration({Color? accent}) => BoxDecoration(
  color: surfaceDark,
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: (accent ?? white).withValues(alpha: accent == null ? 0.06 : 0.35)),
);

InputDecoration inputDecoration({required String hint}) => InputDecoration(
  hintText: hint,
  hintStyle: TextStyle(color: lightText.withValues(alpha: 0.4), fontSize: 13),
  filled: true,
  fillColor: darkBg,
  isDense: true,
  contentPadding: const EdgeInsets.all(12),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
  counterStyle: TextStyle(color: lightText.withValues(alpha: 0.4), fontSize: 11),
);

class FieldLabel extends StatelessWidget {
  final String text;

  const FieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(color: lightText, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

class ErrorLine extends StatelessWidget {
  final String text;

  const ErrorLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.error_outline, size: 16, color: errorRed),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text, style: const TextStyle(color: errorRed, fontSize: 13)),
      ),
    ],
  );
}

class CountPill extends StatelessWidget {
  final int count;
  final Color color;

  const CountPill({required this.count, required this.color, super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
    child: Text(
      '$count',
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
    ),
  );
}

class MessagePreview extends StatelessWidget {
  final String label;
  final String text;

  const MessagePreview({required this.label, required this.text, super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: primaryAqua.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border(left: BorderSide(color: primaryAqua.withValues(alpha: 0.7), width: 3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: primaryAqua.withValues(alpha: 0.9), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        SelectableText(text, style: const TextStyle(color: white, fontSize: 14, height: 1.35)),
      ],
    ),
  );
}

class CampaignStatusChip extends StatelessWidget {
  final FollowupCampaign campaign;

  const CampaignStatusChip({required this.campaign, super.key});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (campaign.status) {
      'analyzing' => ('Revisando', primaryAqua),
      'ready' => ('Lista', sentGreen),
      'failed' => ('Falló', errorRed),
      'cancelled' => ('Cancelada', lightText),
      _ => (campaign.status, lightText),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Qué está haciendo el goteo de la sesión: enviando, esperando el horario,
/// pausado. Sólo aparece cuando hay algo que decir.
class OutboxStrip extends StatelessWidget {
  final DocumentReference<Map<String, dynamic>> sessionRef;
  final FollowupApi api;
  // Hay aprobados esperando (si no, "fuera de horario" no le importa a nadie).
  final int? scheduledCount;

  const OutboxStrip({required this.sessionRef, required this.api, this.scheduledCount, super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: sessionRef.collection('followup_outbox').doc('state').snapshots(),
      builder: (context, snap) {
        final state = snap.data?.exists == true ? OutboxState.fromDoc(snap.data!) : OutboxState.idle;
        final message = outboxMessage(state, scheduledCount: scheduledCount);
        if (message == null) return const SizedBox.shrink();
        final color = state.paused ? collisionAmber : primaryAqua;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          child: Row(
            children: [
              Icon(state.paused ? Icons.pause_circle_outline : Icons.schedule_send_outlined, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              _PauseButton(api: api, paused: state.paused),
            ],
          ),
        );
      },
    );
  }
}

/// El texto de la franja del goteo. null = nada que decir.
String? outboxMessage(OutboxState s, {int? scheduledCount, DateTime? now}) {
  if (s.paused) {
    switch (s.pausedReason) {
      case 'failures':
        return 'Envíos pausados: 3 fallaron seguidos. Revisa que WhatsApp esté conectado antes de reanudar.';
      case 'number_change':
        return 'Envíos pausados por el cambio de número.';
      default:
        return 'Envíos pausados.';
    }
  }
  if (scheduledCount == 0) return null;
  switch (s.waiting) {
    case 'hours':
      return 'Los envíos salen de 9:00 a 20:00. Se reanudan a las 9:00.';
    case 'cap':
      return 'Hoy ya salieron ${s.sentToday}. Lo demás sale mañana a partir de las 9:00.';
    case 'offline':
      return 'WhatsApp está desconectado: los envíos esperan a que vuelva.';
  }
  final next = s.nextAt;
  if (next == null) return null;
  final secs = next.difference(now ?? DateTime.now()).inSeconds;
  final when = secs <= 30 ? 'en unos segundos' : 'en ~${(secs / 60).ceil()} min';
  return 'Enviando uno a la vez para cuidar tu número · siguiente $when';
}

class _PauseButton extends StatefulWidget {
  final FollowupApi api;
  final bool paused;

  const _PauseButton({required this.api, required this.paused});

  @override
  State<_PauseButton> createState() => _PauseButtonState();
}

class _PauseButtonState extends State<_PauseButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.setPaused(!widget.paused);
    } on FollowupApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: _busy ? null : _toggle, child: Text(widget.paused ? 'Reanudar' : 'Pausar'));
}

/// Una propuesta: a quién, por qué (con la cita del cliente), el mensaje que
/// saldría hoy y lo que se puede hacer con ella.
class ProposalCard extends StatefulWidget {
  final FollowupProposal proposal;
  final FollowupApi api;
  final String today;
  final ValueChanged<String> onOpenChat;

  const ProposalCard({
    required this.proposal,
    required this.api,
    required this.today,
    required this.onOpenChat,
    super.key,
  });

  @override
  State<ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<ProposalCard> {
  bool _busy = false;

  Future<void> _decide(String action, {String? text}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.decide(widget.proposal.chatId, action, text: text);
    } on FollowupApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text('Mensaje para ${widget.proposal.displayName}', style: const TextStyle(color: white, fontSize: 16)),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 3,
                maxLines: 10,
                maxLength: 1000,
                style: const TextStyle(color: white, fontSize: 14),
                decoration: inputDecoration(hint: 'Mensaje'),
              ),
              Text(
                'Se enviará tal cual: los días que faltan ya no se actualizan solos.',
                style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty && result != current) await _decide('edit', text: result);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final expired = p.isExpired(widget.today);
    final preview = p.previewFor(widget.today);
    final open = p.status == 'pending' || p.status == 'approved' || p.status == 'failed';
    final canEdit = open && !expired && preview != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: cardDecoration(accent: p.status == 'failed' ? errorRed : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: primaryAqua.withValues(alpha: 0.15),
                child: Text(
                  p.displayName.characters.first.toUpperCase(),
                  style: const TextStyle(color: primaryAqua, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: () => widget.onOpenChat(p.chatId),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: white, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Ver conversación',
                        style: TextStyle(color: primaryAqua.withValues(alpha: 0.85), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (p.evidenceText != null) ...[
            const SizedBox(height: 10),
            Text(
              '“${p.evidenceText}”${p.evidenceAt != null ? ' · ${_shortDate(p.evidenceAt!)}' : ''}',
              style: const TextStyle(color: white, fontSize: 13, fontStyle: FontStyle.italic),
            ),
          ],
          if (p.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(p.reason, style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12)),
          ],
          const SizedBox(height: 10),
          if (preview != null)
            Stack(
              children: [
                MessagePreview(
                  label: p.editedText != null
                      ? 'Mensaje (editado)'
                      : p.status == 'sent'
                      ? 'Mensaje'
                      : 'Saldría hoy así',
                  text: p.status == 'sent' ? (p.editedText ?? preview) : preview,
                ),
                if (canEdit)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      tooltip: 'Editar mensaje',
                      icon: const Icon(Icons.edit_outlined, size: 18, color: primaryAqua),
                      onPressed: _busy ? null : () => _edit(preview),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: _footer(p, expired)),
        ],
      ),
    );
  }

  Widget _footer(FollowupProposal p, bool expired) {
    if (_busy) {
      return const Align(
        alignment: Alignment.centerRight,
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (expired && (p.status == 'pending' || p.status == 'approved')) {
      return Text('Venció sin enviarse', style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 12));
    }
    switch (p.status) {
      case 'pending':
        // Wrap y no Row: con letra grande (accesibilidad) los botones bajan
        // de línea en vez de desbordarse.
        return Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => _decide('reject'),
              child: const Text('Rechazar', style: TextStyle(color: lightText)),
            ),
            FilledButton.icon(
              onPressed: () => _decide('approve'),
              style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Aprobar'),
            ),
          ],
        );
      case 'approved':
        return Row(
          children: [
            const Icon(Icons.schedule_send_outlined, size: 16, color: primaryAqua),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('En la fila de envío', style: TextStyle(color: primaryAqua, fontSize: 13)),
            ),
            TextButton(onPressed: () => _decide('unapprove'), child: const Text('No enviar')),
          ],
        );
      case 'sending':
        return const Text('Enviando…', style: TextStyle(color: primaryAqua, fontSize: 13));
      case 'failed':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ErrorLine(p.outcomeLabel ?? 'No salió'),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => _decide('reject'),
                  child: const Text('Descartar', style: TextStyle(color: lightText)),
                ),
                FilledButton(
                  onPressed: () => _decide('approve'),
                  style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ],
        );
      default:
        final label = p.outcomeLabel;
        if (label == null) return const SizedBox.shrink();
        final color = p.status == 'sent' || p.status == 'handled'
            ? sentGreen
            : p.status == 'in_doubt'
            ? collisionAmber
            : lightText;
        return Text(
          '$label${p.sentAt != null && p.status == 'sent' ? ' · ${_shortDate(p.sentAt!)}' : ''}',
          style: TextStyle(color: color, fontSize: 12),
        );
    }
  }
}

String _shortDate(DateTime d) {
  final day = dayString(d.toLocal());
  final hh = d.toLocal().hour.toString().padLeft(2, '0');
  final mm = d.toLocal().minute.toString().padLeft(2, '0');
  return '${formatDayMonth(day)}, $hh:$mm';
}
