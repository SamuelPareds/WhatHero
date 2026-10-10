import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'package:crm_whatsapp/core/services/notification_service.dart';
import 'package:crm_whatsapp/core/services/socket_service.dart';
import 'package:crm_whatsapp/core/services/storage_service.dart';
import 'package:crm_whatsapp/core/services/version_service.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';
import 'package:crm_whatsapp/features/auth.dart';
import 'package:crm_whatsapp/features/accounts/change_number/change_number_flow.dart';
import 'package:crm_whatsapp/features/accounts/link_result.dart';
import 'package:crm_whatsapp/features/accounts/session_linking.dart';
import 'package:crm_whatsapp/features/members/members_screen.dart';
import 'package:crm_whatsapp/features/settings.dart';
import 'package:crm_whatsapp/features/chat.dart';
import 'package:crm_whatsapp/features/chat/widgets/unread_badge.dart';

class AccountsScreen extends StatefulWidget {
  final String accountId;

  const AccountsScreen({required this.accountId, super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  String _appVersion = '0.0.0+0';

  @override
  void initState() {
    super.initState();
    // Nota: SocketService().init(...) vive en SessionDispatcher (main.dart)
    // — único punto de entrada tras login con accountId disponible. Aquí no
    // se reinicializa para no duplicar la fuente de verdad; el método es
    // idempotente igual, así que es seguro removerlo.
    _loadVersion();
  }

  /// Stream de sesiones segun los permisos del usuario.
  /// - Owner / acceso total: todas las sesiones de la cuenta.
  /// - Sub-user restringido: solo las sesiones cuyo `allowedUids` lo incluye
  ///   (query filtrable que las rules aprueban; sin orderBy para no exigir
  ///   índice compuesto — el orden se aplica en memoria en el builder).
  Stream<QuerySnapshot> _sessionsStream() {
    final col = FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(widget.accountId)
        .collection('whatsapp_sessions');

    final ctx = AccountContextService();
    if (ctx.hasAllSessionsAccess) {
      return col.orderBy('connected_at', descending: true).snapshots();
    }
    final uid = ctx.currentUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    return col.where('allowedUids', arrayContains: uid).snapshots();
  }

  Future<void> _loadVersion() async {
    final version = await VersionService.getVersion();
    if (mounted) {
      setState(() {
        _appVersion = version;
      });
    }
  }

  Future<void> _handleLogout() async {
    try {
      // Limpiar preferencia de última sesión
      await StorageService().clearLastSessionId();

      // Limpieza ordenada ANTES del signOut para evitar que cualquier listener
      // que reaccione al cambio de auth state vea contexto stale del usuario
      // anterior. Especialmente importante en dev: cuando cambiamos de usuario
      // para validar que los datos no se "filtren" entre cuentas.
      await NotificationService().unregister();
      await SocketService().shutdown();
      await AccountContextService().clear();

      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      print('[AccountsScreen] Error en logout: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al cerrar sesión: ${e.toString()}')),
      );
    }
  }

  // Última foto de la lista, para que el FAB pueda preguntar si el número
  // nuevo reemplaza a uno de estos sin abrir otra consulta.
  List<QueryDocumentSnapshot> _sessions = const [];

  /// FAB "Agregar número". Si ya hay sesiones, el owner elige antes del QR si
  /// el número reemplaza a otro: es el momento natural de quien perdió su
  /// línea, y si lo vincula suelto y empieza a trabajar ahí, después ya no se
  /// pueden juntar los dos historiales.
  Future<void> _onAddNumber() async {
    if (!AccountContextService().isOwner || _sessions.isEmpty) {
      await linkWhatsApp(context, accountId: widget.accountId);
      return;
    }

    final replaced = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '¿Este número reemplaza a otro?',
                  style: TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Text(
                  'Si perdiste o cambiaste un número, el nuevo se queda con sus chats y su configuración.',
                  style: TextStyle(color: lightText, fontSize: 13),
                ),
              ),
              for (final doc in _sessions)
                ListTile(
                  leading: const Icon(Icons.swap_horiz, color: primaryAqua),
                  title: Text(_aliasOf(doc), style: const TextStyle(color: white)),
                  subtitle: Text(
                    'Reemplaza a ${displayPhone(sessionPhone(_dataOf(doc), doc.id))}',
                    style: const TextStyle(color: lightText, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetContext, doc.id),
                ),
              const Divider(color: Colors.white12),
              ListTile(
                leading: const Icon(Icons.add, color: lightText),
                title: const Text('No, es una línea más', style: TextStyle(color: white)),
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
            ],
          ),
        ),
      ),
    );
    if (replaced == null || !mounted) return;
    if (replaced.isEmpty) {
      await linkWhatsApp(context, accountId: widget.accountId);
    } else {
      await showChangeNumberFlow(context, accountId: widget.accountId, sessionId: replaced);
    }
  }

  /// Re-vincular una tarjeta desconectada. El owner elige primero si es el
  /// mismo número o uno nuevo; un miembro del equipo sólo puede reconectar el
  /// mismo (cambiar el número es decisión del dueño).
  Future<void> _onRelink(String sessionId, Map<String, dynamic> data) async {
    final phone = sessionPhone(data, sessionId);
    final alias = (data['alias'] as String?) ?? displayPhone(phone);

    bool newNumber = false;
    if (AccountContextService().isOwner) {
      final choice = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: surfaceDark,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '¿Con qué número reconectas “$alias”?',
                    style: const TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.sync, color: primaryAqua),
                  title: Text('El mismo: ${displayPhone(phone)}', style: const TextStyle(color: white)),
                  subtitle: const Text(
                    'Se desconectó, pero sigues usando ese número',
                    style: TextStyle(color: lightText, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetContext, false),
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz, color: primaryAqua),
                  title: const Text('Uno nuevo', style: TextStyle(color: white)),
                  subtitle: const Text(
                    'Perdiste o cambiaste el número: el nuevo se queda con los chats y la configuración',
                    style: TextStyle(color: lightText, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(sheetContext, true),
                ),
              ],
            ),
          ),
        ),
      );
      if (choice == null || !mounted) return;
      newNumber = choice;
    }

    if (newNumber) {
      await showChangeNumberFlow(context, accountId: widget.accountId, sessionId: sessionId);
      return;
    }

    final result = await linkWhatsApp(
      context,
      accountId: widget.accountId,
      intoSessionId: sessionId,
      title: 'Reconectar $alias',
      hint: 'Escanea con el WhatsApp de ${displayPhone(phone)}',
    );
    if (result == null || !result.rejected || !mounted) return;
    await _explainRejection(result, sessionId);
  }

  Future<void> _explainRejection(LinkResult result, String sessionId) async {
    // Escanearon con otro número desde "El mismo": casi siempre es alguien
    // que cambió de número y no lo sabía decir. Le damos la salida ahí mismo.
    final offerChange = result.rejectedReason == 'wrong_number' && AccountContextService().isOwner;
    final change = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('No se vinculó', style: TextStyle(color: white)),
        content: Text(result.rejectionMessage, style: const TextStyle(color: lightText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Entendido'),
          ),
          if (offerChange)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Cambiar de número'),
            ),
        ],
      ),
    );
    if (change == true && mounted) {
      await showChangeNumberFlow(context, accountId: widget.accountId, sessionId: sessionId);
    }
  }

  static Map<String, dynamic> _dataOf(DocumentSnapshot doc) =>
      doc.data() as Map<String, dynamic>? ?? const {};

  static String _aliasOf(DocumentSnapshot doc) {
    final data = _dataOf(doc);
    final alias = data['alias'];
    return alias is String && alias.trim().isNotEmpty ? alias : displayPhone(sessionPhone(data, doc.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis Cuentas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: white)),
        elevation: 0,
        actions: [
          // El acceso a "Miembros" solo aparece para owners. Los sub-users
          // verían una pantalla casi vacía (sin FAB) y por ahora no
          // necesitan ver la lista — la mostramos cuando agreguemos
          // permisos de read-only en una fase futura.
          if (AccountContextService().isOwner)
            IconButton(
              icon: const Icon(Icons.group_outlined, color: lightText),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MembersScreen(accountId: widget.accountId),
                  ),
                );
              },
              tooltip: 'Miembros del equipo',
            ),
          IconButton(
            icon: const Icon(Icons.logout, color: lightText),
            onPressed: _handleLogout,
            tooltip: 'Cerrar sesión',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onAddNumber,
        backgroundColor: primaryAqua,
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'WhatHero v$_appVersion',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: lightText.withValues(alpha: 0.45),
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _sessionsStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          // Ordenamos en memoria por connected_at desc: el branch restringido
          // (arrayContains) no puede usar orderBy sin un índice compuesto, y
          // la lista de sesiones es pequeña. Owners y restringidos comparten
          // el mismo orden visual.
          final sessions = snapshot.data!.docs.toList()
            ..sort((a, b) {
              final ta = (a.data() as Map<String, dynamic>?)?['connected_at'];
              final tb = (b.data() as Map<String, dynamic>?)?['connected_at'];
              if (ta is Timestamp && tb is Timestamp) {
                return tb.compareTo(ta);
              }
              if (ta is Timestamp) return -1;
              if (tb is Timestamp) return 1;
              return 0;
            });

          _sessions = sessions;

          if (sessions.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.smartphone, size: 48, color: primaryAqua),
                  const SizedBox(height: 16),
                  const Text(
                    'Sin cuentas vinculadas',
                    style: TextStyle(fontSize: 18, color: white, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Toca el + para vincular una cuenta',
                    style: TextStyle(fontSize: 14, color: lightText),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final sessionDoc = sessions[index];
              // El id del doc es la sesión; el número que hoy usa vive en
              // `phone_number` (cambia si la sesión cambió de número).
              final phoneNumber = sessionDoc.id;
              final data = sessionDoc.data() as Map<String, dynamic>? ?? {};
              final alias = _aliasOf(sessionDoc);
              final previousLines = _livePreviousLines(data);
              final visual = _SessionVisual.from(
                data['status'] as String?,
                (data['last_sync'] as Timestamp?)?.toDate(),
              );
              final isConnected = visual.isConnected;

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: surfaceDark.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: visual.color.withValues(alpha: 0.2)),
                ),
                child: InkWell(
                  onTap: () {
                    final sessionKey = sessionDoc['session_key'] as String?;
                    // Permitimos entrar aunque no haya sessionKey (será modo lectura)
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatsScreen(
                          sessionId: phoneNumber,
                          sessionKey: sessionKey ?? 'disconnected',
                          accountId: widget.accountId,
                          initialAlias: alias,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: visual.color.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Center(
                                child: Text(
                                  alias.substring(0, 1).toUpperCase(),
                                  style: TextStyle(
                                    color: visual.color,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 22,
                                  ),
                                ),
                              ),
                            ),
                            // Badge de chats pendientes (estilo iOS app icon)
                            Positioned(
                              top: -6,
                              right: -6,
                              child: StreamBuilder<QuerySnapshot>(
                                stream: FirebaseFirestore.instance
                                    .collection(accountsCollection)
                                    .doc(widget.accountId)
                                    .collection('whatsapp_sessions')
                                    .doc(phoneNumber)
                                    .collection('chats')
                                    .where('unresponded_count', isGreaterThan: 0)
                                    .snapshots(),
                                builder: (context, snap) {
                                  final count = snap.data?.docs.length ?? 0;
                                  if (count <= 0) return const SizedBox.shrink();
                                  // Borde para separar visualmente del avatar
                                  return Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: darkBg, width: 2),
                                    ),
                                    child: UnrespondedBadge(count: count),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                alias,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                displayPhone(sessionPhone(data, phoneNumber)),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: lightText,
                                ),
                              ),
                              // La red de seguridad tras un cambio de número:
                              // el anterior sigue recibiendo en estos chats.
                              for (final line in previousLines)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Número anterior ${displayPhone(line)} · recibiendo',
                                    style: TextStyle(fontSize: 11.5, color: lightText.withValues(alpha: 0.75)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: visual.color.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (visual.showSpinner) ...[
                                    SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor: AlwaysStoppedAnimation<Color>(visual.color),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    visual.label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: visual.color,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Visible en CUALQUIER estado que no sea "conectado",
                            // reconexión incluida. Esconderlo durante `reconnecting`
                            // dejó a un cliente 26 horas sin salida cuando el estado
                            // se congeló ahí: la única acción que lo arreglaba era
                            // justo la que la UI ocultaba.
                            if (!isConnected)
                              IconButton(
                                icon: const Icon(Icons.sync, color: primaryAqua, size: 22),
                                onPressed: () => _onRelink(phoneNumber, data),
                                tooltip: 'Re-vincular cuenta',
                              ),
                          ],
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.settings_outlined, color: lightText, size: 20),
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              backgroundColor: surfaceDark,
                              isScrollControlled: true,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                              ),
                              builder: (_) => SessionSettingsPanel(
                                sessionId: phoneNumber,
                                accountId: widget.accountId,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Números anteriores que siguen conectados recibiendo (`previous_lines`). Los
/// desconectados no se muestran en la tarjeta: viven en Ajustes › Conexión.
List<String> _livePreviousLines(Map<String, dynamic> data) {
  final lines = data['previous_lines'];
  if (lines is! Map) return const [];
  return [
    for (final entry in lines.entries)
      if (entry.value is Map && (entry.value as Map)['status'] != 'disconnected') entry.key as String,
  ];
}

/// Cómo se ve una sesión en la lista, derivado de `status` + `last_sync`.
///
/// No basta con leer `status`: ese campo lo escribe el backend y, si el backend
/// se cae o pierde el hilo de una sesión, el doc queda congelado en lo último
/// que alcanzó a decir. El 03-sep-2026 una sesión pasó 26 horas mostrando
/// "Reconectando..." con un spinner girando sobre algo que ya no estaba pasando.
///
/// Por eso se cruza con `last_sync`: mientras una sesión está reconectando, el
/// watchdog del backend refresca ese timestamp cada 2 minutos. Si lleva más de
/// [_staleAfter] sin latir, el que se cayó fue el backend — y el spinner deja de
/// prometer una reconexión que nadie está intentando.
class _SessionVisual {
  final String label;
  final Color color;
  final bool showSpinner;
  final bool isConnected;

  const _SessionVisual({
    required this.label,
    required this.color,
    this.showSpinner = false,
    this.isConnected = false,
  });

  /// Holgado respecto al heartbeat de 2 min del backend: tres latidos perdidos
  /// antes de desconfiar, para no acusar de muerto a un backend que sólo tuvo
  /// un mal minuto.
  static const _staleAfter = Duration(minutes: 5);

  factory _SessionVisual.from(String? status, DateTime? lastSync) {
    if (status == 'connected') {
      return const _SessionVisual(label: 'Conectado', color: accentAqua, isConnected: true);
    }

    if (status == 'reconnecting') {
      final beat = lastSync == null || DateTime.now().difference(lastSync) > _staleAfter;
      return beat
          ? _SessionVisual(label: 'Sin respuesta', color: Colors.orange.shade400)
          : _SessionVisual(label: 'Reconectando...', color: Colors.orange.shade400, showSpinner: true);
    }

    if (status == 'reconnect_failed') {
      // El backend sigue reintentando de fondo, pero ya lleva rato caída: se
      // dice tal cual y se ofrece la salida manual.
      return _SessionVisual(label: 'Sin conexión', color: Colors.red.shade400);
    }

    return _SessionVisual(label: 'Desvinculado', color: Colors.red.shade400);
  }
}
