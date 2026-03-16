import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:crm_whatsapp/core.dart';

class LinkAccountScreen extends StatefulWidget {
  final String sessionKey;
  final IO.Socket socket;
  final String accountId;

  const LinkAccountScreen({
    required this.sessionKey,
    required this.socket,
    required this.accountId,
    super.key,
  });

  @override
  State<LinkAccountScreen> createState() => _LinkAccountScreenState();
}

class _LinkAccountScreenState extends State<LinkAccountScreen> {
  String? qrCode;
  bool sessionConnected = false;
  String status = 'Iniciando sesión...';

  @override
  void initState() {
    super.initState();
    print('[LinkAccountScreen] initState - sessionKey: ${widget.sessionKey}, accountId: ${widget.accountId}');
    print('[LinkAccountScreen] Socket.id: ${widget.socket.id}, conectado: ${widget.socket.connected}');
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    print('[LinkAccountScreen] Configurando listeners de socket para sessionKey: ${widget.sessionKey}');

    widget.socket.on('qr', (data) {
      print('[LinkAccountScreen] Evento QR recibido: data=$data, sessionKey esperado=${widget.sessionKey}');
      if (data is Map && data['sessionKey'] == widget.sessionKey) {
        print('[LinkAccountScreen] QR coincide con sessionKey, mostrando QR');
        if (mounted) {
          setState(() {
            qrCode = data['qr'];
            status = 'Escanea el código QR';
          });
        }
      } else {
        print('[LinkAccountScreen] QR NO coincide: data[sessionKey]=${data is Map ? data['sessionKey'] : 'N/A'}');
      }
    });

    widget.socket.on('ready', (data) {
      print('[LinkAccountScreen] Evento READY recibido: data=$data');
      if (data is Map && data['sessionKey'] == widget.sessionKey) {
        print('[LinkAccountScreen] Cuenta conectada exitosamente, cerrando pantalla');
        if (mounted) {
          setState(() {
            sessionConnected = true;
            status = 'Conectado exitosamente ✅';
          });
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.pop(context);
          });
        }
      } else {
        print('[LinkAccountScreen] READY NO coincide: data[sessionKey]=${data is Map ? data['sessionKey'] : 'N/A'}');
      }
    });

    widget.socket.on('status_update', (data) {
      print('[LinkAccountScreen] Evento STATUS_UPDATE recibido: data=$data');
      if (data is Map && data['sessionKey'] == widget.sessionKey && data['status'] == 'logged_out') {
        print('[LinkAccountScreen] Sesión cerrada, mostrando error y cerrando');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sesión cerrada'), backgroundColor: Colors.red),
          );
          Navigator.pop(context);
        }
      }
    });

    // Listener para detectar desconexiones
    widget.socket.on('disconnect', (_) {
      print('[LinkAccountScreen] Socket desconectado inesperadamente');
      if (mounted) {
        setState(() => status = 'Desconectado - Reconectando...');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vincular Cuenta'),
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: primaryAqua.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Center(
                  child: Text('🦸', style: TextStyle(fontSize: 48)),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                status,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: white,
                ),
              ),
              const SizedBox(height: 48),
              if (qrCode != null)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: primaryAqua.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: QrImageView(
                    data: qrCode!,
                    version: QrVersions.auto,
                    size: 260.0,
                  ),
                )
              else
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cancelSession() async {
    try {
      // Solo cancelar si la sesión NO se conectó exitosamente
      if (sessionConnected) {
        print('[LinkAccountScreen] Sesión ya conectada, no cancelar');
        return;
      }

      print('[LinkAccountScreen] Cancelando sesión: ${widget.sessionKey}');

      // Usar Socket.io para cancelar
      widget.socket.emit('cancel_session', {
        'sessionKey': widget.sessionKey,
      });
    } catch (error) {
      print('[LinkAccountScreen] Error cancelando sesión: $error');
    }
  }

  @override
  void dispose() {
    // Cancelar la sesión en el backend antes de desmontar
    _cancelSession();

    // Limpiar los listeners específicos para esta sesión
    widget.socket.off('qr');
    widget.socket.off('ready');
    widget.socket.off('status_update');
    widget.socket.off('disconnect');
    super.dispose();
  }
}
