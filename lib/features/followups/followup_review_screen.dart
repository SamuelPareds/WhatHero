import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

import 'followup_api.dart';
import 'followup_campaigns_screen.dart' show campaignSubtitle, periodLabel;
import 'followup_message.dart';
import 'followup_models.dart';
import 'followup_widgets.dart';

/// Revisar lo que encontró una campaña (o el barrido diario, con
/// `campaignId == null`): aprobar, rechazar o editar cada mensaje. Lo
/// aprobado sale solo, espaciado, desde el backend.
class FollowupReviewScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String? campaignId;
  final bool isOwner;
  final ValueChanged<String> onOpenChat;

  const FollowupReviewScreen({
    required this.accountId,
    required this.sessionId,
    required this.campaignId,
    required this.isOwner,
    required this.onOpenChat,
    super.key,
  });

  @override
  State<FollowupReviewScreen> createState() => _FollowupReviewScreenState();
}

class _FollowupReviewScreenState extends State<FollowupReviewScreen> {
  late final FollowupApi _api = FollowupApi(accountId: widget.accountId, sessionId: widget.sessionId);
  late final DocumentReference<Map<String, dynamic>> _sessionRef = FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId);
  // Una sola condición de igualdad: no necesita índice compuesto. Se ordena
  // en memoria (son a lo sumo unos cientos).
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _queue = widget.campaignId == null
      ? _sessionRef.collection('followup_queue').where('source', isEqualTo: 'daily').snapshots()
      : _sessionRef.collection('followup_queue').where('campaignId', isEqualTo: widget.campaignId).snapshots();
  late final Stream<DocumentSnapshot<Map<String, dynamic>>>? _campaign = widget.campaignId == null
      ? null
      : _sessionRef.collection('followup_campaigns').doc(widget.campaignId).snapshots();

  bool _approvingAll = false;
  bool _cancelling = false;

  void _openChat(String chatId) {
    // La pantalla de revisión va encima de la lista; el chat se abre en ella.
    widget.onOpenChat(chatId);
  }

  Future<void> _approveAll(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text('¿Aprobar $count ${count == 1 ? 'mensaje' : 'mensajes'}?', style: const TextStyle(color: white)),
        content: const Text(
          'Saldrán solos, uno cada 1 o 2 minutos, de 9:00 a 20:00 y hasta 80 por día. '
          'Si un cliente escribe antes de que le toque, su mensaje no sale.',
          style: TextStyle(color: lightText, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Revisar primero')),
          FilledButton(
            autofocus: false,
            style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aprobar todos'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _approvingAll = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _api.approveAll(widget.campaignId!);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.skipped > 0
                ? '${r.approved} aprobados. ${r.skipped} ya no se podían enviar.'
                : '${r.approved} aprobados. Empiezan a salir en unos segundos.',
          ),
        ),
      );
    } on FollowupApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _approvingAll = false);
    }
  }

  Future<void> _cancelCampaign() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('¿Cancelar la campaña?', style: TextStyle(color: white)),
        content: const Text(
          'Se detiene la revisión y no sale nada de lo que falta, aunque ya esté aprobado. Lo que ya se envió, enviado está.',
          style: TextStyle(color: lightText, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: errorRed, foregroundColor: darkBg),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar campaña'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _cancelling = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _api.cancel(widget.campaignId!);
    } on FollowupApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _campaign,
      builder: (context, campaignSnap) {
        final campaign = campaignSnap.data?.exists == true ? FollowupCampaign.fromDoc(campaignSnap.data!) : null;
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _queue,
          builder: (context, queueSnap) {
            if (queueSnap.hasError) {
              debugPrint('[Seguimiento] No se pudo leer la cola: ${queueSnap.error}');
            }
            final today = todayString();
            final all = (queueSnap.data?.docs ?? const []).map(FollowupProposal.fromDoc).toList()
              ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
            ReviewTab tabOf(FollowupProposal p) =>
                (p.status == 'pending' || p.status == 'approved') && p.isExpired(today) ? ReviewTab.discarded : p.tab;
            final byTab = {for (final t in ReviewTab.values) t: all.where((p) => tabOf(p) == t).toList()};
            final toReview = byTab[ReviewTab.toReview]!;

            return DefaultTabController(
              length: 4,
              child: Scaffold(
                backgroundColor: darkBg,
                appBar: AppBar(
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Revisar seguimiento', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      Text(
                        widget.campaignId == null
                            ? 'Revisión diaria'
                            : (campaign?.audience.isNotEmpty == true ? campaign!.audience : 'Campaña'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: lightText.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                  actions: [
                    if (widget.isOwner &&
                        campaign != null &&
                        campaign.status != 'cancelled' &&
                        (campaign.isAnalyzing ||
                            byTab[ReviewTab.toReview]!.isNotEmpty ||
                            byTab[ReviewTab.scheduled]!.isNotEmpty))
                      TextButton(
                        onPressed: _cancelling ? null : _cancelCampaign,
                        child: const Text('Cancelar campaña', style: TextStyle(color: errorRed)),
                      ),
                  ],
                  bottom: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    indicatorColor: primaryAqua,
                    labelColor: primaryAqua,
                    unselectedLabelColor: lightText,
                    tabs: [
                      Tab(text: 'Por revisar (${toReview.length})'),
                      Tab(text: 'En fila (${byTab[ReviewTab.scheduled]!.length})'),
                      Tab(text: 'Enviados (${byTab[ReviewTab.sent]!.length})'),
                      Tab(text: 'Descartados (${byTab[ReviewTab.discarded]!.length})'),
                    ],
                  ),
                ),
                body: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Column(
                        children: [
                          if (campaign != null) _CampaignHeader(campaign: campaign),
                          OutboxStrip(
                            sessionRef: _sessionRef,
                            api: _api,
                            scheduledCount: byTab[ReviewTab.scheduled]!.length,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: !queueSnap.hasData
                          ? const Center(child: CircularProgressIndicator())
                          : TabBarView(
                              children: [
                                _list(
                                  toReview,
                                  today,
                                  empty: campaign?.isAnalyzing == true
                                      ? 'Buscando clientes… lo que vaya encontrando aparece aquí.'
                                      : 'No queda nada por revisar.',
                                  header: widget.campaignId != null && toReview.length > 1
                                      ? Align(
                                          alignment: Alignment.centerRight,
                                          child: Padding(
                                            padding: const EdgeInsets.only(bottom: 8),
                                            child: OutlinedButton.icon(
                                              onPressed: _approvingAll ? null : () => _approveAll(toReview.length),
                                              icon: _approvingAll
                                                  ? const SizedBox(
                                                      width: 14,
                                                      height: 14,
                                                      child: CircularProgressIndicator(strokeWidth: 2),
                                                    )
                                                  : const Icon(Icons.done_all, size: 18),
                                              label: Text('Aprobar todos (${toReview.length})'),
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                                _list(byTab[ReviewTab.scheduled]!, today, empty: 'Nada en la fila de envío.'),
                                _list(byTab[ReviewTab.sent]!, today, empty: 'Todavía no sale ninguno.'),
                                _list(byTab[ReviewTab.discarded]!, today, empty: 'Nada descartado.'),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _list(List<FollowupProposal> items, String today, {required String empty, Widget? header}) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            empty,
            textAlign: TextAlign.center,
            style: TextStyle(color: lightText.withValues(alpha: 0.6)),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          itemCount: items.length + (header == null ? 0 : 1),
          itemBuilder: (context, i) {
            if (header != null && i == 0) return header;
            final p = items[i - (header == null ? 0 : 1)];
            return ProposalCard(key: ValueKey(p.chatId), proposal: p, api: _api, today: today, onOpenChat: _openChat);
          },
        ),
      ),
    );
  }
}

class _CampaignHeader extends StatelessWidget {
  final FollowupCampaign campaign;

  const _CampaignHeader({required this.campaign});

  @override
  Widget build(BuildContext context) {
    final c = campaign;
    final skipped = c.skipped.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              periodLabel(c.fromDate, c.toDate),
              if (c.deadline != null) 'promo hasta el ${formatDayMonth(c.deadline!)}',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(color: lightText.withValues(alpha: 0.75), fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            campaignSubtitle(c),
            style: const TextStyle(color: white, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          if (c.isAnalyzing) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: c.total > 0 ? c.analyzed / c.total : null,
              minHeight: 3,
              color: primaryAqua,
              backgroundColor: darkBg,
            ),
            const SizedBox(height: 4),
            Text(
              'Puedes salir de esta pantalla: la revisión sigue en el servidor.',
              style: TextStyle(color: lightText.withValues(alpha: 0.55), fontSize: 11),
            ),
          ],
          if (c.totalInPeriod > c.total)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'El periodo tenía ${c.totalInPeriod} conversaciones; se revisaron las ${c.total} más recientes.',
                style: const TextStyle(color: collisionAmber, fontSize: 12),
              ),
            ),
          if (skipped.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                dense: true,
                title: Text(
                  'Por qué no entraron los demás',
                  style: TextStyle(color: primaryAqua.withValues(alpha: 0.9), fontSize: 13),
                ),
                children: [
                  for (final e in skipped)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            skipLabels[e.key] ?? e.key,
                            style: const TextStyle(color: lightText, fontSize: 12),
                          ),
                        ),
                        Text('${e.value}', style: const TextStyle(color: lightText, fontSize: 12)),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
