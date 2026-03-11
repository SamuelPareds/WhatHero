import 'dart:io';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
    // Una vez conectado, navegar a la pantalla de chats
    if (isConnected) {
      return ChatsScreen(socket: socket);
    }

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
              if (qrCode != null)
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

class ChatsScreen extends StatefulWidget {
  final IO.Socket socket;

  const ChatsScreen({required this.socket, super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String? selectedChatPhone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp CRM - Chats'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Row(
        children: [
          // Lista de chats
          SizedBox(
            width: 300,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .orderBy('lastMessageTimestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final chats = snapshot.data!.docs;

                if (chats.isEmpty) {
                  return const Center(child: Text('Sin chats'));
                }

                return ListView.builder(
                  itemCount: chats.length,
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    final phoneNumber = chat['phoneNumber'];
                    final lastMessage = chat['lastMessage'] ?? 'Sin mensajes';

                    return ListTile(
                      title: Text(phoneNumber),
                      subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: selectedChatPhone == phoneNumber,
                      onTap: () {
                        setState(() {
                          selectedChatPhone = phoneNumber;
                        });
                      },
                    );
                  },
                );
              },
            ),
          ),
          // Detalle del chat
          Expanded(
            child: selectedChatPhone != null
                ? MessagesView(phoneNumber: selectedChatPhone!)
                : const Center(child: Text('Selecciona un chat')),
          ),
        ],
      ),
    );
  }
}

class MessagesView extends StatefulWidget {
  final String phoneNumber;

  const MessagesView({required this.phoneNumber, super.key});

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final TextEditingController _messageController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Encabezado con el número
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.shade100,
            border: Border(bottom: BorderSide(color: Colors.green.shade300)),
          ),
          child: Text(
            widget.phoneNumber,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        // Stream de mensajes en tiempo real
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('chats')
                .doc(widget.phoneNumber)
                .collection('messages')
                .orderBy('timestamp', descending: false)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final messages = snapshot.data!.docs;

              if (messages.isEmpty) {
                return const Center(child: Text('Sin mensajes'));
              }

              return ListView.builder(
                reverse: true,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final msg = messages[messages.length - 1 - index];
                  final text = msg['text'] ?? '';
                  final fromMe = msg['fromMe'] ?? false;
                  final timestamp = msg['timestamp'] as Timestamp;

                  return Align(
                    alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: fromMe ? Colors.green.shade200 : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(text),
                          const SizedBox(height: 4),
                          Text(
                            _formatTime(timestamp.toDate()),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        // Input para enviar mensajes
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  decoration: InputDecoration(
                    hintText: 'Escribe un mensaje...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton(
                mini: true,
                backgroundColor: Colors.green,
                onPressed: () {
                  // TODO: Implementar envío de mensajes
                  _messageController.clear();
                },
                child: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }
}
