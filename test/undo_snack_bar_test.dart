import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/widgets/undo_snack_bar.dart';

void main() {
  late ScaffoldMessengerState messenger;
  late List<String> log;

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          messenger = ScaffoldMessenger.of(context);
          return const SizedBox.shrink();
        }),
      ),
    ));
  }

  void show(String id) => showUndoSnackBar(
        messenger,
        'Marcado como listo: $id',
        onUndo: () => log.add('undo $id'),
        onCommit: () => log.add('commit $id'),
      );

  setUp(() => log = []);

  testWidgets('se cierra solo y confirma (un SnackBar con acción no se cierra por default)',
      (tester) async {
    await pumpApp(tester);
    show('Ana');
    await tester.pumpAndSettle(); // el tiempo corre desde que terminó de entrar
    expect(find.text('Deshacer'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Deshacer'), findsNothing);
    expect(log, ['commit Ana']);
  });

  testWidgets('Deshacer revierte y no confirma (el teléfono no se marca leído)', (tester) async {
    await pumpApp(tester);
    show('Ana');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Deshacer'));
    await tester.pumpAndSettle();
    expect(log, ['undo Ana']);
  });

  testWidgets('el siguiente reemplaza al anterior, que se confirma', (tester) async {
    await pumpApp(tester);
    show('Ana');
    await tester.pumpAndSettle();
    show('Beto');
    await tester.pumpAndSettle();

    expect(log, ['commit Ana']);
    expect(find.text('Marcado como listo: Beto'), findsOneWidget);
    expect(find.text('Marcado como listo: Ana'), findsNothing);

    await tester.tap(find.text('Deshacer'));
    await tester.pumpAndSettle();
    expect(log, ['commit Ana', 'undo Beto']);
  });
}
