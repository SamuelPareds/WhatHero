import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/reply_collision.dart';

const me = 'uid-me';

/// Reloj manual: el detector nunca mira el reloj real.
class FakeClock {
  DateTime now = DateTime(2026, 9, 24, 10);
  void advance(Duration d) => now = now.add(d);
}

CollisionCandidate client(String id) =>
    CollisionCandidate(id: id, fromMe: false, preview: 'hola');

CollisionCandidate teammate(String id, {String name = 'Ana'}) =>
    CollisionCandidate(
      id: id,
      fromMe: true,
      senderType: 'human',
      senderName: name,
      senderUid: 'uid-$name',
      preview: 'Ya quedó tu pedido',
    );

CollisionCandidate mine(String id) => CollisionCandidate(
      id: id,
      fromMe: true,
      senderType: 'human',
      senderName: 'Samuel',
      senderUid: me,
      preview: 'yo',
    );

void main() {
  late FakeClock clock;
  late ReplyCollisionDetector detector;
  late Map<String, CollisionCandidate> docs;
  late List<String> readCalls;

  setUp(() {
    clock = FakeClock();
    detector = ReplyCollisionDetector(clock: () => clock.now);
    docs = {};
    readCalls = [];
  });

  ReplyCollision? snap(
    List<CollisionCandidate> newestFirst, {
    bool fromCache = false,
    bool composing = true,
  }) {
    for (final d in newestFirst) {
      docs[d.id] = d;
    }
    return detector.onSnapshot(
      idsNewestFirst: [for (final d in newestFirst) d.id],
      fromCache: fromCache,
      composing: composing,
      myUid: me,
      read: (id) {
        readCalls.add(id);
        return docs[id]!;
      },
    );
  }

  /// Chat abierto y asentado: baseline tomada y ventana de arranque vencida.
  void openChat(List<CollisionCandidate> history) {
    snap(history);
    clock.advance(ReplyCollisionDetector.settle);
  }

  group('detecta el choque', () {
    test('un compañero responde mientras escribo', () {
      openChat([client('c1')]);
      final hit = snap([teammate('t1'), client('c1')]);
      expect(hit, isNotNull);
      expect(hit!.source, ReplyCollisionSource.teammate);
      expect(hit.headline, 'Ana acaba de responder');
      expect(hit.preview, 'Ya quedó tu pedido');
    });

    test('responde la IA', () {
      openChat([client('c1')]);
      final hit = snap([
        const CollisionCandidate(
            id: 'a1', fromMe: true, senderType: 'ai', senderName: 'ai', preview: 'x'),
        client('c1'),
      ]);
      expect(hit?.source, ReplyCollisionSource.ai);
    });

    test('responden desde el teléfono (WhatsApp)', () {
      openChat([client('c1')]);
      final hit = snap([
        const CollisionCandidate(
            id: 'w1', fromMe: true, senderType: 'human', senderName: 'WhatsApp', preview: 'x'),
        client('c1'),
      ]);
      expect(hit?.source, ReplyCollisionSource.whatsapp);
    });

    test('dos nuevos en un mismo snapshot: el cliente no tapa al compañero', () {
      openChat([client('c1')]);
      final hit = snap([client('c2'), teammate('t1'), client('c1')]);
      expect(hit?.messageId, 't1');
    });

    test('mi usuario desde otro dispositivo (login compartido)', () {
      openChat([client('c1')]);
      final hit = snap([mine('m1'), client('c1')]);
      expect(hit?.source, ReplyCollisionSource.sameUser);
    });

    test('mío, pero mi último envío desde aquí ya pasó la ventana', () {
      openChat([client('c1')]);
      detector.noteLocalSend();
      clock.advance(ReplyCollisionDetector.ownSendWindow + const Duration(seconds: 1));
      expect(snap([mine('m1'), client('c1')])?.source, ReplyCollisionSource.sameUser);
    });
  });

  group('no molesta cuando no hay choque', () {
    test('mi propio envío desde esta vista', () {
      openChat([client('c1')]);
      detector.noteLocalSend();
      expect(snap([mine('m1'), client('c1')]), isNull);
    });

    test('escribe el cliente', () {
      openChat([client('c1')]);
      expect(snap([client('c2'), client('c1')]), isNull);
    });

    test('reglas automáticas y recordatorios (bot)', () {
      openChat([client('c1')]);
      final hit = snap([
        const CollisionCandidate(
            id: 'b1', fromMe: true, senderType: 'bot', senderName: 'bot', preview: 'x'),
        client('c1'),
      ]);
      expect(hit, isNull);
    });

    test('composer vacío: nadie estaba escribiendo', () {
      openChat([client('c1')]);
      expect(snap([teammate('t1'), client('c1')], composing: false), isNull);
    });

    test('lo que llegó con el composer vacío no se vuelve choque después', () {
      openChat([client('c1')]);
      snap([teammate('t1'), client('c1')], composing: false);
      // Empiezo a escribir y entra otro mensaje del cliente.
      expect(snap([client('c2'), teammate('t1'), client('c1')]), isNull);
    });

    test('ponerse al día al abrir: cache y luego servidor', () {
      // El cache no tenía la respuesta de Ana; el servidor la trae enseguida.
      snap([client('c1')], fromCache: true);
      expect(snap([teammate('t1'), client('c1')]), isNull);
    });

    test('ponerse al día sin snapshot de cache (cache ya al día)', () {
      snap([client('c1')]);
      clock.advance(const Duration(seconds: 1));
      expect(snap([teammate('t1'), client('c1')]), isNull);
    });

    test('snapshot desde cache (sin conexión) no evalúa', () {
      openChat([client('c1')]);
      expect(snap([teammate('t1'), client('c1')], fromCache: true), isNull);
    });

    test('borrar el más reciente no asciende una respuesta vieja', () {
      openChat([client('c2'), teammate('t1'), client('c1')]);
      expect(snap([teammate('t1'), client('c1')]), isNull);
    });

    test('paginar hacia atrás agrega viejos abajo, no arriba', () {
      openChat([client('c2'), client('c1')]);
      expect(snap([client('c2'), client('c1'), teammate('t0')]), isNull);
    });

    test('ventana reemplazada entera: calla en vez de adivinar', () {
      openChat([client('c1')]);
      expect(snap([teammate('t1'), client('c9')]), isNull);
    });
  });

  test('sólo lee los docs nuevos, no toda la conversación', () {
    openChat([client('c3'), client('c2'), client('c1')]);
    readCalls.clear();
    snap([teammate('t1'), client('c3'), client('c2'), client('c1')]);
    expect(readCalls, ['t1']);
  });
}
