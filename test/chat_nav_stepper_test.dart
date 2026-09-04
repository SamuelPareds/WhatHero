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

  testWidgets('Alt+↑ / Alt+↓ recorren la cola con el foco en un TextField',
      (tester) async {
    final steps = <int>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatNavShortcuts(
          onStep: steps.add,
          // El foco vive en el composer casi siempre: si el atajo no gana ahí,
          // no sirve de nada.
          child: TextField(focusNode: focusNode, autofocus: true),
        ),
      ),
    ));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(steps, [1, -1]);

    // Sin Alt las flechas son del TextField (y del selector de respuestas
    // rápidas), no nuestras.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(steps, [1, -1]);
  });
}
