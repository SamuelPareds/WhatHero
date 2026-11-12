import 'package:crm_whatsapp/features/followups/followup_message.dart';
import 'package:flutter_test/flutter_test.dart';

// Mismas frases que backend/src/services/followupCampaigns.test.ts: la vista
// previa tiene que decir lo mismo que va a salir.
void main() {
  const promo = 'Hola Ana, {faltan_dias} para el fin de esta promo.';

  test('cuenta los días que faltan', () {
    expect(
      renderDateVariables(promo, '2026-11-14', '2026-11-11'),
      'Hola Ana, faltan 3 días para el fin de esta promo.',
    );
    expect(renderDateVariables(promo, '2026-11-14', '2026-11-13'), 'Hola Ana, falta 1 día para el fin de esta promo.');
  });

  test('al inicio de frase va con mayúscula, y el último día se dice así', () {
    expect(
      renderDateVariables('{faltan_dias} de la promo.', '2026-11-14', '2026-11-14'),
      'Hoy es el último día de la promo.',
    );
    expect(renderDateVariables('¡Corre! {faltan_dias}.', '2026-11-20', '2026-11-11'), '¡Corre! Faltan 9 días.');
  });

  test('vencida o sin fecha límite, no hay mensaje', () {
    expect(renderDateVariables(promo, '2026-11-10', '2026-11-11'), isNull);
    expect(renderDateVariables(promo, null, '2026-11-11'), isNull);
  });

  test('sin variables de fecha sale igual', () {
    expect(renderDateVariables('¿Sigues interesada?', null, '2026-11-11'), '¿Sigues interesada?');
  });

  test('{fecha_limite} se escribe como lo diría una persona', () {
    expect(renderDateVariables('Termina el {fecha_limite}.', '2026-12-01', '2026-11-11'), 'Termina el 1 de diciembre.');
  });

  test('el cruce de año cuenta bien', () {
    expect(daysBetween('2026-12-30', '2027-01-02'), 3);
  });
}
