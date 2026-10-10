import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/number_change_divider.dart';

void main() {
  final t1 = DateTime(2026, 10, 1, 12);
  final t2 = DateTime(2026, 10, 9, 12);
  final a = NumberChange('5215500000001', t1); // A hasta t1, después B
  final b = NumberChange('5215500000002', t2); // B hasta t2, después C
  final changes = [a, b];

  DateTime at(DateTime base, int minutes) => base.add(Duration(minutes: minutes));

  group('parseNumberHistory', () {
    test('ordena del más viejo al más nuevo e ignora entradas rotas', () {
      final parsed = parseNumberHistory([
        {'phone': b.phone, 'until': Timestamp.fromDate(t2)},
        {'phone': 'sin fecha'},
        'basura',
        {'phone': a.phone, 'until': Timestamp.fromDate(t1)},
      ]);
      expect(parsed.map((c) => c.phone), [a.phone, b.phone]);
    });

    test('sin historial no hay cambios', () {
      expect(parseNumberHistory(null), isEmpty);
    });
  });

  group('numberChangeBetween — dónde va la línea', () {
    test('entre un mensaje anterior y uno posterior al cambio', () {
      expect(numberChangeBetween(at(t1, -5), at(t1, 5), changes), a);
    });

    test('dos mensajes del mismo lado no llevan línea', () {
      expect(numberChangeBetween(at(t1, -10), at(t1, -5), changes), isNull);
      expect(numberChangeBetween(at(t1, 5), at(t1, 10), changes), isNull);
    });

    test('un mensaje justo en el instante del cambio ya es del número nuevo', () {
      expect(numberChangeBetween(at(t1, -1), t1, changes), a);
    });

    test('si entre los dos hubo dos cambios, gana el primero (el número de arriba)', () {
      expect(numberChangeBetween(at(t1, -5), at(t2, 5), changes), a);
    });
  });

  group('isFromPreviousNumber — qué no se puede editar ni reaccionar', () {
    test('lo anterior al último cambio es del número anterior', () {
      expect(isFromPreviousNumber(at(t2, -5), changes), isTrue);
      expect(isFromPreviousNumber(at(t2, 5), changes), isFalse);
    });

    test('lo que llegó por la línea anterior también, aunque sea posterior', () {
      expect(isFromPreviousNumber(at(t2, 60), changes, previousNumber: b.phone), isTrue);
    });

    test('sesión que nunca cambió de número: nada es del anterior', () {
      expect(isFromPreviousNumber(DateTime(2020), const []), isFalse);
    });
  });

  group('showNewNumberHint — "lo que envíes ahora sale del número nuevo"', () {
    test('lo último del chat es anterior al cambio', () {
      expect(
        showNewNumberHint(newestAt: at(t2, -5), newestPreviousNumber: null, changes: changes),
        isTrue,
      );
    });

    test('el cliente acaba de escribirle al número anterior', () {
      expect(
        showNewNumberHint(newestAt: at(t2, 60), newestPreviousNumber: b.phone, changes: changes),
        isTrue,
      );
    });

    test('ya se le contestó desde el número nuevo', () {
      expect(
        showNewNumberHint(newestAt: at(t2, 61), newestPreviousNumber: null, changes: changes),
        isFalse,
      );
    });

    test('chat vacío o sesión sin cambios: nada', () {
      expect(showNewNumberHint(newestAt: null, newestPreviousNumber: null, changes: changes), isFalse);
      expect(showNewNumberHint(newestAt: t1, newestPreviousNumber: null, changes: const []), isFalse);
    });
  });

  test('shortDate', () {
    expect(shortDate(DateTime(2026, 10, 9)), '9 oct 2026');
  });
}
