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
  
  // States
  bool _aiEnabled = false;
  String _selectedProvider = 'gemini';
  String _selectedModel = 'gemini-2.5-flash';
  int _responseDelayMs = 15000;
  bool _activeHoursEnabled = false;
  String _activeHoursTimezone = 'America/Mexico_City';
  TimeOfDay _activeHoursStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _activeHoursEnd = const TimeOfDay(hour: 18, minute: 0);
  List<Map<String, String>> _keywordRules = [];
  String _newKeyword = '';
  String _newKeywordResponse = '';
  bool _discriminatorEnabled = false;
  
  // AgendaCool
  bool _reminderEnabled = false;
  TimeOfDay _reminderScheduledTime = const TimeOfDay(hour: 9, minute: 0);

  bool _isSaving = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _aliasController = TextEditingController();
    _apiKeyController = TextEditingController();
    _openaiApiKeyController = TextEditingController();
    _systemPromptController = TextEditingController();
    _discriminatorPromptController = TextEditingController();
    _reminderApiUrlController = TextEditingController();
    _reminderTemplateController = TextEditingController();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('accounts')
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
            _keywordRules = List<Map<String, String>>.from((data['ai_keyword_rules'] as List).map((rule) => {
              'keyword': rule['keyword'] as String? ?? '',
              'response': rule['response'] as String? ?? '',
            }));
          }

          _discriminatorEnabled = data['ai_discriminator_enabled'] ?? false;
          _discriminatorPromptController.text = data['ai_discriminator_prompt'] ?? '';
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
          .collection('accounts')
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
        tabs: const [
          Tab(icon: Icon(Icons.person_outline, size: 20), text: 'Perfil'),
          Tab(icon: Icon(Icons.auto_awesome_outlined, size: 20), text: 'Asistente'),
          Tab(icon: Icon(Icons.reply_all_rounded, size: 20), text: 'Respuestas'),
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
                  maxLines: 6
                ),
              ],
            ),
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
          ..._keywordRules.asMap().entries.map((e) => _keywordTile(e.key, e.value['keyword']!, e.value['response']!)),
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
                  _textField(controller: _reminderTemplateController, label: 'Mensaje de Recordatorio', hint: 'Hola {name}...', maxLines: 3),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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

  // --- Helper Widgets ---

  Widget _sectionTitle(String title) {
    return Text(title.toUpperCase(), style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2));
  }

  Widget _textField({required TextEditingController controller, required String label, String? hint, int maxLines = 1, bool isPassword = false, IconData? icon}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: lightText, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          obscureText: isPassword,
          style: const TextStyle(color: white),
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

  Widget _keywordTile(int index, String key, String resp) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: darkBg.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(key, style: const TextStyle(color: primaryAqua, fontWeight: FontWeight.bold)),
          Text(resp, style: const TextStyle(color: lightText, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: () => setState(() => _keywordRules.removeAt(index))),
      ]),
    );
  }

  Widget _addKeywordSection() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: primaryAqua.withValues(alpha: 0.2)), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        TextField(
          onChanged: (v) => _newKeyword = v,
          style: const TextStyle(color: white, fontSize: 13),
          decoration: const InputDecoration(hintText: 'Palabra clave...', border: InputBorder.none, isDense: true),
        ),
        const Divider(color: white, height: 16),
        TextField(
          onChanged: (v) => _newKeywordResponse = v,
          style: const TextStyle(color: white, fontSize: 13),
          decoration: const InputDecoration(hintText: 'Respuesta...', border: InputBorder.none, isDense: true),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            if (_newKeyword.isNotEmpty && _newKeywordResponse.isNotEmpty) {
              setState(() {
                _keywordRules.add({'keyword': _newKeyword, 'response': _newKeywordResponse});
                _newKeyword = ''; _newKeywordResponse = '';
              });
            }
          },
          child: const Text('+ Agregar Regla', style: TextStyle(color: primaryAqua, fontWeight: FontWeight.bold)),
        ),
      ]),
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
