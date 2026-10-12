import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/widgets/message_bubble.dart';

// La cita dentro de una respuesta lleva al mensaje original. Lo que no puede
// romper: el long-press sigue abriendo el menú, y en una burbuja que no salió
// todo toque sigue abriendo Reintentar (failed_message_bubble_test.dart).
void main() {
  Widget bubble({
    String? status,
    String? mediaType,
    String? quotedId = 'orig-1',
    VoidCallback? onQuoteTap,
    VoidCallback? onFailedActions,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            text: mediaType == null ? 'Sí, el jueves' : '',
            fromMe: true,
            timestamp: DateTime(2026, 10, 12, 17, 7),
            messageId: 'm-2',
            chatPhone: '5215511111111',
            sessionKey: 'sk',
            accountId: 'acc',
            sessionPhone: '5215500000000',
            mediaType: mediaType,
            quotedMessageId: quotedId,
            quotedText: '¿Tienen cita el jueves?',
            quotedFromMe: false,
            onQuoteTap: onQuoteTap,
            onReplyTap: () {},
            sendStatus: status,
            onFailedActions: onFailedActions,
          ),
        ),
      );

  testWidgets('tocar la cita lleva al original', (tester) async {
    var jumps = 0;
    await tester.pumpWidget(bubble(onQuoteTap: () => jumps++));
    await tester.tap(find.text('¿Tienen cita el jueves?'));
    expect(jumps, 1);
  });

  testWidgets('el long-press sobre la cita abre el menú, no salta', (tester) async {
    // Alto de teléfono: en la ventana de prueba (600 de alto) el menú de un
    // saliente no cabe en la hoja.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var jumps = 0;
    await tester.pumpWidget(bubble(onQuoteTap: () => jumps++));
    await tester.longPress(find.text('¿Tienen cita el jueves?'));
    await tester.pumpAndSettle();
    expect(jumps, 0);
    expect(find.text('Responder'), findsOneWidget);
  });

  testWidgets('en una fallida la cita abre Reintentar, no salta', (tester) async {
    var jumps = 0;
    var actions = 0;
    await tester.pumpWidget(bubble(
      status: 'failed',
      onQuoteTap: () => jumps++,
      onFailedActions: () => actions++,
    ));
    await tester.tap(find.text('¿Tienen cita el jueves?'));
    expect(jumps, 0);
    expect(actions, 1);
  });

  testWidgets('una en vuelo sí salta: el original existe', (tester) async {
    var jumps = 0;
    await tester.pumpWidget(bubble(status: 'pending', onQuoteTap: () => jumps++));
    await tester.tap(find.text('¿Tienen cita el jueves?'));
    expect(jumps, 1);
  });

  testWidgets('sin cita no hay nada que tocar', (tester) async {
    await tester.pumpWidget(bubble(quotedId: null, onQuoteTap: () {}));
    expect(find.text('¿Tienen cita el jueves?'), findsNothing);
    expect(find.bySemanticsLabel('Ir al mensaje citado'), findsNothing);
  });

  testWidgets('un sticker que responde muestra su cita y salta', (tester) async {
    var jumps = 0;
    await tester.pumpWidget(bubble(mediaType: 'sticker', onQuoteTap: () => jumps++));
    expect(find.text('Cliente'), findsOneWidget);
    await tester.tap(find.text('¿Tienen cita el jueves?'));
    expect(jumps, 1);
  });
}
