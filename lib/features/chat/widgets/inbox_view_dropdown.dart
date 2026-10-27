import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

import '../chat_filter.dart';

/// La vista principal de la lista de chats (Todos / Pendientes / Listos), como
/// desplegable al inicio de la fila de chips. Siempre resaltada: los chips de
/// al lado filtran DENTRO de ella (ver `chatIsVisible`).
///
/// Tests en `test/inbox_view_dropdown_test.dart`.
class InboxViewDropdown extends StatelessWidget {
  final InboxView view;
  // Total de pendientes de la sesión, sin chips: en la píldora sólo con la
  // vista Pendientes (al lado de "Todos" se leería como el total de chats);
  // en el menú, siempre.
  final int pendingCount;
  // Con Seguimiento activo la vista no aplica (la cola del agente se ve
  // entera), así que la píldora se apaga para no prometer un filtro que no
  // está filtrando. Sigue abriendo el menú: elegir una vista sale de
  // Seguimiento.
  final bool dimmed;
  final ValueChanged<InboxView> onSelected;

  const InboxViewDropdown({
    required this.view,
    required this.pendingCount,
    required this.onSelected,
    this.dimmed = false,
    super.key,
  });

  static String labelOf(InboxView view) => switch (view) {
        InboxView.todos => 'Todos',
        InboxView.pendientes => 'Pendientes',
        InboxView.listos => 'Listos',
      };

  static String _hintOf(InboxView view) => switch (view) {
        InboxView.todos => 'Toda la bandeja',
        InboxView.pendientes => 'Esperan respuesta',
        InboxView.listos => 'Ya no esperan respuesta',
      };

  @override
  Widget build(BuildContext context) {
    final Color bg = dimmed ? surfaceDark.withValues(alpha: 0.6) : primaryAqua;
    final Color fg = dimmed ? lightText : darkBg;
    final showCount = view == InboxView.pendientes && pendingCount > 0;

    return Center(
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: PopupMenuButton<InboxView>(
          tooltip: 'Cambiar vista',
          initialValue: view,
          onSelected: onSelected,
          position: PopupMenuPosition.under,
          color: surfaceDark,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          itemBuilder: (_) => [
            for (final v in InboxView.values)
              PopupMenuItem(value: v, child: _menuRow(v)),
          ],
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: dimmed ? white.withValues(alpha: 0.08) : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  labelOf(view),
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: dimmed ? FontWeight.w500 : FontWeight.w700,
                  ),
                ),
                if (showCount) ...[
                  const SizedBox(width: 6),
                  _CountPill(count: pendingCount, color: fg),
                ],
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 18, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuRow(InboxView v) {
    final selected = v == view;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          child: selected
              ? const Icon(Icons.check, size: 18, color: primaryAqua)
              : null,
        ),
        const SizedBox(width: 10),
        // Flexible: el menú mide 256 px como máximo y con el texto agrandado
        // del sistema la descripción no cabría.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                labelOf(v),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: white,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              Text(
                _hintOf(v),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: lightText, fontSize: 12),
              ),
            ],
          ),
        ),
        if (v == InboxView.pendientes && pendingCount > 0) ...[
          const SizedBox(width: 16),
          _CountPill(count: pendingCount, color: lightText),
        ],
      ],
    );
  }
}

// Mismo badge neutro que los chips de filtro: el color del texto sobre un
// pill tenue del mismo tono.
class _CountPill extends StatelessWidget {
  final int count;
  final Color color;

  const _CountPill({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
