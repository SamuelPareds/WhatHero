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

  Future<void> clearLastSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLastSessionId);
    print('[StorageService] SessionId limpiado');
  }
}
