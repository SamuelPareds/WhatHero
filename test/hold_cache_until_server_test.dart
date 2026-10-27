import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/hold_cache_until_server.dart';

/// Un snapshot de mentira: sólo importa si viene del caché.
typedef Snap = ({bool fromCache, String id});

Snap cache(String id) => (fromCache: true, id: id);
Snap server(String id) => (fromCache: false, id: id);

void main() {
  late StreamController<Snap> source;
  late StreamSubscription<Snap> sub;
  late List<String> shown;

  // Dentro de testWidgets los timers corren en tiempo falso: tester.pump
  // avanza el reloj y entrega los eventos pendientes.
  void listen() {
    source = StreamController<Snap>();
    shown = [];
    sub = holdCacheUntilServer<Snap>(
      source.stream,
      isFromCache: (s) => s.fromCache,
    ).listen((s) => shown.add(s.id));
  }

  // Sin await: dentro de testWidgets, esperar el cancel cuelga el test (su
  // aviso queda en la cola del tiempo falso). tester.pump la vacía.
  Future<void> stop(WidgetTester tester) async {
    sub.cancel();
    await tester.pump();
  }

  testWidgets('caché parcial y luego servidor: sólo se pinta el servidor',
      (tester) async {
    listen();
    source.add(cache('solo-pendientes'));
    await tester.pump();
    expect(shown, isEmpty);

    source.add(server('bandeja-completa'));
    await tester.pump();
    expect(shown, ['bandeja-completa']);

    // El margen ya no suelta lo retenido: quedó viejo.
    await tester.pump(const Duration(seconds: 3));
    expect(shown, ['bandeja-completa']);
    await stop(tester);
  });

  testWidgets('servidor primero: pasa al instante', (tester) async {
    listen();
    source.add(server('a'));
    await tester.pump();
    expect(shown, ['a']);

    await tester.pump(const Duration(seconds: 3));
    expect(shown, ['a']);
    await stop(tester);
  });

  testWidgets('sin servidor (offline): a los 2 s se pinta lo guardado',
      (tester) async {
    listen();
    source.add(cache('viejo'));
    await tester.pump(const Duration(milliseconds: 1900));
    expect(shown, isEmpty);

    await tester.pump(const Duration(milliseconds: 100));
    expect(shown, ['viejo']);
    await stop(tester);
  });

  testWidgets('se suelta sólo el último snapshot retenido', (tester) async {
    listen();
    source.add(cache('uno'));
    source.add(cache('dos'));
    await tester.pump(const Duration(seconds: 2));
    expect(shown, ['dos']);
    await stop(tester);
  });

  testWidgets('vencido el margen sin nada, el caché pasa al llegar',
      (tester) async {
    listen();
    await tester.pump(const Duration(seconds: 3));
    expect(shown, isEmpty);

    source.add(cache('tarde'));
    await tester.pump();
    expect(shown, ['tarde']);
    await stop(tester);
  });

  testWidgets('tras el servidor, una caída de red (fromCache) sí pasa',
      (tester) async {
    listen();
    source.add(server('a'));
    source.add(cache('a-sin-red'));
    await tester.pump();
    expect(shown, ['a', 'a-sin-red']);
    await stop(tester);
  });

  testWidgets('servidor lento: se pinta lo guardado y después se actualiza',
      (tester) async {
    listen();
    source.add(cache('guardado'));
    await tester.pump(const Duration(seconds: 2));
    source.add(server('real'));
    await tester.pump();
    expect(shown, ['guardado', 'real']);
    await stop(tester);
  });

  testWidgets('cancelar suelta la fuente y el timer', (tester) async {
    listen();
    source.add(cache('x'));
    await stop(tester);
    expect(source.hasListener, isFalse);

    // testWidgets falla si queda un timer pendiente; además no emite nada.
    await tester.pump(const Duration(seconds: 3));
    expect(shown, isEmpty);
  });

  testWidgets('los errores de la fuente se propagan', (tester) async {
    source = StreamController<Snap>();
    final errors = <Object>[];
    sub = holdCacheUntilServer<Snap>(
      source.stream,
      isFromCache: (s) => s.fromCache,
    ).listen((_) {}, onError: errors.add);
    source.addError(StateError('permission-denied'));
    await tester.pump();
    expect(errors, hasLength(1));
    await stop(tester);
  });
}
