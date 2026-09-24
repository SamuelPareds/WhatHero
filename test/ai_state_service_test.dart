import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/services/ai_state_service.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';

const sk = 'session-key';
const chatA = '5215511111111';
const chatB = '5215522222222';

Map<String, dynamic> payload(String chat, String state) =>
    {'sessionKey': sk, 'contactPhone': chat, 'state': state};

void main() {
  final service = AiStateService();

  setUp(service.clearAll);
  tearDown(service.clearAll);

  group('foto al (re)conectar', () {
    test('reemplaza todo: lo que no viene en la foto ya terminó', () {
      service.applySocketPayload(payload(chatA, 'thinking'));
      service.replaceAll([payload(chatB, 'buffering')]);
      expect(service.statusFor(sk, chatA), isNull, reason: 'su idle se perdió desconectados');
      expect(service.statusFor(sk, chatB)?.state, AiChatState.buffering);
    });

    test('quien conecta a mitad de un ciclo lo ve', () {
      service.replaceAll([payload(chatA, 'responding')]);
      expect(service.isActiveFor(sk, chatA), isTrue);
    });

    test('entradas rotas o idle se ignoran sin tirar las demás', () {
      service.replaceAll([
        'basura',
        {'sessionKey': sk, 'contactPhone': 7, 'state': 'thinking'},
        payload(chatB, 'idle'),
        payload(chatA, 'thinking'),
      ]);
      expect(service.isActiveFor(sk, chatA), isTrue);
      expect(service.statusFor(sk, chatB), isNull);
    });

    test('notifica una sola vez', () {
      var notified = 0;
      void listener() => notified++;
      service.addListener(listener);
      service.replaceAll([payload(chatA, 'thinking'), payload(chatB, 'buffering')]);
      service.removeListener(listener);
      expect(notified, 1);
    });
  });

  testWidgets('la foto rearma el watchdog de 90 s', (tester) async {
    service.replaceAll([payload(chatA, 'thinking')]);
    await tester.pump(const Duration(seconds: 89));
    expect(service.isActiveFor(sk, chatA), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(service.isActiveFor(sk, chatA), isFalse);
  });

  testWidgets('el latido del backend mantiene vivo un ciclo largo', (tester) async {
    service.applySocketPayload(payload(chatA, 'thinking'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 30));
      service.applySocketPayload(payload(chatA, 'thinking')); // re-emisión
    }
    expect(service.isActiveFor(sk, chatA), isTrue, reason: '3 min pensando y sigue a la vista');
    service.clearAll(); // testWidgets exige cero timers pendientes al terminar
  });

  test('idle apaga; payload sin campos se ignora', () {
    service.applySocketPayload(payload(chatA, 'buffering'));
    service.applySocketPayload({'sessionKey': sk});
    expect(service.isActiveFor(sk, chatA), isTrue);
    service.applySocketPayload(payload(chatA, 'idle'));
    expect(service.statusFor(sk, chatA), isNull);
  });

  test('recuperación del socket: 2, 4, 8, 16 y luego 30 s', () {
    expect(
      [for (var i = 0; i < 7; i++) socketRecoveryDelay(i).inSeconds],
      [2, 4, 8, 16, 30, 30, 30],
    );
    expect(socketRecoveryDelay(100).inSeconds, 30);
  });
}
