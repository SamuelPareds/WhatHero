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
