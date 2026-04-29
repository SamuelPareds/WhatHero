import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/ai_state_service.dart';

/// Indicador visual del ciclo de IA: spinner aqua + leyenda corta.
/// Tres variantes según `AiChatState`:
/// - buffering  → "esperando…"   (la IA está dejando que el cliente termine)
/// - thinking   → "pensando…"    (corriendo discriminador o generación)
/// - responding → "respondiendo…" (mandando chunks; momento crítico para interceptar)
class AiStateIndicator extends StatelessWidget {
  final AiChatState state;
  final bool compact;

  const AiStateIndicator({
    required this.state,
    this.compact = false,
    super.key,
  });

  String get _label {
    switch (state) {
      case AiChatState.buffering:
        return 'esperando…';
      case AiChatState.thinking:
        return 'pensando…';
      case AiChatState.responding:
        return 'respondiendo…';
      case AiChatState.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (state == AiChatState.idle) return const SizedBox.shrink();

    final spinnerSize = compact ? 12.0 : 14.0;
    final fontSize = compact ? 10.0 : 11.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: spinnerSize,
          height: spinnerSize,
          child: const CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _label,
          style: TextStyle(
            color: primaryAqua,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
      ],
    );
  }
}
