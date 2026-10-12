import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/jump_to_message.dart';

// El salto calculaba la posición del destino como índice / total × el
// maxScrollExtent estimado. En un chat con fotos entre textos caía pantallas
// lejos, el destino no se construía y el operador aterrizaba en otra parte sin
// aviso. Estas pruebas usan alturas mezcladas, con la parte vieja más alta,
// que es justo donde la estimación se equivoca.
void main() {
  const total = 600;
  // Lo reciente es texto corto; lo viejo, fotos y párrafos largos.
  double heightOf(int i) => i < 100 ? 48 + (i % 3) * 16 : 120 + (i * 37) % 300;

  late ScrollController controller;
  late BuiltIndexTracker built;
  late GlobalKey anchor;
  late int? target;

  Widget list() => MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, _) => ListView.builder(
              controller: controller,
              reverse: true,
              itemCount: total,
              itemBuilder: (context, i) => IndexProbe(
                index: i,
                tracker: built,
                child: JumpTarget(
                  highlighted: false,
                  anchorKey: i == target ? anchor : null,
                  child: SizedBox(height: heightOf(i), child: Text('m$i')),
                ),
              ),
            ),
          ),
        ),
      );

  setUp(() {
    controller = ScrollController();
    built = BuiltIndexTracker();
    anchor = GlobalKey();
    target = null;
  });

  Future<bool> reveal(WidgetTester tester, int index,
      {bool Function()? stillWanted, int? Function()? indexOf}) async {
    target = index;
    // Re-build para que el ancla quede en el ítem destino.
    await tester.pumpWidget(list());
    final future = revealListItem(
      controller: controller,
      anchor: anchor,
      built: built,
      indexOf: indexOf ?? () => index,
      stillWanted: stillWanted ?? () => true,
    );
    await tester.pumpAndSettle();
    return future;
  }

  bool onScreen(WidgetTester tester, int index) {
    final viewport = tester.getRect(find.byType(ListView));
    final item = tester.getRect(find.text('m$index'));
    return viewport.overlaps(item);
  }

  testWidgets('llega a un mensaje viejo y lejano desde el fondo', (tester) async {
    await tester.pumpWidget(list());
    expect(await reveal(tester, 550), isTrue);
    expect(onScreen(tester, 550), isTrue);
  });

  testWidgets('llega a un mensaje de abajo estando arriba', (tester) async {
    await tester.pumpWidget(list());
    expect(await reveal(tester, 500), isTrue);
    expect(await reveal(tester, 12), isTrue);
    expect(onScreen(tester, 12), isTrue);
  });

  testWidgets('con el destino ya en pantalla no salta, sólo lo centra', (tester) async {
    await tester.pumpWidget(list());
    final before = controller.offset;
    expect(await reveal(tester, 2), isTrue);
    expect(onScreen(tester, 2), isTrue);
    // ensureVisible lo acomoda, pero no recorre la lista.
    expect((controller.offset - before).abs(), lessThan(400));
  });

  testWidgets('un salto reemplazado deja de moverse', (tester) async {
    await tester.pumpWidget(list());
    var steps = 0;
    final arrived = await reveal(tester, 590, stillWanted: () => ++steps < 3);
    expect(arrived, isFalse);
    expect(find.text('m590'), findsNothing);
  });

  testWidgets('un destino que ya no está en la lista no se busca', (tester) async {
    await tester.pumpWidget(list());
    expect(await reveal(tester, 400, indexOf: () => null), isFalse);
  });

  testWidgets('el tracker sólo cuenta lo construido', (tester) async {
    await tester.pumpWidget(list());
    final range = built.range!;
    expect(range.lo, 0);
    // El viewport de prueba (600px) más la cache no llega a 100 textos.
    expect(range.hi, lessThan(40));
    controller.jumpTo(20000);
    await tester.pump();
    expect(built.range!.lo, greaterThan(40));
  });

  testWidgets('el resalte y el ancla no recrean la burbuja', (tester) async {
    var inits = 0;
    Widget target({required bool on}) => MaterialApp(
          home: JumpTarget(
            highlighted: on,
            anchorKey: on ? anchor : null,
            child: _CountsInits(onInit: () => inits++),
          ),
        );
    await tester.pumpWidget(target(on: false));
    await tester.pumpWidget(target(on: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(target(on: false));
    await tester.pumpAndSettle();
    expect(inits, 1);
  });
}

class _CountsInits extends StatefulWidget {
  final VoidCallback onInit;
  const _CountsInits({required this.onInit});

  @override
  State<_CountsInits> createState() => _CountsInitsState();
}

class _CountsInitsState extends State<_CountsInits> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 80);
}
