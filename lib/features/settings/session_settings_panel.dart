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

class _SessionSettingsPanelState extends State<SessionSettingsPanel> {
  late TextEditingController _apiKeyController;
  late TextEditingController _systemPromptController;
  late TextEditingController _discriminatorPromptController;
  bool _aiEnabled = false;
  String _selectedModel = 'gemini-2.5-flash';
  int _responseDelayMs = 15000; // Default: 15 seconds
  bool _activeHoursEnabled = false;
  String _activeHoursTimezone = 'America/Mexico_City';
  TimeOfDay _activeHoursStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _activeHoursEnd = const TimeOfDay(hour: 18, minute: 0);
  List<String> _optedOutContacts = [];
  List<Map<String, String>> _keywordRules = [];
  String _newKeyword = '';
  String _newKeywordResponse = '';
  bool _discriminatorEnabled = false;
  bool _isSaving = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController();
    _systemPromptController = TextEditingController();
    _discriminatorPromptController = TextEditingController();
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
          _aiEnabled = data['ai_enabled'] ?? false;
          _apiKeyController.text = data['ai_api_key'] ?? '';
          _systemPromptController.text =
              data['ai_system_prompt'] ?? 'Eres un asistente útil.';
          _selectedModel = data['ai_model'] ?? 'gemini-2.5-flash';
          _responseDelayMs = data['ai_response_delay_ms'] ?? 15000;

          // Active hours
          if (data['ai_active_hours'] is Map) {
            final hours = data['ai_active_hours'] as Map;
            _activeHoursEnabled = hours['enabled'] ?? false;
            _activeHoursTimezone = hours['timezone'] ?? 'America/Mexico_City';
            if (hours['start'] is String) {
              final parts = (hours['start'] as String).split(':');
              _activeHoursStart = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? 9,
                minute: int.tryParse(parts[1]) ?? 0,
              );
            }
            if (hours['end'] is String) {
              final parts = (hours['end'] as String).split(':');
              _activeHoursEnd = TimeOfDay(
                hour: int.tryParse(parts[0]) ?? 18,
                minute: int.tryParse(parts[1]) ?? 0,
              );
            }
          }

          // Opted out contacts
          _optedOutContacts =
              List<String>.from(data['ai_opted_out_contacts'] ?? []);

          // Keyword rules
          if (data['ai_keyword_rules'] is List) {
            _keywordRules = List<Map<String, String>>.from(
              (data['ai_keyword_rules'] as List).map(
                (rule) => {
                  'keyword': rule['keyword'] as String? ?? '',
                  'response': rule['response'] as String? ?? '',
                },
              ),
            );
          }

          // Discriminator
          _discriminatorEnabled = data['ai_discriminator_enabled'] ?? false;
          _discriminatorPromptController.text =
              data['ai_discriminator_prompt'] ?? '';

          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
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
        'ai_enabled': _aiEnabled,
        'ai_api_key': _apiKeyController.text,
        'ai_system_prompt': _systemPromptController.text,
        'ai_model': _selectedModel,
        'ai_response_delay_ms': _responseDelayMs,
        'ai_active_hours': {
          'enabled': _activeHoursEnabled,
          'timezone': _activeHoursTimezone,
          'start': '${_activeHoursStart.hour.toString().padLeft(2, '0')}:${_activeHoursStart.minute.toString().padLeft(2, '0')}',
          'end': '${_activeHoursEnd.hour.toString().padLeft(2, '0')}:${_activeHoursEnd.minute.toString().padLeft(2, '0')}',
        },
        'ai_opted_out_contacts': _optedOutContacts,
        'ai_keyword_rules': _keywordRules,
        'ai_discriminator_enabled': _discriminatorEnabled,
        'ai_discriminator_prompt': _discriminatorPromptController.text.trim(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuración guardada')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _systemPromptController.dispose();
    _discriminatorPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox(
        height: 400,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: lightText.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Title
            const Text(
              'Configuración IA',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: white,
              ),
            ),
            const SizedBox(height: 24),
            // Enable toggle
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryAqua.withValues(alpha: 0.1),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Activar Asistente IA',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: white,
                      ),
                    ),
                    Switch(
                      value: _aiEnabled,
                      onChanged: (value) {
                        setState(() => _aiEnabled = value);
                      },
                      activeThumbColor: primaryAqua,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Model selector
            const Text(
              'Modelo de IA',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primaryAqua.withValues(alpha: 0.2),
                ),
              ),
              child: DropdownButton<String>(
                value: _selectedModel,
                onChanged: (String? value) {
                  if (value != null) {
                    setState(() => _selectedModel = value);
                  }
                },
                isExpanded: true,
                underline: const SizedBox(),
                dropdownColor: surfaceDark,
                items: [
                  DropdownMenuItem(
                    value: 'gemini-2.5-flash',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash 2.5 (Recomendado)',
                        style: TextStyle(color: primaryAqua),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-3-flash',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash 3 (Más rápido)',
                        style: TextStyle(color: white),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-2.5-pro',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Pro 2.5 (Más preciso)',
                        style: TextStyle(color: white),
                      ),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'gemini-2.5-flash-lite',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Flash Lite (Más barato)',
                        style: TextStyle(color: lightText),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // API Key field
            const Text(
              'Gemini API Key',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'sk-...',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryAqua.withValues(alpha: 0.2),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 20),
            // System prompt field
            const Text(
              'Instrucciones del Asistente',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: lightText,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _systemPromptController,
              maxLines: 4,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'Eres un asistente de ventas para nuestra empresa...',
                hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                filled: true,
                fillColor: darkBg.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: primaryAqua.withValues(alpha: 0.2),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 24),
            // Message buffer wait time slider
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Espera entre mensajes',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: lightText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'El asistente espera este tiempo para recibir más mensajes antes de responder',
                  style: TextStyle(
                    fontSize: 12,
                    color: lightText.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: darkBg.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: primaryAqua.withValues(alpha: 0.1),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      Slider(
                        value: _responseDelayMs.toDouble(),
                        min: 8000,
                        max: 30000,
                        divisions: 22,
                        activeColor: primaryAqua,
                        onChanged: (value) {
                          setState(() => _responseDelayMs = value.toInt());
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${(_responseDelayMs / 1000).toStringAsFixed(1)}s',
                          style: const TextStyle(
                            fontSize: 12,
                            color: primaryAqua,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Discriminator section
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Discriminador de Intenciones',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: white,
                        ),
                      ),
                      Switch(
                        value: _discriminatorEnabled,
                        onChanged: (value) {
                          setState(() => _discriminatorEnabled = value);
                        },
                        activeThumbColor: primaryAqua,
                      ),
                    ],
                  ),
                  if (_discriminatorEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Define cuándo se requiere atención humana (lenguaje natural)',
                      style: TextStyle(
                        fontSize: 12,
                        color: lightText.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _discriminatorPromptController,
                      minLines: 4,
                      maxLines: 6,
                      style: const TextStyle(color: white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Ejemplo:\n\nPasa al humano si:\n- El cliente pregunta disponibilidad de fechas específicas\n- Quiere agendar una cita\n- Pregunta por saldo o historial personal\n\nDe lo contrario, responde tú mismo.',
                        hintStyle: TextStyle(
                          color: lightText.withValues(alpha: 0.3),
                          fontSize: 13,
                        ),
                        filled: true,
                        fillColor: darkBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: primaryAqua.withValues(alpha: 0.1),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: primaryAqua, width: 2),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Active hours section
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Horario de atención',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: white,
                        ),
                      ),
                      Switch(
                        value: _activeHoursEnabled,
                        onChanged: (v) => setState(() => _activeHoursEnabled = v),
                        activeThumbColor: primaryAqua,
                      ),
                    ],
                  ),
                  if (_activeHoursEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Zona horaria',
                      style: const TextStyle(
                        fontSize: 12,
                        color: lightText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      decoration: BoxDecoration(
                        color: darkBg.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButton<String>(
                        value: _activeHoursTimezone,
                        isExpanded: true,
                        underline: const SizedBox(),
                        dropdownColor: surfaceDark,
                        items: [
                          'America/Mexico_City',
                          'America/New_York',
                          'Europe/Madrid',
                          'Europe/London',
                          'America/Los_Angeles',
                        ].map((tz) => DropdownMenuItem(value: tz, child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(tz, style: const TextStyle(color: white)),
                        ))).toList(),
                        onChanged: (v) => setState(() => _activeHoursTimezone = v ?? 'America/Mexico_City'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Inicio', style: const TextStyle(fontSize: 12, color: lightText)),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () async {
                                  final time = await showTimePicker(context: context, initialTime: _activeHoursStart);
                                  if (time != null) setState(() => _activeHoursStart = time);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: darkBg.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('${_activeHoursStart.hour.toString().padLeft(2, '0')}:${_activeHoursStart.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: primaryAqua)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Fin', style: const TextStyle(fontSize: 12, color: lightText)),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () async {
                                  final time = await showTimePicker(context: context, initialTime: _activeHoursEnd);
                                  if (time != null) setState(() => _activeHoursEnd = time);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: darkBg.withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text('${_activeHoursEnd.hour.toString().padLeft(2, '0')}:${_activeHoursEnd.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: primaryAqua)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Opted-out contacts
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Contactos bloqueados',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: white),
                  ),
                  const SizedBox(height: 12),
                  if (_optedOutContacts.isNotEmpty)
                    Column(
                      children: _optedOutContacts.map((phone) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(child: Text(phone, style: const TextStyle(color: lightText, fontSize: 13))),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                onPressed: () => setState(() => _optedOutContacts.remove(phone)),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: '+1234567890',
                            hintStyle: TextStyle(color: lightText.withValues(alpha: 0.5)),
                            isDense: true,
                            filled: true,
                            fillColor: darkBg.withValues(alpha: 0.3),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          style: const TextStyle(color: white, fontSize: 13),
                          onChanged: (v) => setState(() {}),
                          onSubmitted: (phone) {
                            if (phone.trim().isNotEmpty && !_optedOutContacts.contains(phone)) {
                              setState(() {
                                _optedOutContacts.add(phone);
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 40,
                        child: ElevatedButton(
                          onPressed: () => {},
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryAqua.withValues(alpha: 0.3),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: const Text('Agregar', style: TextStyle(fontSize: 12, color: primaryAqua)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Keyword rules
            Container(
              decoration: BoxDecoration(
                color: darkBg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryAqua.withValues(alpha: 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Respuestas por palabra clave',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: white),
                  ),
                  const SizedBox(height: 12),
                  if (_keywordRules.isNotEmpty)
                    Column(
                      children: _keywordRules.asMap().entries.map((e) {
                        final idx = e.key;
                        final rule = e.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${rule['keyword']}', style: const TextStyle(color: primaryAqua, fontSize: 12, fontWeight: FontWeight.w600)),
                                    Text('${rule['response']!.substring(0, (rule['response']!.length < 30 ? rule['response']!.length : 30))}...', style: const TextStyle(color: lightText, fontSize: 11)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                onPressed: () => setState(() => _keywordRules.removeAt(idx)),
                                padding: EdgeInsets.zero,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  Column(
                    children: [
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Palabra clave',
                          isDense: true,
                          filled: true,
                          fillColor: darkBg.withValues(alpha: 0.3),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        style: const TextStyle(color: white, fontSize: 12),
                        onChanged: (v) => _newKeyword = v,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: InputDecoration(
                          hintText: 'Respuesta',
                          isDense: true,
                          filled: true,
                          fillColor: darkBg.withValues(alpha: 0.3),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        maxLines: 2,
                        style: const TextStyle(color: white, fontSize: 12),
                        onChanged: (v) => _newKeywordResponse = v,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            if (_newKeyword.trim().isNotEmpty && _newKeywordResponse.trim().isNotEmpty) {
                              setState(() {
                                _keywordRules.add({'keyword': _newKeyword, 'response': _newKeywordResponse});
                                _newKeyword = '';
                                _newKeywordResponse = '';
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryAqua.withValues(alpha: 0.3),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          child: const Text('Agregar regla', style: TextStyle(fontSize: 12, color: primaryAqua)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  disabledBackgroundColor: primaryAqua.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(darkBg),
                        ),
                      )
                    : const Text(
                        'Guardar',
                        style: TextStyle(
                          color: darkBg,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
