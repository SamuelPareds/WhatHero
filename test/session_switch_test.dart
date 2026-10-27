import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';
import 'package:crm_whatsapp/features/accounts/session_switch.dart';
import 'package:crm_whatsapp/features/accounts/session_visual.dart';

SessionOption s(String id, String? status) =>
    SessionOption(id: id, name: id, phone: id, status: status);

void main() {
  group('pickRootSession: la sesión que se ve no se suelta sola', () {
    test('una reconexión NO saca al operador de su cuenta', () {
      // El bug: el dispatcher sólo mostraba `connected`, y cada reintento del
      // backend escribe `reconnecting`. La pantalla saltaba a otra cuenta.
      for (final status in ['reconnecting', 'reconnect_failed', 'disconnected']) {
        final pick = pickRootSession(
          sessions: [s('A', 'connected'), s('B', status)],
          current: 'B',
        );
        expect(pick.sessionId, 'B', reason: status);
        expect(pick.requestRejected, isFalse);
      }
    });

    test('si la actual desaparece (eliminada o sin acceso), elige otra', () {
      final pick = pickRootSession(
        sessions: [s('A', 'connected')],
        current: 'B',
        lastUsed: 'B',
      );
      expect(pick.sessionId, 'A');
    });

    test('sin ninguna sesión visible, bienvenida', () {
      expect(pickRootSession(sessions: const [], current: 'A').sessionId, isNull);
    });
  });

  group('pickRootSession: lo que se pide', () {
    test('se abre con cualquier status: una caída se puede leer', () {
      final pick = pickRootSession(
        sessions: [s('A', 'connected'), s('B', 'disconnected')],
        requested: 'B',
        current: 'A',
      );
      expect(pick.sessionId, 'B');
      expect(pick.requestRejected, isFalse);
    });

    test('una sesión que no está se rechaza y se queda la actual', () {
      final pick = pickRootSession(
        sessions: [s('A', 'connected'), s('B', 'connected')],
        requested: 'Z',
        current: 'B',
      );
      expect(pick.sessionId, 'B');
      expect(pick.requestRejected, isTrue);
    });

    test('rechazada al arrancar (push a una sesión borrada): elección automática', () {
      final pick = pickRootSession(
        sessions: [s('A', 'connected')],
        requested: 'Z',
      );
      expect(pick.sessionId, 'A');
      expect(pick.requestRejected, isTrue);
    });
  });

  group('pickRootSession: al arrancar', () {
    test('la última usada, aunque esté reconectando (redeploy)', () {
      final pick = pickRootSession(
        sessions: [s('A', 'connected'), s('B', 'reconnecting')],
        lastUsed: 'B',
      );
      expect(pick.sessionId, 'B');
    });

    test('la última usada caída hace rato pierde contra una viva', () {
      final pick = pickRootSession(
        sessions: [s('A', 'reconnect_failed'), s('B', 'disconnected'), s('C', 'connected')],
        lastUsed: 'A',
      );
      expect(pick.sessionId, 'C');
    });

    test('todas caídas: la última usada', () {
      final pick = pickRootSession(
        sessions: [s('A', 'disconnected'), s('B', 'reconnect_failed')],
        lastUsed: 'B',
      );
      expect(pick.sessionId, 'B');
    });

    test('sin última usada: la primera viva en el orden de la lista', () {
      final pick = pickRootSession(
        sessions: [s('A', 'disconnected'), s('B', 'connected'), s('C', 'connected')],
      );
      expect(pick.sessionId, 'B');
    });

    test('todas caídas y sin última usada: la primera', () {
      final pick = pickRootSession(sessions: [s('A', 'disconnected'), s('B', 'disconnected')]);
      expect(pick.sessionId, 'A');
    });
  });

  group('visibleSessionOptions', () {
    Timestamp at(int day) => Timestamp.fromDate(DateTime(2026, 10, day));

    test('sin lápidas, la vinculada más reciente primero y sin fecha al final', () {
      final options = visibleSessionOptions([
        (id: 'viejo', data: {'connected_at': at(1), 'status': 'connected'}),
        (id: 'sinFecha', data: {'status': 'connected'}),
        (id: 'borrandose', data: {'connected_at': at(9), 'deleting_at': at(9)}),
        (id: 'nuevo', data: {'connected_at': at(5), 'status': 'reconnecting'}),
      ]);
      expect(options.map((o) => o.id), ['nuevo', 'viejo', 'sinFecha']);
    });

    test('lleva el número actual, no el id, y el session_key en vivo', () {
      final o = SessionOption.fromData('5215500000000', {
        'phone_number': '5215511111111',
        'session_key': 'k2',
        'status': 'connected',
      });
      expect(o.phone, '5215511111111');
      expect(o.sessionKey, 'k2');
      expect(o.isLive, isTrue);
    });
  });

  group('sessionDisplayName', () {
    test('alias, luego nombre verificado de Meta, luego el número', () {
      expect(sessionDisplayName({'alias': 'AC', 'cloud_api_verified_name': 'Meta'}, '1'), 'AC');
      expect(sessionDisplayName({'alias': '  ', 'cloud_api_verified_name': 'Meta'}, '1'), 'Meta');
      expect(sessionDisplayName({'phone_number': '5215561642726'}, '5210000000000'), '+52 55 6164 2726');
    });

    test('un doc sin alias no rompe el título (antes: StateError)', () {
      expect(sessionDisplayName(const {}, '5215561642726'), '+52 55 6164 2726');
      expect(sessionDisplayName(null, '5215561642726'), '+52 55 6164 2726');
    });
  });

  group('SessionVisual', () {
    final now = DateTime(2026, 10, 27, 12);

    test('la lápida gana sobre cualquier status', () {
      final v = SessionVisual.from('connected', now, deleting: true, now: now);
      expect(v.label, 'Eliminando…');
      expect(v.isConnected, isFalse);
    });

    test('reconectando con latido reciente gira; sin latido, "Sin respuesta"', () {
      final fresh = SessionVisual.from('reconnecting', now.subtract(const Duration(minutes: 2)), now: now);
      expect(fresh.label, 'Reconectando...');
      expect(fresh.showSpinner, isTrue);

      final stale = SessionVisual.from('reconnecting', now.subtract(const Duration(minutes: 6)), now: now);
      expect(stale.label, 'Sin respuesta');
      expect(stale.showSpinner, isFalse);

      expect(SessionVisual.from('reconnecting', null, now: now).label, 'Sin respuesta');
    });

    test('conectada, caída hace rato y desvinculada', () {
      expect(SessionVisual.from('connected', null).isConnected, isTrue);
      expect(SessionVisual.from('reconnect_failed', null).label, 'Sin conexión');
      expect(SessionVisual.from('disconnected', null).label, 'Desvinculado');
      expect(SessionVisual.from(null, null).label, 'Desvinculado');
    });
  });
}
