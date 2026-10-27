import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

/// Cómo se ve una sesión (tarjeta de Mis Cuentas y selector de cuenta del
/// título), derivado de `status` + `last_sync`.
///
/// No basta con leer `status`: ese campo lo escribe el backend y, si el backend
/// se cae o pierde el hilo de una sesión, el doc queda congelado en lo último
/// que alcanzó a decir. El 03-sep-2026 una sesión pasó 26 horas mostrando
/// "Reconectando..." con un spinner girando sobre algo que ya no estaba pasando.
///
/// Por eso se cruza con `last_sync`: mientras una sesión está reconectando, el
/// watchdog del backend refresca ese timestamp cada 2 minutos. Si lleva más de
/// [_staleAfter] sin latir, el que se cayó fue el backend — y el spinner deja de
/// prometer una reconexión que nadie está intentando.
///
/// Tests en `test/session_switch_test.dart`.
class SessionVisual {
  final String label;
  final Color color;
  final bool showSpinner;
  final bool isConnected;

  const SessionVisual({
    required this.label,
    required this.color,
    this.showSpinner = false,
    this.isConnected = false,
  });

  /// Holgado respecto al heartbeat de 2 min del backend: tres latidos perdidos
  /// antes de desconfiar, para no acusar de muerto a un backend que sólo tuvo
  /// un mal minuto.
  static const _staleAfter = Duration(minutes: 5);

  factory SessionVisual.from(
    String? status,
    DateTime? lastSync, {
    bool deleting = false,
    DateTime? now,
  }) {
    // Gana sobre cualquier status: el owner la mandó eliminar y el backend
    // está borrando todo lo suyo. La tarjeta desaparece sola al terminar.
    if (deleting) {
      return const SessionVisual(label: 'Eliminando…', color: lightText, showSpinner: true);
    }

    if (status == 'connected') {
      return const SessionVisual(label: 'Conectado', color: accentAqua, isConnected: true);
    }

    if (status == 'reconnecting') {
      final stale = lastSync == null || (now ?? DateTime.now()).difference(lastSync) > _staleAfter;
      return stale
          ? SessionVisual(label: 'Sin respuesta', color: Colors.orange.shade400)
          : SessionVisual(label: 'Reconectando...', color: Colors.orange.shade400, showSpinner: true);
    }

    if (status == 'reconnect_failed') {
      // El backend sigue reintentando de fondo, pero ya lleva rato caída: se
      // dice tal cual y se ofrece la salida manual.
      return SessionVisual(label: 'Sin conexión', color: Colors.red.shade400);
    }

    return SessionVisual(label: 'Desvinculado', color: Colors.red.shade400);
  }
}
