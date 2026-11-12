import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

import 'followup_api.dart';
import 'followup_message.dart';
import 'followup_models.dart';
import 'followup_review_screen.dart';
import 'followup_widgets.dart';

/// "Campañas de seguimiento": el owner escribe a quién quiere darle
/// seguimiento y qué mandarle, la IA lo convierte en un plan, el owner lo
/// confirma y el backend revisa las conversaciones del periodo. Lo que
/// encuentra queda por revisar; nada sale sin que alguien lo apruebe.
///
/// Un miembro del equipo entra aquí a revisar, no a lanzar. Ver CLAUDE.md,
/// "📣 Campañas de seguimiento".
class FollowupCampaignsScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String sessionName;
  final bool isOwner;
  final ValueChanged<String> onOpenChat;

  const FollowupCampaignsScreen({
    required this.accountId,
    required this.sessionId,
    required this.sessionName,
    required this.isOwner,
    required this.onOpenChat,
    super.key,
  });

  @override
  State<FollowupCampaignsScreen> createState() => _FollowupCampaignsScreenState();
}

class _FollowupCampaignsScreenState extends State<FollowupCampaignsScreen> {
  late final FollowupApi _api = FollowupApi(accountId: widget.accountId, sessionId: widget.sessionId);
  late final DocumentReference<Map<String, dynamic>> _sessionRef = FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId);
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _campaigns = _sessionRef
      .collection('followup_campaigns')
      .orderBy('createdAt', descending: true)
      .limit(15)
      .snapshots();
  // Las propuestas del barrido diario no tienen campaña: se revisan aparte.
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _daily = _sessionRef
      .collection('followup_queue')
      .where('source', isEqualTo: 'daily')
      .snapshots();

  final _instruction = TextEditingController();
  bool _planning = false;
  String? _planError;
  PlanResult? _plan;

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _readInstruction() async {
    final text = _instruction.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _planning = true;
      _planError = null;
    });
    try {
      final plan = await _api.planFromInstruction(text);
      if (!mounted) return;
      setState(() => _plan = plan);
    } on FollowupApiException catch (e) {
      if (mounted) setState(() => _planError = e.message);
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  void _openReview(String? campaignId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FollowupReviewScreen(
          accountId: widget.accountId,
          sessionId: widget.sessionId,
          campaignId: campaignId,
          isOwner: widget.isOwner,
          onOpenChat: widget.onOpenChat,
        ),
      ),
    );
  }

  void _onCreated(String campaignId) {
    setState(() {
      _plan = null;
      _instruction.clear();
    });
    _openReview(campaignId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Campañas de seguimiento', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            Text(
              widget.sessionName,
              style: TextStyle(fontSize: 12, color: lightText.withValues(alpha: 0.7)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              OutboxStrip(sessionRef: _sessionRef, api: _api),
              if (widget.isOwner) ...[
                if (_plan == null)
                  _InstructionCard(
                    controller: _instruction,
                    loading: _planning,
                    error: _planError,
                    onSubmit: _readInstruction,
                  )
                else
                  PlanCard(
                    key: ObjectKey(_plan),
                    api: _api,
                    instruction: _instruction.text.trim(),
                    initial: _plan!,
                    onBack: () => setState(() => _plan = null),
                    onCreated: _onCreated,
                  ),
                const SizedBox(height: 24),
              ],
              _sectionTitle('Campañas'),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _daily,
                builder: (context, snap) {
                  final today = todayString();
                  final pending = (snap.data?.docs ?? const [])
                      .map(FollowupProposal.fromDoc)
                      .where((p) => p.status == 'pending' && !p.isExpired(today))
                      .length;
                  if (pending == 0) return const SizedBox.shrink();
                  return _ListTileCard(
                    icon: Icons.wb_sunny_outlined,
                    title: 'Revisión diaria',
                    subtitle: 'Conversaciones que se enfriaron ayer',
                    trailing: CountPill(count: pending, color: primaryAqua),
                    onTap: () => _openReview(null),
                  );
                },
              ),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _campaigns,
                builder: (context, snap) {
                  if (snap.hasError) {
                    debugPrint('[Seguimiento] No se pudieron leer las campañas: ${snap.error}');
                    return const _Hint('No se pudieron cargar las campañas.');
                  }
                  if (!snap.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final campaigns = snap.data!.docs.map(FollowupCampaign.fromDoc).toList();
                  if (campaigns.isEmpty) {
                    return _Hint(
                      widget.isOwner
                          ? 'Todavía no hay campañas. Escribe arriba a quién quieres darle seguimiento.'
                          : 'Todavía no hay campañas en esta cuenta.',
                    );
                  }
                  return Column(
                    children: [
                      for (final c in campaigns)
                        _ListTileCard(
                          icon: c.isAnalyzing ? Icons.manage_search : Icons.campaign_outlined,
                          title: c.audience.isNotEmpty ? c.audience : c.instruction,
                          subtitle: campaignSubtitle(c),
                          progress: c.isAnalyzing && c.total > 0 ? c.analyzed / c.total : null,
                          trailing: CampaignStatusChip(campaign: c),
                          onTap: () => _openReview(c.id),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: lightText.withValues(alpha: 0.6),
        fontSize: 12,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

String campaignSubtitle(FollowupCampaign c) {
  final period = periodLabel(c.fromDate, c.toDate);
  switch (c.status) {
    case 'analyzing':
      return 'Revisando ${c.analyzed} de ${c.total} · ${c.matched} encontrados';
    case 'failed':
      return c.error ?? 'Se interrumpió';
    case 'cancelled':
      return '$period · cancelada';
    default:
      return '$period · ${c.matched} encontrados de ${c.analyzed} revisados';
  }
}

/// "4 nov – 11 nov".
String periodLabel(String from, String to) {
  String short(String d) {
    final full = formatDayMonth(d); // "4 de noviembre"
    final parts = full.split(' de ');
    return parts.length == 2 ? '${parts[0]} ${parts[1].substring(0, 3)}' : full;
  }

  if (from.isEmpty || to.isEmpty) return '';
  return from == to ? short(from) : '${short(from)} – ${short(to)}';
}

class _InstructionCard extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final String? error;
  final VoidCallback onSubmit;

  const _InstructionCard({required this.controller, required this.loading, required this.onSubmit, this.error});

  static const _examples = [
    'De los últimos 7 días, a los que preguntaron por microblading y no agendaron, mándales: "Faltan x días para el fin de la promo, aparta tu cita hoy con \$200"',
    'Del mes pasado, a quienes pidieron precio de nuestro platillo principal y no ordenaron: "¡Hola {nombre}! Esta semana tenemos 2x1, ¿te aparto?"',
    'De los últimos 30 días, a los que preguntaron por disponibilidad y no respondieron después: "¿Sigues buscando fecha? Nos quedan pocos lugares este mes"',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, color: primaryAqua, size: 18),
              SizedBox(width: 8),
              Text(
                '¿A quién quieres darle seguimiento?',
                style: TextStyle(color: white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Dime el periodo, a quién buscar y qué mensaje mandar. Antes de buscar te muestro lo que entendí, y nada se envía sin tu aprobación.',
            style: TextStyle(color: lightText.withValues(alpha: 0.75), fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            maxLength: 2000,
            enabled: !loading,
            style: const TextStyle(color: white, fontSize: 14),
            decoration: inputDecoration(
              hint: 'Ej. De los últimos 7 días, a los que preguntaron por microblading y no compraron, mándales…',
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _examples)
                ActionChip(
                  label: Text(e.split(',').first, overflow: TextOverflow.ellipsis),
                  labelStyle: const TextStyle(color: lightText, fontSize: 12),
                  backgroundColor: darkBg,
                  side: BorderSide(color: white.withValues(alpha: 0.1)),
                  onPressed: loading ? null : () => controller.text = e,
                ),
            ],
          ),
          if (error != null) ...[const SizedBox(height: 12), ErrorLine(error!)],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => FilledButton.icon(
                onPressed: loading || controller.text.trim().isEmpty ? null : onSubmit,
                style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
                icon: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: darkBg),
                      )
                    : const Icon(Icons.arrow_forward, size: 18),
                label: Text(loading ? 'Leyendo…' : 'Continuar'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Esto entendí": el plan, editable campo por campo, con las fechas exactas
/// y cuántas conversaciones se van a revisar. Todavía no se envía nada.
class PlanCard extends StatefulWidget {
  final FollowupApi api;
  final String instruction;
  final PlanResult initial;
  final VoidCallback onBack;
  final ValueChanged<String> onCreated;

  const PlanCard({
    required this.api,
    required this.instruction,
    required this.initial,
    required this.onBack,
    required this.onCreated,
    super.key,
  });

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  late PlanResult _result = widget.initial;
  late final _audience = TextEditingController(text: widget.initial.plan.audience);
  late final _exclusions = TextEditingController(text: widget.initial.plan.exclusions);
  late final _message = TextEditingController(text: widget.initial.plan.message);
  late PeriodSpec _period = widget.initial.plan.period;
  late String? _deadline = widget.initial.plan.deadline;
  late bool _adapt = widget.initial.plan.adapt;
  bool _recounting = false;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _audience.dispose();
    _exclusions.dispose();
    _message.dispose();
    super.dispose();
  }

  CampaignPlan get _plan => CampaignPlan(
    period: _period,
    audience: _audience.text.trim(),
    exclusions: _exclusions.text.trim(),
    message: _message.text.trim(),
    deadline: _deadline,
    adapt: _adapt,
  );

  // Cambió el periodo o la fecha límite: el backend recalcula las fechas en
  // la zona de la sesión y vuelve a contar.
  Future<void> _revalidate() async {
    setState(() {
      _recounting = true;
      _error = null;
    });
    try {
      final r = await widget.api.revalidate(_plan);
      if (mounted) setState(() => _result = r);
    } on FollowupApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _recounting = false);
    }
  }

  void _setPeriod(PeriodSpec p) {
    setState(() => _period = p);
    _revalidate();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 90)),
      lastDate: now,
      helpText: 'Conversaciones entre',
      cancelText: 'Cancelar',
      confirmText: 'Listo',
      saveText: 'Listo',
    );
    if (picked != null) _setPeriod(PeriodSpec.range(dayString(picked.start), dayString(picked.end)));
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: parseDay(_deadline) ?? now.add(const Duration(days: 3)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 120)),
      helpText: '¿Cuándo termina la promo?',
      cancelText: 'Cancelar',
      confirmText: 'Listo',
    );
    if (picked != null) {
      setState(() => _deadline = dayString(picked));
      _revalidate();
    }
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final id = await widget.api.create(instruction: widget.instruction, plan: _plan);
      if (mounted) widget.onCreated(id);
    } on FollowupApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  // Lo que falta, en el estado ACTUAL de los campos (el owner pudo haberlo
  // completado ya). Los problemas del mensaje los vuelve a revisar el backend.
  List<String> _missingNow() {
    final out = <String>[];
    if (_result.missing.contains('period') && _period == widget.initial.plan.period) {
      out.add('Elige qué conversaciones revisar.');
    }
    if (_audience.text.trim().isEmpty) out.add('Falta a quién buscar.');
    if (_message.text.trim().isEmpty) out.add('Falta el mensaje que quieres mandar.');
    if (usesDateVariables(_message.text) && _deadline == null) {
      out.add('El mensaje cuenta los días que faltan: elige cuándo termina la promo.');
    }
    final unknown = RegExp(r'\{([^{}\n]{0,40})\}')
        .allMatches(_message.text)
        .map((m) => m[1]!.trim())
        .where((v) => !const ['nombre', 'faltan_dias', 'fecha_limite'].contains(v))
        .toSet();
    if (unknown.isNotEmpty) {
      out.add('No conozco ${unknown.map((u) => '{$u}').join(', ')}: saldría tal cual al cliente.');
    }
    return out;
  }

  String? _previewText() {
    final text = _message.text.trim().replaceAll('{nombre}', 'Ana');
    if (text.isEmpty) return null;
    return renderDateVariables(text, _deadline, todayString());
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final presets = <(String, PeriodSpec)>[
      ('7 días', const PeriodSpec.lastDays(7)),
      ('15 días', const PeriodSpec.lastDays(15)),
      ('30 días', const PeriodSpec.lastDays(30)),
      ('Mes pasado', const PeriodSpec.lastMonth()),
    ];
    bool isSelected(PeriodSpec p) =>
        p.kind == _period.kind && p.days == _period.days && p.from == _period.from && p.to == _period.to;
    final customSelected = !presets.any((e) => isSelected(e.$2));

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(accent: primaryAqua),
      child: ListenableBuilder(
        listenable: Listenable.merge([_audience, _exclusions, _message]),
        builder: (context, _) {
          final missing = _missingNow();
          final preview = _previewText();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.fact_check_outlined, color: primaryAqua, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Esto entendí',
                      style: TextStyle(color: white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(onPressed: _creating ? null : widget.onBack, child: const Text('Cambiar instrucción')),
                ],
              ),
              Text(
                'Revisa y corrige lo que haga falta. Todavía no se envía nada.',
                style: TextStyle(color: lightText.withValues(alpha: 0.75), fontSize: 13),
              ),
              const SizedBox(height: 16),

              const FieldLabel('Conversaciones a revisar'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (label, spec) in presets)
                    ChoiceChip(
                      label: Text(label),
                      selected: isSelected(spec),
                      onSelected: _recounting ? null : (_) => _setPeriod(spec),
                    ),
                  ChoiceChip(
                    label: Text(
                      customSelected && _period.kind == 'range'
                          ? periodLabel(_period.from!, _period.to!)
                          : 'Otras fechas…',
                    ),
                    selected: customSelected,
                    onSelected: _recounting ? null : (_) => _pickRange(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_recounting)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  Expanded(
                    child: Text(
                      r.missing.contains('period')
                          ? 'No dijiste el periodo: elige uno.'
                          : '${periodLabel(r.fromDate, r.toDate)} · ${r.candidates} ${r.candidates == 1 ? 'conversación' : 'conversaciones'} con mensajes'
                                '${r.candidates > r.cap ? ' (se revisan las ${r.cap} más recientes)' : ''}',
                      style: TextStyle(color: lightText.withValues(alpha: 0.85), fontSize: 13),
                    ),
                  ),
                ],
              ),
              if (r.clamped)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Se revisan como máximo los últimos 90 días.',
                    style: TextStyle(color: collisionAmber, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 16),

              const FieldLabel('A quién sí'),
              TextField(
                controller: _audience,
                maxLines: 2,
                minLines: 1,
                style: const TextStyle(color: white, fontSize: 14),
                decoration: inputDecoration(hint: 'Ej. Preguntaron por el servicio de microblading'),
              ),
              const SizedBox(height: 12),
              const FieldLabel('A quién no'),
              TextField(
                controller: _exclusions,
                maxLines: 3,
                minLines: 1,
                style: const TextStyle(color: white, fontSize: 14),
                decoration: inputDecoration(hint: 'Ej. Ya compraron o agendaron su cita'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  r.settingsExclusions.isNotEmpty
                      ? 'Además se aplican tus reglas de Ajustes › Seguimiento, y nunca entra quien ya compró, pidió no recibir mensajes, espera tu respuesta o recibió un seguimiento esta semana.'
                      : 'Nunca entra quien ya compró, pidió no recibir mensajes, espera tu respuesta o recibió un seguimiento esta semana.',
                  style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 12, height: 1.3),
                ),
              ),
              const SizedBox(height: 16),

              const FieldLabel('Mensaje'),
              TextField(
                controller: _message,
                maxLines: 6,
                minLines: 2,
                maxLength: 1000,
                style: const TextStyle(color: white, fontSize: 14),
                decoration: inputDecoration(hint: 'El texto que recibirá cada cliente'),
              ),
              Text(
                '{nombre} pone el nombre del cliente. {faltan_dias} escribe "Faltan 3 días", "Falta 1 día" u "Hoy es el último día" el día que sale.',
                style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.event_outlined, size: 18, color: lightText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _deadline == null ? 'La promo no tiene fecha límite' : 'Termina el ${formatDayMonth(_deadline!)}',
                      style: const TextStyle(color: white, fontSize: 14),
                    ),
                  ),
                  if (_deadline != null)
                    IconButton(
                      tooltip: 'Quitar fecha límite',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        setState(() => _deadline = null);
                        _revalidate();
                      },
                    ),
                  TextButton(onPressed: _pickDeadline, child: Text(_deadline == null ? 'Elegir fecha' : 'Cambiar')),
                ],
              ),
              if (preview != null) ...[
                const SizedBox(height: 8),
                MessagePreview(label: 'Así lo verá Ana hoy', text: preview),
              ],
              const SizedBox(height: 8),
              // Material transparente: el ListTile pinta su ripple en el
              // Material más cercano, y el de la tarjeta queda tapado por su color.
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _adapt,
                  onChanged: (v) => setState(() => _adapt = v),
                  activeThumbColor: primaryAqua,
                  title: const Text(
                    'Adaptar el saludo a cada conversación',
                    style: TextStyle(color: white, fontSize: 14),
                  ),
                  subtitle: Text(
                    'La IA agrega una frase sobre lo que preguntó cada cliente. La oferta, los precios y las fechas no se tocan. Revisa cada uno antes de aprobar.',
                    style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 12),
                  ),
                ),
              ),

              for (final m in [...missing, ...r.problems.where((p) => !missing.contains(p))]) ...[
                const SizedBox(height: 6),
                ErrorLine(m),
              ],
              if (_error != null) ...[const SizedBox(height: 6), ErrorLine(_error!)],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed:
                      _creating ||
                          _recounting ||
                          missing.isNotEmpty ||
                          r.missing.contains('period') ||
                          r.candidates == 0
                      ? null
                      : _create,
                  style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
                  icon: _creating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: darkBg),
                        )
                      : const Icon(Icons.manage_search, size: 18),
                  label: Text(
                    _creating
                        ? 'Creando…'
                        : r.candidates == 0
                        ? 'Sin conversaciones en ese periodo'
                        : 'Buscar clientes (${r.candidates > r.cap ? r.cap : r.candidates})',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ListTileCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final double? progress;
  final VoidCallback onTap;

  const _ListTileCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: surfaceDark,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(icon, color: primaryAqua, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: white, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(subtitle, style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12)),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: progress, minHeight: 3, color: primaryAqua, backgroundColor: darkBg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;

  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 13),
    ),
  );
}
