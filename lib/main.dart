import 'dart:io';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WhatsApp CRM',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const WhatsAppHandshakeScreen(),
    );
  }
}

class WhatsAppHandshakeScreen extends StatefulWidget {
  const WhatsAppHandshakeScreen({super.key});

  @override
  State<WhatsAppHandshakeScreen> createState() => _WhatsAppHandshakeScreenState();
}

class _WhatsAppHandshakeScreenState extends State<WhatsAppHandshakeScreen> {
  late IO.Socket socket;
  String? qrCode;
  bool isConnected = false;
  String status = 'Desconectado';

  @override
  void initState() {
    super.initState();
    initSocket();
  }

  void initSocket() {
    // Detectamos si es Android para usar la IP del host del emulador
    String host = Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000';

    socket = IO.io(host, IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .build());

    socket.connect();

    socket.onConnect((_) {
      print('Conectado al servidor de sockets');
      setState(() {
        status = 'Esperando QR';
      });
    });

    socket.on('qr', (data) {
      print('Nuevo QR recibido');
      setState(() {
        qrCode = data;
        status = 'Esperando QR';
        isConnected = false;
      });
    });

    socket.on('ready', (_) {
      print('WhatsApp conectado exitosamente');
      setState(() {
        isConnected = true;
        qrCode = null;
        status = 'Conectado';
      });
    });

    socket.onDisconnect((_) {
      setState(() {
        status = 'Desconectado';
        isConnected = false;
        qrCode = null;
      });
    });
  }

  Color getAppBarColor() {
    if (isConnected) return Colors.green;
    if (qrCode != null || status == 'Esperando QR') return Colors.orange;
    return Colors.grey;
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp CRM - Handshake'),
        backgroundColor: getAppBarColor(),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isConnected)
                const Column(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 100),
                    SizedBox(height: 20),
                    Text(
                      '¡WhatsApp Vinculado!',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                  ],
                )
              else if (qrCode != null)
                Column(
                  children: [
                    const Text(
                      'Escanea el código QR en WhatsApp',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(10),
                      child: QrImageView(
                        data: qrCode!,
                        version: QrVersions.auto,
                        size: 250.0,
                      ),
                    ),
                  ],
                )
              else
                const Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text('Conectando con el servidor...'),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
