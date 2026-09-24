import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'socket_service.dart';

/// Lo que ESTE dispositivo le cuenta al equipo: en qué chat estoy y si estoy
/// respondiendo. La otra mitad, lo que hacen los demás, es
/// `TeamPresenceService`.
///
/// Un solo evento de ida, `team_presence_set`, con el estado completo. Nada se
/// escribe en Firestore: el backend lo guarda en memoria y lo borra solo cuando
/// el socket se cae. Por eso al (re)conectar se reenvía todo; un reinicio del
/// backend o un redeploy se reconstruyen sin intervención.
///
/// **Registro por pantalla, no "el último que escribe gana".** Puede haber dos
/// `ChatsScreen` vivos a la vez: la raíz queda montada debajo de
/// `AccountsScreen` y encima se empuja otra, o `SessionDispatcher` monta la
/// nueva sesión antes de desmontar la vieja. La de abajo sigue rebuildeando (su
/// stream de etiquetas hace setState), así que con un simple "último valor"
/// la presencia saltaría entre los dos chats. Manda la pantalla registrada más
/// reciente de las que están en pantalla (`TickerMode`).
class PresenceReporter {
  PresenceReporter._({
    required void Function(String event, Map<String, dynamic> data) emit,
    required bool Function() isConnected,
    DateTime Function()? clock,
  })  : _emit = emit,
        _isConnected = isConnected,
        _now = clock ?? DateTime.now;

  static final PresenceReporter instance = PresenceReporter._(
    emit: (event, data) => SocketService().emit(event, data),
    isConnected: () => SocketService().isConnected,
  );

  @visibleForTesting
  factory PresenceReporter.test({
    required void Function(String event, Map<String, dynamic> data) emit,
    required bool Function() isConnected,
    DateTime Function()? clock,
  }) =>
      PresenceReporter._(emit: emit, isConnected: isConnected, clock: clock);

  // Salir de un chat se anuncia AL INSTANTE, a propósito. Hubo una espera de
  // 5 s para que tu nombre no parpadeara si volvías enseguida, pero lo único
  // que lograba era atrasar un dato cierto ("ya salí"): dos operadores en el
  // mismo chat se quedaban esperándose para ver quién soltaba primero. Pasar
  // de un chat a otro nunca la tuvo. No volver a ponerla.

  /// App en segundo plano o pestaña oculta. La espera cubre el selector de
  /// fotos y el alt-tab de ida y vuelta, que también ocultan la app.
  /// `inactive` (la ventana web perdió el foco) NO cuenta: puedes tener
  /// WhatHero a la vista en otro monitor mientras escribes en otra app.
  static const hiddenGrace = Duration(seconds: 15);

  /// Sin tocar la app este tiempo = ya no estás atendiendo ese chat. Sin esto
  /// un chat abierto en un escritorio abandonado bloquearía a todo el equipo.
  static const idleAfter = Duration(minutes: 3);

  /// Identifica a esta instancia de la app (cada pestaña es una). El backend
  /// la usa para retirar el fantasma del socket anterior al reconectar (el
  /// viejo tarda hasta 45 s en morir), y los demás para distinguir "otro
  /// dispositivo con tu usuario" en equipos que comparten login.
  final String clientId = _newClientId();

  final void Function(String event, Map<String, dynamic> data) _emit;
  final bool Function() _isConnected;
  final DateTime Function() _now;

  // Orden de inserción = orden de registro (LinkedHashMap por default).
  final Map<Object, _ScreenReport> _screens = {};

  // Chat con texto en el composer: sólo cuenta si es el chat abierto.
  ({String sessionPhone, String chatId})? _composing;

  bool _away = false;
  bool _idle = false;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _hiddenTimer;
  Timer? _idleTimer;
  bool _flushScheduled = false;

  // Último estado que de verdad salió por el socket. null = nada enviado en
  // esta conexión: el próximo flush manda el estado completo.
  _PresenceState? _sent;

  bool _started = false;

  /// Se llama una vez tras el login, junto a `SocketService().init`.
  /// Idempotente.
  void start() {
    if (_started) return;
    _started = true;
    // Viven lo que vive la app: el logout desregistra las pantallas (su
    // dispose) y el próximo login reutiliza estos mismos listeners.
    AppLifecycleListener(onStateChange: onLifecycleChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    SocketService().connectionStream.listen((connected) {
      connected ? onConnected() : onDisconnected();
    });
    noteActivity();
  }

  // ─── Pantallas ─────────────────────────────────────────────────────────

  void register(Object owner) {
    _screens.remove(owner);
    _screens[owner] = const _ScreenReport();
    _scheduleFlush();
  }

  void unregister(Object owner) {
    if (_screens.remove(owner) != null) _scheduleFlush();
  }

  /// Seguro de llamar desde `build`: sólo compara y agenda el envío en un
  /// microtask, sin notificar a nadie.
  void report(
    Object owner, {
    required String? sessionPhone,
    required String? chatId,
    required bool onScreen,
  }) {
    final next = _ScreenReport(
      sessionPhone: sessionPhone,
      chatId: chatId,
      onScreen: onScreen,
    );
    if (_screens[owner] == next) return;
    // Un report sin register previo (no debería pasar) igual se toma en cuenta.
    _screens[owner] = next;
    _scheduleFlush();
  }

  /// El composer de [chatId] tiene (o dejó de tener) texto.
  void setComposing(String sessionPhone, String chatId, bool composing) {
    final current = _composing;
    if (composing) {
      if (current?.sessionPhone == sessionPhone && current?.chatId == chatId) {
        return;
      }
      _composing = (sessionPhone: sessionPhone, chatId: chatId);
    } else {
      // Sólo apaga el suyo: al cambiar de chat, el dispose del composer viejo
      // puede llegar después de que el nuevo ya encendió el propio.
      if (current == null ||
          current.sessionPhone != sessionPhone ||
          current.chatId != chatId) {
        return;
      }
      _composing = null;
    }
    _scheduleFlush();
  }

  // ─── Actividad (idle) y ciclo de vida ──────────────────────────────────

  /// Hay alguien frente a la app. Barato a propósito: se llama con cada
  /// movimiento del mouse, así que sólo toca un campo salvo al despertar.
  void noteActivity() {
    _lastActivity = _now();
    if (_idle) {
      _idle = false;
      _scheduleFlush();
    }
    _idleTimer ??= Timer(idleAfter, _checkIdle);
  }

  // Un solo Timer que se re-arma con lo que falta, en vez de reprogramarlo
  // en cada evento del puntero.
  void _checkIdle() {
    _idleTimer = null;
    final elapsed = _now().difference(_lastActivity);
    if (elapsed < idleAfter) {
      _idleTimer = Timer(idleAfter - elapsed, _checkIdle);
      return;
    }
    _idle = true;
    _scheduleFlush();
  }

  void _onPointer(PointerEvent event) => noteActivity();

  bool _onKey(KeyEvent event) {
    noteActivity();
    return false; // sólo miramos: la tecla sigue su camino
  }

  @visibleForTesting
  void onLifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        _hiddenTimer?.cancel();
        _hiddenTimer = null;
        if (state == AppLifecycleState.resumed) noteActivity();
        if (_away) {
          _away = false;
          _scheduleFlush();
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_away || _hiddenTimer != null) return;
        _hiddenTimer = Timer(hiddenGrace, () {
          _hiddenTimer = null;
          _away = true;
          _scheduleFlush();
        });
    }
  }

  // ─── Conexión ──────────────────────────────────────────────────────────

  /// Conexión nueva = socket nuevo: el backend no sabe nada de nosotros.
  @visibleForTesting
  void onConnected() {
    _sent = null;
    _scheduleFlush();
  }

  @visibleForTesting
  void onDisconnected() => _sent = null;

  // ─── Envío ─────────────────────────────────────────────────────────────

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      _flush();
    });
  }

  _PresenceState _desired() {
    _ScreenReport? active;
    for (final screen in _screens.values.toList().reversed) {
      if (screen.onScreen) {
        active = screen;
        break;
      }
    }
    final sessionPhone = active?.sessionPhone;
    if (active == null || sessionPhone == null || sessionPhone.isEmpty) {
      return const _PresenceState();
    }
    // Ausente o inactivo: seguimos en la sala de la sesión (vemos la lista y
    // la presencia de los demás) pero no "estamos" en ningún chat.
    final chatId = (_away || _idle) ? null : active.chatId;
    final composing = chatId != null &&
        _composing?.sessionPhone == sessionPhone &&
        _composing?.chatId == chatId;
    return _PresenceState(
      sessionPhone: sessionPhone,
      chatId: chatId,
      composing: composing,
    );
  }

  void _flush() {
    final desired = _desired();
    // emit() descarta en silencio si el socket está caído. No damos por
    // enviado lo que no salió: onConnected reenvía el estado completo.
    if (!_isConnected()) return;
    if (desired == _sent) return;
    // Nada que contarle a un socket que nunca supo de nosotros.
    if (_sent == null && desired.sessionPhone == null) return;
    _emit('team_presence_set', {
      'clientId': clientId,
      'sessionPhone': desired.sessionPhone,
      'chatId': desired.chatId,
      'composing': desired.composing,
    });
    _sent = desired;
  }
}

String _newClientId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return List.generate(16, (_) => chars[random.nextInt(chars.length)]).join();
}

@immutable
class _ScreenReport {
  final String? sessionPhone;
  final String? chatId;
  final bool onScreen;

  const _ScreenReport({this.sessionPhone, this.chatId, this.onScreen = false});

  @override
  bool operator ==(Object other) =>
      other is _ScreenReport &&
      other.sessionPhone == sessionPhone &&
      other.chatId == chatId &&
      other.onScreen == onScreen;

  @override
  int get hashCode => Object.hash(sessionPhone, chatId, onScreen);
}

@immutable
class _PresenceState {
  final String? sessionPhone;
  final String? chatId;
  final bool composing;

  const _PresenceState({this.sessionPhone, this.chatId, this.composing = false});

  @override
  bool operator ==(Object other) =>
      other is _PresenceState &&
      other.sessionPhone == sessionPhone &&
      other.chatId == chatId &&
      other.composing == composing;

  @override
  int get hashCode => Object.hash(sessionPhone, chatId, composing);
}
