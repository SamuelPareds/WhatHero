import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';

void main() {
  final mx = countryForIso('MX')!;
  final co = countryForIso('CO')!;
  final ar = countryForIso('AR')!;
  final es = countryForIso('ES')!;

  group('countryForE164', () {
    test('deriva el país del número de la sesión', () {
      expect(countryForE164('5215561642726')?.iso2, 'MX');
      expect(countryForE164('525561642726')?.iso2, 'MX');
      expect(countryForE164('573001234567')?.iso2, 'CO');
      expect(countryForE164('15551234567')?.iso2, 'US');
    });

    test('gana el prefijo más largo', () {
      expect(countryForE164('18761234567')?.iso2, 'JM');
    });

    test('vacío o basura devuelve null', () {
      expect(countryForE164(''), isNull);
      expect(countryForE164('abc'), isNull);
    });
  });

  group('normalizeTyped — el usuario que sólo escribe sus 10 dígitos', () {
    test('un nacional válido se respeta intacto', () {
      final r = normalizeTyped('5561642726', mx);
      expect(r.national, '5561642726');
      expect(r.country.iso2, 'MX');
      expect(r.stripped, isNull);
      expect(r.isComplete, isTrue);
    });

    test('número incompleto no se toca ni se completa', () {
      final r = normalizeTyped('55616', mx);
      expect(r.national, '55616');
      expect(r.isComplete, isFalse);
    });
  });

  group('normalizeTyped — el usuario que pega el código incluido', () {
    test('quita el 52 de México', () {
      final r = normalizeTyped('525561642726', mx);
      expect(r.national, '5561642726');
      expect(r.stripped, '+52');
    });

    test('quita el 521 legacy de México', () {
      final r = normalizeTyped('5215561642726', mx);
      expect(r.national, '5561642726');
      expect(r.stripped, '+521');
    });

    test('quita el 549 de Argentina', () {
      final r = normalizeTyped('5491112345678', ar);
      expect(r.national, '1112345678');
      expect(r.stripped, '+549');
    });

    test('respeta formato humano con símbolos', () {
      final r = normalizeTyped('+52 55 6164 2726', mx);
      expect(r.national, '5561642726');
      expect(r.e164, '525561642726');
    });

    test('quita el cero de marcado nacional', () {
      final r = normalizeTyped('03001234567', co);
      expect(r.national, '3001234567');
      expect(r.stripped, '0');
    });
  });

  group('normalizeTyped — pegar un número de otro país mueve el selector', () {
    test('un +57 estando en México cambia a Colombia', () {
      final r = normalizeTyped('+573001234567', mx);
      expect(r.country.iso2, 'CO');
      expect(r.national, '3001234567');
    });

    test('sin el + también, si el largo lo delata', () {
      final r = normalizeTyped('573001234567', mx);
      expect(r.country.iso2, 'CO');
      expect(r.national, '3001234567');
    });

    test('un español de 9 dígitos con +34', () {
      final r = normalizeTyped('+34612345678', mx);
      expect(r.country.iso2, 'ES');
      expect(r.national, '612345678');
      expect(r.isComplete, isTrue);
    });
  });

  group('normalizeTyped — casos donde NO hay que tocar nada', () {
    test('un nacional que empieza igual que su código de país se respeta', () {
      // 10 dígitos: cabe en México, así que manda el largo y no se recorta
      // aunque empiece con "52".
      final r = normalizeTyped('5212345678', mx);
      expect(r.national, '5212345678');
      expect(r.stripped, isNull);
    });

    test('un largo que no cuadra con nadie se deja crudo', () {
      final r = normalizeTyped('99999', es);
      expect(r.national, '99999');
      expect(r.country.iso2, 'ES');
      expect(r.isComplete, isFalse);
    });

    test('vacío devuelve vacío sin romper', () {
      final r = normalizeTyped('', mx);
      expect(r.national, '');
      expect(r.isComplete, isFalse);
    });
  });

  group('formato para mostrar', () {
    test('agrupa según el patrón del país', () {
      expect(formatNational(mx, '5561642726'), '55 6164 2726');
      expect(formatE164(mx, '5561642726'), '+52 55 6164 2726');
    });

    test('sin patrón devuelve los dígitos tal cual', () {
      final bo = countryForIso('BO')!;
      expect(formatNational(bo, '71234567'), '71234567');
    });

    test('parcial no inventa dígitos', () {
      expect(formatNational(mx, '5561'), '55 61');
    });
  });
}
