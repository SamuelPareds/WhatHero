import 'package:crm_whatsapp/features/followups/followup_models.dart';
import 'package:crm_whatsapp/features/followups/followup_api.dart';
import 'package:crm_whatsapp/features/followups/followup_widgets.dart';
import 'package:crm_whatsapp/features/followups/followup_campaigns_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FollowupProposal proposal({
  String status = 'pending',
  String template = 'Hola Ana, {faltan_dias} de la promo.',
  String? deadline = '2026-11-15',
  String? lastDay = '2026-11-15',
  String? editedText,
  String? closedReason,
  String? error,
}) => FollowupProposal(
  chatId: '5215512345678',
  status: status,
  messageTemplate: template,
  reason: 'Preguntó por microblading',
  source: 'campaign',
  contactName: 'Ana López',
  deadline: deadline,
  lastDay: lastDay,
  editedText: editedText,
  closedReason: closedReason,
  error: error,
  evidenceText: '¿cuánto cuesta el microblading?',
);

void main() {
  group('FollowupProposal', () {
    test('la vista previa cuenta los días de hoy', () {
      expect(proposal().previewFor('2026-11-12'), 'Hola Ana, faltan 3 días de la promo.');
      expect(proposal().previewFor('2026-11-15'), 'Hola Ana, hoy es el último día de la promo.');
    });

    test('un texto editado se muestra tal cual', () {
      expect(proposal(editedText: 'Te esperamos').previewFor('2026-11-12'), 'Te esperamos');
    });

    test('pasado el último día vence', () {
      expect(proposal().isExpired('2026-11-16'), isTrue);
      expect(proposal().isExpired('2026-11-15'), isFalse);
      expect(proposal().previewFor('2026-11-16'), isNull);
    });

    test('cada estado cae en su pestaña', () {
      expect(proposal().tab, ReviewTab.toReview);
      expect(proposal(status: 'approved').tab, ReviewTab.scheduled);
      expect(proposal(status: 'failed').tab, ReviewTab.scheduled);
      expect(proposal(status: 'sent').tab, ReviewTab.sent);
      expect(proposal(status: 'in_doubt').tab, ReviewTab.sent);
      expect(proposal(status: 'stale').tab, ReviewTab.discarded);
      expect(proposal(status: 'rejected').tab, ReviewTab.discarded);
    });

    test('dice por qué no salió', () {
      expect(
        proposal(status: 'stale', closedReason: 'client_wrote').outcomeLabel,
        'El cliente escribió antes del envío',
      );
      expect(proposal(status: 'in_doubt').outcomeLabel, contains('revisa el chat'));
      expect(
        proposal(status: 'failed', error: 'WhatsApp no está conectado').outcomeLabel,
        contains('WhatsApp no está conectado'),
      );
    });

    test('lee un doc del barrido diario viejo (sin plantilla)', () {
      // Los docs anteriores a las campañas sólo traen draftMessage.
      final p = FollowupProposal(
        chatId: '1',
        status: 'pending',
        messageTemplate: '¿Seguimos?',
        reason: '',
        source: 'daily',
      );
      expect(p.previewFor('2026-11-12'), '¿Seguimos?');
    });
  });

  group('franja del goteo', () {
    final now = DateTime(2026, 11, 11, 10);

    test('pausado por fallos lo dice y pide revisar la conexión', () {
      const s = OutboxState(paused: true, pausedReason: 'failures', sentToday: 3);
      expect(outboxMessage(s, now: now), contains('3 fallaron seguidos'));
    });

    test('sin nada en fila no dice nada', () {
      const s = OutboxState(paused: false, waiting: 'hours', sentToday: 0);
      expect(outboxMessage(s, scheduledCount: 0, now: now), isNull);
    });

    test('fuera de horario, tope y desconexión', () {
      expect(
        outboxMessage(const OutboxState(paused: false, waiting: 'hours', sentToday: 0), scheduledCount: 4, now: now),
        contains('9:00 a 20:00'),
      );
      expect(
        outboxMessage(const OutboxState(paused: false, waiting: 'cap', sentToday: 80), scheduledCount: 4, now: now),
        contains('80'),
      );
      expect(
        outboxMessage(const OutboxState(paused: false, waiting: 'offline', sentToday: 0), scheduledCount: 4, now: now),
        contains('desconectado'),
      );
    });

    test('enviando: cuánto falta para el siguiente', () {
      final s = OutboxState(paused: false, sentToday: 5, nextAt: now.add(const Duration(seconds: 90)));
      expect(outboxMessage(s, scheduledCount: 4, now: now), contains('~2 min'));
    });
  });

  testWidgets('"Esto entendí" muestra fechas, conteo y la vista previa, y cabe en 360dp', (tester) async {
    await pumpPlan(tester, planResult());
    expect(tester.takeException(), isNull);
    expect(find.textContaining('4 nov – 11 nov · 214 conversaciones'), findsOneWidget);
    expect(find.text('Buscar clientes (214)'), findsOneWidget);
    expect(find.textContaining('Así lo verá Ana hoy'), findsOneWidget);
    expect(find.textContaining('reglas de Ajustes'), findsOneWidget);
  });

  testWidgets('sin fecha límite y con {faltan_dias}, no deja buscar', (tester) async {
    await pumpPlan(tester, planResult(missing: const ['deadline']));
    expect(find.textContaining('elige cuándo termina la promo'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Buscar clientes (214)'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('la tarjeta de una propuesta cabe en un teléfono de 360dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final status in ['pending', 'approved', 'failed', 'sent', 'stale'])
                  ProposalCard(
                    proposal: proposal(status: status, error: 'No está conectado', closedReason: 'client_wrote'),
                    api: const _NoApi(),
                    today: '2026-11-12',
                    onOpenChat: (_) {},
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Aprobar'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(find.text('No enviar'), findsOneWidget);
    expect(find.textContaining('cuánto cuesta el microblading'), findsNWidgets(5));
  });
}

PlanResult planResult({
  List<String> missing = const [],
  String message = 'Hola {nombre}, {faltan_dias} para el fin de esta promo, aparta tu cita hoy con \$200.',
}) => PlanResult(
  plan: CampaignPlan(
    period: const PeriodSpec.lastDays(7),
    audience: 'Preguntaron por el servicio de microblading',
    exclusions: 'Ya compraron o agendaron su cita',
    message: message,
    deadline: missing.contains('deadline') ? null : '2026-11-15',
    adapt: false,
  ),
  missing: missing,
  problems: const [],
  fromDate: '2026-11-04',
  toDate: '2026-11-11',
  clamped: false,
  candidates: 214,
  cap: 600,
  settingsExclusions: 'Conversaciones personales',
);

Future<void> pumpPlan(WidgetTester tester, PlanResult r) async {
  tester.view.physicalSize = const Size(360, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlanCard(
            api: const _NoApi(),
            instruction: 'De los últimos 7 días…',
            initial: r,
            onBack: () {},
            onCreated: (_) {},
          ),
        ),
      ),
    ),
  );
}

// La tarjeta no llama al backend hasta que se toca un botón.
class _NoApi extends FollowupApi {
  const _NoApi() : super(accountId: 'a', sessionId: 's');
}
