import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core/theme.dart';

// Piezas del panel de Ajustes de Sesión que no dependen de Firebase, para
// poder probarlas solas (test/session_settings_fields_test.dart). Ver
// CLAUDE.md, "⚙️ Ajustes de sesión".

const minResponseDelaySeconds = 8;
const maxResponseDelaySeconds = 30;
const recommendedResponseDelaySeconds = 20;
const defaultResponseDelaySeconds = 15;

const defaultAiProvider = 'gemini';
const defaultSystemPrompt = 'Eres un asistente útil.';
const defaultReminderTemplate =
    '¡Hola {name}! 🌸\n\nTe recordamos tu cita para mañana a las {time}.';

// Modelo por defecto al cambiar de proveedor (el "Recomendado" de cada uno).
String defaultModelFor(String? provider) {
  switch (provider) {
    case 'openai':
      return 'gpt-4.1-mini';
    case 'deepseek':
      return 'deepseek-v4-flash';
    default:
      return 'gemini-2.5-flash';
  }
}

// Firestore guarda milisegundos y el slider trabaja en segundos enteros dentro
// de su rango. Un valor viejo (1500 ms) o ausente se muestra ajustado.
int responseDelaySecondsFrom(Object? raw) {
  if (raw is num && raw.isFinite) {
    return (raw / Duration.millisecondsPerSecond)
        .round()
        .clamp(minResponseDelaySeconds, maxResponseDelaySeconds);
  }
  return defaultResponseDelaySeconds;
}

/// Campos que el panel MUESTRA con un valor que el doc no tiene, porque falta
/// o porque el panel lo ajustó. Se mezclan en la primera escritura del panel.
///
/// Sin esto, guardar campo por campo dejaría al backend con sus propios
/// defaults, que no son los que el operador vio: sin `ai_response_delay_ms`
/// usa 1 500 ms, y activar la IA en una sesión nueva la dejaría respondiendo
/// a los 1,5 s mientras el slider dice 15 s. El botón global de antes lo
/// tapaba porque reescribía la pantalla entera.
Map<String, Object> sessionSettingsDisplayGaps(Map<String, dynamic> data) {
  final gaps = <String, Object>{};
  final rawDelay = data['ai_response_delay_ms'];
  final shownDelayMs =
      responseDelaySecondsFrom(rawDelay) * Duration.millisecondsPerSecond;
  if (rawDelay != shownDelayMs) gaps['ai_response_delay_ms'] = shownDelayMs;

  final provider = data['ai_provider'] as String?;
  if (provider == null) gaps['ai_provider'] = defaultAiProvider;
  if (data['ai_model'] == null) {
    gaps['ai_model'] = defaultModelFor(provider ?? defaultAiProvider);
  }
  if (data['ai_system_prompt'] == null) {
    gaps['ai_system_prompt'] = defaultSystemPrompt;
  }
  if (data['reminder_template'] == null) {
    gaps['reminder_template'] = defaultReminderTemplate;
  }
  return gaps;
}

/// Controller de un campo de texto de Ajustes que se guarda con su propio
/// botón. Sabe qué hay guardado (`saved`) para decir si hay cambios, y nunca
/// pisa lo que el operador está escribiendo cuando llega un snapshot.
class DraftTextController extends TextEditingController {
  DraftTextController({required this.field, required this.label});

  /// Campo del doc de sesión.
  final String field;

  /// Nombre para los avisos ("No se pudo guardar Alias").
  final String label;

  String _saved = '';
  bool _saving = false;
  Future<void>? _pending;
  bool _disposed = false;

  String get saved => _saved;
  bool get isSaving => _saving;
  String get trimmed => text.trim();
  bool get isDirty => trimmed != _saved;

  /// Lo que dice el servidor. Sólo toca el texto si el valor guardado cambió
  /// de verdad y el campo no tiene cambios ni se está guardando: un snapshot
  /// (propio, de otro operador o el rollback de una escritura rechazada) no
  /// puede borrar un borrador, ni comerse el espacio que se acaba de teclear.
  void applyServer(String serverValue) {
    if (serverValue == _saved) return;
    final keepText = _saving || isDirty;
    _saved = serverValue;
    if (keepText) {
      _notify();
    } else {
      text = serverValue; // notifica
    }
  }

  /// Escribe el valor con [write]. Si falla, el texto se queda y el campo
  /// vuelve a "Sin guardar", llegue el rollback del listener antes o después
  /// del error. Un segundo `save` con uno en vuelo espera a ese.
  Future<void> save(Future<void> Function(String value) write) =>
      _pending ??= _save(write).whenComplete(() => _pending = null);

  Future<void> _save(Future<void> Function(String value) write) async {
    final before = _saved;
    final attempted = trimmed;
    _saving = true;
    _notify();
    try {
      await write(attempted);
      _saved = attempted;
    } catch (_) {
      _saved = before;
      rethrow;
    } finally {
      _saving = false;
      _notify();
    }
  }

  // Un guardado puede terminar con el panel ya cerrado.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void discard() => text = _saved;
}

/// "Sin guardar · Descartar · Guardar" debajo de un campo. Sólo se ve con
/// cambios, y escucha al controller: no rebuildea el panel con cada tecla.
class DraftSaveBar extends StatelessWidget {
  const DraftSaveBar({required this.controller, required this.onSave, super.key});

  final DraftTextController controller;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isDirty && !controller.isSaving) {
          return const SizedBox.shrink();
        }
        final saving = controller.isSaving;
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Sin guardar',
                  style: TextStyle(color: collisionAmber, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: saving ? null : controller.discard,
                child: const Text('Descartar', style: TextStyle(color: lightText)),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: saving ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  visualDensity: VisualDensity.compact,
                ),
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: darkBg),
                      )
                    : const Text('Guardar', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );
  }
}
