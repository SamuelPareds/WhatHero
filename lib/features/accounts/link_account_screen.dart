import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';

class LinkAccountScreen extends StatefulWidget {
  final String sessionKey;
  final String accountId;

  const LinkAccountScreen({
    required this.sessionKey,
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
  
  // Guardar suscripciones para cancelarlas en dispose
  StreamSubscription? _qrSubscription;
  StreamSubscription? _statusSubscription;

  @override
  void initState() {
    super.initState();
    print('[LinkAccountScreen] initState - sessionKey: ${widget.sessionKey}, accountId: ${widget.accountId}');
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    print('[LinkAccountScreen] Escuchando SocketService para sessionKey: ${widget.sessionKey}');

    // Escuchar QRs globales
    _qrSubscription = SocketService().qrStream.listen((event) {
      if (event.sessionKey == widget.sessionKey) {
        print('[LinkAccountScreen] QR coincide con sessionKey, mostrando QR');
        if (mounted) {
          setState(() {
            qrCode = event.qr;
            status = 'Escanea el código QR';
          });
        }
      }
    });

    // Escuchar cambios de estado (ready, logged_out)
    _statusSubscription = SocketService().statusStream.listen((event) {
      if (event.sessionKey == widget.sessionKey) {
        if (event.status == 'ready') {
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
        } else if (event.status == 'logged_out') {
          print('[LinkAccountScreen] Sesión cerrada, mostrando error y cerrando');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Sesión cerrada'), backgroundColor: Colors.red),
            );
            Navigator.pop(context);
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          print('[LinkAccountScreen] onPopInvoked - didPop: $didPop');
        }
      },
      child: Scaffold(
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
                    color: sessionConnected 
                        ? Colors.green.withValues(alpha: 0.15) 
                        : primaryAqua.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Center(
                    child: Text(
                      sessionConnected ? '✅' : '🦸', 
                      style: const TextStyle(fontSize: 48)
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: sessionConnected ? Colors.green.shade400 : white,
                  ),
                ),
                const SizedBox(height: 48),
                if (qrCode != null && !sessionConnected)
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
                else if (sessionConnected)
                  const Column(
                    children: [
                      Icon(Icons.check_circle_outline, size: 100, color: Colors.green),
                      SizedBox(height: 16),
                      Text('¡Vinculación Exitosa!', style: TextStyle(color: white, fontSize: 20)),
                    ],
                  )
                else
                  const Column(
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
                        ),
                      ),
                      SizedBox(height: 24),
                      Text(
                        'Generando código QR...\nEsto puede tardar unos segundos',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: lightText, fontSize: 14),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _cancelSession() {
    // Solo cancelar si la sesión NO se conectó exitosamente
    if (sessionConnected) return;

    print('[LinkAccountScreen] Cancelando sesión via SocketService: ${widget.sessionKey}');
    
    // Usar el nuevo método emit para enviar el evento directamente
    SocketService().emit('cancel_session', {
      'sessionKey': widget.sessionKey,
    });
  }

  @override
  void dispose() {
    _cancelSession();
    _qrSubscription?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }
}
