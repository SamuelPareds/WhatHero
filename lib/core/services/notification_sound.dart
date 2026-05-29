// Fachada del sonido de notificación con selección por plataforma.
//
// Web → `notification_sound_web.dart`: beep sintetizado con Web Audio API.
//   Sin assets, sin `just_audio`, sin el bug de "solo suena una vez" (cada
//   beep crea un OscillatorNode nuevo y descartable).
// Móvil/otros → `notification_sound_stub.dart`: no-op. Android ya tiene su
//   sonido desde el canal FCM; no queremos tocar ese comportamiento.
//
// El import condicional resuelve `package:web` SOLO en builds web, así el
// compilador de Android/iOS nunca ve esas APIs.
export 'notification_sound_stub.dart'
    if (dart.library.js_interop) 'notification_sound_web.dart';
