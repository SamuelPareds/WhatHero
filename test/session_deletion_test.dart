import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/session_deletion.dart';
import 'package:crm_whatsapp/features/accounts/link_result.dart';

void main() {
  group('confirmación con los últimos 4 dígitos', () {
    test('se toman del número completo, con o sin formato', () {
      expect(deleteConfirmationDigits('5215512345678'), '5678');
      expect(deleteConfirmationDigits('+52 1 55 1234 5678'), '5678');
    });

    test('lo tecleado ignora espacios y separadores', () {
      expect(deleteConfirmationMatches('5678', '5215512345678'), isTrue);
      expect(deleteConfirmationMatches(' 56 78 ', '5215512345678'), isTrue);
      expect(deleteConfirmationMatches('56-78', '5215512345678'), isTrue);
    });

    test('dígitos de otro número, incompletos o de más no confirman', () {
      expect(deleteConfirmationMatches('1234', '5215512345678'), isFalse);
      expect(deleteConfirmationMatches('678', '5215512345678'), isFalse);
      expect(deleteConfirmationMatches('45678', '5215512345678'), isFalse);
      expect(deleteConfirmationMatches('', '5215512345678'), isFalse);
    });

    test('un número sin dígitos nunca se confirma (no hay qué teclear)', () {
      expect(deleteConfirmationMatches('', ''), isFalse);
    });
  });

  group('lápida', () {
    test('sólo cuenta como eliminándose con deleting_at', () {
      expect(isSessionDeleting({'deleting_at': DateTime(2026)}), isTrue);
      expect(isSessionDeleting({'status': 'deleting'}), isFalse);
      expect(isSessionDeleting({'status': 'connected'}), isFalse);
      expect(isSessionDeleting(null), isFalse);
    });
  });

  test('un QR rechazado porque la sesión se está eliminando lo explica', () {
    const result = LinkResult(phone: '5215512345678', rejectedReason: 'deleting');
    expect(result.rejected, isTrue);
    expect(result.rejectionMessage, contains('se está eliminando'));
  });
}
