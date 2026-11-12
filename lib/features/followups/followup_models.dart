import 'package:cloud_firestore/cloud_firestore.dart';

import 'followup_message.dart';

/// Una propuesta de seguimiento (`followup_queue/{chatId}`). La escribe sólo el
/// backend; la app la lee y la decide por HTTP. Ver CLAUDE.md, "📣 Campañas de
/// seguimiento".
class FollowupProposal {
  final String chatId;
  final String? contactName;
  final String? campaignId;
  final String source;
  final String status;
  final String messageTemplate;
  final String? editedText;
  final String? deadline;
  final String? lastDay;
  final String reason;
  final String? evidenceText;
  final DateTime? evidenceAt;
  final String? error;
  final String? closedReason;
  final DateTime? createdAt;
  final DateTime? sentAt;

  const FollowupProposal({
    required this.chatId,
    required this.status,
    required this.messageTemplate,
    required this.reason,
    required this.source,
    this.contactName,
    this.campaignId,
    this.editedText,
    this.deadline,
    this.lastDay,
    this.evidenceText,
    this.evidenceAt,
    this.error,
    this.closedReason,
    this.createdAt,
    this.sentAt,
  });

  factory FollowupProposal.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? const {};
    final evidence = d['evidence'] as Map<String, dynamic>?;
    final evidenceAt = evidence?['at'];
    return FollowupProposal(
      chatId: doc.id,
      contactName: d['contactName'] as String?,
      campaignId: d['campaignId'] as String?,
      source: (d['source'] as String?) ?? 'daily',
      status: (d['status'] as String?) ?? 'pending',
      // Las propuestas del barrido diario de antes no tienen plantilla: su
      // borrador es el texto final.
      messageTemplate: (d['messageTemplate'] as String?) ?? (d['draftMessage'] as String?) ?? '',
      editedText: d['editedText'] as String?,
      deadline: d['deadline'] as String?,
      lastDay: d['lastDay'] as String?,
      reason: (d['reason'] as String?) ?? '',
      evidenceText: evidence?['text'] as String?,
      evidenceAt: evidenceAt is num ? DateTime.fromMillisecondsSinceEpoch(evidenceAt.toInt()) : null,
      error: d['error'] as String?,
      closedReason: d['closedReason'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      sentAt: (d['sentAt'] as Timestamp?)?.toDate(),
    );
  }

  String get displayName {
    final name = contactName?.trim();
    return (name == null || name.isEmpty) ? '+$chatId' : name;
  }

  /// Ya no se puede enviar: la fecha límite (o los 7 días) pasó.
  bool isExpired(String today) => status == 'expired' || (lastDay != null && daysBetween(today, lastDay!) < 0);

  /// El texto que saldría hoy. null = ya no saldría (venció).
  String? previewFor(String today) {
    final edited = editedText?.trim();
    if (edited != null && edited.isNotEmpty) return edited;
    return renderDateVariables(messageTemplate, deadline, today);
  }

  ReviewTab get tab {
    switch (status) {
      case 'pending':
        return ReviewTab.toReview;
      case 'approved':
      case 'sending':
      case 'failed':
        return ReviewTab.scheduled;
      case 'sent':
      case 'handled':
      case 'in_doubt':
        return ReviewTab.sent;
      default:
        return ReviewTab.discarded;
    }
  }

  /// Por qué terminó así, en palabras del operador.
  String? get outcomeLabel {
    switch (status) {
      case 'sent':
        return 'Enviado';
      case 'handled':
        return 'Lo atendió alguien del equipo';
      case 'in_doubt':
        return 'Sin confirmar: revisa el chat antes de volver a escribirle';
      case 'rejected':
        return 'Rechazado';
      case 'expired':
        return 'Venció sin enviarse';
      case 'cancelled':
        return 'Campaña cancelada';
      case 'failed':
        return error == null ? 'No salió' : 'No salió: $error';
      case 'stale':
        switch (closedReason) {
          case 'client_wrote':
            return 'El cliente escribió antes del envío';
          case 'conversation_moved':
            return 'La conversación cambió antes del envío';
          case 'pending':
            return 'El cliente espera una respuesta';
          case 'opted_out':
            return 'Pidió no recibir mensajes';
          case 'chat_deleted':
            return 'El chat se borró';
          default:
            return 'La conversación cambió';
        }
      default:
        return null;
    }
  }
}

enum ReviewTab { toReview, scheduled, sent, discarded }

/// Una campaña (`followup_campaigns/{id}`).
class FollowupCampaign {
  final String id;
  final String status;
  final String instruction;
  final String audience;
  final String exclusions;
  final String message;
  final String? deadline;
  final bool adapt;
  final String fromDate;
  final String toDate;
  final String? lastDay;
  final int total;
  final int totalInPeriod;
  final int analyzed;
  final int matched;
  final Map<String, int> skipped;
  final String? error;
  final DateTime? createdAt;

  const FollowupCampaign({
    required this.id,
    required this.status,
    required this.instruction,
    required this.audience,
    required this.exclusions,
    required this.message,
    required this.adapt,
    required this.fromDate,
    required this.toDate,
    required this.total,
    required this.totalInPeriod,
    required this.analyzed,
    required this.matched,
    required this.skipped,
    this.deadline,
    this.lastDay,
    this.error,
    this.createdAt,
  });

  factory FollowupCampaign.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? const {};
    final plan = (d['plan'] as Map<String, dynamic>?) ?? const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    return FollowupCampaign(
      id: doc.id,
      status: (d['status'] as String?) ?? 'analyzing',
      instruction: (d['instruction'] as String?) ?? '',
      audience: (plan['audience'] as String?) ?? '',
      exclusions: (plan['exclusions'] as String?) ?? '',
      message: (plan['message'] as String?) ?? '',
      deadline: plan['deadline'] as String?,
      adapt: plan['adapt'] == true,
      fromDate: (d['fromDate'] as String?) ?? '',
      toDate: (d['toDate'] as String?) ?? '',
      lastDay: d['lastDay'] as String?,
      total: n(d['total']),
      totalInPeriod: n(d['totalInPeriod']),
      analyzed: n(d['analyzed']),
      matched: n(d['matched']),
      skipped: {for (final e in ((d['skipped'] as Map<String, dynamic>?) ?? const {}).entries) e.key: n(e.value)},
      error: d['error'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  bool get isAnalyzing => status == 'analyzing';
}

/// Lo que el backend dice del goteo de la sesión (`followup_outbox/state`).
class OutboxState {
  final bool paused;
  final String? pausedReason;
  final String? waiting;
  final DateTime? nextAt;
  final int sentToday;

  const OutboxState({required this.paused, required this.sentToday, this.pausedReason, this.waiting, this.nextAt});

  factory OutboxState.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? const {};
    return OutboxState(
      paused: d['paused'] == true,
      pausedReason: d['pausedReason'] as String?,
      waiting: d['waiting'] as String?,
      nextAt: (d['nextAt'] as Timestamp?)?.toDate(),
      sentToday: (d['sentToday'] as num?)?.toInt() ?? 0,
    );
  }

  static const idle = OutboxState(paused: false, sentToday: 0);
}

/// Motivos por los que un chat no entró, para el resumen de la campaña.
/// Mismas claves que `SKIP_LABELS` en followupCampaigns.ts.
const skipLabels = <String, String>{
  'group': 'Grupos',
  'opted_out': 'Pidieron no recibir mensajes',
  'pending': 'Esperan tu respuesta',
  'recent_activity': 'Conversación activa hoy',
  'recent_followup': 'Ya recibieron seguimiento esta semana',
  'already_scheduled': 'Ya tienen un seguimiento programado',
  'in_other_campaign': 'Están en otra campaña',
  'no_history': 'Sin mensajes legibles',
  'no_match': 'No coinciden con lo que pediste',
  'ai_error': 'La IA no pudo revisarlos',
};
