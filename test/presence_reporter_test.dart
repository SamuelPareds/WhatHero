import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/services/presence_reporter.dart';

/// Dos pantallas de chat, como en la app real: la raíz queda viva debajo
/// de AccountsScreen y encima se empuja otra.
final screenA = Object();
final screenB = Object();

void main() {
  late List<Map<String, dynamic>> sent;
  late List<String> events;
  late bool connected;
  late DateTime now;
  late PresenceReporter reporter;

  setUp(() {
    sent = [];
    events = [];
    connected = true;
    now = DateTime(2026, 9, 24, 10);
    reporter = PresenceReporter.test(
      emit: (event, data) {
        events.add(event);
        sent.add(data);
      },
      isConnected: () => connected,
      clock: () => now,
    );
  });

  // Los timers corren en el reloj falso de testWidgets; el reloj del reporter
  // avanza a la par.
  Future<void> advance(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
  }

  Map<String, dynamic>? last() => sent.isEmpty ? null : sent.last;

  void open(Object screen, String? chatId, {String session = '5215500000001', bool onScreen = true}) {
    reporter.report(screen, sessionPhone: session, chatId: chatId, onScreen: onScreen);
  }

  testWidgets('reporta el chat abierto con el estado completo', (tester) async {
    reporter.register(screenA);
    open(screenA, '5215511111111');
    await tester.pump();
    expect(events, ['team_presence_set']);
    expect(last(), {
      'clientId': reporter.clientId,
      'sessionPhone': '5215500000001',
      'chatId': '5215511111111',
      'composing': false,
    });
  });

  testWidgets('no repite lo que ya envió', (tester) async {
    reporter.register(screenA);
    open(screenA, '5215511111111');
    await tester.pump();
    open(screenA, '5215511111111');
    await tester.pump();
    expect(sent, hasLength(1));
  });

  group('varias pantallas vivas', () {
    testWidgets('la de abajo rebuildeando no le gana a la de arriba', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      reporter.register(screenB);
      open(screenB, '5215522222222', session: '5215500000002');
      await tester.pump();
      // A rebuildea (su stream de etiquetas) con el mismo chat de siempre.
      open(screenA, '5215533333333');
      await tester.pump();
      expect(last()!['chatId'], '5215522222222');
      expect(last()!['sessionPhone'], '5215500000002');
    });

    testWidgets('al salir la de arriba, vuelve a mandar la de abajo', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      reporter.register(screenB);
      open(screenB, '5215522222222');
      await tester.pump();
      reporter.unregister(screenB);
      await tester.pump();
      expect(last()!['chatId'], '5215511111111');
    });

    testWidgets('una tapada por una ruta opaca no cuenta', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      reporter.register(screenB);
      open(screenB, '5215522222222', onScreen: false);
      await tester.pump();
      expect(last()!['chatId'], '5215511111111');
    });

    testWidgets('sin ninguna en pantalla sale de la sesión', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      open(screenA, '5215511111111', onScreen: false);
      await tester.pump();
      expect(last()!['sessionPhone'], isNull);
      expect(last()!['chatId'], isNull);
    });
  });

  group('salir de un chat', () {
    testWidgets('a la lista espera la gracia', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      open(screenA, null);
      await tester.pump();
      expect(sent, hasLength(1));
      await advance(tester, PresenceReporter.leaveGrace);
      expect(last()!['chatId'], isNull);
      expect(last()!['sessionPhone'], '5215500000001');
    });

    testWidgets('a otro chat es inmediato', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      open(screenA, null);
      await tester.pump();
      open(screenA, '5215522222222');
      await tester.pump();
      expect(last()!['chatId'], '5215522222222');
      // La gracia pendiente se canceló: no manda un null tardío.
      await advance(tester, PresenceReporter.leaveGrace);
      expect(last()!['chatId'], '5215522222222');
    });

    testWidgets('ir a la lista y volver al mismo chat no parpadea', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      open(screenA, null);
      await tester.pump();
      open(screenA, '5215511111111');
      await advance(tester, PresenceReporter.leaveGrace);
      expect(sent, hasLength(1));
    });
  });

  group('respondiendo (composer con texto)', () {
    testWidgets('sólo cuenta en el chat abierto', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      reporter.setComposing('5215500000001', '5215511111111', true);
      await tester.pump();
      expect(last()!['composing'], isTrue);

      open(screenA, '5215522222222');
      await tester.pump();
      expect(last()!['composing'], isFalse);
    });

    testWidgets('el dispose tardío del composer viejo no apaga el nuevo', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215522222222');
      reporter.setComposing('5215500000001', '5215522222222', true);
      reporter.setComposing('5215500000001', '5215511111111', false);
      await tester.pump();
      expect(last()!['composing'], isTrue);
    });
  });

  group('conexión', () {
    testWidgets('caído no da nada por enviado; al conectar manda todo', (tester) async {
      connected = false;
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      expect(sent, isEmpty);

      connected = true;
      reporter.onConnected();
      await tester.pump();
      expect(last()!['chatId'], '5215511111111');
    });

    testWidgets('reconexión = socket nuevo: reenvía aunque nada cambió', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      reporter.onDisconnected();
      reporter.onConnected();
      await tester.pump();
      expect(sent, hasLength(2));
      expect(sent[1], sent[0]);
    });

    testWidgets('sin sesión y sin nada enviado, no molesta al backend', (tester) async {
      reporter.register(screenA);
      reporter.onConnected();
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('ausente', () {
    testWidgets('app oculta: sale del chat pasada la gracia', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      reporter.onLifecycleChanged(AppLifecycleState.inactive);
      reporter.onLifecycleChanged(AppLifecycleState.hidden);
      await advance(tester, PresenceReporter.hiddenGrace - const Duration(seconds: 1));
      expect(sent, hasLength(1));
      await advance(tester, const Duration(seconds: 1));
      await tester.pump();
      expect(last()!['chatId'], isNull);
      // Sigue en la sala de la sesión: ve la lista y a los demás.
      expect(last()!['sessionPhone'], '5215500000001');

      reporter.onLifecycleChanged(AppLifecycleState.inactive);
      reporter.onLifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(last()!['chatId'], '5215511111111');
      // resumed cuenta como actividad: dejamos vencer el idle para cerrar timers.
      await advance(tester, PresenceReporter.idleAfter);
    });

    testWidgets('volver antes de la gracia (selector de fotos) no se nota', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      reporter.onLifecycleChanged(AppLifecycleState.hidden);
      await advance(tester, const Duration(seconds: 5));
      reporter.onLifecycleChanged(AppLifecycleState.resumed);
      await advance(tester, PresenceReporter.hiddenGrace);
      expect(sent, hasLength(1));
      await advance(tester, PresenceReporter.idleAfter);
    });

    testWidgets('perder el foco de la ventana (inactive) no es ausencia', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      await tester.pump();
      reporter.onLifecycleChanged(AppLifecycleState.inactive);
      await advance(tester, PresenceReporter.hiddenGrace * 2);
      expect(sent, hasLength(1));
    });

    testWidgets('sin actividad deja de estar en el chat; al volver, regresa', (tester) async {
      reporter.register(screenA);
      open(screenA, '5215511111111');
      reporter.noteActivity();
      await tester.pump();

      // La actividad a mitad de camino re-arma el plazo desde ahí.
      await advance(tester, const Duration(minutes: 2));
      reporter.noteActivity();
      await advance(tester, const Duration(minutes: 2));
      expect(sent, hasLength(1));

      await advance(tester, const Duration(minutes: 1));
      expect(last()!['chatId'], isNull);

      reporter.noteActivity();
      await tester.pump();
      expect(last()!['chatId'], '5215511111111');
      await advance(tester, PresenceReporter.idleAfter);
      expect(last()!['chatId'], isNull);
    });
  });
}
