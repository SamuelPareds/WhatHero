import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/phone_search.dart';

/// ¿Encuentra [query] al chat guardado como [stored]?
bool finds(String stored, String query) {
  final tail = phoneSearchTail(query);
  return tail != null && phoneMatchesTail(stored, tail);
}

void main() {
  group('el número pegado desde otra plataforma', () {
    // El caso que motivó todo: WhatsApp da el E.164 sin el `1` móvil y con
    // espacios; nosotros guardamos `521` pegado.
    const mx = '5215512345678';

    test('pegado con +52 y espacios encuentra al 521 guardado', () {
      expect(finds(mx, '+52 55 1234 5678'), isTrue);
      expect(finds(mx, '+52 1 55 1234 5678'), isTrue);
      expect(finds(mx, '+5215512345678'), isTrue);
      expect(finds(mx, '52 5512345678'), isTrue);
    });

    test('y al revés: guardado sin el 1 móvil, pegado con él', () {
      expect(finds('525512345678', '+52 1 55 1234 5678'), isTrue);
    });

    test('los 10 dígitos nacionales pelados bastan', () {
      expect(finds(mx, '5512345678'), isTrue);
    });

    test('guiones y paréntesis tampoco estorban', () {
      expect(finds(mx, '(55) 1234-5678'), isTrue);
      expect(finds('573001234567', '+57 300 123 4567'), isTrue);
    });

    test('otro número no se cuela', () {
      expect(finds(mx, '+52 55 1234 5679'), isFalse);
      expect(finds(mx, '+57 300 123 4567'), isFalse);
    });
  });

  group('países con nacional más corto que 10', () {
    test('Chile: 9 dígitos', () {
      expect(finds('56912345678', '+56 9 1234 5678'), isTrue);
      expect(finds('56912345678', '912345678'), isTrue);
    });

    test('Costa Rica: 8 dígitos, se usan todos', () {
      expect(phoneSearchTail('+506 8765 4321'), '0687654321');
      expect(finds('50687654321', '+506 8765 4321'), isTrue);
      expect(finds('50687654321', '87654321'), isTrue);
    });

    test('Brasil con nona: la cola de 10 sigue siendo sufijo', () {
      expect(finds('5511987654321', '+55 11 98765-4321'), isTrue);
    });

    test('Argentina con y sin el 9 móvil', () {
      expect(finds('5491112345678', '+54 9 11 1234-5678'), isTrue);
      expect(finds('5491112345678', '+54 11 1234-5678'), isTrue);
    });
  });

  group('escribir a mano sigue funcionando', () {
    test('un prefijo parcial encuentra igual', () {
      expect(finds('5215512345678', '5512'), isTrue);
      expect(finds('5215512345678', '5215'), isTrue);
    });

    test('sin dígitos no hay búsqueda por teléfono', () {
      expect(phoneSearchTail('juan'), isNull);
      expect(phoneSearchTail(''), isNull);
      expect(phoneSearchTail('   '), isNull);
      expect(phoneSearchTail('+'), isNull);
    });

    // El guard que evita inundar la lista: un nombre con una cifra dentro no
    // es un teléfono, aunque tenga dígitos.
    test('un nombre con número dentro se busca como texto, no como teléfono', () {
      expect(phoneSearchTail('ana 2'), isNull);
      expect(phoneSearchTail('sala 3'), isNull);
      expect(phoneSearchTail('cliente vip 007'), isNull);
    });
  });

  group('phoneSearchTail', () {
    test('recorta a los últimos 10 dígitos', () {
      expect(phoneSearchTail('+52 1 55 1234 5678'), '5512345678');
      expect(phoneSearchTail('+55 11 98765-4321'), '1987654321');
    });

    test('lo más corto que 10 se devuelve entero', () {
      expect(phoneSearchTail('55 1234'), '551234');
      expect(phoneSearchTail('7'), '7');
    });
  });
}
