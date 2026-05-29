// Implementación no-op para plataformas no-web (Android/iOS/desktop).
// Android obtiene su sonido del canal FCM; aquí no hay nada que hacer.

/// Desbloquea el audio tras un gesto del usuario. No-op fuera de web.
void unlockNotificationAudio() {}

/// Reproduce el beep de notificación. No-op fuera de web.
void playNotificationBeep() {}

/// Registra el puente Service Worker → página para sonar con la ventana
/// minimizada. No-op fuera de web.
void initBackgroundSoundBridge() {}
