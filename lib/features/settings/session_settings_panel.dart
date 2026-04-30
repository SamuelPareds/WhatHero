import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';

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

class _SessionSettingsPanelState extends State<SessionSettingsPanel> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  // Controllers
  late TextEditingController _aliasController;
  late TextEditingController _apiKeyController;
  late TextEditingController _openaiApiKeyController;
  late TextEditingController _systemPromptController;
  late TextEditingController _discriminatorPromptController;
  late TextEditingController _reminderApiUrlController;
  late TextEditingController _reminderTemplateController;
  
  // FocusNodes for focus management
  late FocusNode _systemPromptFocus;
  late FocusNode _discriminatorFocus;
  late FocusNode _reminderTemplateFocus;
  
  // States
  bool _aiEnabled = false;
  String _selectedProvider = 'gemini';
  String _selectedModel = 'gemini-2.5-flash';
  int _responseDelayMs = 15000;
  bool _activeHoursEnabled = false;
  String _activeHoursTimezone = 'America/Mexico_City';
  TimeOfDay _activeHoursStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _activeHoursEnd = const TimeOfDay(hour: 18, minute: 0);
  List<Map<String, dynamic>> _keywordRules = [];
  String _newKeyword = '';
  String _newKeywordResponse = '';
  String _newKeywordImageUrl = '';
  bool _discriminatorEnabled = false;

  // Allowlist de tipos de media que la IA puede leer. Por defecto todo en
  // false: la IA es solo-texto. En Fase 1 los toggles son read-only
  // ("próximamente") — el estado se carga y persiste para que el backend
  // tenga el campo disponible y para evitar reescribir cuando se abra
  // la edición en Fase 2.
  bool _mediaAllowImage = false;
  bool _mediaAllowAudio = false;
  bool _mediaAllowVideo = false;
  bool _mediaAllowDocument = false;

  // AgendaCool
  bool _reminderEnabled = false;
  TimeOfDay _reminderScheduledTime = const TimeOfDay(hour: 9, minute: 0);

  bool _isSaving = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _aliasController = TextEditingController();
    _apiKeyController = TextEditingController();
    _openaiApiKeyController = TextEditingController();
    _systemPromptController = TextEditingController();
    _discriminatorPromptController = TextEditingController();
    _reminderApiUrlController = TextEditingController();
    _reminderTemplateController = TextEditingController();
    _systemPromptFocus = FocusNode();
    _discriminatorFocus = FocusNode();
    _reminderTemplateFocus = FocusNode();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .get();

      if (doc.exists) {
        final data = doc.data() ?? {};
        setState(() {
          _aliasController.text = data['alias'] ?? 'Sucursal - ${widget.sessionId}';
          _aiEnabled = data['ai_enabled'] ?? false;
          _selectedProvider = data['ai_provider'] ?? 'gemini';
          _apiKeyController.text = data['ai_api_key'] ?? '';
          _openaiApiKeyController.text = data['ai_openai_api_key'] ?? '';
          _systemPromptController.text = data['ai_system_prompt'] ?? 'Eres un asistente útil.';
          _selectedModel = data['ai_model'] ?? (_selectedProvider == 'openai' ? 'gpt-4o-mini' : 'gemini-2.5-flash');
          _responseDelayMs = data['ai_response_delay_ms'] ?? 15000;

          _reminderEnabled = data['reminder_enabled'] ?? false;
          _reminderApiUrlController.text = data['reminder_api_url'] ?? '';
          _reminderTemplateController.text = data['reminder_template'] ?? '¡Hola {name}! 🌸\n\nTe recordamos tu cita para mañana a las {time}.';
          
          if (data['reminder_scheduled_time'] is String) {
            final parts = (data['reminder_scheduled_time'] as String).split(':');
            _reminderScheduledTime = TimeOfDay(hour: int.tryParse(parts[0]) ?? 9, minute: int.tryParse(parts[1]) ?? 0);
          }

          if (data['ai_active_hours'] is Map) {
            final hours = data['ai_active_hours'] as Map;
            _activeHoursEnabled = hours['enabled'] ?? false;
            _activeHoursTimezone = hours['timezone'] ?? 'America/Mexico_City';
            if (hours['start'] is String) {
              final parts = (hours['start'] as String).split(':');
              _activeHoursStart = TimeOfDay(hour: int.tryParse(parts[0]) ?? 9, minute: int.tryParse(parts[1]) ?? 0);
            }
            if (hours['end'] is String) {
              final parts = (hours['end'] as String).split(':');
              _activeHoursEnd = TimeOfDay(hour: int.tryParse(parts[0]) ?? 18, minute: int.tryParse(parts[1]) ?? 0);
            }
          }

          if (data['ai_keyword_rules'] is List) {
            _keywordRules = List<Map<String, dynamic>>.from((data['ai_keyword_rules'] as List).map((rule) => {
              'keyword': rule['keyword'] as String? ?? '',
              'response': rule['response'] as String? ?? '',
              'imageUrl': rule['imageUrl'] as String? ?? '',
            }));
          }

          _discriminatorEnabled = data['ai_discriminator_enabled'] ?? false;
          _discriminatorPromptController.text = data['ai_discriminator_prompt'] ?? '';

          if (data['ai_media_allowlist'] is Map) {
            final allow = data['ai_media_allowlist'] as Map;
            _mediaAllowImage = allow['image'] == true;
            _mediaAllowAudio = allow['audio'] == true;
            _mediaAllowVideo = allow['video'] == true;
            _mediaAllowDocument = allow['document'] == true;
          }

          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(widget.accountId)
          .collection('whatsapp_sessions')
          .doc(widget.sessionId)
          .update({
        'alias': _aliasController.text.trim(),
        'ai_enabled': _aiEnabled,
        'ai_provider': _selectedProvider,
        'ai_api_key': _apiKeyController.text,
        'ai_openai_api_key': _openaiApiKeyController.text,
        'ai_system_prompt': _systemPromptController.text,
        'ai_model': _selectedModel,
        'ai_response_delay_ms': _responseDelayMs,
        'ai_active_hours': {
          'enabled': _activeHoursEnabled,
          'timezone': _activeHoursTimezone,
          'start': '${_activeHoursStart.hour.toString().padLeft(2, '0')}:${_activeHoursStart.minute.toString().padLeft(2, '0')}',
          'end': '${_activeHoursEnd.hour.toString().padLeft(2, '0')}:${_activeHoursEnd.minute.toString().padLeft(2, '0')}',
        },
        'ai_keyword_rules': _keywordRules,
        'ai_discriminator_enabled': _discriminatorEnabled,
        'ai_discriminator_prompt': _discriminatorPromptController.text.trim(),
        'ai_media_allowlist': {
          'image': _mediaAllowImage,
          'audio': _mediaAllowAudio,
          'video': _mediaAllowVideo,
          'document': _mediaAllowDocument,
        },
        'reminder_enabled': _reminderEnabled,
        'reminder_api_url': _reminderApiUrlController.text.trim(),
        'reminder_template': _reminderTemplateController.text.trim(),
        'reminder_scheduled_time': '${_reminderScheduledTime.hour.toString().padLeft(2, '0')}:${_reminderScheduledTime.minute.toString().padLeft(2, '0')}',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Configuración guardada exitosamente')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _aliasController.dispose();
    _apiKeyController.dispose();
    _openaiApiKeyController.dispose();
    _systemPromptController.dispose();
    _discriminatorPromptController.dispose();
    _reminderApiUrlController.dispose();
    _reminderTemplateController.dispose();
    _systemPromptFocus.dispose();
    _discriminatorFocus.dispose();
    _reminderTemplateFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(height: 500, child: Center(child: CircularProgressIndicator(color: primaryAqua)));
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          // Header & Handle
          _buildHeader(),
          
          // TabBar
          _buildTabBar(),
          
          // Content
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
          
          // Footer with Save Button
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        const SizedBox(height: 12),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(color: lightText.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Ajustes de Sesión', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: white)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, color: lightText)),
            ],
          ),
        ),
      ],
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
          _infoTile('ID de Sesión', widget.sessionId, Icons.fingerprint),
          _infoTile('Número Vinculado', '+${widget.sessionId}', Icons.chat_bubble_outline),
        ],
      ),
    );
  }

  Widget _buildAITab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          _switchTile('Activar Asistente IA', _aiEnabled, (v) => setState(() => _aiEnabled = v)),
          const SizedBox(height: 24),
          _sectionTitle('Cerebro del Asistente'),
          const SizedBox(height: 16),
          _dropdownTile('Proveedor', _selectedProvider, ['gemini', 'openai'], (v) {
            setState(() {
              _selectedProvider = v!;
              _selectedModel = v == 'openai' ? 'gpt-4o-mini' : 'gemini-2.5-flash';
            });
          }),
          const SizedBox(height: 16),
          _modelDropdownTile(),
          const SizedBox(height: 16),
          _textField(
            controller: _selectedProvider == 'gemini' ? _apiKeyController : _openaiApiKeyController,
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
          _sliderTile(
            'Espera para responder', 
            '${(_responseDelayMs / 1000).toStringAsFixed(1)}s', 
            'El asistente espera este tiempo para recibir más mensajes antes de procesar una respuesta única.',
            _responseDelayMs.toDouble(), 
            8000, 
            30000, 
            (v) => setState(() => _responseDelayMs = v.toInt())
          ),
          const SizedBox(height: 24),
          _sectionTitle('Control de Disponibilidad'),
          const SizedBox(height: 16),
          _expandableSection(
            'Horario de Atención',
            Icons.access_time,
            _activeHoursEnabled,
            (v) => setState(() => _activeHoursEnabled = v),
            Column(
              children: [
                _dropdownTile('Zona Horaria', _activeHoursTimezone, ['America/Mexico_City', 'America/New_York', 'Europe/Madrid'], (v) => setState(() => _activeHoursTimezone = v!)),
                Row(
                  children: [
                    Expanded(child: _timeTile('Apertura', _activeHoursStart, (t) => setState(() => _activeHoursStart = t))),
                    const SizedBox(width: 12),
                    Expanded(child: _timeTile('Cierre', _activeHoursEnd, (t) => setState(() => _activeHoursEnd = t))),
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
            (v) => setState(() => _discriminatorEnabled = v),
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
                Row(
                  children: [
                    Text(label, style: const TextStyle(color: white, fontSize: 13, fontWeight: FontWeight.w600)),
                    if (comingSoon) ...[
                      const SizedBox(width: 8),
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
            activeColor: primaryAqua,
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
          const Text('Si el mensaje del cliente contiene alguna de estas palabras, el bot responderá de forma inmediata ignorando a la IA.', style: TextStyle(color: lightText, fontSize: 13)),
          const SizedBox(height: 20),
          ..._keywordRules.asMap().entries.map((e) => _keywordTile(e.key, e.value['keyword']!, e.value['response']!, e.value['imageUrl'])),
          _addKeywordSection(),
        ],
      ),
    );
  }

  Widget _buildIntegrationsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
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
                    Switch(value: _reminderEnabled, activeColor: primaryAqua, onChanged: (v) => setState(() => _reminderEnabled = v)),
                  ],
                ),
                if (_reminderEnabled) ...[
                  const SizedBox(height: 24),
                  _textField(controller: _reminderApiUrlController, label: 'API URL de Sincronización', hint: 'https://...'),
                  const SizedBox(height: 16),
                  _timeTile('Hora de Envío Diario', _reminderScheduledTime, (t) => setState(() => _reminderScheduledTime = t)),
                  const SizedBox(height: 16),
                  _textField(
                    controller: _reminderTemplateController, 
                    label: 'Mensaje de Recordatorio', 
                    hint: 'Hola {name}...', 
                    maxLines: 3,
                    canExpand: true,
                    focusNode: _reminderTemplateFocus,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Pestaña 5: gestión de etiquetas. CRUD live sobre la subcolección `labels`
  // de la sesión. No usa _save() del footer porque cada etiqueta se persiste
  // al instante (modelo idéntico a quick_responses).
  Widget _buildLabelsTab() {
    return _LabelsTabBody(accountId: widget.accountId, sessionId: widget.sessionId);
  }

  Widget _buildFooter() {
    return Container(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 16 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: surfaceDark,
        border: Border(top: BorderSide(color: white.withValues(alpha: 0.05))),
      ),
      child: ElevatedButton(
        onPressed: _isSaving ? null : _save,
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryAqua,
          minimumSize: const Size(double.infinity, 56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: _isSaving 
          ? const CircularProgressIndicator(color: darkBg) 
          : const Text('Guardar Todos los Cambios', style: TextStyle(color: darkBg, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _showExpandedEditor(String title, TextEditingController controller, FocusNode? focusNode) {
    showDialog(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: surfaceDark,
        child: Scaffold(
          backgroundColor: surfaceDark,
          appBar: AppBar(
            backgroundColor: surfaceDark,
            elevation: 0,
            title: Text(title, style: const TextStyle(color: white, fontSize: 18, fontWeight: FontWeight.bold)),
            leading: IconButton(
              icon: const Icon(Icons.close, color: white),
              onPressed: () {
                Navigator.pop(context);
                focusNode?.requestFocus();
              },
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  focusNode?.requestFocus();
                },
                child: const Text('LISTO', style: TextStyle(color: primaryAqua, fontWeight: FontWeight.bold)),
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
      ),
    );
  }

  // --- Helper Widgets ---

  Widget _sectionTitle(String title) {
    return Text(title.toUpperCase(), style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2));
  }

  Widget _textField({
    required TextEditingController controller, 
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
            Text(label, style: const TextStyle(color: lightText, fontSize: 13, fontWeight: FontWeight.w600)),
            if (canExpand)
              GestureDetector(
                onTap: () => _showExpandedEditor(label, controller, focusNode),
                child: const Row(
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
          Text(title, style: const TextStyle(color: white, fontWeight: FontWeight.bold)),
          Switch(value: value, activeColor: primaryAqua, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _modelDropdownTile() {
    final List<Map<String, String>> models = _selectedProvider == 'openai' 
      ? [
          {'id': 'gpt-4o-mini', 'name': 'GPT-4o Mini', 'desc': 'Recomendado'},
          {'id': 'gpt-4o', 'name': 'GPT-4o', 'desc': 'Más potente'},
          {'id': 'gpt-4-turbo', 'name': 'GPT-4 Turbo', 'desc': 'Más rápido'},
        ]
      : [
          {'id': 'gemini-2.5-flash', 'name': 'Flash 2.5', 'desc': 'Recomendado'},
          {'id': 'gemini-3-flash', 'name': 'Flash 3', 'desc': 'Más rápido'},
          {'id': 'gemini-2.5-pro', 'name': 'Pro 2.5', 'desc': 'Más preciso'},
          {'id': 'gemini-2.5-flash-lite', 'name': 'Flash Lite', 'desc': 'Más barato'},
        ];

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
                  Text('(${m['desc']})', style: TextStyle(color: primaryAqua.withValues(alpha: 0.7), fontSize: 11)),
                ],
              )
            )).toList(),
            onChanged: (v) => setState(() => _selectedModel = v!),
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
          trailing: Switch(value: enabled, activeColor: primaryAqua, onChanged: onToggle),
        ),
        if (enabled) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: child),
      ]),
    );
  }

  Widget _keywordTile(int index, String key, String resp, String? imageUrl) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            children: [
              Text(key, style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.bold)),
              if (imageUrl != null && imageUrl.isNotEmpty) ...[
                const SizedBox(width: 8),
                const Icon(Icons.image, color: primaryAqua, size: 14),
              ],
            ],
          ),
          Text(resp, style: const TextStyle(color: lightText, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: () => setState(() => _keywordRules.removeAt(index))),
      ]),
    );
  }

  Widget _addKeywordSection() {
    // Controller temporal para el editor expandido si el usuario lo requiere
    final TextEditingController tempResponseController = TextEditingController(text: _newKeywordResponse);
    
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: darkBg.withValues(alpha: 0.2),
        border: Border.all(color: primaryAqua.withValues(alpha: 0.2)), 
        borderRadius: BorderRadius.circular(16)
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CREAR NUEVA REGLA', style: TextStyle(color: primaryAqua, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => _newKeyword = v,
            style: const TextStyle(color: white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Palabra clave (ej: info, precio)...',
              hintStyle: TextStyle(color: white.withValues(alpha: 0.3)),
              border: InputBorder.none,
              isDense: true,
              prefixIcon: const Icon(Icons.key, size: 16, color: primaryAqua),
            ),
          ),
          const Divider(color: white, height: 16, thickness: 0.1),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Respuesta del Bot', style: TextStyle(color: lightText, fontSize: 12)),
              GestureDetector(
                onTap: () {
                  tempResponseController.text = _newKeywordResponse;
                  _showExpandedEditor('Redactar Respuesta Automática', tempResponseController, null);
                  // Actualizar el estado cuando el diálogo se cierre (aunque el editor expandido aquí es modal)
                  // Para simplificar, usamos un listener o actualizamos al cerrar
                  tempResponseController.addListener(() {
                    _newKeywordResponse = tempResponseController.text;
                    setState(() {});
                  });
                },
                child: const Row(
                  children: [
                    Icon(Icons.open_in_full_rounded, color: primaryAqua, size: 12),
                    SizedBox(width: 4),
                    Text('Expandir', style: TextStyle(color: primaryAqua, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: TextEditingController.fromValue(
              TextEditingValue(
                text: _newKeywordResponse,
                selection: TextSelection.collapsed(offset: _newKeywordResponse.length),
              ),
            ),
            onChanged: (v) => _newKeywordResponse = v,
            maxLines: 4,
            minLines: 2,
            style: const TextStyle(color: white, fontSize: 13, height: 1.4),
            decoration: InputDecoration(
              hintText: 'Escribe el mensaje que enviará el bot...',
              hintStyle: TextStyle(color: white.withValues(alpha: 0.3)),
              filled: true,
              fillColor: darkBg.withValues(alpha: 0.3),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (v) => _newKeywordImageUrl = v,
            style: const TextStyle(color: white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'URL de imagen (opcional)...',
              hintStyle: TextStyle(color: white.withValues(alpha: 0.3)),
              border: InputBorder.none,
              isDense: true,
              prefixIcon: const Icon(Icons.link, size: 16, color: primaryAqua),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (_newKeyword.isNotEmpty && (_newKeywordResponse.isNotEmpty || _newKeywordImageUrl.isNotEmpty)) {
                  setState(() {
                    _keywordRules.add({
                      'keyword': _newKeyword, 
                      'response': _newKeywordResponse,
                      'imageUrl': _newKeywordImageUrl,
                    });
                    _newKeyword = ''; _newKeywordResponse = ''; _newKeywordImageUrl = '';
                    tempResponseController.clear();
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryAqua.withValues(alpha: 0.1),
                foregroundColor: primaryAqua,
                side: const BorderSide(color: primaryAqua),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: const Text('+ Guardar Regla', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sliderTile(String label, String value, String description, double current, double min, double max, Function(double) onChanged) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(color: white, fontWeight: FontWeight.bold, fontSize: 13)),
        Text(value, style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 4),
      Text(description, style: TextStyle(color: lightText.withValues(alpha: 0.7), fontSize: 12)),
      const SizedBox(height: 8),
      Slider(value: current, min: min, max: max, activeColor: primaryAqua, inactiveColor: darkBg, onChanged: onChanged),
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

  Future<void> _openEditor({ChatLabel? existing, int nextOrder = 0}) async {
    final controller = TextEditingController(text: existing?.name ?? '');
    String selectedHex = existing?.colorHex ?? kLabelPalette.first.hex;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Dialog(
          backgroundColor: surfaceDark,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  existing == null ? 'Nueva etiqueta' : 'Editar etiqueta',
                  style: const TextStyle(
                    color: white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: white, fontSize: 14),
                  maxLength: 24,
                  decoration: InputDecoration(
                    hintText: 'Ej: VIP, Urgente, Seguimiento...',
                    hintStyle: TextStyle(color: white.withValues(alpha: 0.3)),
                    filled: true,
                    fillColor: darkBg.withValues(alpha: 0.4),
                    counterStyle: const TextStyle(color: lightText, fontSize: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(14),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'COLOR',
                  style: TextStyle(
                    color: primaryAqua,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: kLabelPalette.map((c) {
                    final isOn = c.hex.toUpperCase() == selectedHex.toUpperCase();
                    return GestureDetector(
                      onTap: () => setSt(() => selectedHex = c.hex),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.color,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isOn ? Colors.white : Colors.transparent,
                            width: 2.5,
                          ),
                          boxShadow: isOn
                              ? [
                                  BoxShadow(
                                    color: c.color.withValues(alpha: 0.5),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                        child: isOn
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: lightText.withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text('Cancelar',
                            style: TextStyle(color: lightText)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final name = controller.text.trim();
                          if (name.isEmpty) return;
                          if (existing == null) {
                            await _ref.add({
                              'name': name,
                              'color': selectedHex,
                              'order': nextOrder,
                              'createdAt': FieldValue.serverTimestamp(),
                            });
                          } else {
                            await _ref.doc(existing.id).update({
                              'name': name,
                              'color': selectedHex,
                            });
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryAqua,
                          foregroundColor: darkBg,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 0,
                        ),
                        child: const Text('Guardar',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
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
      stream: _ref.orderBy('order').snapshots(),
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
