import 'dart:async';

import 'package:crm_whatsapp/features/settings/session_settings_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Reglas de Ajustes de Sesión que fallan en silencio si se rompen: un borrador
// pisado por un snapshot, un guardado fallido que parece guardado, o un valor
// que el panel muestra y el backend no tiene. Ver CLAUDE.md, "⚙️ Ajustes de
// sesión".
void main() {
  DraftTextController draft([String saved = '']) {
    final c = DraftTextController(field: 'ai_system_prompt', label: 'Instrucciones');
    c.applyServer(saved);
    return c;
  }

  group('DraftTextController', () {
    test('el valor del servidor llena un campo limpio', () {
      final c = draft();
      c.applyServer('Eres un asistente.');
      expect(c.text, 'Eres un asistente.');
      expect(c.isDirty, isFalse);
    });

    test('los espacios de los bordes no cuentan como cambio', () {
      final c = draft('Hola');
      c.text = '  Hola \n';
      expect(c.isDirty, isFalse);
      c.text = 'Hola mundo';
      expect(c.isDirty, isTrue);
    });

    test('un snapshot con otro valor no pisa lo que se está escribiendo', () {
      final c = draft('viejo');
      c.text = 'mi borrador';
      c.applyServer('lo cambió otro operador');
      expect(c.text, 'mi borrador');
      expect(c.saved, 'lo cambió otro operador');
      expect(c.isDirty, isTrue);
    });

    test('un snapshot que no cambia nada no se come el espacio recién tecleado', () {
      final c = draft('Hola');
      c.text = 'Hola ';
      c.applyServer('Hola');
      expect(c.text, 'Hola ');
    });

    test('descartar vuelve a lo guardado', () {
      final c = draft('guardado');
      c.text = 'borrador';
      c.discard();
      expect(c.text, 'guardado');
      expect(c.isDirty, isFalse);
    });

    test('guardar escribe el texto recortado y deja el campo limpio', () async {
      final c = draft('viejo');
      c.text = '  nuevo  ';
      String? written;
      await c.save((v) async => written = v);
      expect(written, 'nuevo');
      expect(c.saved, 'nuevo');
      expect(c.isDirty, isFalse);
    });

    test('lo que se escribe mientras guarda sigue pendiente', () async {
      final c = draft('viejo');
      c.text = 'nuevo';
      final gate = Completer<void>();
      final saving = c.save((_) => gate.future);
      c.text = 'nuevo y más';
      gate.complete();
      await saving;
      expect(c.saved, 'nuevo');
      expect(c.isDirty, isTrue);
    });

    group('si el guardado falla, el borrador se queda y vuelve a "Sin guardar"', () {
      test('con el rollback llegando antes del error', () async {
        final c = draft('viejo');
        c.text = 'nuevo';
        await expectLater(
          c.save((value) async {
            c.applyServer(value); // eco de la escritura local
            c.applyServer('viejo'); // rollback: el servidor la rechazó
            throw Exception('permission-denied');
          }),
          throwsException,
        );
        expect(c.text, 'nuevo');
        expect(c.saved, 'viejo');
        expect(c.isDirty, isTrue);
        expect(c.isSaving, isFalse);
      });

      test('con el rollback llegando después del error', () async {
        final c = draft('viejo');
        c.text = 'nuevo';
        await expectLater(
          c.save((value) async {
            c.applyServer(value); // eco de la escritura local
            throw Exception('permission-denied');
          }),
          throwsException,
        );
        c.applyServer('viejo'); // rollback tardío
        expect(c.text, 'nuevo');
        expect(c.saved, 'viejo');
        expect(c.isDirty, isTrue);
      });
    });

    test('un segundo guardado con uno en vuelo espera al primero', () async {
      final c = draft('viejo');
      c.text = 'nuevo';
      var writes = 0;
      final gate = Completer<void>();
      final first = c.save((_) {
        writes++;
        return gate.future;
      });
      final second = c.save((_) async => writes++);
      gate.complete();
      await Future.wait([first, second]);
      expect(writes, 1);
    });

    test('un guardado que termina con el panel cerrado no revienta', () async {
      final c = draft('viejo');
      c.text = 'nuevo';
      final gate = Completer<void>();
      final saving = c.save((_) => gate.future);
      c.dispose();
      gate.complete();
      await saving;
    });
  });

  group('sessionSettingsDisplayGaps', () {
    test('una sesión nueva guarda los valores que el panel muestra', () {
      expect(sessionSettingsDisplayGaps({}), {
        // Sin esto el backend usa 1 500 ms: la IA respondería a los 1,5 s.
        'ai_response_delay_ms': defaultResponseDelaySeconds * 1000,
        'ai_provider': 'gemini',
        'ai_model': 'gemini-2.5-flash',
        'ai_system_prompt': defaultSystemPrompt,
        'reminder_template': defaultReminderTemplate,
      });
    });

    test('una espera fuera del rango se guarda como la muestra el slider', () {
      expect(sessionSettingsDisplayGaps({'ai_response_delay_ms': 1500})['ai_response_delay_ms'], 8000);
      expect(sessionSettingsDisplayGaps({'ai_response_delay_ms': 90000})['ai_response_delay_ms'], 30000);
      expect(sessionSettingsDisplayGaps({'ai_response_delay_ms': 12400})['ai_response_delay_ms'], 12000);
    });

    test('lo que el doc ya tiene no se toca', () {
      final gaps = sessionSettingsDisplayGaps({
        'ai_response_delay_ms': 20000,
        'ai_provider': 'openai',
        'ai_model': 'gpt-5-mini',
        'ai_system_prompt': '',
        'reminder_template': 'Hola {name}',
      });
      expect(gaps, isEmpty);
    });

    test('sin modelo, el default es el del proveedor guardado', () {
      final gaps = sessionSettingsDisplayGaps({'ai_provider': 'deepseek'});
      expect(gaps['ai_model'], 'deepseek-v4-flash');
      expect(gaps.containsKey('ai_provider'), isFalse);
    });
  });

  group('DraftSaveBar', () {
    Future<DraftTextController> pump(WidgetTester tester, {required VoidCallback onSave}) async {
      final c = draft('guardado');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Column(children: [
              TextField(controller: c),
              DraftSaveBar(controller: c, onSave: onSave),
            ]),
          ),
        ),
      ));
      return c;
    }

    testWidgets('no se ve sin cambios y aparece al escribir', (tester) async {
      await pump(tester, onSave: () {});
      expect(find.text('Guardar'), findsNothing);
      await tester.enterText(find.byType(TextField), 'otro texto');
      await tester.pump();
      expect(find.text('Sin guardar'), findsOneWidget);
      expect(find.text('Guardar'), findsOneWidget);
    });

    testWidgets('Descartar vuelve a lo guardado y la barra se va', (tester) async {
      final c = await pump(tester, onSave: () {});
      await tester.enterText(find.byType(TextField), 'otro texto');
      await tester.pump();
      await tester.tap(find.text('Descartar'));
      await tester.pump();
      expect(c.text, 'guardado');
      expect(find.text('Sin guardar'), findsNothing);
    });

    testWidgets('Guardar llama a onSave', (tester) async {
      var saves = 0;
      await pump(tester, onSave: () => saves++);
      await tester.enterText(find.byType(TextField), 'otro texto');
      await tester.pump();
      await tester.tap(find.text('Guardar'));
      expect(saves, 1);
    });
  });
}
