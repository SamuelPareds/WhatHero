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

/// Chip neutro para la nota/comentario de un chat. El icono de nota basta como
/// señal: el texto va en `lightText` (igual que el último mensaje) para no
/// recargar el tile con color. Trunca con maxWidth para no romper el layout
/// cuando la nota es larga.
class NoteChip extends StatelessWidget {
  final String note;
  final bool compact;
  final double maxWidth;

  const NoteChip({
    required this.note,
    this.compact = false,
    this.maxWidth = 150,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final padH = compact ? 8.0 : 10.0;
    final padV = compact ? 2.0 : 4.0;
    final fontSize = compact ? 10.0 : 12.0;
    final iconSize = compact ? 11.0 : 13.0;

    // Chip neutro: fondo tenue y texto/icono en lightText, igual que el último
    // mensaje. El icono de nota es la señal; el color queda reservado para las
    // etiquetas, evitando recargar el tile.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        decoration: BoxDecoration(
          color: white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(compact ? 6 : 8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined,
                size: iconSize, color: lightText),
            SizedBox(width: compact ? 3 : 4),
            Flexible(
              child: Text(
                note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: lightText,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renderiza una fila de chips a partir de una lista de IDs y un mapa del
/// catálogo cargado. IDs que no existan en el catálogo se ignoran (puede pasar
/// si la etiqueta fue eliminada después de asignarse). El parámetro [trailing]
/// permite añadir un widget extra (p. ej. el NoteChip) en la misma fila Wrap,
/// conservando la lógica de overflow de las etiquetas.
class LabelChipsRow extends StatelessWidget {
  final List<String> labelIds;
  final Map<String, ChatLabel> catalog;
  final bool compact;
  final int? maxVisible;
  final VoidCallback? onOverflowTap;
  final Widget? trailing;

  const LabelChipsRow({
    required this.labelIds,
    required this.catalog,
    this.compact = false,
    this.maxVisible,
    this.onOverflowTap,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = labelIds
        .map((id) => catalog[id])
        .whereType<ChatLabel>()
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    // Sin etiquetas ni trailing no hay nada que pintar.
    if (resolved.isEmpty && trailing == null) return const SizedBox.shrink();

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
        if (trailing != null) trailing!,
      ],
    );
  }
}
