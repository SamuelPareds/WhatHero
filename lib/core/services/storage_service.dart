import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _keyLastSessionId = 'last_session_id';

  // Singleton pattern
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  Future<void> saveLastSessionId(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastSessionId, sessionId);
    print('[StorageService] SessionId guardado: $sessionId');
  }

  Future<String?> getLastSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString(_keyLastSessionId);
    print('[StorageService] SessionId recuperado: $sessionId');
    return sessionId;
  }

  /// Olvida la última sesión sólo si es [sessionId]. La usa la eliminación de
  /// una sesión: la sesión preferida de este dispositivo ya no existe.
  Future<void> clearLastSessionIdIf(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_keyLastSessionId) == sessionId) {
      await prefs.remove(_keyLastSessionId);
    }
  }

  Future<void> clearLastSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLastSessionId);
    print('[StorageService] SessionId limpiado');
  }
}
