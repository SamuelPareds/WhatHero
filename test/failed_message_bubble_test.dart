import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/widgets/message_bubble.dart';

// Del 9-jul al 12-oct un mensaje que no salió no tenía ninguna salida: el tap
// de reintentar vivía en la burbuja de AUDIO y las burbujas optimistas son de
// texto, y el long-press salía de entrada con cualquier sendStatus.
void main() {
  Widget bubble({required String status, required VoidCallback onFailedActions}) =>
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            text: 'Te confirmo la cita del jueves',
            fromMe: true,
            timestamp: DateTime(2026, 10, 12, 10, 30),
            messageId: 'tmp-1',
            chatPhone: '5215511111111',
            sessionKey: 'sk',
            accountId: 'acc',
            sessionPhone: '5215500000000',
            sendStatus: status,
            onFailedActions: onFailedActions,
          ),
        ),
      );

  testWidgets('una fallida dice qué hacer y abre sus acciones con tap', (tester) async {
    var calls = 0;
    await tester.pumpWidget(bubble(status: 'failed', onFailedActions: () => calls++));
    expect(find.text('No se envió · toca para ver opciones'), findsOneWidget);

    await tester.tap(find.text('Te confirmo la cita del jueves'));
    expect(calls, 1);
  });

  testWidgets('una fallida abre sus acciones con long-press', (tester) async {
    var calls = 0;
    await tester.pumpWidget(bubble(status: 'failed', onFailedActions: () => calls++));
    await tester.longPress(find.text('Te confirmo la cita del jueves'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    // Y no el menú de un mensaje que sí existe en WhatsApp.
    expect(find.text('Eliminar para todos'), findsNothing);
  });

  testWidgets('en vuelo no hay acciones ni menú', (tester) async {
    var calls = 0;
    await tester.pumpWidget(bubble(status: 'pending', onFailedActions: () => calls++));
    await tester.tap(find.text('Te confirmo la cita del jueves'));
    await tester.longPress(find.text('Te confirmo la cita del jueves'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('No se envió · toca para ver opciones'), findsNothing);
  });

  testWidgets('el aviso cabe en un teléfono de 360 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bubble(status: 'failed', onFailedActions: () {}));
    expect(tester.takeException(), isNull);
  });
}
