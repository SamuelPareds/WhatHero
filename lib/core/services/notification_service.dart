import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Payload normalizado de una notificación push de "atención humana".
/// Lo mínimo que la UI necesita para mostrar un banner o hacer deep-link.
class HumanAttentionPush {
  final String accountId;
  final String sessionPhone;
  final String? sessionKey;
  final String chatId;
  final String? reason;
  final String? title;
  final String? body;

  HumanAttentionPush({
    required this.accountId,
    required this.sessionPhone,
    required this.chatId,
    this.sessionKey,
    this.reason,
    this.title,
    this.body,
  });

  factory HumanAttentionPush.fromMessage(RemoteMessage m) {
    final data = m.data;
    return HumanAttentionPush(
      accountId: (data['accountId'] ?? '').toString(),
      sessionPhone: (data['sessionPhone'] ?? '').toString(),
      sessionKey: data['sessionKey']?.toString(),
      chatId: (data['chatId'] ?? '').toString(),
      reason: data['reason']?.toString(),
      title: m.notification?.title,
      body: m.notification?.body,
    );
  }

  bool get isValid => accountId.isNotEmpty && chatId.isNotEmpty;
}

/// Servicio singleton para FCM. Misma forma que SocketService:
/// - init(accountId) idempotente, único punto de entrada post-login.
/// - Streams para foreground (banner) y tap (deep-link).
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Clave en shared_preferences para el deviceId estable por instalación.
  static const _kDeviceIdKey = 'notif_device_id';

  String? _currentAccountId;
  String? _deviceId;
  String? _currentToken;

  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _onOpenSub;

  // Foreground: la UI muestra un banner in-app aqua.
  final _foregroundController =
      StreamController<HumanAttentionPush>.broadcast();
  Stream<HumanAttentionPush> get foregroundStream =>
      _foregroundController.stream;

  // Tap en notificación: la UI navega al chat.
  final _tapController = StreamController<HumanAttentionPush>.broadcast();
  Stream<HumanAttentionPush> get tapStream => _tapController.stream;

  // Cold-start tap: completer que resuelve cuando init() determinó si la app
  // abrió desde un tap (con la data del push) o no (null). Usamos Future en
  // vez de "consume-once" para evitar la race entre ChatsScreen.initState y
  // FirebaseMessaging.getInitialMessage(): el widget puede await tranquilo.
  Completer<HumanAttentionPush?>? _initialTapCompleter;

  /// Future que resuelve con el push que abrió la app (cold-start) o null si
  /// la app abrió normalmente. Seguro de await desde cualquier widget; si
  /// init() todavía no fue llamado, espera. Idempotente: múltiples awaits OK.
  Future<HumanAttentionPush?> get initialTapReady {
    _initialTapCompleter ??= Completer<HumanAttentionPush?>();
    return _initialTapCompleter!.future;
  }

  void _completeInitialTap(HumanAttentionPush? push) {
    _initialTapCompleter ??= Completer<HumanAttentionPush?>();
    if (!_initialTapCompleter!.isCompleted) {
      _initialTapCompleter!.complete(push);
    }
  }

  /// Inicializa el servicio para un usuario. Por ahora solo Android.
  /// Web → Fase 2 (requiere VAPID + service worker).
  /// iOS → Fase 3 (requiere APNs Auth Key).
  Future<void> init(String accountId) async {
    if (_currentAccountId == accountId && _currentToken != null) {
      debugPrint('[NotificationService] Ya inicializado para $accountId');
      return;
    }

    // Si cambió de usuario en el mismo dispositivo, despublicamos el doc
    // previo para que pushes del dueño anterior no aterricen aquí.
    if (_currentAccountId != null && _currentAccountId != accountId) {
      await _removeDeviceDoc(_currentAccountId!);
    }
    _currentAccountId = accountId;

    if (defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb) {
      debugPrint('[NotificationService] iOS: pendiente Fase 3 (APNs)');
      _completeInitialTap(null);
      return;
    }
    // Plataformas no-móviles, no-web: nada que hacer (macOS desktop, Linux…).
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      debugPrint('[NotificationService] Plataforma sin push, skip');
      _completeInitialTap(null);
      return;
    }
    // Web: si la VAPID key sigue siendo el placeholder, salimos limpio.
    // Sin VAPID, getToken() crashea con
    // FirebaseException 'messaging/failed-service-worker-registration'.
    // OJO: este string DEBE ser literalmente 'PASTE_VAPID_KEY_HERE' — es el
    // valor placeholder original. Si lo cambias por la VAPID real, esta
    // comparación se vuelve `vapid == vapid` y el init siempre sale en este
    // return, así que el navegador nunca pediría permiso.
    if (kIsWeb && fcmVapidKey == 'PASTE_VAPID_KEY_HERE') {
      debugPrint(
        '[NotificationService] Web: fcmVapidKey no configurada — skip. '
        'Genera la key en Firebase Console y pégala en lib/core/config.dart',
      );
      _completeInitialTap(null);
      return;
    }

    try {
      final messaging = FirebaseMessaging.instance;

      // 0. PRIMERO: leer el mensaje inicial. Es la operación más sensible al
      // timing porque ChatsScreen ya está esperando este Future. Hacerlo antes
      // que permisos/token reduce la ventana antes de que se complete.
      // En web getInitialMessage siempre devuelve null (el SW maneja el click
      // de manera distinta), pero la llamada es segura.
      final initial = await messaging.getInitialMessage();
      if (initial != null && _isHumanAttentionMessage(initial)) {
        final push = HumanAttentionPush.fromMessage(initial);
        debugPrint(
          '[NotificationService] Cold-start tap detectado para chat ${push.chatId}',
        );
        _completeInitialTap(push);
      } else {
        _completeInitialTap(null);
      }

      // 1. Permiso. Android 13+ lo exige explícito; versiones anteriores lo
      // conceden al instalar. Web abre el prompt nativo del navegador.
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[NotificationService] Permiso DENEGADO');
        return;
      }

      // 2. deviceId estable (sobrevive a refrescos de token, no a reinstall)
      _deviceId = await _ensureDeviceId();

      // 3. Token FCM y persistencia en Firestore
      // En web getToken() exige vapidKey explícitamente; en mobile lo ignora.
      final token = await messaging.getToken(
        vapidKey: kIsWeb ? fcmVapidKey : null,
      );
      if (token == null) {
        debugPrint('[NotificationService] getToken() devolvió null');
        return;
      }
      _currentToken = token;
      await _writeDeviceDoc(accountId, _deviceId!, token);

      // 4. Refresh: el token rota cada cierto tiempo, hay que actualizarlo
      _tokenRefreshSub?.cancel();
      _tokenRefreshSub = messaging.onTokenRefresh.listen((newToken) async {
        _currentToken = newToken;
        if (_deviceId != null && _currentAccountId != null) {
          await _writeDeviceDoc(_currentAccountId!, _deviceId!, newToken);
          debugPrint('[NotificationService] Token refrescado y persistido');
        }
      });

      // 5. Foreground: el SO no muestra notif por su cuenta cuando la app
      // está en primer plano; nosotros decidimos qué hacer (banner in-app).
      _foregroundSub?.cancel();
      _foregroundSub = FirebaseMessaging.onMessage.listen((m) {
        if (_isHumanAttentionMessage(m)) {
          _foregroundController.add(HumanAttentionPush.fromMessage(m));
        }
      });

      // 6. Tap con app en background (no terminada): SO muestra notif y al
      // tocar abre la app → este listener se dispara.
      _onOpenSub?.cancel();
      _onOpenSub = FirebaseMessaging.onMessageOpenedApp.listen((m) {
        if (_isHumanAttentionMessage(m)) {
          _tapController.add(HumanAttentionPush.fromMessage(m));
        }
      });

      debugPrint(
        '[NotificationService] ✅ Inicializado (deviceId=$_deviceId, token=${token.substring(0, 12)}…)',
      );
    } catch (e, st) {
      debugPrint('[NotificationService] Error en init: $e\n$st');
      // Aunque init falle, no dejamos a ChatsScreen colgada esperando el Future.
      _completeInitialTap(null);
    }
  }

  /// Llamar al hacer logout para que pushes futuros no lleguen al ex-usuario.
  Future<void> unregister() async {
    if (_currentAccountId == null) return;
    await _removeDeviceDoc(_currentAccountId!);
    _currentAccountId = null;
    _currentToken = null;
    await _tokenRefreshSub?.cancel();
    await _foregroundSub?.cancel();
    await _onOpenSub?.cancel();
    _tokenRefreshSub = null;
    _foregroundSub = null;
    _onOpenSub = null;
  }

  // Filtro: solo despachamos pushes que traen los campos esperados.
  bool _isHumanAttentionMessage(RemoteMessage m) {
    return m.data['chatId'] != null && m.data['accountId'] != null;
  }

  Future<String> _ensureDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _generateDeviceId();
    await prefs.setString(_kDeviceIdKey, fresh);
    return fresh;
  }

  // Generamos 16 bytes aleatorios → 32 chars hex. Suficiente y sin paquete extra.
  String _generateDeviceId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'd-$hex';
  }

  Future<void> _writeDeviceDoc(
    String accountId,
    String deviceId,
    String token,
  ) async {
    try {
      String version = 'unknown';
      try {
        final pkg = await PackageInfo.fromPlatform();
        version = '${pkg.version}+${pkg.buildNumber}';
      } catch (_) {
        // package_info puede fallar en algunos runtimes; no es crítico.
      }
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(accountId)
          .collection('devices')
          .doc(deviceId)
          .set({
        'fcm_token': token,
        'platform': _platformLabel(),
        'app_version': version,
        'last_seen_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[NotificationService] Error guardando token: $e');
    }
  }

  Future<void> _removeDeviceDoc(String accountId) async {
    if (_deviceId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(accountId)
          .collection('devices')
          .doc(_deviceId)
          .delete();
      debugPrint(
        '[NotificationService] Doc devices/$_deviceId borrado de $accountId',
      );
    } catch (e) {
      debugPrint('[NotificationService] Error borrando device doc: $e');
    }
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'other';
    }
  }
}
