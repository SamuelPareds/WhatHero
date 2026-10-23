import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/templates/template_editor_screen.dart';

void main() {
  // Alto suficiente para que el ListView construya todo el formulario.
  Future<void> pumpEditor(WidgetTester tester, {double height = 2400}) async {
    tester.view.physicalSize = Size(360, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: TemplateEditorScreen(accountId: 'acc', sessionId: '5215512345678', defaultLanguage: 'es_MX'),
    ));
  }

  testWidgets('cabe en un teléfono de 360 dp con botones agregados', (tester) async {
    await pumpEditor(tester, height: 800);
    await tester.scrollUntilVisible(find.text('Llamar'), 200, scrollable: find.byType(Scrollable).first);
    for (final label in ['Respuesta rápida', 'Enlace', 'Llamar']) {
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('pide un ejemplo por cada variable del mensaje, sin repetir', (tester) async {
    await pumpEditor(tester);
    final body = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Hola {{nombre}}'),
    );
    await tester.enterText(body, 'Hola {{nombre}}, tu cita es el {{fecha}}. Te esperamos, {{nombre}}.');
    await tester.pump();
    expect(find.text('Ejemplos para Meta'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ejemplo de {{nombre}}'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ejemplo de {{fecha}}'), findsOneWidget);
  });

  testWidgets('sin categoría elegida no se manda nada y se explica', (tester) async {
    await pumpEditor(tester);
    await tester.tap(find.text('Enviar a revisión'));
    await tester.pump();
    expect(find.textContaining('Elige la categoría'), findsOneWidget);
  });
}
