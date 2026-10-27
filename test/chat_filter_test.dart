import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/features/chat/chat_filter.dart';

void main() {
  // Chats típicos de una bandeja: cómo los deja el backend y la app.
  final chats = <String, Map<String, dynamic>?>{
    'cliente escribió y la IA no contestó': {'unresponded_count': 3},
    'marcado a mano como pendiente': {'marked_pending': true},
    'las dos señales': {'unresponded_count': 1, 'marked_pending': true},
    'respondido (contador en 0)': {'unresponded_count': 0, 'marked_pending': false},
    'chat viejo sin los campos': {},
    'doc sin datos': null,
  };

  group('Pendientes y Listos son las dos mitades de Todos', () {
    test('cada chat cae en exactamente una de las dos vistas', () {
      for (final entry in chats.entries) {
        final pendiente = matchesInboxView(InboxView.pendientes, entry.value);
        final listo = matchesInboxView(InboxView.listos, entry.value);
        expect(pendiente != listo, isTrue, reason: entry.key);
        expect(matchesInboxView(InboxView.todos, entry.value), isTrue, reason: entry.key);
      }
    });

    test('pendiente = contador automático o marca manual', () {
      expect(isChatPending({'unresponded_count': 3}), isTrue);
      expect(isChatPending({'marked_pending': true}), isTrue);
      expect(isChatPending({'unresponded_count': 0, 'marked_pending': false}), isFalse);
      expect(isChatPending({}), isFalse);
      expect(isChatPending(null), isFalse);
    });

    test('lo que deja "Listo" (contador en 0, sin marca) sale de Pendientes', () {
      final listo = {'unresponded_count': 0, 'marked_pending': false};
      expect(matchesInboxView(InboxView.pendientes, listo), isFalse);
      expect(matchesInboxView(InboxView.listos, listo), isTrue);
    });
  });

  group('los chips filtran dentro de la vista', () {
    final vipPendiente = {'unresponded_count': 2, 'labelIds': ['vip']};
    final vipListo = {'labelIds': ['vip']};
    final otroPendiente = {'unresponded_count': 1, 'labelIds': ['frio']};
    const labels = {'vip', 'frio'};

    bool visible(InboxView v, ChatFilter? chip, Map<String, dynamic> chat,
            {bool searching = false}) =>
        chatIsVisible(v, chip, chat,
            labelId: 'vip', knownLabelIds: labels, searching: searching);

    test('Pendientes + VIP = sólo los pendientes con VIP', () {
      expect(visible(InboxView.pendientes, ChatFilter.etiqueta, vipPendiente), isTrue);
      expect(visible(InboxView.pendientes, ChatFilter.etiqueta, vipListo), isFalse);
      expect(visible(InboxView.pendientes, ChatFilter.etiqueta, otroPendiente), isFalse);
    });

    test('Listos + VIP y Todos + VIP', () {
      expect(visible(InboxView.listos, ChatFilter.etiqueta, vipListo), isTrue);
      expect(visible(InboxView.listos, ChatFilter.etiqueta, vipPendiente), isFalse);
      expect(visible(InboxView.todos, ChatFilter.etiqueta, vipListo), isTrue);
      expect(visible(InboxView.todos, ChatFilter.etiqueta, vipPendiente), isTrue);
    });

    test('Con notas también se combina', () {
      final notaListo = {'note': 'Quiere cita'};
      expect(chatIsVisible(InboxView.pendientes, ChatFilter.conNotas, notaListo), isFalse);
      expect(chatIsVisible(InboxView.listos, ChatFilter.conNotas, notaListo), isTrue);
    });

    test('Seguimiento ignora la vista: la cola del agente mezcla pendientes y listos', () {
      final encoladoListo = {'followup_status': 'queued'};
      final encoladoPendiente = {'followup_status': 'queued', 'unresponded_count': 1};
      for (final v in InboxView.values) {
        expect(chatIsVisible(v, ChatFilter.seguimiento, encoladoListo), isTrue, reason: '$v');
        expect(chatIsVisible(v, ChatFilter.seguimiento, encoladoPendiente), isTrue, reason: '$v');
        expect(chatIsVisible(v, ChatFilter.seguimiento, {'unresponded_count': 1}), isFalse,
            reason: '$v');
      }
    });

    test('sin chip, manda sólo la vista', () {
      expect(chatIsVisible(InboxView.pendientes, null, vipPendiente), isTrue);
      expect(chatIsVisible(InboxView.pendientes, null, vipListo), isFalse);
    });
  });

  group('el buscador encuentra al cliente esté como esté', () {
    test('con texto, la vista no acota', () {
      for (final entry in chats.entries) {
        for (final v in InboxView.values) {
          expect(chatIsVisible(v, null, entry.value, searching: true), isTrue,
              reason: '${entry.key} en $v');
        }
      }
    });

    test('Con notas y etiquetas sí acotan la búsqueda, como siempre', () {
      expect(
          chatIsVisible(InboxView.todos, ChatFilter.conNotas, {'note': '  '}, searching: true),
          isFalse);
      expect(
        chatIsVisible(InboxView.listos, ChatFilter.etiqueta, {'labelIds': ['b']},
            labelId: 'a', knownLabelIds: {'a', 'b'}, searching: true),
        isFalse,
      );
    });
  });

  group('cada chip por sí solo, igual que antes', () {
    test('Seguimiento: sólo los encolados por el agente', () {
      expect(matchesChip(ChatFilter.seguimiento, {'followup_status': 'queued'}), isTrue);
      expect(matchesChip(ChatFilter.seguimiento, {'followup_status': 'sent'}), isFalse);
      expect(matchesChip(ChatFilter.seguimiento, null), isFalse);
    });

    test('Con notas: una nota en blanco no cuenta', () {
      expect(matchesChip(ChatFilter.conNotas, {'note': 'Quiere cita'}), isTrue);
      expect(matchesChip(ChatFilter.conNotas, {'note': '   '}), isFalse);
      expect(matchesChip(ChatFilter.conNotas, {}), isFalse);
    });

    test('etiqueta: filtra por la activa; una borrada del catálogo no oculta nada', () {
      final chat = {'labelIds': ['vip']};
      expect(matchesChip(ChatFilter.etiqueta, chat, labelId: 'vip', knownLabelIds: {'vip'}),
          isTrue);
      expect(matchesChip(ChatFilter.etiqueta, {}, labelId: 'vip', knownLabelIds: {'vip'}),
          isFalse);
      expect(matchesChip(ChatFilter.etiqueta, {}, labelId: 'borrada', knownLabelIds: {'vip'}),
          isTrue);
    });
  });

  group('la vista guardada', () {
    test('ida y vuelta para las tres vistas', () {
      for (final v in InboxView.values) {
        expect(inboxViewFromPref(inboxViewPref(v)), v);
      }
    });

    test('los valores guardados no cambian (los leen las apps instaladas)', () {
      expect(inboxViewPref(InboxView.todos), 'todos');
      expect(inboxViewPref(InboxView.pendientes), 'pendientes');
      expect(inboxViewPref(InboxView.listos), 'listos');
    });

    test('sin valor o con uno desconocido abre en Todos', () {
      expect(inboxViewFromPref(null), InboxView.todos);
      expect(inboxViewFromPref(''), InboxView.todos);
      expect(inboxViewFromPref('asignados'), InboxView.todos);
    });
  });
}
