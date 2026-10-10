import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';

/// Cómo terminó una vinculación por QR. Lo devuelve `LinkAccountScreen` al
/// cerrarse (null = el usuario salió antes de escanear).
class LinkResult {
  /// Número realmente vinculado.
  final String phone;

  /// Doc de sesión al que quedó escribiendo. Tras un cambio de número no es
  /// [phone]: es el de la sesión que adoptó el número nuevo.
  final String? sessionId;

  /// != null → el backend no aceptó ese número para esa sesión (ver
  /// backend/src/services/sessionTarget.ts) y ya cerró la vinculación.
  final String? rejectedReason;

  /// Número anterior, si la sesión cambió de número.
  final String? numberChangedFrom;

  /// 'followups' / 'reminders' que quedaron pausados por el cambio.
  final List<String> pausedAutomations;

  /// Qué pasó con el número anterior: 'kept' (sigue recibiendo),
  /// 'disconnected' o null (no estaba conectado).
  final String? previousLine;

  const LinkResult({
    required this.phone,
    this.sessionId,
    this.rejectedReason,
    this.numberChangedFrom,
    this.pausedAutomations = const [],
    this.previousLine,
  });

  factory LinkResult.fromEvent(SessionStatusEvent event) {
    final data = event.data;
    final paused = data['pausedAutomations'];
    return LinkResult(
      phone: event.phoneNumber ?? '',
      sessionId: data['sessionId'] as String?,
      rejectedReason: event.status == 'link_rejected' ? (data['reason'] as String? ?? 'error') : null,
      numberChangedFrom: data['numberChangedFrom'] as String?,
      pausedAutomations: paused is List ? paused.whereType<String>().toList() : const [],
      previousLine: data['previousLine'] as String?,
    );
  }

  bool get rejected => rejectedReason != null;
  bool get numberChanged => numberChangedFrom != null;

  /// El rechazo explicado para cualquier persona.
  String get rejectionMessage {
    final number = displayPhone(phone);
    switch (rejectedReason) {
      case 'wrong_number':
        return 'Escaneaste con $number, que no es el número de esta sesión. '
            'Si cambiaste de número, elige “Uno nuevo”.';
      case 'has_history':
        return '$number ya tiene chats propios en WhatHero. '
            'Por ahora no podemos juntar dos historiales en una sola sesión.';
      case 'in_use':
        return '$number ya es el número de otra de tus sesiones.';
      case 'number_replaced':
        return '$number fue reemplazado por otro número en una de tus sesiones. '
            'No puede volver como una línea aparte.';
      case 'stale':
        return 'El número de esta sesión cambió mientras escaneabas. Vuelve a intentarlo.';
      case 'not_found':
        return 'Esa sesión ya no existe.';
      default:
        return 'No pudimos completar la vinculación. Vuelve a intentarlo.';
    }
  }
}

/// Nombre para el operador de cada automático que se pausa al cambiar de número.
String automationLabel(String name) => switch (name) {
      'followups' => 'Seguimientos automáticos',
      'reminders' => 'Recordatorios',
      _ => name,
    };
