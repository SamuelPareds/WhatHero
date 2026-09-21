import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/widgets/chat_nav_stepper.dart';

// El stepper vive en `AppBar.actions`, donde el ancho es un recurso peleado:
// comparte fila con el toggle de IA, el botón de info y el nombre del contacto.
// Estas pruebas fijan lo que no se puede romper sin darse cuenta — que quepa en
// un teléfono chico y que las flechas de los extremos estén muertas.
void main() {
  // AppBar realista: back + título largo + stepper + los dos IconButton que ya
  // vivían ahí. Si el stepper engorda, esto revienta con un RenderFlex overflow.
  Widget appBarWith(Widget stepper, {required Size size}) {
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('María Fernanda Rodríguez',
                overflow: TextOverflow.ellipsis, maxLines: 1),
            actions: [
              stepper,
              IconButton(
                  icon: const Icon(Icons.face_retouching_natural, size: 20),
                  onPressed: () {}),
              IconButton(
                  icon: const Icon(Icons.info_outline, size: 20),
                  onPressed: () {}),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('cabe en un teléfono de 360dp junto al resto del AppBar',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(appBarWith(
      ChatNavStepper(
        position: 4,
        total: 12,
        onPrev: () {},
        onNext: () {},
      ),
      size: const Size(360, 800),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('4/12'), findsOneWidget);
  });

  testWidgets('el contador de tres dígitos tampoco desborda', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(appBarWith(
      ChatNavStepper(
        position: 128,
        total: 340,
        onPrev: () {},
        onNext: () {},
      ),
      size: const Size(360, 800),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('128/340'), findsOneWidget);
  });

  testWidgets('las flechas de los extremos no disparan nada', (tester) async {
    var prev = 0;
    var next = 0;

    // Primera posición: sólo se puede bajar (hacia lo más antiguo).
    await tester.pumpWidget(appBarWith(
      ChatNavStepper(
        position: 1,
        total: 3,
        onPrev: null,
        onNext: () => next++,
      ),
      size: const Size(800, 600),
    ));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();

    expect(prev, 0, reason: 'arriba está deshabilitado en la posición 1');
    expect(next, 1);

    // Última posición: sólo se puede subir (hacia lo más reciente).
    await tester.pumpWidget(appBarWith(
      ChatNavStepper(
        position: 3,
        total: 3,
        onPrev: () => prev++,
        onNext: null,
      ),
      size: const Size(800, 600),
    ));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pump();

    expect(prev, 1);
    expect(next, 1, reason: 'abajo está deshabilitado en la última posición');
  });

  // El foco casi nunca está en el composer: MessagesView no lo enfoca al
  // abrir, y tocar la conversación hace un `unfocus()` para bajar el teclado.
  // Estos escenarios fueron, cada uno en su momento, el atajo sordo.
  Future<List<int>> pressArrows(
    WidgetTester tester,
    LogicalKeyboardKey modifier, {
    required Future<void> Function(WidgetTester) setUpFocus,
    String initialText = '',
  }) async {
    final steps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatNavShortcuts(
          onStep: steps.add,
          child: TextField(
            controller: TextEditingController(text: initialText),
          ),
        ),
      ),
    ));
    await tester.pump();
    await setUpFocus(tester);

    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
    return steps;
  }

  testWidgets('funciona recién abierto el chat, sin foco en el composer',
      (tester) async {
    final steps = await pressArrows(
      tester,
      LogicalKeyboardKey.altLeft,
      setUpFocus: (_) async {},
    );
    expect(steps, [1, -1]);
  });

  testWidgets('funciona con el foco puesto en el composer', (tester) async {
    final steps = await pressArrows(
      tester,
      LogicalKeyboardKey.altLeft,
      setUpFocus: (t) async {
        await t.tap(find.byType(TextField));
        await t.pump();
      },
    );
    expect(steps, [1, -1]);
  });

  testWidgets('sobrevive al unfocus de tocar la conversación', (tester) async {
    final steps = await pressArrows(
      tester,
      LogicalKeyboardKey.altLeft,
      setUpFocus: (t) async {
        await t.tap(find.byType(TextField));
        await t.pump();
        // Lo mismo que hace el GestureDetector del ListView de mensajes.
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump();
      },
    );
    expect(steps, [1, -1]);
  });

  testWidgets('⌘ también sirve: confundirla con ⌥ no cuesta el atajo',
      (tester) async {
    final steps = await pressArrows(
      tester,
      LogicalKeyboardKey.metaLeft,
      setUpFocus: (t) async {
        await t.tap(find.byType(TextField));
        await t.pump();
      },
    );
    expect(steps, [1, -1]);
  });

  testWidgets('sin modificador las flechas no son nuestras', (tester) async {
    final steps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatNavShortcuts(onStep: steps.add, child: const TextField()),
      ),
    ));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    // Son del selector de respuestas rápidas y del cursor del TextField.
    expect(steps, isEmpty);
  });

  // Escribiendo, las flechas son del texto: navegar ahí tiraba el borrador,
  // que muere con el chat. Estas pruebas fijan la frontera de esa regla.
  group('con texto escrito en el composer', () {
    Future<void> focusInput(WidgetTester t) async {
      await t.tap(find.byType(TextField));
      await t.pump();
    }

    for (final modifier in [
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      testWidgets('${modifier.keyLabel}+flechas no cambian de chat',
          (tester) async {
        final steps = await pressArrows(
          tester,
          modifier,
          initialText: 'Hola, te escribo por lo del pedido',
          setUpFocus: focusInput,
        );
        expect(steps, isEmpty);
      });
    }

    // El reporte original: seleccionar hasta arriba para borrar un párrafo y
    // aterrizar en otra conversación con el mensaje perdido.
    testWidgets('⌘⇧↑ selecciona hasta el inicio en vez de navegar',
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
        (tester) async {
      final steps = <int>[];
      final controller = TextEditingController(
          text: 'Primer párrafo\nSegundo párrafo\nTercero');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatNavShortcuts(
            onStep: steps.add,
            child: TextField(controller: controller, maxLines: 6),
          ),
        ),
      ));
      await focusInput(tester);
      // Cursor en medio del segundo párrafo.
      controller.selection = const TextSelection.collapsed(offset: 20);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(steps, isEmpty);
      expect(controller.selection.start, 0);
      expect(controller.selection.end, 20);
    });

    // La regla mira el foco, no sólo si hay texto: tocar la conversación hace
    // `unfocus()` y ahí las flechas ya no tienen nada que editar.
    testWidgets('sin foco en el input vuelven a navegar', (tester) async {
      final steps = await pressArrows(
        tester,
        LogicalKeyboardKey.altLeft,
        initialText: 'Hola, te escribo por lo del pedido',
        setUpFocus: (t) async {
          await focusInput(t);
          FocusManager.instance.primaryFocus?.unfocus();
          await t.pump();
        },
      );
      expect(steps, [1, -1]);
    });
  });

  // El atajo escucha a HardwareKeyboard, no al árbol de foco. Estas pruebas
  // fijan que ningún destino del foco lo deje sordo, y que igual se apague
  // cuando algo tapa el detalle.
  group('el foco no manda', () {
    // Detalle mínimo: la conversación (con el mismo tap que MessagesView) y
    // el composer debajo.
    Future<(List<int>, TextEditingController)> mountDetail(
      WidgetTester tester, {
      bool enabled = true,
    }) async {
      final steps = <int>[];
      final controller = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatNavShortcuts(
            onStep: steps.add,
            enabled: enabled,
            child: Column(children: [
              Expanded(
                child: GestureDetector(
                  key: const Key('conversacion'),
                  behavior: HitTestBehavior.translucent,
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  child: const SizedBox.expand(),
                ),
              ),
              TextField(controller: controller),
            ]),
          ),
        ),
      ));
      await tester.pump();
      return (steps, controller);
    }

    Future<void> altDown(WidgetTester t) async {
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.pump();
    }

    // El reporte: escribir, arrepentirse, borrarlo todo y querer seguir.
    testWidgets('escribir y borrar todo devuelve el atajo', (tester) async {
      final (steps, _) = await mountDetail(tester);
      await tester.enterText(find.byType(TextField), 'mejor no');
      await altDown(tester);
      expect(steps, isEmpty, reason: 'con texto, la flecha es del editor');

      await tester.enterText(find.byType(TextField), '');
      await altDown(tester);
      expect(steps, [1]);
    });

    // `unfocus()` sobre un scope manda el foco al scope PADRE. Con el atajo
    // colgado del foco, un solo tap en la conversación lo dejaba sordo.
    testWidgets('tocar la conversación, una y otra vez, no lo apaga',
        (tester) async {
      final (steps, _) = await mountDetail(tester);
      await tester.tap(find.byKey(const Key('conversacion')));
      await tester.pump();
      await altDown(tester);
      await tester.tap(find.byKey(const Key('conversacion')));
      await tester.pump();
      await altDown(tester);
      expect(steps, [1, 1]);
    });

    // Lo que hace la web cuando el DOM pierde el foco (por ejemplo, al
    // cerrarse el input de texto): estaciona el foco de Flutter en la raíz.
    testWidgets('funciona con el foco estacionado en la raíz', (tester) async {
      final (steps, _) = await mountDetail(tester);
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pump();
      await altDown(tester);
      expect(steps, [1]);
    });

    testWidgets('con un diálogo encima no navega', (tester) async {
      final (steps, _) = await mountDetail(tester);
      showDialog<void>(
        context: tester.element(find.byType(TextField)),
        builder: (_) => const AlertDialog(content: Text('¿Seguro?')),
      );
      await tester.pumpAndSettle();
      await altDown(tester);
      expect(steps, isEmpty);
    });

    testWidgets('enabled: false lo apaga (la galería tapa el detalle)',
        (tester) async {
      final (steps, _) = await mountDetail(tester, enabled: false);
      await altDown(tester);
      expect(steps, isEmpty);
    });
  });
}
