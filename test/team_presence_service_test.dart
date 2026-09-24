import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/services/team_presence_service.dart';
import 'package:crm_whatsapp/features/chat/reply_collision.dart';
import 'package:crm_whatsapp/features/chat/widgets/team_presence_banner.dart';

const session = '5215500000001';
const chat = '5215511111111';
const myClient = 'miclienteid00001';

Map<String, dynamic> viewer(
  String clientId,
  String uid,
  String name, {
  String chatId = chat,
  bool composing = false,
}) =>
    {'clientId': clientId, 'uid': uid, 'name': name, 'chatId': chatId, 'composing': composing};

TeamViewer tv(String uid, String name, {bool composing = false, String clientId = 'c'}) =>
    TeamViewer(clientId: '$clientId$uid', uid: uid, name: name, chatId: chat, composing: composing);

void main() {
  group('TeamPresenceService', () {
    late TeamPresenceService service;
    setUp(() => service = TeamPresenceService.test(myClientId: myClient));

    test('me excluye por clientId, no por uid (login compartido)', () {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [
          viewer(myClient, 'uid-me', 'Samuel'),
          viewer('otrapestana00001', 'uid-me', 'Samuel'),
          viewer('anacliente000001', 'uid-ana', 'Ana'),
        ],
      });
      final here = service.othersIn(session, chat);
      expect(here.map((v) => v.clientId), ['otrapestana00001', 'anacliente000001']);
    });

    test('quien responde va primero', () {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [
          viewer('anacliente000001', 'uid-ana', 'Ana'),
          viewer('luiscliente00001', 'uid-luis', 'Luis', composing: true),
        ],
      });
      expect(service.othersIn(session, chat).first.name, 'Luis');
    });

    test('cada payload reemplaza el estado completo de la sesión', () {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [viewer('anacliente000001', 'uid-ana', 'Ana')],
      });
      service.applyPayload({'sessionPhone': session, 'viewers': []});
      expect(service.othersIn(session, chat), isEmpty);
    });

    test('otra sesión u otro chat no se mezclan', () {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [viewer('anacliente000001', 'uid-ana', 'Ana', chatId: '5215599999999')],
      });
      expect(service.othersIn(session, chat), isEmpty);
      expect(service.othersIn('5215500000002', '5215599999999'), isEmpty);
      expect(service.othersIn(null, '5215599999999'), isEmpty);
    });

    test('una entrada rota no tira las demás', () {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [
          {'clientId': 'x', 'uid': 7},
          'basura',
          viewer('anacliente000001', 'uid-ana', 'Ana'),
        ],
      });
      expect(service.othersIn(session, chat), hasLength(1));
    });

    testWidgets('socket caído: se limpia si no reconecta a tiempo', (tester) async {
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [viewer('anacliente000001', 'uid-ana', 'Ana')],
      });
      service.markStale();
      await tester.pump(TeamPresenceService.staleAfter - const Duration(seconds: 1));
      expect(service.othersIn(session, chat), hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(service.othersIn(session, chat), isEmpty);
    });

    testWidgets('si reconecta a tiempo, el payload fresco cancela la limpieza', (tester) async {
      service.markStale();
      service.applyPayload({
        'sessionPhone': session,
        'viewers': [viewer('anacliente000001', 'uid-ana', 'Ana')],
      });
      await tester.pump(TeamPresenceService.staleAfter * 2);
      expect(service.othersIn(session, chat), hasLength(1));
    });
  });

  group('describeTeamPresence', () {
    test('nadie → nada', () {
      expect(describeTeamPresence(const [], myUid: 'uid-me'), isNull);
    });

    test('una persona con dos pestañas cuenta una vez', () {
      final p = describeTeamPresence(
        [tv('uid-ana', 'Ana'), tv('uid-ana', 'Ana', clientId: 'otra')],
        myUid: 'uid-me',
      );
      expect(p!.text, 'Ana también está en este chat');
    });

    test('respondiendo gana a estar', () {
      final p = describeTeamPresence(
        [tv('uid-ana', 'Ana'), tv('uid-luis', 'Luis', composing: true)],
        myUid: 'uid-me',
      );
      expect(p!.composing, isTrue);
      expect(p.text, 'Luis está respondiendo…');
    });

    test('varios', () {
      expect(
        describeTeamPresence([tv('a', 'Ana'), tv('b', 'Luis')], myUid: 'me')!.text,
        'Ana y Luis también están en este chat',
      );
      expect(
        describeTeamPresence(
          [tv('a', 'Ana'), tv('b', 'Luis'), tv('c', 'Eva'), tv('d', 'Leo')],
          myUid: 'me',
        )!.text,
        'Ana, Luis y 2 más también están en este chat',
      );
    });

    test('mi usuario en otro dispositivo se rotula como tal', () {
      final p = describeTeamPresence([tv('uid-me', 'Samuel', composing: true)], myUid: 'uid-me');
      expect(p!.text, 'Tu usuario en otro dispositivo está respondiendo…');
    });
  });

  group('TeamPresenceBanner', () {
    Future<void> pumpBanner(WidgetTester tester, Widget banner) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: banner)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('360 dp con nombres largos y varios compañeros: sin overflow', (tester) async {
      await pumpBanner(
        tester,
        TeamPresenceBanner(
          myUid: 'uid-me',
          viewers: [
            tv('a', 'Maximiliano Alejandro', composing: true),
            tv('b', 'Guadalupe Concepción', composing: true),
            tv('c', 'Bartolomé'),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('respondiendo'), findsOneWidget);
    });

    testWidgets('el choque gana a la presencia', (tester) async {
      await pumpBanner(
        tester,
        TeamPresenceBanner(
          myUid: 'uid-me',
          viewers: [tv('a', 'Luis', composing: true)],
          collision: const ReplyCollision(
            messageId: 'm1',
            source: ReplyCollisionSource.teammate,
            name: 'Ana',
            preview: 'Ya quedó tu pedido',
          ),
          onDismissCollision: () {},
        ),
      );
      expect(find.text('Ana acaba de responder · revisa antes de enviar'), findsOneWidget);
      expect(find.textContaining('Luis'), findsNothing);
    });

    testWidgets('sin nadie, no ocupa lugar', (tester) async {
      await pumpBanner(tester, const TeamPresenceBanner(myUid: 'uid-me', viewers: []));
      expect(tester.getSize(find.byType(TeamPresenceBanner)).height, 0);
    });
  });
}
