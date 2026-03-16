import 'package:flutter/foundation.dart';

/// Get backend URL based on platform and build mode
/// - Release: Railway production
/// - Web/iOS/macOS: localhost:3000
/// - Android emulator: 10.0.2.2:3000 (host machine access)
String get backendUrl {
  if (kReleaseMode) {
    return 'https://whathero-production.up.railway.app';
  }

  if (kIsWeb) {
    return 'http://localhost:3000';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000';
  }
  return 'http://localhost:3000';
}
