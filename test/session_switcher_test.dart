import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/accounts/session_switch.dart';
import 'package:crm_whatsapp/features/chat/widgets/session_switcher.dart';

// El selector de cuenta vive en el título de la lista de chats, donde el ancho
// es un recurso peleado: comparte fila con la bandeja del equipo, las campañas
// de seguimiento, el buscador y las respuestas rápidas. Es también la única
// entrada a Mis Cuentas desde la lista: ya no hay ícono a la izquierda.
void main() {
  const ac = SessionOption(id: '5215514252103', name: 'AC', phone: '5215514252103', status: 'connected');
  const sucursal = SessionOption(id: '5215561642726', name: 'Sucursal Norte', phone: '5215561642726', status: 'connected');
  const caida = SessionOption(id: '573001234567', name: 'Bogotá', phone: '573001234567', status: 'reconnect_failed');

  Future<({List<String> selected, List<String> managed})> pump(
    WidgetTester tester, {
    SessionOption current = ac,
    List<SessionOption> sessions = const [ac, sucursal, caida],
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final selected = <String>[];
    final managed = <String>[];
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          // AppBar realista: selector + las cuatro acciones que puede tener en
          // móvil (bandeja del equipo, campañas, buscador y respuestas
          // rápidas). Si el título engorda, revienta con overflow.
          appBar: AppBar(
            title: SessionSwitcher(
              current: current,
              sessions: sessions,
              onSelected: selected.add,
              onManage: () => managed.add('manage'),
              pendingBadge: (id) => Text('badge-$id'),
            ),
            actions: [
              IconButton(icon: const Icon(Icons.forum_outlined, size: 20), onPressed: () {}),
              IconButton(
                icon: const Badge(label: Text('23'), child: Icon(Icons.campaign_outlined, size: 20)),
                onPressed: () {},
              ),
              IconButton(icon: const Icon(Icons.search, size: 20), onPressed: () {}),
              IconButton(icon: const Icon(Icons.flash_on, size: 20), onPressed: () {}),
            ],
          ),
        ),
      ),
    ));
    return (selected: selected, managed: managed);
  }

  testWidgets('con una sola sesión el menú sigue ahí: es la salida a Mis Cuentas', (tester) async {
    final calls = await pump(tester, sessions: const [ac]);
    expect(find.text('AC'), findsOneWidget);
    expect(find.text('+52 55 1425 2103'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.text('AC'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('Gestionar cuentas'));
    await tester.pumpAndSettle();
    expect(calls.managed, ['manage']);
    expect(calls.selected, isEmpty);
  });

  testWidgets('con varias, el menú lista cada cuenta con su número y marca la actual', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.text('AC'));
    await tester.pumpAndSettle();

    expect(find.text('Sucursal Norte'), findsOneWidget);
    expect(find.text('+52 55 6164 2726'), findsOneWidget);
    expect(find.text('Bogotá'), findsOneWidget);
    expect(find.text('Gestionar cuentas'), findsOneWidget);
    // Los pendientes de cada cuenta, sólo con el menú abierto.
    expect(find.text('badge-5215561642726'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('elegir otra cuenta la pide; elegir la actual no hace nada', (tester) async {
    final calls = await pump(tester);

    await tester.tap(find.text('AC'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AC').last);
    await tester.pumpAndSettle();
    expect(calls.selected, isEmpty);

    await tester.tap(find.text('AC'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sucursal Norte'));
    await tester.pumpAndSettle();
    expect(calls.selected, ['5215561642726']);
  });

  testWidgets('"Gestionar cuentas" abre Mis Cuentas', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('AC'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gestionar cuentas'));
    await tester.pumpAndSettle();
    expect(calls.managed, ['manage']);
    expect(calls.selected, isEmpty);
  });

  testWidgets('una cuenta caída lo dice en el título en vez del número', (tester) async {
    await pump(tester, current: caida);
    expect(find.text('Bogotá'), findsOneWidget);
    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.text('+57 300 123 4567'), findsNothing);
  });

  testWidgets('cabe en un teléfono de 360dp con un alias largo', (tester) async {
    const largo = SessionOption(
      id: '5215514252103',
      name: 'Clínica Dental Sonrisas del Valle — Sucursal Centro',
      phone: '5215514252103',
      status: 'connected',
    );
    await pump(tester, current: largo, sessions: const [largo, sucursal, caida], size: const Size(360, 800));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    // El menú también: los alias largos se recortan.
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Gestionar cuentas'), findsOneWidget);
  });
}
