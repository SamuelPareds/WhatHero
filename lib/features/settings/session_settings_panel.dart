import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'package:crm_whatsapp/core/services/api_client.dart';
import 'package:crm_whatsapp/core/services/storage_service.dart';
import 'package:crm_whatsapp/core/utils/phone_input.dart';
import 'package:crm_whatsapp/core/utils/session_phone.dart';
import '../accounts/change_number/change_number_flow.dart';
import '../accounts/connect_cloud_api_sheet.dart';
import '../templates/templates_screen.dart';
import '../followups/followup_message.dart' show formatDayMonth, todayString;
import '../accounts/link_result.dart';
import '../chat/number_change_divider.dart';
import '../chat/widgets/label_editor_dialog.dart';
import 'delete_session_dialog.dart';
import 'session_settings_fields.dart';

/// Abre los Ajustes de la sesión a pantalla completa. Es la única forma de
/// abrirlos: la lista de chats, el chat abierto y Mis Cuentas pasan por aquí.
Future<void> openSessionSettings(
  BuildContext context, {
  required String accountId,
  required String sessionId,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => SessionSettingsPanel(accountId: accountId, sessionId: sessionId),
  ));
}

// Ajustes de la sesión, a pantalla completa (era una hoja al 85 %: con cinco
// pestañas, prompts largos y hojas encima, se quedaba corta y un arrastre la
// cerraba sin querer). Cada cambio se guarda donde se hace: los controles
// (switches, selectores, horas, slider) al instante y sólo su campo; el texto
// con su propio Guardar, o al salir de la pantalla. No hay "guardar todo": eso
// reescribía la pantalla entera y pisaba lo que otro (o el backend) había
// cambiado. Ver CLAUDE.md, "⚙️ Ajustes de sesión".
class SessionSettingsPanel extends StatefulWidget {
  final String sessionId;
  final String accountId;

  const SessionSettingsPanel({
    required this.sessionId,
    required this.accountId,
    super.key,
  });

  @override
  State<SessionSettingsPanel> createState() => _SessionSettingsPanelState();
}

enum _SaveStatus { idle, saving, saved }

class _SessionSettingsPanelState extends State<SessionSettingsPanel> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Campos de texto: cada uno sabe qué hay guardado y se guarda con su botón
  // (DraftSaveBar) o al cerrar el panel (_flushDrafts).
  final _aliasController = DraftTextController(field: 'alias', label: 'Alias');
  final _apiKeyController = DraftTextController(field: 'ai_api_key', label: 'API Key de Gemini');
  final _openaiApiKeyController = DraftTextController(field: 'ai_openai_api_key', label: 'API Key de OpenAI');
  final _deepseekApiKeyController = DraftTextController(field: 'ai_deepseek_api_key', label: 'API Key de DeepSeek');
  final _systemPromptController = DraftTextController(field: 'ai_system_prompt', label: 'Instrucciones del Sistema');
  final _discriminatorPromptController = DraftTextController(field: 'ai_discriminator_prompt', label: 'Reglas de Intervención Humana');
  final _reminderApiUrlController = DraftTextController(field: 'reminder_api_url', label: 'API URL de Sincronización');
  final _reminderTemplateController = DraftTextController(field: 'reminder_template', label: 'Mensaje de Recordatorio');
  final _followupExclusionController = DraftTextController(field: 'followup_exclusion_prompt', label: 'A quién NO dar seguimiento');
  final _followupMessageController = DraftTextController(field: 'followup_message_prompt', label: 'Tono del mensaje de seguimiento');

  List<DraftTextController> get _drafts => [
        _aliasController,
        _apiKeyController,
        _openaiApiKeyController,
        _deepseekApiKeyController,
        _systemPromptController,
        _discriminatorPromptController,
        _reminderApiUrlController,
        _reminderTemplateController,
        _followupExclusionController,
        _followupMessageController,
      ];

  // FocusNodes for focus management
  late FocusNode _systemPromptFocus;
  late FocusNode _discriminatorFocus;
  late FocusNode _reminderTemplateFocus;
  late FocusNode _followupExclusionFocus;
  late FocusNode _followupMessageFocus;
  
  // States
  bool _aiEnabled = false;
  String _selectedProvider = 'gemini';
  String _selectedModel = 'gemini-2.5-flash';
  int _responseDelaySeconds = 15;
  bool _activeHoursEnabled = false;
  String _activeHoursTimezone = 'America/Mexico_City';
  TimeOfDay _activeHoursStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _activeHoursEnd = const TimeOfDay(hour: 18, minute: 0);
  // Reglas del bot por palabra clave. Persistido en Firestore como
  // `bot_keyword_rules` (antes `ai_keyword_rules`); el rename refleja que
  // estas respuestas son canned, no generadas por la IA.
  List<Map<String, dynamic>> _botKeywordRules = [];
  bool _discriminatorEnabled = false;
  // Default true: es el comportamiento que hace útil la bandeja del teléfono.
  bool _markReadOnReply = true;

  // Allowlist de tipos de media que la IA puede leer. Por defecto todo en
  // false: la IA es solo-texto. En Fase 1 los toggles son read-only
  // ("próximamente"): el estado sólo se lee y el panel no lo escribe (el
  // backend trata la falta del campo como todo apagado). Cuando se abra la
  // edición en Fase 2, cada toggle se guarda con `_change`.
  bool _mediaAllowImage = false;
  bool _mediaAllowAudio = false;
  bool _mediaAllowVideo = false;
  bool _mediaAllowDocument = false;

  // AgendaCool
  bool _reminderEnabled = false;
  // `reminder_last_run` del doc: lo escribe el backend en cada lote.
  Map<String, dynamic>? _reminderLastRun;
  bool _sendingReminders = false;
  TimeOfDay _reminderScheduledTime = const TimeOfDay(hour: 9, minute: 0);

  // Agente de Seguimiento de Ventas (Re-engagement)
  bool _followupEnabled = false;

  // Número de la sesión. Sólo se muestran: los escribe el backend al cambiar
  // de número (ver CLAUDE.md, "📲 Cambiar de número").
  String? _linkedPhone;
  List<NumberChange> _numberHistory = const [];
  Map<String, dynamic> _previousLines = const {};
  List<String> _pausedAutomations = const [];
  String? _disconnectingLine;
  TimeOfDay _followupScheduledTime = const TimeOfDay(hour: 9, minute: 0);

  // Metadatos de WhatsApp Cloud API (Meta Oficial)
  bool _isCloudApi = false;
  String? _cloudApiPhoneNumberId;
  String? _cloudApiWabaId;
  String? _cloudApiVerifiedName;
  String? _cloudApiTokenHint;

  bool _isLoading = true;
  // Nombre de la sesión para el AppBar (alias, nombre verificado o número).
  String? _sessionName;
  // La lectura falló: se muestra el error con Reintentar, NUNCA un formulario
  // con valores por defecto (guardar ahí pisaba la configuración real).
  String? _loadError;
  // La sesión se está eliminando (lápida) o ya no existe.
  bool _sessionGone = false;

  // El panel escucha el doc en vivo: refleja lo que cambie el backend (pausa
  // por cambio de número, recordatorios en curso, línea anterior) u otro
  // operador, y si el servidor rechaza una escritura, el snapshot del
  // rollback devuelve el control a su valor sin lógica de revertir.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  // Lo que se ve y el doc todavía no tiene. Va en la primera escritura.
  Map<String, Object> _displayGaps = const {};

  // Estado del indicador del header (Guardando… / ✓ Guardado).
  final _saveStatus = ValueNotifier<_SaveStatus>(_SaveStatus.idle);
  int _writesInFlight = 0;
  bool _batchFailed = false;
  Timer? _savedTimer;

  DocumentReference<Map<String, dynamic>> get _sessionRef => FirebaseFirestore.instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId);

  Future<void> _openCloudApiConfig() async {
    // Lo que escriba la hoja llega solo por el listener.
    await showConnectCloudApiSheet(
      context,
      accountId: widget.accountId,
      intoSessionId: widget.sessionId,
      initialPhoneNumberId: _cloudApiPhoneNumberId,
      initialWabaId: _cloudApiWabaId,
      initialAlias: _aliasController.trimmed,
      tokenHint: _cloudApiTokenHint,
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _systemPromptFocus = FocusNode();
    _discriminatorFocus = FocusNode();
    _reminderTemplateFocus = FocusNode();
    _followupExclusionFocus = FocusNode();
    _followupMessageFocus = FocusNode();
    _listen();
  }

  void _listen() {
    _sub?.cancel();
    _sub = _sessionRef.snapshots().listen(_applySnapshot, onError: (Object e) {
      debugPrint('[SessionSettings] No se pudo leer la sesión ${widget.sessionId}: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = _errorReason(e);
      });
    });
  }

  void _retry() {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    _listen();
  }

  void _applySnapshot(DocumentSnapshot<Map<String, dynamic>> doc) {
    if (!mounted) return;
    final data = doc.data();
    // Un "no existe" del caché no es la respuesta: sin el doc cacheado, el
    // primer snapshot puede llegar vacío antes que el del servidor.
    if (data == null && doc.metadata.isFromCache) return;
    if (data == null || data['deleting_at'] != null) {
      // No se cierra el panel desde aquí: al eliminar desde este mismo panel,
      // la lápida llega con el diálogo de confirmación todavía abierto.
      setState(() {
        _isLoading = false;
        _sessionGone = true;
      });
      return;
    }

    String str(String field, [String fallback = '']) {
      final value = data[field];
      return value is String ? value : fallback;
    }

    setState(() {
      _isLoading = false;
      _loadError = null;
      _sessionGone = false;
      _displayGaps = sessionSettingsDisplayGaps(data);
      _sessionName = sessionDisplayName(data, widget.sessionId);
      _linkedPhone = sessionPhone(data, widget.sessionId);
      _isCloudApi = data['provider'] == 'cloud_api';
      _cloudApiPhoneNumberId = data['cloud_api_phone_number_id'] as String?;
      _cloudApiWabaId = data['cloud_api_waba_id'] as String?;
      _cloudApiVerifiedName = data['cloud_api_verified_name'] as String?;
      _cloudApiTokenHint = data['cloud_api_token_hint'] as String?;
      _numberHistory = parseNumberHistory(data['number_history']);
      _previousLines = data['previous_lines'] is Map
          ? Map<String, dynamic>.from(data['previous_lines'] as Map)
          : const {};
      final change = data['number_change'];
      _pausedAutomations = change is Map && change['pausedAutomations'] is List
          ? (change['pausedAutomations'] as List).whereType<String>().toList()
          : const [];

      // Texto: `applyServer` no pisa lo que el operador está escribiendo.
      // Sin alias el campo queda vacío: el resto de la app muestra el nombre
      // verificado o el número, y un "Sucursal - …" de relleno parecería
      // guardado sin estarlo.
      _aliasController.applyServer(str('alias', _cloudApiVerifiedName ?? ''));
      _apiKeyController.applyServer(str('ai_api_key'));
      _openaiApiKeyController.applyServer(str('ai_openai_api_key'));
      _deepseekApiKeyController.applyServer(str('ai_deepseek_api_key'));
      _systemPromptController.applyServer(str('ai_system_prompt', defaultSystemPrompt));
      _discriminatorPromptController.applyServer(str('ai_discriminator_prompt'));
      _reminderApiUrlController.applyServer(str('reminder_api_url'));
      _reminderTemplateController.applyServer(str('reminder_template', defaultReminderTemplate));
      _followupExclusionController.applyServer(str('followup_exclusion_prompt'));
      _followupMessageController.applyServer(str('followup_message_prompt'));

      _aiEnabled = data['ai_enabled'] ?? false;
      _selectedProvider = str('ai_provider', defaultAiProvider);
      _selectedModel = str('ai_model', defaultModelFor(_selectedProvider));
      _responseDelaySeconds = responseDelaySecondsFrom(data['ai_response_delay_ms']);

      _reminderEnabled = data['reminder_enabled'] ?? false;
      _reminderLastRun = data['reminder_last_run'] as Map<String, dynamic>?;
      if (data['reminder_scheduled_time'] is String) {
        _reminderScheduledTime = _parseTime(data['reminder_scheduled_time'] as String, 9);
      }

      _followupEnabled = data['followup_enabled'] ?? false;
      if (data['followup_scheduled_time'] is String) {
        _followupScheduledTime = _parseTime(data['followup_scheduled_time'] as String, 9);
      }

      if (data['ai_active_hours'] is Map) {
        final hours = data['ai_active_hours'] as Map;
        _activeHoursEnabled = hours['enabled'] ?? false;
        _activeHoursTimezone = hours['timezone'] ?? 'America/Mexico_City';
        if (hours['start'] is String) _activeHoursStart = _parseTime(hours['start'] as String, 9);
        if (hours['end'] is String) _activeHoursEnd = _parseTime(hours['end'] as String, 18);
      }

      // Back-compat: leer del nuevo nombre (`bot_keyword_rules`) primero
      // y caer al viejo (`ai_keyword_rules`) si todavía no se migró.
      // Reglas sin campo `trigger` se asumen como 'incoming' para preservar
      // su comportamiento histórico hasta que el usuario las edite.
      final rawRules = data['bot_keyword_rules'] ?? data['ai_keyword_rules'];
      if (rawRules is List) {
        _botKeywordRules = List<Map<String, dynamic>>.from(rawRules.map((rule) => {
          // `ruleId` ancla el archivo en Storage (path determinista).
          // Reglas legacy no lo tienen → se genera al editarlas en el sheet.
          'ruleId': rule['ruleId'] as String? ?? '',
          'keyword': rule['keyword'] as String? ?? '',
          'response': rule['response'] as String? ?? '',
          'imageUrl': rule['imageUrl'] as String? ?? '',
          // Adjunto documento (PDF). Una regla lleva imagen O documento.
          'documentUrl': rule['documentUrl'] as String? ?? '',
          'documentName': rule['documentName'] as String? ?? '',
          'trigger': (rule['trigger'] as String?) ?? 'incoming',
        }));
      }

      _markReadOnReply = data['mark_read_on_reply'] ?? true;
      _discriminatorEnabled = data['ai_discriminator_enabled'] ?? false;

      if (data['ai_media_allowlist'] is Map) {
        final allow = data['ai_media_allowlist'] as Map;
        _mediaAllowImage = allow['image'] == true;
        _mediaAllowAudio = allow['audio'] == true;
        _mediaAllowVideo = allow['video'] == true;
        _mediaAllowDocument = allow['document'] == true;
      }
    });
  }

  static TimeOfDay _parseTime(String hhmm, int fallbackHour) {
    final parts = hhmm.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? fallbackHour,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  static String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Map<String, Object> get _activeHoursMap => {
        'enabled': _activeHoursEnabled,
        'timezone': _activeHoursTimezone,
        'start': _hhmm(_activeHoursStart),
        'end': _hhmm(_activeHoursEnd),
      };

  static String _errorReason(Object e) {
    if (e is FirebaseException) {
      switch (e.code) {
        case 'permission-denied':
          return 'no tienes permiso para cambiar esta sesión';
        case 'unavailable':
          return 'sin conexión';
        case 'not-found':
          return 'la sesión ya no existe';
      }
      return e.message ?? e.code;
    }
    return '$e';
  }

  // El único que escribe en el doc de la sesión desde el panel. Escribe SÓLO
  // los campos que cambiaron (más lo que se ve y el doc no tiene, ver
  // `sessionSettingsDisplayGaps`). Si el servidor lo rechaza, avisa; el
  // control vuelve a su valor solo, con el snapshot del rollback.
  Future<bool> _saveFields(Map<String, Object?> fields, {required String what}) async {
    if (_sessionGone || !mounted) return false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final payload = {..._displayGaps, ...fields};
    _displayGaps = const {};
    if (_writesInFlight++ == 0) _batchFailed = false;
    _savedTimer?.cancel();
    _saveStatus.value = _SaveStatus.saving;
    try {
      await _sessionRef.update(payload);
      return true;
    } catch (e) {
      _batchFailed = true;
      debugPrint('[SessionSettings] No se pudo guardar $what: $e');
      messenger?.showSnackBar(SnackBar(content: Text('No se pudo guardar $what: ${_errorReason(e)}')));
      return false;
    } finally {
      if (--_writesInFlight == 0 && mounted) {
        if (_batchFailed) {
          _saveStatus.value = _SaveStatus.idle;
        } else {
          _saveStatus.value = _SaveStatus.saved;
          _savedTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) _saveStatus.value = _SaveStatus.idle;
          });
        }
      }
    }
  }

  // Controles discretos: se ven al instante y se guardan al instante.
  void _change(VoidCallback apply, Map<String, Object?> fields, String what) {
    setState(apply);
    _saveFields(fields, what: what);
  }

  // El horario se guarda como mapa completo, cambie la pieza que cambie.
  void _changeActiveHours(VoidCallback apply) {
    setState(apply);
    _saveFields({'ai_active_hours': _activeHoursMap}, what: 'Horario de Atención');
  }

  Future<bool> _saveDraft(DraftTextController draft) async {
    try {
      await draft.save((value) async {
        if (!await _saveFields({draft.field: value}, what: draft.label)) {
          throw StateError('No se guardó ${draft.field}');
        }
      });
      return true;
    } catch (_) {
      return false; // el aviso ya salió desde _saveFields
    }
  }

  // Al salir de la pantalla (flecha, atrás de Android, gesto de iOS), lo
  // escrito y no guardado se guarda solo y se avisa. Se guarda en vez de
  // preguntar "¿descartar cambios?": preguntar exige `canPop: false`, que en
  // iOS apaga el gesto de volver mientras haya cambios, y perder un prompt
  // largo es mucho peor que guardar algo que se podía descartar con su botón.
  void _flushDrafts() {
    if (_sessionGone) return;
    final pending = _drafts.where((d) => d.isDirty && !d.isSaving).toList();
    if (pending.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final names = pending.map((d) => '«${d.label}»').join(', ');
    _sessionRef.update({
      ..._displayGaps,
      for (final d in pending) d.field: d.trimmed,
    }).then((_) {
      messenger?.showSnackBar(SnackBar(content: Text('Se guardó lo que escribiste en $names.')));
    }, onError: (Object e) {
      debugPrint('[SessionSettings] No se pudo guardar al cerrar: $e');
      messenger?.showSnackBar(SnackBar(content: Text('No se pudo guardar lo que escribiste en $names: ${_errorReason(e)}')));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _savedTimer?.cancel();
    _saveStatus.dispose();
    _tabController.dispose();
    for (final draft in _drafts) {
      draft.dispose();
    }
    _systemPromptFocus.dispose();
    _discriminatorFocus.dispose();
    _reminderTemplateFocus.dispose();
    _followupExclusionFocus.dispose();
    _followupMessageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Se salga como se salga (flecha, atrás de Android, gesto de iOS), lo
      // escrito no se pierde.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flushDrafts();
      },
      child: Scaffold(
        // surfaceDark y no darkBg: las tarjetas del panel son darkBg
        // translúcido y sobre darkBg desaparecerían.
        backgroundColor: surfaceDark,
        appBar: _buildAppBar(),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: primaryAqua));
    }
    if (_loadError != null) {
      return _buildBlocked(
        icon: Icons.cloud_off_outlined,
        title: 'No se pudo leer la configuración',
        detail: _loadError!,
        onRetry: _retry,
      );
    }
    if (_sessionGone) {
      return _buildBlocked(
        icon: Icons.delete_outline,
        title: 'Esta sesión se está eliminando',
        detail: 'Ya no se puede cambiar su configuración.',
      );
    }
    // En escritorio el contenido no se estira a todo el ancho: un campo de
    // 1 800 px es ilegible y los switches quedarían lejísimos de su texto.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          children: [
            _buildTabBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildGeneralTab(),
                  _buildAITab(),
                  _buildRulesTab(),
                  _buildLabelsTab(),
                  _buildIntegrationsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Lectura fallida o sesión eliminada: un aviso, nunca un formulario.
  Widget _buildBlocked({required IconData icon, required String title, required String detail, VoidCallback? onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: lightText.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: lightText, fontSize: 13)),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(backgroundColor: primaryAqua, foregroundColor: darkBg),
                child: const Text('Reintentar'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Título + de qué sesión son estos ajustes. Con varias cuentas abiertas el
  // nombre importa: el dispatcher puede cambiar la sesión de la lista (un push
  // de otra cuenta) mientras esta pantalla sigue arriba.
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: surfaceDark,
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Ajustes de Sesión',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: white),
          ),
          if (_sessionName != null)
            Text(
              _sessionName!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: lightText),
            ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16, left: 8),
          child: Center(child: _buildSaveStatus()),
        ),
      ],
    );
  }

  // "Guardando…" / "✓ Guardado" a la derecha del título. Es la confirmación
  // de los cambios al instante; los errores van en SnackBar.
  Widget _buildSaveStatus() {
    return ValueListenableBuilder<_SaveStatus>(
      valueListenable: _saveStatus,
      builder: (context, status, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: switch (status) {
          _SaveStatus.idle => const SizedBox.shrink(key: ValueKey('idle')),
          _SaveStatus.saving => const Row(
              key: ValueKey('saving'),
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: lightText)),
                SizedBox(width: 6),
                Text('Guardando…', style: TextStyle(color: lightText, fontSize: 12)),
              ],
            ),
          _SaveStatus.saved => const Row(
              key: ValueKey('saved'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, size: 14, color: primaryAqua),
                SizedBox(width: 5),
                Text('Guardado', style: TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
        },
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(16)),
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(color: primaryAqua.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12), border: Border.all(color: primaryAqua.withValues(alpha: 0.5))),
        labelColor: primaryAqua,
        unselectedLabelColor: lightText,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: const [
          Tab(icon: Icon(Icons.person_outline, size: 20), text: 'Perfil'),
          Tab(icon: Icon(Icons.auto_awesome_outlined, size: 20), text: 'Asistente'),
          Tab(icon: Icon(Icons.reply_all_rounded, size: 20), text: 'Respuestas'),
          Tab(icon: Icon(Icons.label_outline, size: 20), text: 'Etiquetas'),
          Tab(icon: Icon(Icons.electrical_services, size: 20), text: 'Conexión'),
        ],
      ),
    );
  }

  Widget _buildGeneralTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Identidad de la Cuenta'),
          const SizedBox(height: 8),
          const Text('Este nombre te ayudará a identificar esta sucursal o número rápidamente.', style: TextStyle(color: lightText, fontSize: 13)),
          const SizedBox(height: 20),
          _textField(
            controller: _aliasController,
            label: 'Nombre Personalizado (Alias)',
            hint: 'Ej: Ventas México, Sucursal Centro...',
            icon: Icons.edit_note,
          ),
          const SizedBox(height: 32),
          _sectionTitle('Información de Conexión'),
          const SizedBox(height: 16),
          _infoTile('Número Vinculado', displayPhone(_linkedPhone ?? widget.sessionId), Icons.chat_bubble_outline),
          _infoTile('ID de Sesión', widget.sessionId, Icons.fingerprint),
          if (_isCloudApi) ...[
            _infoTile(
              'Proveedor',
              'Meta WhatsApp Cloud API (${_cloudApiVerifiedName ?? 'Oficial'})',
              Icons.cloud_done_rounded,
            ),
            if (_cloudApiPhoneNumberId != null && _cloudApiPhoneNumberId!.isNotEmpty)
              _infoTile('Phone Number ID', _cloudApiPhoneNumberId!, Icons.pin_outlined),
            if (_cloudApiWabaId != null && _cloudApiWabaId!.isNotEmpty)
              _infoTile('WABA ID', _cloudApiWabaId!, Icons.business_outlined),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openCloudApiConfig,
                icon: const Icon(Icons.key_rounded, color: primaryAqua, size: 20),
                label: const Text(
                  'Actualizar Access Token / Ver Webhook de Meta',
                  style: TextStyle(color: primaryAqua),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MetaTemplatesScreen(
                    accountId: widget.accountId,
                    sessionId: widget.sessionId,
                    sessionPhone: _linkedPhone,
                  ),
                )),
                icon: const Icon(Icons.article_outlined, color: primaryAqua, size: 20),
                label: const Text(
                  'Plantillas de WhatsApp (crear y revisar)',
                  style: TextStyle(color: primaryAqua),
                ),
              ),
            ),
          ] else ...[
            if (_numberHistory.isNotEmpty) _buildPreviousNumbers(),
            if (AccountContextService().isOwner)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _openChangeNumber,
                  icon: const Icon(Icons.swap_horiz, color: primaryAqua, size: 20),
                  label: const Text('Cambiar a un número nuevo', style: TextStyle(color: primaryAqua)),
                ),
              ),
          ],
          const SizedBox(height: 32),
          _sectionTitle('Sincronización con WhatsApp'),
          const SizedBox(height: 8),
          const Text(
            'Al responder un chat (tú o la IA) se limpia su "no leído" en el WhatsApp de tu teléfono. '
            'Lo que siga sin leer allá es lo que de verdad falta atender: sin esto, la bandeja crece '
            'sin techo y deja de servir para encontrar a quien te escribió.',
            style: TextStyle(color: lightText, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _switchTile(
            'Marcar como leído al responder',
            _markReadOnReply,
            (v) => _change(() => _markReadOnReply = v, {'mark_read_on_reply': v}, 'Marcar como leído'),
          ),
          if (AccountContextService().isOwner) ..._buildDangerZone(),
        ],
      ),
    );
  }

  // Eliminar la sesión con todo lo suyo. Sólo el owner (el backend también lo
  // exige). Ver delete_session_dialog.dart.
  List<Widget> _buildDangerZone() {
    return [
      const SizedBox(height: 40),
      const Text('Zona de peligro', style: TextStyle(color: Color(0xFFF87171), fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text(
        'Si ya no trabajas con este número, elimina la sesión y todo lo suyo: chats, mensajes, '
        'archivos, configuración y permisos del equipo. No queda nada en WhatHero.',
        style: TextStyle(color: lightText, fontSize: 13),
      ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _deleteSession,
          icon: const Icon(Icons.delete_forever_outlined, color: Colors.red, size: 20),
          label: const Text('Eliminar esta sesión', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    ];
  }

  Future<void> _deleteSession() async {
    final phone = _linkedPhone ?? widget.sessionId;
    final alias = _aliasController.text.trim();
    final loggedOut = await showDeleteSessionDialog(
      context,
      accountId: widget.accountId,
      sessionId: widget.sessionId,
      alias: alias.isEmpty ? displayPhone(phone) : alias,
      phone: phone,
    );
    if (loggedOut == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    await StorageService().clearLastSessionIdIf(widget.sessionId);
    if (!mounted) return;
    // Sólo se cierra el panel: lo demás reacciona solo a la lápida (la lista
    // muestra "Eliminando…" y, si es la sesión que se ve, el dispatcher cambia
    // a otra y lo avisa).
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        loggedOut
            ? 'Eliminando la sesión. WhatHero también se cerró en el WhatsApp del teléfono.'
            : 'Eliminando la sesión. Si en el teléfono sigue apareciendo WhatHero en '
                'Dispositivos vinculados, ciérralo desde ahí.',
      ),
    ));
  }

  // Números que usó esta sesión antes del actual, del más reciente al más
  // viejo. El que quedó conectado recibiendo se puede desconectar aquí.
  Widget _buildPreviousNumbers() {
    final isOwner = AccountContextService().isOwner;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.history, color: lightText, size: 20),
            SizedBox(width: 16),
            Text('Números anteriores', style: TextStyle(color: lightText, fontSize: 11)),
          ]),
          for (final change in _numberHistory.reversed) ...[
            const SizedBox(height: 10),
            _previousNumberRow(change, isOwner),
          ],
        ],
      ),
    );
  }

  Widget _previousNumberRow(NumberChange change, bool isOwner) {
    final line = _previousLines[change.phone];
    final status = line is Map ? line['status'] as String? : null;
    final live = status != null && status != 'disconnected';
    final statusLabel = switch (status) {
      'connected' => 'Recibiendo mensajes',
      'reconnecting' => 'Reconectando…',
      'reconnect_failed' => 'Sin conexión',
      _ => null,
    };

    return Row(
      children: [
        const SizedBox(width: 36),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(displayPhone(change.phone), style: const TextStyle(color: white, fontWeight: FontWeight.bold)),
              Text(
                'Hasta el ${shortDate(change.until)}${statusLabel != null ? ' · $statusLabel' : ''}',
                style: TextStyle(color: status == 'connected' ? accentAqua : lightText, fontSize: 12),
              ),
            ],
          ),
        ),
        if (live && isOwner)
          _disconnectingLine == change.phone
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: () => _disconnectPreviousLine(change.phone),
                  child: Text('Desconectar', style: TextStyle(color: Colors.red.shade300)),
                ),
      ],
    );
  }

  Future<void> _openChangeNumber() async {
    // El cambio reescribe el número, el alias por defecto y pausa los
    // automáticos: llega solo por el listener. Como el panel guarda campo por
    // campo, ya no hay un "Guardar" que pueda volver a encenderlos.
    await showChangeNumberFlow(context, accountId: widget.accountId, sessionId: widget.sessionId);
  }

  Future<void> _disconnectPreviousLine(String phone) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: surfaceDark,
        title: Text('¿Desconectar ${displayPhone(phone)}?', style: const TextStyle(color: white)),
        content: const Text(
          'Lo que te escriban a ese número ya no llegará a WhatHero. Para volver a recibirlo '
          'tendrías que escanear un QR con ese teléfono.',
          style: TextStyle(color: lightText),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Desconectar', style: TextStyle(color: Colors.red.shade300)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _disconnectingLine = phone);
    try {
      final response = await http
          .post(
            Uri.parse('$backendUrl/sessions/previous-line/disconnect'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': widget.accountId, 'sessionId': widget.sessionId, 'phone': phone}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      messenger.showSnackBar(SnackBar(content: Text('${displayPhone(phone)} desconectado')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('No se pudo desconectar: $e')));
    } finally {
      if (mounted) setState(() => _disconnectingLine = null);
    }
  }

  // Aviso junto al switch de un automático que se pausó al cambiar de número.
  // Desaparece en cuanto el operador lo vuelve a encender.
  Widget _pausedByNumberChange(String automation, bool enabled) {
    if (enabled || !_pausedAutomations.contains(automation)) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: collisionAmber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.pause_circle_outline, size: 18, color: collisionAmber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${automationLabel(automation)}: en pausa desde el cambio de número, para cuidar '
              'tu número nuevo de un bloqueo. Reactívalo cuando lleve unos días.',
              style: const TextStyle(color: white, fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAITab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          _switchTile('Activar Asistente IA', _aiEnabled, (v) => _change(() => _aiEnabled = v, {'ai_enabled': v}, 'Asistente IA')),
          const SizedBox(height: 24),
          _sectionTitle('Cerebro del Asistente'),
          const SizedBox(height: 16),
          _dropdownTile('Proveedor', _selectedProvider, ['gemini', 'openai', 'deepseek'], (v) {
            // Proveedor y modelo van juntos: un modelo de otro proveedor
            // guardado a medias rompería la siguiente respuesta.
            final model = defaultModelFor(v);
            _change(() {
              _selectedProvider = v!;
              _selectedModel = model;
            }, {'ai_provider': v, 'ai_model': model}, 'Proveedor');
          }),
          const SizedBox(height: 16),
          _modelDropdownTile(),
          const SizedBox(height: 16),
          _textField(
            controller: _activeApiKeyController,
            label: 'API Key (${_selectedProvider.toUpperCase()})',
            hint: 'Pega tu llave aquí...',
            isPassword: true,
          ),
          const SizedBox(height: 24),
          _sectionTitle('Personalidad y Tiempo'),
          const SizedBox(height: 16),
          _textField(
            controller: _systemPromptController,
            label: 'Instrucciones del Sistema',
            hint: 'Ej: Eres un asistente de ventas amable...',
            maxLines: 5,
            canExpand: true,
            focusNode: _systemPromptFocus,
          ),
          const SizedBox(height: 24),
          _responseDelayTile(),
          const SizedBox(height: 24),
          _sectionTitle('Control de Disponibilidad'),
          const SizedBox(height: 16),
          _expandableSection(
            'Horario de Atención',
            Icons.access_time,
            _activeHoursEnabled,
            (v) => _changeActiveHours(() => _activeHoursEnabled = v),
            Column(
              children: [
                _dropdownTile('Zona Horaria', _activeHoursTimezone, ['America/Mexico_City', 'America/New_York', 'Europe/Madrid'], (v) => _changeActiveHours(() => _activeHoursTimezone = v!)),
                Row(
                  children: [
                    Expanded(child: _timeTile('Apertura', _activeHoursStart, (t) => _changeActiveHours(() => _activeHoursStart = t))),
                    const SizedBox(width: 12),
                    Expanded(child: _timeTile('Cierre', _activeHoursEnd, (t) => _changeActiveHours(() => _activeHoursEnd = t))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _expandableSection(
            'Discriminador IA',
            Icons.psychology,
            _discriminatorEnabled,
            (v) => _change(() => _discriminatorEnabled = v, {'ai_discriminator_enabled': v}, 'Discriminador IA'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Define cuándo se requiere atención humana (lenguaje natural)',
                  style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12),
                ),
                const SizedBox(height: 12),
                _textField(
                  controller: _discriminatorPromptController,
                  label: 'Reglas de Intervención Humana',
                  hint: 'Ejemplo:\n\nPasa al humano si:\n- El cliente pregunta disponibilidad de fechas específicas\n- Quiere agendar una cita\n- Pregunta por saldo o historial personal\n\nDe lo contrario, responde tú mismo.',
                  maxLines: 6,
                  canExpand: true,
                  focusNode: _discriminatorFocus,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _pausedByNumberChange('followups', _followupEnabled),
          _expandableSection(
            'Seguimiento de Ventas',
            Icons.campaign_outlined,
            _followupEnabled,
            (v) => _change(() => _followupEnabled = v, {'followup_enabled': v}, 'Seguimiento de Ventas'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cada día revisa las conversaciones que quedaron frías sin cerrar y deja un mensaje de seguimiento en una cola para que lo apruebes antes de enviar.',
                  style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.campaign_outlined, size: 16, color: primaryAqua),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Para revisar más días o mandar un mensaje tuyo (una promo, por ejemplo), usa Campañas: el ícono del megáfono en la lista de chats. Las reglas de "A quién NO" de aquí también se aplican ahí.',
                        style: TextStyle(color: primaryAqua.withValues(alpha: 0.85), fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _timeTile(
                  'Hora del Barrido Diario',
                  _followupScheduledTime,
                  (t) => _change(() => _followupScheduledTime = t, {'followup_scheduled_time': _hhmm(t)}, 'Hora del Barrido Diario'),
                ),
                const SizedBox(height: 16),
                _textField(
                  controller: _followupExclusionController,
                  label: 'A quién NO dar seguimiento (lenguaje natural)',
                  hint: 'Ejemplo:\n\nNo des seguimiento si:\n- El cliente ya agendó o se le confirmó la cita\n- Es una conversación personal o no comercial\n- Dijo "luego te aviso" o "yo te escribo"\n- Rechazó la oferta',
                  maxLines: 6,
                  canExpand: true,
                  focusNode: _followupExclusionFocus,
                ),
                const SizedBox(height: 16),
                _textField(
                  controller: _followupMessageController,
                  label: 'Tono del mensaje de seguimiento',
                  hint: 'Ejemplo: Sé cálido y cercano. Retoma con naturalidad el servicio que preguntó e invítalo a agendar, sin presionar.',
                  maxLines: 4,
                  canExpand: true,
                  focusNode: _followupMessageFocus,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _mediaFiltersCard(),
        ],
      ),
    );
  }

  // Tarjeta de "Filtros de Media": informa al usuario por qué un mensaje con
  // multimedia se redirige a humano cuando la IA aún no puede leer ese tipo.
  // En Fase 1 los toggles son read-only ("próximamente"). En fases futuras
  // se habilitarán cuando integremos lectura multimodal por tipo.
  Widget _mediaFiltersCard() {
    return Container(
      decoration: BoxDecoration(
        color: darkBg.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: primaryAqua),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Filtros de Media',
                  style: TextStyle(color: white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: primaryAqua.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'SIEMPRE ACTIVO',
                  style: TextStyle(color: primaryAqua, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'El asistente IA solo entiende texto. Cuando un cliente envía media de un tipo que la IA aún no puede leer, su mensaje se redirige automáticamente a un humano para evitar respuestas sin contexto. Los stickers y GIFs se ignoran (son decorativos).',
            style: TextStyle(color: lightText.withValues(alpha: 0.85), fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 16),
          _mediaToggleRow(Icons.image_outlined, 'Imágenes', _mediaAllowImage, comingSoon: true),
          const SizedBox(height: 8),
          _mediaToggleRow(Icons.mic_none_outlined, 'Audios y notas de voz', _mediaAllowAudio, comingSoon: true),
          const SizedBox(height: 8),
          _mediaToggleRow(Icons.description_outlined, 'Documentos', _mediaAllowDocument, comingSoon: true),
          const SizedBox(height: 8),
          _mediaToggleRow(
            Icons.videocam_outlined,
            'Videos',
            _mediaAllowVideo,
            comingSoon: true,
            note: 'Costo elevado en tokens',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: primaryAqua.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: primaryAqua.withValues(alpha: 0.8), size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Los toggles se irán habilitando conforme la IA aprenda a leer cada tipo de media.',
                    style: TextStyle(color: lightText.withValues(alpha: 0.8), fontSize: 11, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Fila individual del filtro de media. En Fase 1 todos los toggles llegan
  // con comingSoon=true (deshabilitados visualmente con etiqueta).
  Widget _mediaToggleRow(IconData icon, String label, bool value, {bool comingSoon = false, String? note}) {
    return Opacity(
      opacity: comingSoon ? 0.55 : 1.0,
      child: Row(
        children: [
          Icon(icon, color: primaryAqua, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wrap y no Row: en un iPhone de 393pt "Audios y notas de voz"
                // + la etiqueta ya no caben, y la etiqueta baja de línea en
                // vez de recortarse.
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(label, style: const TextStyle(color: white, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (comingSoon)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: lightText.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'PRÓXIMAMENTE',
                          style: TextStyle(color: lightText, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 0.4),
                        ),
                      ),
                  ],
                ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(note, style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 10)),
                  ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: primaryAqua,
            onChanged: comingSoon ? null : (v) {},
          ),
        ],
      ),
    );
  }

  Widget _buildRulesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Respuestas Automáticas'),
          const SizedBox(height: 8),
          const Text(
            'Cuando un mensaje contiene la palabra clave, el bot envía una respuesta inmediata sin pasar por la IA. Elige si la regla se dispara con mensajes del cliente, con los que tú envías (desde aquí, WhatsApp Web o el celular), o con ambos.',
            style: TextStyle(color: lightText, fontSize: 13),
          ),
          const SizedBox(height: 20),
          if (_botKeywordRules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Aún no tienes respuestas automáticas. Crea una con el botón de abajo.',
                style: TextStyle(color: lightText.withValues(alpha: 0.6), fontSize: 13),
              ),
            )
          else
            ..._botKeywordRules.asMap().entries.map((e) => _keywordTile(
                  e.key,
                  e.value['keyword'] as String? ?? '',
                  e.value['response'] as String? ?? '',
                  e.value['imageUrl'] as String?,
                  e.value['documentUrl'] as String?,
                  e.value['trigger'] as String? ?? 'incoming',
                )),
          const SizedBox(height: 12),
          // Botón sutil para crear una regla nueva (abre el editor en blanco)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showRuleEditor(),
              icon: const Icon(Icons.add, size: 18, color: primaryAqua),
              label: const Text('Nueva regla',
                  style: TextStyle(color: primaryAqua, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: primaryAqua.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Abre el editor de regla en bottom sheet. Sin argumentos → crear; con
  // index → editar esa regla. Cada acción (crear/editar/eliminar) se persiste
  // de inmediato en Firestore, igual que las etiquetas.
  Future<void> _showRuleEditor([int? index]) async {
    final existing = index != null ? _botKeywordRules[index] : null;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _KeywordRuleEditorSheet(
        accountId: widget.accountId,
        sessionId: widget.sessionId,
        ruleId: existing?['ruleId'] as String? ?? '',
        keyword: existing?['keyword'] as String? ?? '',
        response: existing?['response'] as String? ?? '',
        imageUrl: existing?['imageUrl'] as String? ?? '',
        documentUrl: existing?['documentUrl'] as String? ?? '',
        documentName: existing?['documentName'] as String? ?? '',
        // Reglas nuevas arrancan en 'both'; las existentes conservan su trigger
        trigger: existing?['trigger'] as String? ?? (index == null ? 'both' : 'incoming'),
        isEditing: index != null,
      ),
    );

    if (result == null) return; // canceló

    final deleted = result['_delete'] == true;
    if (deleted) {
      // Limpieza best-effort: borra los archivos en Storage antes de quitar la
      // regla del array. Cubre el borrado directo de la regla completa.
      await _deleteRuleAttachments(result['ruleId'] as String?);
    }

    setState(() {
      if (deleted) {
        if (index != null) _botKeywordRules.removeAt(index);
      } else if (index != null) {
        _botKeywordRules[index] = result;
      } else {
        _botKeywordRules.add(result);
      }
    });

    await _persistRules(deleted: deleted);
  }

  // Borra los objetos (imagen y/o documento) de una regla en Storage; ignora
  // los que no existan (reglas sin adjunto o con URL externa legacy).
  Future<void> _deleteRuleAttachments(String? ruleId) async {
    if (ruleId == null || ruleId.isEmpty) return;
    final base = '$accountsCollection/${widget.accountId}/whatsapp_sessions/'
        '${widget.sessionId}/bot_rules/$ruleId';
    for (final ext in ['jpg', 'pdf']) {
      try {
        await FirebaseStorage.instance.ref('$base.$ext').delete();
      } catch (_) {
        // Sin archivo o sin permiso → no es crítico.
      }
    }
  }

  // Persiste solo el campo de reglas de inmediato, siguiendo el patrón de las
  // etiquetas.
  Future<void> _persistRules({bool deleted = false}) async {
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .update({'bot_keyword_rules': _botKeywordRules});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(deleted ? 'Regla eliminada' : 'Regla guardada')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    }
  }

  // "Enviar ahora": antes era un comando que cualquiera podía escribir por
  // WhatsApp ("enviar recordatorios"), y lo escribía también un cliente. El
  // backend lee la configuración GUARDADA, así que primero se guarda lo que
  // el operador dejó escrito en la URL y el mensaje: si no, salía el mensaje
  // viejo. Si hoy ya salieron, pregunta antes de repetir: cada cliente
  // recibiría su recordatorio dos veces.
  Future<void> _sendRemindersNow({bool force = false}) async {
    setState(() => _sendingReminders = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final draft in [_reminderApiUrlController, _reminderTemplateController]) {
        if ((draft.isDirty || draft.isSaving) && !await _saveDraft(draft)) return;
      }
      if (!mounted) return;
      final response = await http
          .post(
            Uri.parse('$backendUrl/send-reminders'),
            headers: await authHeaders(),
            body: jsonEncode({'accountId': widget.accountId, 'sessionId': widget.sessionId, 'force': force}),
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      Map<String, dynamic> body = const {};
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}
      if (response.statusCode == 202) {
        setState(() => _reminderLastRun = {'day': todayString(), 'status': 'running'});
        messenger.showSnackBar(const SnackBar(content: Text('Enviando recordatorios: sale uno cada 7 segundos.')));
        return;
      }
      if (body['code'] == 'already_sent_today') {
        final last = body['lastRun'] as Map<String, dynamic>?;
        final sent = (last?['sent'] as num?)?.toInt() ?? 0;
        final running = last?['status'] == 'running';
        final again = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: surfaceDark,
            title: const Text('Hoy ya se enviaron', style: TextStyle(color: white)),
            content: Text(
              running
                  ? 'Un envío de hoy quedó a medias (el servidor se reinició mientras enviaba). Si los mandas otra vez, quienes ya lo recibieron lo recibirán dos veces.'
                  : 'Hoy ya salieron $sent ${sent == 1 ? 'recordatorio' : 'recordatorios'}. Si los mandas otra vez, cada cliente recibirá el suyo dos veces.',
              style: const TextStyle(color: lightText, height: 1.4),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No enviar')),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Enviar otra vez', style: TextStyle(color: Color(0xFFF87171))),
              ),
            ],
          ),
        );
        if (again == true && mounted) await _sendRemindersNow(force: true);
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text((body['error'] as String?) ?? 'No se pudieron enviar (HTTP ${response.statusCode}).')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Sin conexión con el servidor.')));
    } finally {
      if (mounted) setState(() => _sendingReminders = false);
    }
  }

  String _reminderLastRunLabel() {
    final last = _reminderLastRun;
    final day = last?['day'] as String?;
    if (last == null || day == null) return 'Todavía no se ha enviado ninguno.';
    final isToday = day == todayString();
    final when = isToday ? 'Hoy' : 'El ${formatDayMonth(day)}';
    if (last['status'] == 'running') return '$when: enviando…';
    final sent = (last['sent'] as num?)?.toInt() ?? 0;
    final failed = (last['failed'] as num?)?.toInt() ?? 0;
    return '$when: $sent ${sent == 1 ? 'enviado' : 'enviados'}${failed > 0 ? ', $failed no salieron' : ''}.';
  }

  Widget _buildIntegrationsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          _pausedByNumberChange('reminders', _reminderEnabled),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [primaryAqua.withValues(alpha: 0.1), Colors.purple.withValues(alpha: 0.1)]),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: primaryAqua.withValues(alpha: 0.3)),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.calendar_month, color: Color(0xFF6200EE), size: 32),
                    const SizedBox(width: 16),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('AgendaCool', style: TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.bold)),
                      Text('Recordatorios de Citas', style: TextStyle(color: lightText, fontSize: 12)),
                    ])),
                    Switch(
                      value: _reminderEnabled,
                      activeThumbColor: primaryAqua,
                      onChanged: (v) => _change(() => _reminderEnabled = v, {'reminder_enabled': v}, 'Recordatorios'),
                    ),
                  ],
                ),
                if (_reminderEnabled) ...[
                  const SizedBox(height: 24),
                  _textField(controller: _reminderApiUrlController, label: 'API URL de Sincronización', hint: 'https://...'),
                  const SizedBox(height: 16),
                  _timeTile(
                    'Hora de Envío Diario',
                    _reminderScheduledTime,
                    (t) => _change(() => _reminderScheduledTime = t, {'reminder_scheduled_time': _hhmm(t)}, 'Hora de Envío Diario'),
                  ),
                  const SizedBox(height: 16),
                  _textField(
                    controller: _reminderTemplateController, 
                    label: 'Mensaje de Recordatorio', 
                    hint: 'Hola {name}...', 
                    maxLines: 3,
                    canExpand: true,
                    focusNode: _reminderTemplateFocus,
                  ),
                  if (AccountContextService().isOwner) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        Text(_reminderLastRunLabel(), style: const TextStyle(color: lightText, fontSize: 12)),
                        OutlinedButton.icon(
                          onPressed: _sendingReminders ? null : () => _sendRemindersNow(),
                          icon: _sendingReminders
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_outlined, size: 16),
                          label: const Text('Enviar ahora'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sale con lo que ves aquí: si cambiaste el mensaje, se guarda antes de enviar. Antes se podía disparar escribiendo "enviar recordatorios" por WhatsApp; ya no: cualquier cliente podía hacerlo.',
                      style: TextStyle(color: lightText.withValues(alpha: 0.55), fontSize: 11),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Pestaña de etiquetas. CRUD live sobre la subcolección `labels` de la
  // sesión: cada etiqueta se persiste al instante (modelo idéntico a
  // quick_responses).
  Widget _buildLabelsTab() {
    return _LabelsTabBody(accountId: widget.accountId, sessionId: widget.sessionId);
  }

  // Editor a pantalla completa para los textos largos. Con cambios, la acción
  // es GUARDAR (guarda y cierra); sin cambios, LISTO. La ✕ cierra y el
  // borrador se queda en el campo, con su "Sin guardar".
  void _showExpandedEditor(String title, DraftTextController controller, FocusNode? focusNode) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        void close() {
          Navigator.pop(dialogContext);
          focusNode?.requestFocus();
        }

        return Dialog.fullscreen(
          backgroundColor: surfaceDark,
          child: Scaffold(
            backgroundColor: surfaceDark,
            appBar: AppBar(
              backgroundColor: surfaceDark,
              elevation: 0,
              title: Text(title, style: const TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.bold)),
              leading: IconButton(icon: const Icon(Icons.close, color: white), onPressed: close),
              actions: [
                ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) {
                    final dirty = controller.isDirty;
                    return TextButton(
                      onPressed: controller.isSaving
                          ? null
                          : () async {
                              if (dirty && !await _saveDraft(controller)) return;
                              if (dialogContext.mounted) close();
                            },
                      child: Text(
                        dirty ? 'GUARDAR' : 'LISTO',
                        style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(24.0),
              child: TextField(
                controller: controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autofocus: true,
                style: const TextStyle(color: white, fontSize: 16, height: 1.6),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Escribe tus instrucciones detalladas aquí...',
                  hintStyle: TextStyle(color: white.withValues(alpha: 0.1)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Helper Widgets ---

  Widget _sectionTitle(String title) {
    return Text(title.toUpperCase(), style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2));
  }

  // Campo de texto de Ajustes: se guarda con su propio botón (DraftSaveBar),
  // que sólo aparece cuando hay cambios.
  Widget _textField({
    required DraftTextController controller,
    required String label, 
    String? hint, 
    int maxLines = 1, 
    bool isPassword = false, 
    IconData? icon,
    bool canExpand = false,
    FocusNode? focusNode,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(color: lightText, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (canExpand)
              GestureDetector(
                onTap: () => _showExpandedEditor(label, controller, focusNode),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_full_rounded, color: primaryAqua, size: 14),
                    SizedBox(width: 4),
                    Text('Expandir', style: TextStyle(color: primaryAqua, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: maxLines,
          obscureText: isPassword,
          style: const TextStyle(color: white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: icon != null ? Icon(icon, color: primaryAqua, size: 20) : null,
            hintStyle: TextStyle(color: white.withValues(alpha: 0.2)),
            filled: true,
            fillColor: darkBg.withValues(alpha: 0.3),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
        DraftSaveBar(controller: controller, onSave: () => _saveDraft(controller)),
      ],
    );
  }

  Widget _switchTile(String title, bool value, Function(bool) onChanged) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // "Marcar como leído al responder" no cabe junto al Switch en un
          // Android de 360dp: el título se parte en dos líneas.
          Expanded(child: Text(title, style: const TextStyle(color: white, fontWeight: FontWeight.bold))),
          Switch(value: value, activeThumbColor: primaryAqua, onChanged: onChanged),
        ],
      ),
    );
  }

  // Controller de la API key del proveedor activo. Cada proveedor guarda su
  // llave en un campo Firestore aparte; aquí solo elegimos cuál editar.
  DraftTextController get _activeApiKeyController {
    switch (_selectedProvider) {
      case 'openai':
        return _openaiApiKeyController;
      case 'deepseek':
        return _deepseekApiKeyController;
      default:
        return _apiKeyController;
    }
  }

  Widget _modelDropdownTile() {
    final List<Map<String, String>> models = _selectedProvider == 'openai'
      ? [
          {'id': 'gpt-4.1-mini', 'name': 'GPT-4.1 Mini', 'desc': 'Recomendado'},
          {'id': 'gpt-5.6-luna', 'name': 'GPT-5.6 Luna', 'desc': 'Más barato y razona'},
          {'id': 'gpt-5-mini', 'name': 'GPT-5 Mini', 'desc': 'A prueba'},
        ]
      : _selectedProvider == 'deepseek'
      ? [
          {'id': 'deepseek-v4-flash', 'name': 'V4 Flash', 'desc': 'Recomendado'},
          {'id': 'deepseek-v4-pro', 'name': 'V4 Pro', 'desc': 'Más potente'},
        ]
      : [
          {'id': 'gemini-2.5-flash', 'name': 'Flash 2.5', 'desc': 'Recomendado'},
          {'id': 'gemini-3-flash', 'name': 'Flash 3', 'desc': 'Más rápido'},
          {'id': 'gemini-2.5-pro', 'name': 'Pro 2.5', 'desc': 'Más preciso'},
          {'id': 'gemini-2.5-flash-lite', 'name': 'Flash Lite', 'desc': 'Más barato'},
        ];

    // Un modelo guardado que ya no está en la lista (retirado, como el viejo
    // `gpt-4o-mini`) reventaba el panel entero: `DropdownButton` exige que su
    // `value` aparezca EXACTAMENTE una vez entre los items. Lo agregamos como
    // entrada extra en vez de coercionarlo al default, para que el operador vea
    // qué tiene configurado de verdad y no le cambiemos el modelo en silencio.
    if (!models.any((m) => m['id'] == _selectedModel)) {
      models.add({'id': _selectedModel, 'name': _selectedModel, 'desc': 'retirado'});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Modelo de IA', style: TextStyle(color: lightText, fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
          child: DropdownButton<String>(
            value: _selectedModel,
            isExpanded: true,
            underline: const SizedBox(),
            dropdownColor: surfaceDark,
            items: models.map((m) => DropdownMenuItem(
              value: m['id'], 
              child: Row(
                children: [
                  Text(m['name']!, style: const TextStyle(color: white)),
                  const SizedBox(width: 8),
                  // Lo que se recorta en pantallas angostas es la descripción,
                  // nunca el nombre del modelo.
                  Flexible(
                    child: Text(
                      '(${m['desc']})',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: primaryAqua.withValues(alpha: 0.7), fontSize: 11),
                    ),
                  ),
                ],
              )
            )).toList(),
            onChanged: (v) => _change(() => _selectedModel = v!, {'ai_model': v}, 'Modelo de IA'),
          ),
        ),
      ],
    );
  }

  Widget _dropdownTile(String label, String value, List<String> items, Function(String?) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: lightText, fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            underline: const SizedBox(),
            dropdownColor: surfaceDark,
            items: items.map((i) => DropdownMenuItem(value: i, child: Text(i, style: const TextStyle(color: white)))).toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _timeTile(String label, TimeOfDay time, Function(TimeOfDay) onTap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: lightText, fontSize: 12)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () async {
            final t = await showTimePicker(context: context, initialTime: time);
            if (t != null) onTap(t);
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.access_time, color: primaryAqua, size: 18),
              const SizedBox(width: 8),
              Text('${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: white, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _infoTile(String label, String value, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: lightText, size: 20),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: lightText, fontSize: 11)),
          Text(value, style: const TextStyle(color: white, fontWeight: FontWeight.bold)),
        ]),
      ]),
    );
  }

  Widget _expandableSection(String title, IconData icon, bool enabled, Function(bool) onToggle, Widget child) {
    return Container(
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        ListTile(
          leading: Icon(icon, color: enabled ? primaryAqua : lightText),
          title: Text(title, style: TextStyle(color: white, fontWeight: enabled ? FontWeight.bold : FontWeight.normal)),
          trailing: Switch(value: enabled, activeThumbColor: primaryAqua, onChanged: onToggle),
        ),
        if (enabled) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: child),
      ]),
    );
  }

  Widget _keywordTile(int index, String key, String resp, String? imageUrl, String? documentUrl, String trigger) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showRuleEditor(index), // tocar la regla → editar
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            key,
                            style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (imageUrl != null && imageUrl.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.image, color: primaryAqua, size: 14),
                        ],
                        if (documentUrl != null && documentUrl.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.picture_as_pdf, color: Color(0xFFEF4444), size: 14),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    _triggerBadge(trigger),
                    if (resp.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(resp, style: const TextStyle(color: lightText, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: lightText.withValues(alpha: 0.4), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // Etiqueta visual del trigger en cada regla. Colores e iconos consistentes
  // con el segmented control del formulario para que sean reconocibles.
  Widget _triggerBadge(String trigger) {
    late final IconData icon;
    late final String label;
    late final Color color;
    switch (trigger) {
      case 'outgoing':
        icon = Icons.outbox;
        label = 'Cuando yo escribo';
        color = const Color(0xFFF59E0B); // ámbar
        break;
      case 'both':
        icon = Icons.swap_horiz;
        label = 'Ambos';
        color = primaryAqua;
        break;
      case 'incoming':
      default:
        icon = Icons.inbox;
        label = 'Cuando el cliente escribe';
        color = const Color(0xFF10B981); // verde saturado
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _responseDelayTile() {
    final belowRecommended = _responseDelaySeconds < recommendedResponseDelaySeconds;
    final hintColor = belowRecommended ? const Color(0xFFF59E0B) : primaryAqua;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(
          child: Text('Espera para responder', style: TextStyle(color: white, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        const SizedBox(width: 8),
        Text('$_responseDelaySeconds s', style: TextStyle(color: hintColor, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 4),
      Text(
        'El asistente espera este tiempo para recibir más mensajes antes de procesar una respuesta única.',
        style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12),
      ),
      const SizedBox(height: 8),
      Slider(
        value: _responseDelaySeconds.toDouble(),
        min: minResponseDelaySeconds.toDouble(),
        max: maxResponseDelaySeconds.toDouble(),
        divisions: maxResponseDelaySeconds - minResponseDelaySeconds,
        label: '$_responseDelaySeconds s',
        semanticFormatterCallback: (value) => '${value.round()} segundos',
        activeColor: hintColor,
        inactiveColor: darkBg,
        onChanged: (value) => setState(() => _responseDelaySeconds = value.round()),
        // Se guarda al soltar, no en cada paso del arrastre.
        onChangeEnd: (value) => _saveFields(
          {'ai_response_delay_ms': value.round() * Duration.millisecondsPerSecond},
          what: 'Espera para responder',
        ),
      ),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hintColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(belowRecommended ? Icons.warning_amber_rounded : Icons.info_outline, color: hintColor, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recomendado por WhatHero: $recommendedResponseDelaySeconds s o más',
                    style: TextStyle(color: hintColor, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Da tiempo al cliente para completar su mensaje. WhatsApp puede restringir cuentas por automatización; esta espera no garantiza evitar bloqueos.',
                    style: TextStyle(color: lightText, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ]);
  }
}

// Cuerpo de la pestaña Etiquetas. Stateful por su cuenta para que los streams
// y el form de creación no recarguen el resto del panel cuando el usuario
// edita aquí. CRUD directo a Firestore — cada acción se persiste al instante.
class _LabelsTabBody extends StatefulWidget {
  final String accountId;
  final String sessionId;

  const _LabelsTabBody({required this.accountId, required this.sessionId});

  @override
  State<_LabelsTabBody> createState() => _LabelsTabBodyState();
}

class _LabelsTabBodyState extends State<_LabelsTabBody> {
  CollectionReference<Map<String, dynamic>> get _ref => FirebaseFirestore
      .instance
      .collection(accountsCollection)
      .doc(widget.accountId)
      .collection('whatsapp_sessions')
      .doc(widget.sessionId)
      .collection('labels');

  // Se escucha una sola vez: creado en `build`, cada rebuild del panel (y con
  // los guardados al instante son muchos) volvía a suscribirse y la lista
  // parpadeaba al spinner. Ver CLAUDE.md, "Nunca un .snapshots() dentro de
  // build".
  late final Stream<QuerySnapshot> _labels;

  @override
  void initState() {
    super.initState();
    _labels = _ref.orderBy('order').snapshots();
  }

  Future<void> _openEditor({ChatLabel? existing, int nextOrder = 0}) async {
    // Editor compartido con el selector de etiquetas del chat
    // (label_editor_dialog.dart). Aquí no usamos el ID devuelto.
    await showLabelEditorDialog(
      context: context,
      labelsRef: _ref,
      existing: existing,
      nextOrder: nextOrder,
    );
  }

  Future<void> _confirmDelete(ChatLabel label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('¿Eliminar etiqueta?',
            style: TextStyle(color: white, fontWeight: FontWeight.bold)),
        content: Text(
          'Se quitará "${label.name}" de todos los chats que la tengan asignada.',
          style: const TextStyle(color: lightText, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar',
                style: TextStyle(
                    color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Borrado simple del catálogo. Los chats que tenían el ID en `labelIds`
    // lo mantendrán como huérfano: la UI lo ignora (resolución por catálogo)
    // y el ID se limpiará la próxima vez que el usuario edite las etiquetas
    // de ese chat. Evita un fan-out costoso al borrar.
    await _ref.doc(label.id).delete();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _labels,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: primaryAqua));
        }
        final labels = snap.data!.docs.map((d) => ChatLabel.fromDoc(d)).toList();
        final nextOrder = labels.isEmpty ? 0 : labels.last.order + 1;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ETIQUETAS DE LA SESIÓN',
                style: TextStyle(
                  color: primaryAqua,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Crea etiquetas de colores para organizar tus chats. Aplican solo a esta sesión.',
                style: TextStyle(color: lightText, fontSize: 13),
              ),
              const SizedBox(height: 20),
              if (labels.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: darkBg.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: lightText.withValues(alpha: 0.1), width: 1),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.label_outline,
                          size: 40, color: lightText.withValues(alpha: 0.5)),
                      const SizedBox(height: 12),
                      const Text(
                        'Aún no creaste etiquetas',
                        style: TextStyle(
                            color: white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Toca el botón de abajo para crear la primera.',
                        style: TextStyle(color: lightText, fontSize: 12),
                      ),
                    ],
                  ),
                )
              else
                ...labels.map((l) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: darkBg.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: l.color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l.name,
                              style: const TextStyle(
                                  color: white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined,
                                size: 18, color: lightText),
                            onPressed: () => _openEditor(existing: l),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Color(0xFFEF4444)),
                            onPressed: () => _confirmDelete(l),
                          ),
                        ],
                      ),
                    )),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _openEditor(nextOrder: nextOrder),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Crear etiqueta',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAqua.withValues(alpha: 0.1),
                    foregroundColor: primaryAqua,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: primaryAqua),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Editor de una respuesta automática (regla por palabra clave), en bottom sheet
// con la misma identidad que el panel de Respuestas Rápidas (navy, grab handle,
// header Cancelar/Guardar). Devuelve el Map de la regla vía Navigator.pop, o
// null si se cancela. Es StatefulWidget para manejar sus propios controllers.
class _KeywordRuleEditorSheet extends StatefulWidget {
  final String accountId;
  final String sessionId;
  final String ruleId; // '' para reglas nuevas o legacy sin id
  final String keyword;
  final String response;
  final String imageUrl;
  final String documentUrl;
  final String documentName;
  final String trigger;
  final bool isEditing;

  const _KeywordRuleEditorSheet({
    required this.accountId,
    required this.sessionId,
    required this.ruleId,
    required this.keyword,
    required this.response,
    required this.imageUrl,
    required this.documentUrl,
    required this.documentName,
    required this.trigger,
    required this.isEditing,
  });

  @override
  State<_KeywordRuleEditorSheet> createState() => _KeywordRuleEditorSheetState();
}

class _KeywordRuleEditorSheetState extends State<_KeywordRuleEditorSheet> {
  final ImagePicker _picker = ImagePicker();

  late final TextEditingController _keywordController;
  late final TextEditingController _responseController;
  late String _trigger;
  late final String _ruleId;

  // Estado del adjunto. Una regla lleva como máximo UNO: imagen O documento.
  // - _pickedBytes / _pickedDocBytes: archivo recién elegido, aún sin subir.
  // - _imageUrl / _documentUrl: URL ya persistida (Storage o externa legacy).
  Uint8List? _pickedBytes;
  late String _imageUrl;
  Uint8List? _pickedDocBytes;
  String? _pickedDocName;
  late String _documentUrl;
  late String _documentName;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _keywordController = TextEditingController(text: widget.keyword);
    _responseController = TextEditingController(text: widget.response);
    _trigger = widget.trigger;
    _imageUrl = widget.imageUrl;
    _documentUrl = widget.documentUrl;
    _documentName = widget.documentName;
    // Reglas legacy/nuevas sin id reciben uno estable (push-id de Firestore)
    // para anclar su archivo en Storage.
    _ruleId = widget.ruleId.isNotEmpty
        ? widget.ruleId
        : FirebaseFirestore.instance.collection('_ids').doc().id;
    // Recalcular el estado de "Guardar" al escribir
    _keywordController.addListener(_onChanged);
    _responseController.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _keywordController.dispose();
    _responseController.dispose();
    super.dispose();
  }

  bool get _hasImage => _pickedBytes != null || _imageUrl.isNotEmpty;
  bool get _hasDocument => _pickedDocBytes != null || _documentUrl.isNotEmpty;
  bool get _hasAttachment => _hasImage || _hasDocument;

  // Nombre a mostrar del documento (recién elegido o ya persistido).
  String get _documentLabel =>
      _pickedDocName ?? (_documentName.isNotEmpty ? _documentName : 'documento.pdf');

  // Path determinista: un archivo por regla y extensión → reemplazar
  // sobrescribe, sin huérfanos. Respeta storage.rules (accounts/... prod,
  // accounts_dev/... dev).
  Reference _ref(String ext) => FirebaseStorage.instance.ref(
        '$accountsCollection/${widget.accountId}/whatsapp_sessions/'
        '${widget.sessionId}/bot_rules/$_ruleId.$ext',
      );

  Future<void> _deleteObject(String ext) async {
    try {
      await _ref(ext).delete();
    } catch (_) {/* sin archivo o URL externa legacy → ignorar */}
  }

  // Mismo límite para el peso informado por el selector y los bytes leídos.
  bool _fitsAttachment(int size, String what) {
    if (size <= maxAttachmentBytes) return true;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$what supera el límite de $maxAttachmentMegabytes MB'),
        ),
      );
    }
    return false;
  }

  // Elige una imagen de la galería. image_picker ya redimensiona y recomprime.
  // Limpia el documento: el adjunto es mutuamente excluyente.
  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (picked == null) return;

      if (!_fitsAttachment(await picked.length(), 'La imagen')) return;
      final bytes = await picked.readAsBytes();
      if (!_fitsAttachment(bytes.length, 'La imagen')) return;
      if (mounted) {
        setState(() {
          _pickedBytes = bytes;
          _pickedDocBytes = null;
          _pickedDocName = null;
          _documentUrl = '';
          _documentName = '';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cargar la imagen: $e')),
        );
      }
    }
  }

  // Elige un documento PDF. Limpia la imagen (adjunto mutuamente excluyente).
  Future<void> _pickDocument() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (file == null) return;
      if (!_fitsAttachment(await file.length(), 'El documento')) return;
      // readAsBytes: necesitamos los bytes para subirlos a Storage.
      final bytes = await file.readAsBytes();

      if (!_fitsAttachment(bytes.length, 'El documento')) return;
      if (mounted) {
        setState(() {
          _pickedDocBytes = bytes;
          _pickedDocName = file.name;
          _pickedBytes = null;
          _imageUrl = '';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cargar el documento: $e')),
        );
      }
    }
  }

  // Quita el adjunto del editor (se aplica al guardar)
  void _removeAttachment() {
    setState(() {
      _pickedBytes = null;
      _imageUrl = '';
      _pickedDocBytes = null;
      _pickedDocName = null;
      _documentUrl = '';
      _documentName = '';
    });
  }

  // Guardar habilitado si hay palabra clave + (respuesta o adjunto) y, al
  // editar, si hay algún cambio respecto al original.
  bool get _canSave {
    final keyword = _keywordController.text.trim();
    final response = _responseController.text.trim();
    final isValid = keyword.isNotEmpty && (response.isNotEmpty || _hasAttachment);
    if (!isValid) return false;
    if (!widget.isEditing) return true;
    final attachmentChanged = _pickedBytes != null ||
        _pickedDocBytes != null ||
        _imageUrl != widget.imageUrl ||
        _documentUrl != widget.documentUrl;
    return keyword != widget.keyword ||
        response != widget.response ||
        attachmentChanged ||
        _trigger != widget.trigger;
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      // Resolver el adjunto final. Mutuamente excluyente: imagen o documento.
      String imageUrl = '';
      String documentUrl = '';
      String documentName = '';

      if (_pickedBytes != null) {
        final ref = _ref('jpg');
        await ref.putData(_pickedBytes!, SettableMetadata(contentType: 'image/jpeg'));
        imageUrl = await ref.getDownloadURL();
      } else if (_imageUrl.isNotEmpty) {
        imageUrl = _imageUrl; // imagen existente sin cambios
      } else if (_pickedDocBytes != null) {
        final ref = _ref('pdf');
        await ref.putData(_pickedDocBytes!, SettableMetadata(contentType: 'application/pdf'));
        documentUrl = await ref.getDownloadURL();
        documentName = _pickedDocName ?? 'documento.pdf';
      } else if (_documentUrl.isNotEmpty) {
        documentUrl = _documentUrl; // documento existente sin cambios
        documentName = _documentName;
      }

      // Limpieza de huérfanos: borra el objeto del tipo que ya no se usa.
      if (imageUrl.isEmpty) await _deleteObject('jpg');
      if (documentUrl.isEmpty) await _deleteObject('pdf');

      if (!mounted) return;
      Navigator.pop(context, {
        'ruleId': _ruleId,
        'keyword': _keywordController.text.trim(),
        'response': _responseController.text.trim(),
        'imageUrl': imageUrl,
        'documentUrl': documentUrl,
        'documentName': documentName,
        'trigger': _trigger,
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al subir el adjunto: $e')),
        );
      }
    }
  }

  // Bloque de adjunto: preview de imagen, tile de documento, o las dos cajas
  // para agregar uno. La regla lleva como máximo un adjunto.
  Widget _attachmentBlock() {
    if (_hasImage) return _imagePreview();
    if (_hasDocument) return _documentTile();
    return Row(
      children: [
        Expanded(child: _addBox(Icons.add_photo_alternate_outlined, 'Imagen', _pickImage)),
        const SizedBox(width: 12),
        Expanded(child: _addBox(Icons.picture_as_pdf_outlined, 'Documento', _pickDocument)),
      ],
    );
  }

  // Caja "agregar" reutilizable para imagen / documento.
  Widget _addBox(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: _isSaving ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 96,
        decoration: BoxDecoration(
          color: darkBg.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: primaryAqua, size: 28),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: lightText.withValues(alpha: 0.8), fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // Botón flotante de quitar adjunto (esquina superior derecha).
  Widget _removeBadge() => Positioned(
        top: 8,
        right: 8,
        child: InkWell(
          onTap: _isSaving ? null : _removeAttachment,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.close, color: white, size: 20),
          ),
        ),
      );

  Widget _imagePreview() {
    final Widget preview = _pickedBytes != null
        ? Image.memory(_pickedBytes!, height: 160, width: double.infinity, fit: BoxFit.cover)
        : Image.network(_imageUrl, height: 160, width: double.infinity, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                  height: 160,
                  color: darkBg.withValues(alpha: 0.3),
                  child: const Icon(Icons.broken_image, color: lightText),
                ));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(children: [preview, _removeBadge()]),
    );
  }

  Widget _documentTile() {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 44, 16),
          decoration: BoxDecoration(
            color: darkBg.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: primaryAqua.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              const Icon(Icons.picture_as_pdf, color: Color(0xFFEF4444), size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _documentLabel,
                  style: const TextStyle(color: white, fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        _removeBadge(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.9;
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: darkBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Grab handle
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: lightText.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          // Header iOS: Cancelar · título · Guardar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: _isSaving ? null : () => Navigator.pop(context),
                  child: const Text('Cancelar', style: TextStyle(color: lightText)),
                ),
                Expanded(
                  child: Text(
                    widget.isEditing ? 'Editar regla' : 'Nueva regla',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: white,
                    ),
                  ),
                ),
                _isSaving
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: primaryAqua),
                        ),
                      )
                    : TextButton(
                        onPressed: _canSave ? _save : null,
                        child: Text(
                          'Guardar',
                          style: TextStyle(
                            color: _canSave ? primaryAqua : lightText.withValues(alpha: 0.4),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ],
            ),
          ),
          Divider(color: primaryAqua.withValues(alpha: 0.1), height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('Palabra clave'),
                  _field(_keywordController, 'Ej: info, precio, horario'),
                  const SizedBox(height: 20),
                  _label('Respuesta del bot'),
                  _field(_responseController, 'Mensaje que enviará el bot…', maxLines: 5),
                  const SizedBox(height: 20),
                  _label('Adjunto (opcional)'),
                  _attachmentBlock(),
                  const SizedBox(height: 20),
                  _label('Disparar cuando…'),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'incoming', label: Text('Cliente', style: TextStyle(fontSize: 11)), icon: Icon(Icons.inbox, size: 14)),
                      ButtonSegment(value: 'outgoing', label: Text('Yo', style: TextStyle(fontSize: 11)), icon: Icon(Icons.outbox, size: 14)),
                      ButtonSegment(value: 'both', label: Text('Ambos', style: TextStyle(fontSize: 11)), icon: Icon(Icons.swap_horiz, size: 14)),
                    ],
                    selected: {_trigger},
                    onSelectionChanged: (s) => setState(() => _trigger = s.first),
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected) ? primaryAqua.withValues(alpha: 0.2) : Colors.transparent),
                      foregroundColor: WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected) ? primaryAqua : lightText),
                      side: WidgetStateProperty.all(BorderSide(color: primaryAqua.withValues(alpha: 0.3))),
                    ),
                  ),
                  // Eliminar dentro del editor (solo al editar una existente)
                  if (widget.isEditing) ...[
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _confirmDelete,
                        icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                        label: const Text('Eliminar',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Confirma y, si acepta, cierra devolviendo la señal de borrado al panel
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surfaceDark,
        title: const Text('Eliminar regla', style: TextStyle(color: white)),
        content: const Text(
          '¿Seguro que quieres eliminar esta respuesta automática? Esta acción no se puede deshacer.',
          style: TextStyle(color: lightText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: lightText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, {'_delete': true, 'ruleId': _ruleId});
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: lightText)),
      );

  Widget _field(TextEditingController controller, String hint, {int maxLines = 1}) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textCapitalization: TextCapitalization.sentences,
      style: const TextStyle(color: white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
        filled: true,
        fillColor: darkBg.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primaryAqua.withValues(alpha: 0.2)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}
