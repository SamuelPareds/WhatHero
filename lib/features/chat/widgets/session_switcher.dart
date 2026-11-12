import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/features/accounts/session_switch.dart';

/// El título de la lista de chats: la sesión que se ve y el desplegable para
/// cambiar de cuenta en dos toques o ir a "Gestionar cuentas".
///
/// El menú existe también con una sola sesión: es la única entrada a Mis
/// Cuentas desde la lista (vincular otro número, miembros, llaves de API y
/// cerrar sesión). Sin él, quien tiene una sola cuenta no tendría salida.
///
/// El cambio no lo hace este widget: lo pide con [onSelected] y lo aplica el
/// SessionDispatcher, el único que decide qué sesión se ve (ver CLAUDE.md,
/// "🔀 Cambiar de cuenta").
///
/// Tests en `test/session_switcher_test.dart`.
class SessionSwitcher extends StatelessWidget {
  final SessionOption current;

  /// Las que el usuario puede abrir, ya ordenadas (ver `visibleSessionOptions`).
  final List<SessionOption> sessions;
  final ValueChanged<String> onSelected;
  final VoidCallback onManage;

  /// Badge de pendientes de cada fila. Se construye sólo con el menú abierto:
  /// sin listeners permanentes sobre las otras cuentas. Inyectado para poder
  /// probar el widget sin Firestore.
  final Widget Function(String sessionId)? pendingBadge;

  const SessionSwitcher({
    required this.current,
    required this.sessions,
    required this.onSelected,
    required this.onManage,
    this.pendingBadge,
    super.key,
  });

  // Los ids de sesión son dígitos: no puede chocar con uno.
  static const _manageValue = '__manage__';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: sessions.length > 1 ? 'Cambiar de cuenta' : 'Cuentas',
      position: PopupMenuPosition.under,
      color: surfaceDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      onSelected: (value) {
        if (value == _manageValue) {
          onManage();
        } else if (value != current.id) {
          onSelected(value);
        }
      },
      itemBuilder: (_) => [
        for (final s in sessions)
          PopupMenuItem<String>(
            value: s.id,
            height: 56,
            child: _SessionRow(
              session: s,
              selected: s.id == current.id,
              badge: pendingBadge?.call(s.id),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: _manageValue,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.manage_accounts_outlined, size: 20, color: primaryAqua),
              SizedBox(width: 12),
              Text('Gestionar cuentas', style: TextStyle(color: white, fontSize: 14)),
            ],
          ),
        ),
      ],
      child: _title(),
    );
  }

  Widget _title() {
    final visual = current.visual;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                current.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: white),
              ),
            ),
            // Siempre: es lo que dice que el título se toca.
            const Icon(Icons.expand_more, size: 20, color: lightText),
          ],
        ),
        // Conectada: el número que usa hoy (no el id: tras un cambio de número
        // son distintos). Caída: cómo está, en su color. Antes la app saltaba
        // a otra cuenta; ahora se queda y lo dice.
        Text(
          visual.isConnected ? displayPhone(current.phone) : visual.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: visual.isConnected ? lightText : visual.color,
            fontWeight: visual.isConnected ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final SessionOption session;
  final bool selected;
  final Widget? badge;

  const _SessionRow({required this.session, required this.selected, this.badge});

  @override
  Widget build(BuildContext context) {
    final visual = session.visual;
    final initial = session.name.characters.isEmpty
        ? '?'
        : session.name.characters.first.toUpperCase();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // La misma tarjeta de Mis Cuentas en chico: inicial en el color de su
        // estado y los pendientes encima.
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: visual.color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: TextStyle(color: visual.color, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            if (badge != null) Positioned(top: -7, right: -9, child: badge!),
          ],
        ),
        const SizedBox(width: 14),
        // Flexible: el menú mide como máximo 320 px y los alias pueden ser largos.
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: white,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              Text.rich(
                TextSpan(
                  text: displayPhone(session.phone),
                  children: [
                    if (!visual.isConnected)
                      TextSpan(text: ' · ${visual.label}', style: TextStyle(color: visual.color)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: lightText, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 20,
          child: selected ? const Icon(Icons.check, size: 18, color: primaryAqua) : null,
        ),
      ],
    );
  }
}
