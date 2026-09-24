import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';
import '../config.dart';
import 'ai_state_service.dart';
import 'pending_messages_service.dart';
import 'team_presence_service.dart';

/// Evento de QR recibido
class QREvent {
  final String qr;
  final String sessionKey;
  QREvent({required this.qr, required this.sessionKey});
}

/// Evento de cambio de estado (ready, logged_out, etc)
class SessionStatusEvent {
  final String status;
  final String sessionKey;
  final String? phoneNumber;
  SessionStatusEvent({required this.status, required this.sessionKey, this.phoneNumber});
}

/// Espera antes del reintento manual N (0, 1, 2…): 2, 4, 8, 16 y luego 30 s.
Duration socketRecoveryDelay(int attempt) =>
    Duration(seconds: attempt >= 4 ? 30 : min(30, 2 << attempt));

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _currentAccountId;

  // Reintento manual para los casos en que socket_io_client NO reconecta solo
  // (ver _setupListeners). Uno a la vez, con backoff.
  Timer? _recoveryTimer;
  int _recoveryAttempt = 0;

  // StreamControllers para distribuir eventos a las pantallas
  final _qrController = StreamController<QREvent>.broadcast();
  final _statusController = StreamController<SessionStatusEvent>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _humanAttentionController = StreamController<Map<String, dynamic>>.broadcast();

  // Getters para los Streams
  Stream<QREvent> get qrStream => _qrController.stream;
  Stream<SessionStatusEvent> get statusStream => _statusController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<Map<String, dynamic>> get humanAttentionStream => _humanAttentionController.stream;

  bool get isConnected => _isConnected;

  Future<void> init(String accountId) async {
    if (_socket != null && _currentAccountId == accountId) {
      debugPrint('[SocketService] Ya conectado con accountId: $accountId');
      return;
    }

    _currentAccountId = accountId;
    _disconnect();

    debugPrint('[SocketService] Conectando a $backendUrl para accountId: $accountId');

    final socket = IO.io(
      backendUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          // Sin forceNew, IO.io reutiliza el Manager en cache para este host y
          // devuelve el MISMO socket de antes, con el auth de antes: tras
          // cambiar de cuenta (o logout + login) seguía conectando con el
          // accountId y el token del usuario anterior.
          .enableForceNew()
          .disableAutoConnect()
          // El backend valida el idToken en CADA handshake, reconexiones
          // incluidas. Pedirlo en el momento (getIdToken lo renueva sólo si
          // venció) evita reconectar con un token viejo después de que el
          // celular o la laptop durmieron más de una hora: el server lo
          // rechazaba y el socket moría para siempre.
          .setAuthFn((send) => _handshakeAuth(accountId).then(send))
          .build(),
    );
    _socket = socket;
    _setupListeners(socket);
    socket.connect();
  }

  Future<Map<String, dynamic>> _handshakeAuth(String accountId) async {
    String? idToken;
    try {
      idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (e) {
      // Sin red para renovarlo: el server rechazará y la recuperación reintenta.
      debugPrint('[SocketService] No se pudo obtener el idToken: $e');
    }
    return {'accountId': accountId, 'idToken': idToken};
  }

  void _setupListeners(IO.Socket socket) {
    socket.onConnect((_) {
      if (!identical(socket, _socket)) return;
      debugPrint('[SocketService] ✅ Conectado');
      _isConnected = true;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      _recoveryAttempt = 0;
      _connectionController.add(true);
    });

    socket.onDisconnect((reason) {
      if (!identical(socket, _socket)) return;
      debugPrint('[SocketService] ❌ Desconectado ($reason)');
      _isConnected = false;
      _connectionController.add(false);
      // Sin socket no nos enteramos de quién se va: la presencia caduca sola
      // si no reconectamos pronto.
      TeamPresenceService().markStale();
      // Si nos cerró el server, socket_io_client no reconecta solo.
      if (reason == 'io server disconnect') _scheduleRecovery(socket);
    });

    // El server rechazó el handshake (token inválido, error leyendo la
    // membresía). socket_io_client destruye el socket y NO vuelve a intentar:
    // quedaba muerto hasta reiniciar la app, sin estados de IA, sin presencia
    // y sin acks. Un error de red común, en cambio, deja el socket activo y el
    // Manager reintenta solo: ahí no hacemos nada.
    socket.onConnectError((error) {
      if (!identical(socket, _socket) || socket.active) return;
      debugPrint('[SocketService] Handshake rechazado: $error');
      _scheduleRecovery(socket);
    });

    socket.on('qr', (data) {
      debugPrint('[SocketService] QR recibido para ${data['sessionKey']}');
      _qrController.add(QREvent(
        qr: data['qr'],
        sessionKey: data['sessionKey'],
      ));
    });

    socket.on('ready', (data) {
      debugPrint('[SocketService] Sesión READY: ${data['sessionKey']}');
      _statusController.add(SessionStatusEvent(
        status: 'ready',
        sessionKey: data['sessionKey'],
        phoneNumber: data['phoneNumber'],
      ));
    });

    socket.on('status_update', (data) {
      debugPrint('[SocketService] Status update: ${data['status']} para ${data['sessionKey']}');
      _statusController.add(SessionStatusEvent(
        status: data['status'],
        sessionKey: data['sessionKey'],
      ));
    });

    socket.on('human_attention_required', (data) {
      debugPrint('[SocketService] Atención humana requerida: $data');
      _humanAttentionController.add(Map<String, dynamic>.from(data));
    });

    // Estado del ciclo IA (buffering/thinking/responding/idle). No exponemos
    // un Stream porque el AiStateService ya es un ChangeNotifier al que los
    // widgets se suscriben directamente con ListenableBuilder.
    socket.on('ai_state', (data) {
      if (data is Map) {
        AiStateService().applySocketPayload(Map<String, dynamic>.from(data));
      }
    });

    // Foto de los estados de IA en curso, al conectar. Reemplaza lo que había:
    // un `idle` emitido mientras estábamos desconectados se perdió.
    socket.on('ai_state_snapshot', (data) {
      final states = data is Map ? data['states'] : null;
      if (states is List) AiStateService().replaceAll(states);
    });

    // Presencia del equipo: el estado completo de la sesión en cada cambio.
    // Mismo patrón que ai_state.
    socket.on('team_presence', (data) {
      if (data is Map) {
        TeamPresenceService().applyPayload(Map<String, dynamic>.from(data));
      }
    });

    // Acks de envío para las burbujas optimistas (relojito → ✓✓ / reintentar).
    // Mismo patrón que ai_state: directo al singleton, sin Stream intermedio.
    socket.on('message_sent_success', (data) {
      PendingMessagesService().onSendSuccess(
        data['tempId'] as String?,
        data['messageId'] as String?,
      );
    });

    socket.on('message_sent_error', (data) {
      debugPrint('[SocketService] Envío falló: ${data['error']}');
      PendingMessagesService().onSendError(
        data['tempId'] as String?,
        data['error'] as String?,
      );
    });
  }

  void _scheduleRecovery(IO.Socket socket) {
    if (_recoveryTimer != null) return;
    final delay = socketRecoveryDelay(_recoveryAttempt++);
    debugPrint('[SocketService] Reintento de conexión en ${delay.inSeconds}s');
    _recoveryTimer = Timer(delay, () {
      _recoveryTimer = null;
      // Otro init (cambio de cuenta, logout) ya reemplazó o cerró este socket.
      if (!identical(socket, _socket) || socket.connected || socket.active) return;
      socket.connect();
    });
  }

  void _disconnect() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryAttempt = 0;
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    // Cambio de cuenta o logout: la presencia y los estados de IA de la cuenta
    // anterior no aplican.
    TeamPresenceService().clearAll();
    AiStateService().clearAll();
  }

  /// Cierra el socket. Llamar en logout para que el siguiente usuario no
  /// herede la conexión del anterior.
  Future<void> shutdown() async {
    _disconnect();
    _currentAccountId = null;
  }

  /// Cerrar todos los streams al cerrar la app (opcional)
  void dispose() {
    _disconnect();
    _qrController.close();
    _statusController.close();
    _connectionController.close();
    _humanAttentionController.close();
  }

  /// Método genérico para emitir eventos al backend
  void emit(String event, dynamic data) {
    if (_isConnected) {
      _socket?.emit(event, data);
    } else {
      debugPrint('[SocketService] Error: Socket no conectado, no se puede emitir $event');
    }
  }

  /// Método para enviar mensajes a través del socket (más rápido que HTTP)
  void sendMessage(Map<String, dynamic> data) {
    emit('send_message_socket', data);
  }
}
