import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/chat_filter.dart';
import 'package:crm_whatsapp/features/chat/widgets/inbox_view_dropdown.dart';

void main() {
  Future<List<InboxView>> pump(
    WidgetTester tester, {
    required InboxView view,
    int pendingCount = 55,
    bool dimmed = false,
  }) async {
    final selected = <InboxView>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: InboxViewDropdown(
            view: view,
            pendingCount: pendingCount,
            dimmed: dimmed,
            onSelected: selected.add,
          ),
        ),
      ),
    ));
    return selected;
  }

  testWidgets('la píldora muestra la vista y, en Pendientes, cuántos son', (tester) async {
    await pump(tester, view: InboxView.pendientes);
    expect(find.text('Pendientes'), findsOneWidget);
    expect(find.text('55'), findsOneWidget);
  });

  testWidgets('al lado de Todos no hay número (se leería como el total)', (tester) async {
    await pump(tester, view: InboxView.todos);
    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('55'), findsNothing);
  });

  testWidgets('el menú ofrece las tres vistas y elige una', (tester) async {
    final selected = await pump(tester, view: InboxView.pendientes);
    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();

    expect(find.text('Esperan respuesta'), findsOneWidget);
    expect(find.text('Ya no esperan respuesta'), findsOneWidget);
    expect(find.text('Toda la bandeja'), findsOneWidget);

    await tester.tap(find.text('Listos'));
    await tester.pumpAndSettle();
    expect(selected, [InboxView.listos]);
  });

  testWidgets('atenuada (Seguimiento activo) sigue abriendo el menú', (tester) async {
    final selected = await pump(tester, view: InboxView.listos, dimmed: true);
    await tester.tap(find.text('Listos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    expect(selected, [InboxView.todos]);
  });
}
