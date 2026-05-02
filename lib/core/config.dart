import 'package:flutter/foundation.dart';

/// Get backend URL based on platform and build mode
/// - Release: Railway production
/// - Web/iOS/macOS: localhost:3000
/// - Android emulator: 10.0.2.2:3000 (host machine access)
String get backendUrl {
  if (kReleaseMode) {
    return 'https://whathero.up.railway.app';
  }

  if (kIsWeb) {
    return 'http://localhost:3000';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000';
  }
  return 'http://localhost:3000';
}

/// Colección raíz en Firestore según el modo de compilación.
/// - Release (prod): "accounts"  → compartido con el backend de Railway (NODE_ENV=production)
/// - Debug (dev):    "accounts_dev" → compartido con el backend local (NODE_ENV=development)
///
/// Esto evita que el entorno de desarrollo lea/escriba sobre las sesiones
/// reales de producción.
String get accountsCollection => kReleaseMode ? 'accounts' : 'accounts_dev';

/// VAPID key pública para Web Push (FCM).
///
/// Se obtiene UNA SOLA VEZ en:
///   Firebase Console → Project Settings → Cloud Messaging
///   → Web configuration → Web Push certificates → "Generate key pair"
///
/// Es pública (no secreta): el browser la usa para verificar que los pushes
/// vienen del servidor que se identifica con este par de llaves. Aún así
/// no la commiteamos hardcodeada en producción si alguna vez rotamos el
/// par; por ahora vive aquí como constante hasta que crezca la necesidad.
const String fcmVapidKey = 'BChnSj7rB6DfIZB5tmNchAw3EdxuE0OYuR6JsxSX4cxzYZy7phbXrPABGiAb5bfOa1ktTlzjT0Ssnqlr7hC-K5k';
