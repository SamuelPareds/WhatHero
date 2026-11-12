import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { remindersRanToday } from './reminderService';

// Los recordatorios no tienen dedupe por cita: un segundo lote el mismo día
// le manda a cada cliente su recordatorio dos veces.
describe('remindersRanToday', () => {
  const today = '2026-11-11';

  test('sin corrida previa, o de otro día, se puede enviar', () => {
    assert.equal(remindersRanToday(null, today), false);
    assert.equal(remindersRanToday({ day: '2026-11-10', status: 'done', sent: 12 }, today), false);
  });

  test('hoy ya salió algo: no se repite', () => {
    assert.equal(remindersRanToday({ day: today, status: 'done', sent: 12 }, today), true);
  });

  test('una corrida a medias (el proceso murió) tampoco se repite: reenviaría lo que sí salió', () => {
    assert.equal(remindersRanToday({ day: today, status: 'running', sent: 0 }, today), true);
  });

  test('una corrida de hoy que no mandó nada (todo falló) sí deja reintentar', () => {
    assert.equal(remindersRanToday({ day: today, status: 'done', sent: 0, failed: 5 }, today), false);
  });
});
