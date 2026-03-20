import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';
import '../config.dart';

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

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _currentAccountId;

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

  void init(String accountId) {
    if (_socket != null && _currentAccountId == accountId) {
      debugPrint('[SocketService] Ya conectado con accountId: $accountId');
      return;
    }

    _currentAccountId = accountId;
    _disconnect();

    debugPrint('[SocketService] Conectando a $backendUrl para accountId: $accountId');
    
    _socket = IO.io(backendUrl, IO.OptionBuilder()
      .setTransports(['websocket'])
      .setAuth({'accountId': accountId})
      .enableAutoConnect()
      .build());

    _setupListeners();
    _socket?.connect();
  }

  void _setupListeners() {
    _socket?.onConnect((_) {
      debugPrint('[SocketService] ✅ Conectado');
      _isConnected = true;
      _connectionController.add(true);
    });

    _socket?.onDisconnect((_) {
      debugPrint('[SocketService] ❌ Desconectado');
      _isConnected = false;
      _connectionController.add(false);
    });

    _socket?.on('qr', (data) {
      debugPrint('[SocketService] QR recibido para ${data['sessionKey']}');
      _qrController.add(QREvent(
        qr: data['qr'],
        sessionKey: data['sessionKey'],
      ));
    });

    _socket?.on('ready', (data) {
      debugPrint('[SocketService] Sesión READY: ${data['sessionKey']}');
      _statusController.add(SessionStatusEvent(
        status: 'ready',
        sessionKey: data['sessionKey'],
        phoneNumber: data['phoneNumber'],
      ));
    });

    _socket?.on('status_update', (data) {
      debugPrint('[SocketService] Status update: ${data['status']} para ${data['sessionKey']}');
      _statusController.add(SessionStatusEvent(
        status: data['status'],
        sessionKey: data['sessionKey'],
      ));
    });

    _socket?.on('human_attention_required', (data) {
      debugPrint('[SocketService] Atención humana requerida: $data');
      _humanAttentionController.add(Map<String, dynamic>.from(data));
    });
  }

  void _disconnect() {
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
  }

  /// Cerrar todos los streams al cerrar la app (opcional)
  void dispose() {
    _disconnect();
    _qrController.close();
    _statusController.close();
    _connectionController.close();
    _humanAttentionController.close();
  }

  /// Método para enviar mensajes a través del socket (más rápido que HTTP)
  void sendMessage(Map<String, dynamic> data) {
    if (_isConnected) {
      _socket?.emit('send_message_socket', data);
    } else {
      debugPrint('[SocketService] Error: Socket no conectado, no se puede enviar mensaje');
    }
  }
}
