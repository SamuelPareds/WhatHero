import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core.dart';

/// Chip compacto de etiqueta. Dos tamaños: compact para tiles (lista) y normal
/// para el strip del MessagesView. El color del chip lo da la propia etiqueta;
/// el texto se calcula con luminance para mantener contraste legible.
class LabelChip extends StatelessWidget {
  final ChatLabel label;
  final bool compact;
  final VoidCallback? onTap;

  const LabelChip({
    required this.label,
    this.compact = false,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final fg = _foregroundFor(label.color);
    final padH = compact ? 8.0 : 10.0;
    final padV = compact ? 2.0 : 4.0;
    final fontSize = compact ? 10.0 : 12.0;

    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: label.color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: Text(
        label.name,
        style: TextStyle(
          color: fg,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );

    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(compact ? 6 : 8),
      child: chip,
    );
  }

  // Texto blanco sobre colores oscuros, casi negro sobre claros.
  static Color _foregroundFor(Color bg) {
    return bg.computeLuminance() > 0.55 ? const Color(0xFF0F172A) : Colors.white;
  }
}

/// Renderiza una fila de chips a partir de una lista de IDs y un mapa del
/// catálogo cargado. IDs que no existan en el catálogo se ignoran (puede pasar
/// si la etiqueta fue eliminada después de asignarse).
class LabelChipsRow extends StatelessWidget {
  final List<String> labelIds;
  final Map<String, ChatLabel> catalog;
  final bool compact;
  final int? maxVisible;
  final VoidCallback? onOverflowTap;

  const LabelChipsRow({
    required this.labelIds,
    required this.catalog,
    this.compact = false,
    this.maxVisible,
    this.onOverflowTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = labelIds
        .map((id) => catalog[id])
        .whereType<ChatLabel>()
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    if (resolved.isEmpty) return const SizedBox.shrink();

    final visible = maxVisible == null || resolved.length <= maxVisible!
        ? resolved
        : resolved.sublist(0, maxVisible!);
    final hidden = resolved.length - visible.length;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        ...visible.map((l) => LabelChip(label: l, compact: compact)),
        if (hidden > 0)
          GestureDetector(
            onTap: onOverflowTap,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 2 : 4,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(compact ? 6 : 8),
              ),
              child: Text(
                '+$hidden',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: compact ? 10 : 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
