import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';
import '../link_result.dart';
import '../session_linking.dart';

/// Asistente "Cambiar de número": el número nuevo entra en esta sesión y se
/// queda con sus chats, mensajes, notas, etiquetas, respuestas rápidas,
/// asistente y permisos del equipo. No se copia nada: la sesión conserva su id
/// y sólo cambia el número (ver CLAUDE.md, "📲 Cambiar de número").
///
/// Todo se explica ANTES del QR: el cambio ocurre solo, en cuanto el número
/// nuevo conecta. Sólo para el owner (el backend lo exige también).
Future<void> showChangeNumberFlow(
  BuildContext context, {
  required String accountId,
  required String sessionId,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ChangeNumberScreen(accountId: accountId, sessionId: sessionId),
    ),
  );
}

class ChangeNumberScreen extends StatefulWidget {
  final String accountId;
  final String sessionId;

  const ChangeNumberScreen({required this.accountId, required this.sessionId, super.key});

  @override
  State<ChangeNumberScreen> createState() => _ChangeNumberScreenState();
}

class _ChangeNumberScreenState extends State<ChangeNumberScreen> {
  // La red de seguridad va por defecto: si el WhatsApp anterior sigue vivo,
  // perder lo que le escriban ahí es peor que tener una línea de más.
  bool _keepPrevious = true;
  bool _linking = false;
  LinkResult? _result;
  String? _error;

  DocumentReference<Map<String, dynamic>> get _sessionRef => FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId);

  Future<void> _scan({required bool previousIsLive}) async {
    setState(() {
      _linking = true;
      _error = null;
    });
    final result = await linkWhatsApp(
      context,
      accountId: widget.accountId,
      intoSessionId: widget.sessionId,
      allowNumberChange: true,
      keepPrevious: previousIsLive && _keepPrevious,
      title: 'Número nuevo',
      hint: 'Escanea con el WhatsApp de tu número NUEVO',
    );
    if (!mounted) return;
    setState(() {
      _linking = false;
      if (result == null) return; // salió antes de escanear: sigue aquí
      if (result.rejected) {
        _error = result.rejectionMessage;
      } else {
        _result = result;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cambiar de número'), elevation: 0),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _sessionRef.snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final data = snapshot.data!.data() ?? const <String, dynamic>{};
          final phone = sessionPhone(data, widget.sessionId);
          final alias = (data['alias'] as String?)?.trim().isNotEmpty == true ? data['alias'] as String : displayPhone(phone);

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: _result != null
                  ? _ResultView(result: _result!, alias: alias)
                  : _buildIntro(data, phone, alias),
            ),
          );
        },
      ),
    );
  }

  Widget _buildIntro(Map<String, dynamic> data, String phone, String alias) {
    final status = data['status'] as String?;
    final previousIsLive = status == 'connected' || status == 'reconnecting';
    final pausesAutomations = data['followup_enabled'] == true || data['reminder_enabled'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Badge(icon: Icons.swap_horiz),
        const SizedBox(height: 16),
        Text(
          'Cambiar ${displayPhone(phone)} por un número nuevo',
          style: const TextStyle(color: white, fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(alias, style: const TextStyle(color: lightText, fontSize: 14)),
        const SizedBox(height: 24),
        const _SectionTitle('Se queda todo'),
        const _Bullet(icon: Icons.check, text: 'Chats y mensajes, con sus fotos y archivos'),
        const _Bullet(icon: Icons.check, text: 'Notas, etiquetas y respuestas rápidas'),
        const _Bullet(icon: Icons.check, text: 'Asistente de IA, reglas y configuración'),
        const _Bullet(icon: Icons.check, text: 'Permisos de tu equipo'),
        const SizedBox(height: 20),
        const _SectionTitle('Qué cambia'),
        const _Bullet(
          icon: Icons.person_outline,
          text: 'Tus clientes verán los mensajes nuevos desde el número nuevo. '
              'Todavía no lo tienen guardado: preséntate en tu primer mensaje.',
        ),
        if (pausesAutomations)
          const _Bullet(
            icon: Icons.pause_circle_outline,
            text: 'Pausamos los seguimientos y recordatorios automáticos para cuidar tu '
                'número nuevo de un bloqueo. Los reactivas en Ajustes cuando lleve unos días.',
          ),
        if (previousIsLive) ...[
          const SizedBox(height: 20),
          _SectionTitle('${displayPhone(phone)} sigue conectado'),
          _Choice(
            selected: _keepPrevious,
            title: 'Dejarlo recibiendo mensajes',
            subtitle: 'Si alguien te escribe ahí, lo verás en el mismo chat marcado 📵 y '
                'contestarás desde tu número nuevo. WhatsApp lo desconecta solo si tu '
                'teléfono anterior pasa unos 14 días sin conectarse.',
            onTap: () => setState(() => _keepPrevious = true),
          ),
          _Choice(
            selected: !_keepPrevious,
            title: 'Desconectarlo de WhatHero',
            subtitle: 'Lo que te escriban a ese número ya no llegará aquí.',
            onTap: () => setState(() => _keepPrevious = false),
          ),
        ],
        const SizedBox(height: 20),
        const _Tip(
          '¿Todavía tienes tu WhatsApp anterior? Usa primero “Cambiar número” en '
          'WhatsApp (Ajustes › Cuenta): así tus contactos reciben el aviso de tu número nuevo.',
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _ErrorBox(_error!),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _linking ? null : () => _scan(previousIsLive: previousIsLive),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAqua,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: _linking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.qr_code_scanner),
            label: const Text('Escanear con el número nuevo', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

class _ResultView extends StatelessWidget {
  final LinkResult result;
  final String alias;

  const _ResultView({required this.result, required this.alias});

  @override
  Widget build(BuildContext context) {
    final from = result.numberChangedFrom;
    final children = <Widget>[
      const _Badge(icon: Icons.check, color: accentAqua),
      const SizedBox(height: 16),
    ];

    if (from == null) {
      // Escanearon con el mismo número: era una reconexión, no un cambio.
      children.addAll([
        const Text('Era el mismo número',
            style: TextStyle(color: white, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          '${displayPhone(result.phone)} quedó conectado otra vez. No cambió nada.',
          style: const TextStyle(color: lightText, fontSize: 15),
        ),
      ]);
    } else {
      children.addAll([
        Text(
          'Listo: “$alias” ahora usa ${displayPhone(result.phone)}',
          style: const TextStyle(color: white, fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 20),
        if (result.previousLine == 'kept')
          _Bullet(
            icon: Icons.phone_disabled_outlined,
            text: '${displayPhone(from)} sigue recibiendo mensajes. Lo que llegue ahí '
                'aparece en el mismo chat marcado 📵, y contestas desde el número nuevo.',
          )
        else if (result.previousLine == 'disconnected')
          _Bullet(icon: Icons.link_off, text: '${displayPhone(from)} se desconectó de WhatHero.'),
        if (result.pausedAutomations.isNotEmpty)
          _Bullet(
            icon: Icons.pause_circle_outline,
            text: 'Pausamos: ${result.pausedAutomations.map(automationLabel).join(' y ')}. '
                'Reactívalos en Ajustes de la sesión cuando tu número nuevo lleve unos días.',
          ),
        const _Bullet(
          icon: Icons.horizontal_rule,
          text: 'En cada chat verás una línea “Cambio de número” donde termina el '
              'historial del número anterior.',
        ),
      ]);
    }

    children.addAll([
      const SizedBox(height: 28),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryAqua,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Listo', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _Badge({required this.icon, this.color = primaryAqua});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, color: color, size: 30),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(color: primaryAqua, fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Bullet({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: lightText),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: white, fontSize: 14, height: 1.35))),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Choice({required this.selected, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: surfaceDark.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? primaryAqua : lightText.withValues(alpha: 0.15),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: selected ? primaryAqua : lightText,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: white, fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: const TextStyle(color: lightText, fontSize: 12.5, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  final String text;

  const _Tip(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: collisionAmber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline, size: 18, color: collisionAmber),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: white, fontSize: 13, height: 1.35))),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String text;

  const _ErrorBox(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: Colors.red.shade300),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: white, fontSize: 13, height: 1.35))),
        ],
      ),
    );
  }
}
