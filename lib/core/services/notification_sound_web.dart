// Beep de notificación para web con la Web Audio API.
//
// Por qué así y no `just_audio` + asset:
//  - El intento previo con just_audio "solo sonaba una vez": tras terminar, el
//    player queda parado en la posición final y un segundo play() es no-op si
//    no se hace seek(0). Aquí cada beep crea un OscillatorNode NUEVO y
//    descartable, así que suena siempre, sin estado que resetear.
//  - Sin archivo de audio: el tono se genera en runtime. Cero assets, cero
//    latencia de carga, alineado con la regla de minimalismo.
//
// Política de autoplay: el AudioContext nace "suspended" hasta que haya un
// gesto del usuario. `unlockNotificationAudio()` lo reanuda desde un handler
// de pointer; como el operador interactúa con el CRM todo el día, queda
// desbloqueado de inmediato.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

// Único AudioContext reutilizado para toda la sesión. Crear uno por beep
// dispararía el límite de contextos del navegador.
web.AudioContext? _ctx;

web.AudioContext _context() => _ctx ??= web.AudioContext();

/// Reanuda el AudioContext. Debe llamarse dentro de un gesto del usuario
/// (click/tap/tecla) para satisfacer la política de autoplay del navegador.
void unlockNotificationAudio() {
  final ctx = _context();
  if (ctx.state == 'suspended') {
    ctx.resume();
  }
}

// Evita registrar el listener del Service Worker más de una vez.
bool _bridgeReady = false;

/// Registra el puente Service Worker → página: cuando la ventana está
/// minimizada (pestaña oculta), el push lo maneja el SW, no `onMessage`. El SW
/// nos hace `postMessage({type:'whathero_play_sound'})` y aquí reproducimos el
/// beep con el AudioContext ya desbloqueado. Idempotente.
void initBackgroundSoundBridge() {
  if (_bridgeReady) return;
  _bridgeReady = true;

  web.window.navigator.serviceWorker.addEventListener(
    'message',
    (web.Event event) {
      final data = (event as web.MessageEvent).data;
      // Solo reaccionamos a NUESTRO mensaje; otros postMessage se ignoran.
      if (data.isA<JSObject>()) {
        final type = (data as JSObject).getProperty<JSString?>('type'.toJS);
        if (type?.toDart == 'whathero_play_sound') {
          playNotificationBeep();
        }
      }
    }.toJS,
  );
}

/// Reproduce un beep corto de dos tonos (estilo notificación discreta).
void playNotificationBeep() {
  final ctx = _context();
  // Reintentamos reanudar por si el desbloqueo aún no había ocurrido.
  if (ctx.state == 'suspended') {
    ctx.resume();
  }
  final now = ctx.currentTime.toDouble();
  // Dos tonos encadenados: sube de 880Hz a 1320Hz, como un "ding-ding".
  _tone(ctx, now, 880, 0.0, 0.16);
  _tone(ctx, now, 1320, 0.15, 0.22);
}

// Genera un tono: oscilador senoidal + envolvente de ganancia para evitar el
// "click" de inicio/fin abrupto. Se autodestruye al detenerse.
void _tone(
  web.AudioContext ctx,
  double start,
  double freq,
  double offset,
  double dur,
) {
  final osc = ctx.createOscillator();
  final gain = ctx.createGain();
  osc.type = 'sine';
  osc.frequency.value = freq;

  final t0 = start + offset;
  // Envolvente: ataque rápido a 0.22 y caída exponencial casi a 0.
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(0.22, t0 + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);

  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.02);
}
