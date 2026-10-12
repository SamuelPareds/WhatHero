import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/services/pending_messages_service.dart';

// El servicio es un singleton: cada test usa su propio chat y su propio
// tempId, y deja todo limpio (un timer vivo al terminar rompe testWidgets).
void main() {
  final service = PendingMessagesService();
  var n = 0;

  PendingMessage add(String key) {
    final p = PendingMessage(
      tempId: service.newTempId(),
      text: 'hola ${n++}',
      timestamp: DateTime(2026, 10, 12),
      payload: const {},
    );
    service.add(key, p);
    return p;
  }

  group('reconciliar por clientTempId (el ack se perdió)', () {
    testWidgets('el eco llega antes del timeout: la burbuja se va y nunca dice "No se envió"',
        (tester) async {
      const key = 'sk:eco-antes';
      final p = add(key);
      // Socket caído entre el envío y la respuesta: sin ack, sin realMessageId.
      expect(service.visibleForChat(key, {'WA1'}, presentTempIds: {p.tempId}), isEmpty);
      service.purgeReconciled(key, {'WA1'}, presentTempIds: {p.tempId});
      expect(service.hasPendingFor(key), isFalse);

      await tester.pump(PendingMessagesService.ackTimeout + const Duration(seconds: 1));
      // Un error tardío no la resucita.
      service.onSendError(p.tempId, 'Sin respuesta del servidor');
      expect(service.visibleForChat(key, const {}), isEmpty);
    });

    testWidgets('el eco llega después del timeout: la fallida desaparece sola',
        (tester) async {
      const key = 'sk:eco-despues';
      final p = add(key);
      await tester.pump(PendingMessagesService.ackTimeout);
      expect(service.visibleForChat(key, const {}).single.status, PendingStatus.failed);

      service.purgeReconciled(key, {'WA1'}, presentTempIds: {p.tempId});
      expect(service.hasPendingFor(key), isFalse);
    });

    testWidgets('el tempId de otra burbuja no la reconcilia', (tester) async {
      const key = 'sk:otra';
      final p = add(key);
      expect(service.visibleForChat(key, const {}, presentTempIds: {'tmp-ajeno'}), [p]);
      service.discard(p.tempId);
    });

    testWidgets('sigue reconciliando por el id del ack', (tester) async {
      const key = 'sk:ack';
      final p = add(key);
      service.onSendSuccess(p.tempId, 'WA1');
      expect(service.visibleForChat(key, const {}).single.status, PendingStatus.sent);
      service.purgeReconciled(key, {'WA1'});
      expect(service.hasPendingFor(key), isFalse);
    });
  });

  group('acciones de una fallida', () {
    testWidgets('Reintentar vuelve al relojito y re-arma el timeout', (tester) async {
      const key = 'sk:reintentar';
      final p = add(key);
      service.onSendError(p.tempId, 'Session not ready');
      expect(p.status, PendingStatus.failed);

      service.markRetrying(p.tempId);
      expect(p.status, PendingStatus.sending);
      expect(p.error, isNull);
      await tester.pump(PendingMessagesService.ackTimeout);
      expect(p.status, PendingStatus.failed);
      service.discard(p.tempId);
    });

    testWidgets('Eliminar la saca y cancela su timeout', (tester) async {
      const key = 'sk:eliminar';
      final p = add(key);
      service.discard(p.tempId);
      expect(service.hasPendingFor(key), isFalse);
      await tester.pump(PendingMessagesService.ackTimeout);
      expect(p.status, PendingStatus.sending);
    });
  });

  group('describeSendError', () {
    test('traduce lo que el operador puede resolver', () {
      expect(describeSendError('Session not ready'), 'WhatsApp no está conectado');
      expect(describeSendError('Connection Closed'), 'WhatsApp no está conectado');
      expect(describeSendError('HTTP 500'), 'Error del servidor');
      expect(describeSendError('HTTP 503'), 'Error del servidor');
      expect(describeSendError('ClientException: Failed to fetch'), 'Sin conexión con el servidor');
      expect(describeSendError("SocketException: Connection refused"), 'Sin conexión con el servidor');
      expect(describeSendError('TimeoutException after 0:00:10'), 'Sin conexión con el servidor');
    });

    test('lo desconocido se muestra tal cual', () {
      expect(describeSendError('Sin respuesta del servidor'), 'Sin respuesta del servidor');
      expect(describeSendError('HTTP 401'), 'HTTP 401');
      expect(describeSendError(null), 'Error desconocido');
      expect(describeSendError(''), 'Error desconocido');
    });
  });
}
