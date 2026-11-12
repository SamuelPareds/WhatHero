import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';

/// Un error del backend, listo para mostrar.
class FollowupApiException implements Exception {
  final String message;
  final String? code;

  const FollowupApiException(this.message, {this.code});

  @override
  String toString() => message;
}

/// El periodo como lo entiende el backend (`PeriodSpec`).
class PeriodSpec {
  final String kind; // last_days | range | last_month | this_month
  final int? days;
  final String? from;
  final String? to;

  const PeriodSpec.lastDays(int this.days) : kind = 'last_days', from = null, to = null;
  const PeriodSpec.lastMonth() : kind = 'last_month', days = null, from = null, to = null;
  const PeriodSpec.thisMonth() : kind = 'this_month', days = null, from = null, to = null;
  const PeriodSpec.range(String this.from, String this.to) : kind = 'range', days = null;

  factory PeriodSpec.fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'range':
        return PeriodSpec.range('${j['from']}', '${j['to']}');
      case 'last_month':
        return const PeriodSpec.lastMonth();
      case 'this_month':
        return const PeriodSpec.thisMonth();
      default:
        return PeriodSpec.lastDays((j['days'] as num?)?.toInt() ?? 7);
    }
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (days != null) 'days': days,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
  };
}

/// El plan editable de la tarjeta "Esto entendí".
class CampaignPlan {
  final PeriodSpec period;
  final String audience;
  final String exclusions;
  final String message;
  final String? deadline;
  final bool adapt;

  const CampaignPlan({
    required this.period,
    required this.audience,
    required this.exclusions,
    required this.message,
    required this.adapt,
    this.deadline,
  });

  factory CampaignPlan.fromJson(Map<String, dynamic> j) => CampaignPlan(
    period: PeriodSpec.fromJson((j['period'] as Map<String, dynamic>?) ?? const {}),
    audience: (j['audience'] as String?) ?? '',
    exclusions: (j['exclusions'] as String?) ?? '',
    message: (j['message'] as String?) ?? '',
    deadline: j['deadline'] as String?,
    adapt: j['adapt'] == true,
  );

  Map<String, dynamic> toJson() => {
    'period': period.toJson(),
    'audience': audience,
    'exclusions': exclusions,
    'message': message,
    'deadline': deadline,
    'adapt': adapt,
  };

  CampaignPlan copyWith({
    PeriodSpec? period,
    String? audience,
    String? exclusions,
    String? message,
    String? Function()? deadline,
    bool? adapt,
  }) => CampaignPlan(
    period: period ?? this.period,
    audience: audience ?? this.audience,
    exclusions: exclusions ?? this.exclusions,
    message: message ?? this.message,
    deadline: deadline != null ? deadline() : this.deadline,
    adapt: adapt ?? this.adapt,
  );
}

/// Respuesta de `POST /followup-campaigns/plan`.
class PlanResult {
  final CampaignPlan plan;
  final List<String> missing;
  final List<String> problems;
  final String fromDate;
  final String toDate;
  final bool clamped;
  final int candidates;
  final int cap;
  final String? preview;
  final String settingsExclusions;

  const PlanResult({
    required this.plan,
    required this.missing,
    required this.problems,
    required this.fromDate,
    required this.toDate,
    required this.clamped,
    required this.candidates,
    required this.cap,
    required this.settingsExclusions,
    this.preview,
  });

  factory PlanResult.fromJson(Map<String, dynamic> j) {
    final period = (j['period'] as Map<String, dynamic>?) ?? const {};
    return PlanResult(
      plan: CampaignPlan.fromJson((j['plan'] as Map<String, dynamic>?) ?? const {}),
      missing: [for (final m in (j['missing'] as List<dynamic>? ?? const [])) '$m'],
      problems: [for (final p in (j['problems'] as List<dynamic>? ?? const [])) '$p'],
      fromDate: '${period['fromDate'] ?? ''}',
      toDate: '${period['toDate'] ?? ''}',
      clamped: period['clamped'] == true,
      candidates: (j['candidates'] as num?)?.toInt() ?? 0,
      cap: (j['cap'] as num?)?.toInt() ?? 600,
      preview: j['preview'] as String?,
      settingsExclusions: (j['settingsExclusions'] as String?) ?? '',
    );
  }

  bool get ready => missing.isEmpty && problems.isEmpty;
}

/// Las llamadas de campañas y revisión. Todas van con el token del usuario; el
/// backend decide quién puede qué (lanzar: el owner; revisar: quien vea la
/// sesión).
class FollowupApi {
  final String accountId;
  final String sessionId;

  const FollowupApi({required this.accountId, required this.sessionId});

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$backendUrl$path'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': accountId, 'sessionId': sessionId, ...body}),
          )
          .timeout(timeout ?? const Duration(seconds: 30));
    } on TimeoutException {
      throw const FollowupApiException('El servidor tardó demasiado. Intenta de nuevo.', code: 'timeout');
    } catch (_) {
      throw const FollowupApiException('Sin conexión con el servidor.', code: 'network');
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.body);
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }
    if (response.statusCode != 200) {
      throw FollowupApiException(
        (data['error'] as String?) ?? 'Algo falló (HTTP ${response.statusCode}).',
        code: data['code'] as String?,
      );
    }
    return data;
  }

  /// La IA lee la instrucción. Puede tardar: el modelo piensa.
  Future<PlanResult> planFromInstruction(String instruction) async => PlanResult.fromJson(
    await _post('/followup-campaigns/plan', {'instruction': instruction}, timeout: const Duration(seconds: 75)),
  );

  /// Revalida un plan editado y vuelve a contar los chats del periodo.
  Future<PlanResult> revalidate(CampaignPlan plan) async =>
      PlanResult.fromJson(await _post('/followup-campaigns/plan', {'plan': plan.toJson()}));

  Future<String> create({required String instruction, required CampaignPlan plan}) async {
    final data = await _post('/followup-campaigns', {'instruction': instruction, 'plan': plan.toJson()});
    return '${data['campaignId']}';
  }

  Future<int> cancel(String campaignId) async {
    final data = await _post('/followup-campaigns/cancel', {'campaignId': campaignId});
    return (data['cancelled'] as num?)?.toInt() ?? 0;
  }

  /// approve | reject | edit | unapprove
  Future<String> decide(String chatId, String action, {String? text}) async {
    final data = await _post('/followup-queue/decide', {
      'chatId': chatId,
      'action': action,
      if (text != null) 'text': text,
    });
    return '${data['status']}';
  }

  Future<({int approved, int skipped})> approveAll(String campaignId) async {
    final data = await _post('/followup-queue/approve-all', {
      'campaignId': campaignId,
    }, timeout: const Duration(seconds: 90));
    return (approved: (data['approved'] as num?)?.toInt() ?? 0, skipped: (data['skipped'] as num?)?.toInt() ?? 0);
  }

  Future<void> setPaused(bool paused) => _post('/followup-outbox/pause', {'paused': paused});
}
