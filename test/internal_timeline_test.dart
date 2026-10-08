import 'package:crm_whatsapp/core/services/internal_messages_service.dart';
import 'package:crm_whatsapp/features/chat/internal_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

// Los mensajes de WhatsApp se representan con su hora: es lo único que la
// mezcla necesita de ellos.
final _t0 = DateTime(2026, 10, 8, 12);
DateTime _at(int minute) => _t0.add(Duration(minutes: minute));

InternalMessage _note(String id, DateTime at) => InternalMessage(
      id: id,
      chatId: '5215511111111',
      contactName: 'Ana',
      text: id,
      authorUid: 'uid-samuel',
      authorName: 'Samuel',
      recipients: const [],
      timestamp: at,
    );

void main() {
  test('sin internos devuelve la conversación tal cual y no lee ninguna hora', () {
    var reads = 0;
    final wa = [_at(3), _at(2), _at(1)];
    final out = mergeTimeline<DateTime>(
      wa: wa,
      waTime: (d) {
        reads++;
        return d;
      },
      internal: const [],
      waComplete: false,
    );
    expect(out, wa);
    expect(reads, 0);
  });

  test('intercala por hora, del más nuevo al más viejo', () {
    final n = _note('n', _at(2).add(const Duration(seconds: 30)));
    final out = mergeTimeline<DateTime>(
      wa: [_at(3), _at(2), _at(1)],
      waTime: (d) => d,
      internal: [n],
      waComplete: true,
    );
    expect(out, [_at(3), n, _at(2), _at(1)]);
  });

  test('con historial por cargar, esconde los internos más viejos que lo cargado', () {
    final viejo = _note('viejo', _at(5));
    final out = mergeTimeline<DateTime>(
      wa: [_at(10), _at(9)],
      waTime: (d) => d,
      internal: [viejo],
      waComplete: false,
    );
    expect(out, [_at(10), _at(9)]);
  });

  test('con el historial completo, los internos viejos quedan arriba de todo', () {
    final viejo = _note('viejo', _at(5));
    final out = mergeTimeline<DateTime>(
      wa: [_at(10), _at(9)],
      waTime: (d) => d,
      internal: [viejo],
      waComplete: true,
    );
    expect(out, [_at(10), _at(9), viejo]);
  });

  test('chat sin mensajes de WhatsApp (recién abierto): sólo los internos', () {
    final a = _note('a', _at(2));
    final b = _note('b', _at(1));
    final out = mergeTimeline<DateTime>(
      wa: const [],
      waTime: (d) => d,
      internal: [a, b],
      waComplete: true,
    );
    expect(out, [a, b]);
  });

  test('lee la hora de cada mensaje de WhatsApp una sola vez', () {
    var reads = 0;
    final wa = [_at(10), _at(8), _at(6), _at(4)];
    mergeTimeline<DateTime>(
      wa: wa,
      waTime: (d) {
        reads++;
        return d;
      },
      internal: [_note('a', _at(9)), _note('b', _at(7)), _note('c', _at(7))],
      waComplete: true,
    );
    // Cada interno compara contra el mismo "siguiente" sin releerlo.
    expect(reads, lessThanOrEqualTo(wa.length));
  });
}
