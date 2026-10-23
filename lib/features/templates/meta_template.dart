import 'dart:math' as math;

/// Una variable que hay que llenar al enviar la plantilla.
class TemplateParam {
  /// `nombre` en las plantillas con nombre; `1`, `2`… en las numeradas.
  final String key;
  final bool named;

  const TemplateParam(this.key, {required this.named});

  String get placeholder => '{{$key}}';
}

/// Un botón de enlace cuyo final de URL cambia por cliente (`…/pedido/{{1}}`).
class TemplateButtonParam {
  /// Posición del botón en la plantilla: Meta la pide al enviar.
  final int index;
  final String buttonText;

  const TemplateButtonParam(this.index, this.buttonText);
}

/// Una plantilla de Meta tal como la devuelve `GET /sessions/cloud-api/templates`.
///
/// Sabe qué hay que llenar para enviarla y si WhatHero PUEDE enviarla. Lo que
/// no se puede (imagen en el encabezado, botón de código…) se dice antes de
/// enviar: dejarla pasar terminaba en un error de Meta con el operador frente
/// al cliente. Ver CLAUDE.md, "📝 Plantillas propias".
class MetaTemplateModel {
  final String id;
  final String name;
  final String status;
  final String category;
  final String language;
  final String? parameterFormat;
  final String? rejectedReason;

  /// `GREEN`, `YELLOW`, `RED` o `UNKNOWN`.
  final String? qualityScore;
  final List<Map<String, dynamic>> components;

  const MetaTemplateModel({
    required this.id,
    required this.name,
    required this.status,
    required this.category,
    required this.language,
    required this.components,
    this.parameterFormat,
    this.rejectedReason,
    this.qualityScore,
  });

  factory MetaTemplateModel.fromJson(Map<String, dynamic> json) {
    final rawComponents = (json['components'] as List<dynamic>?) ?? const [];
    final quality = json['quality_score'];
    return MetaTemplateModel(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      status: ((json['status'] as String?) ?? 'APPROVED').toUpperCase(),
      category: ((json['category'] as String?) ?? 'UTILITY').toUpperCase(),
      language: (json['language'] as String?) ?? 'en_US',
      parameterFormat: json['parameter_format'] as String?,
      rejectedReason: json['rejected_reason'] as String?,
      qualityScore: quality is Map ? quality['score'] as String? : null,
      components: rawComponents
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }

  bool get isApproved => status == 'APPROVED';

  /// En revisión de Meta (incluye una apelación).
  bool get isInReview => status == 'PENDING' || status == 'IN_APPEAL';

  Map<String, dynamic>? _component(String type) {
    for (final c in components) {
      if ((c['type'] as String?)?.toUpperCase() == type) return c;
    }
    return null;
  }

  /// `TEXT`, `IMAGE`, `VIDEO`, `DOCUMENT`, `LOCATION`… o `null` sin encabezado.
  String? get headerFormat {
    final h = _component('HEADER');
    if (h == null) return null;
    return (h['format'] as String?)?.toUpperCase() ??
        (h['text'] != null ? 'TEXT' : null);
  }

  String? get headerText =>
      headerFormat == 'TEXT' ? _component('HEADER')!['text'] as String? : null;

  String get bodyText => (_component('BODY')?['text'] as String?) ?? '';

  String? get footerText => _component('FOOTER')?['text'] as String?;

  List<Map<String, dynamic>> get buttons {
    final raw = _component('BUTTONS')?['buttons'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((b) => Map<String, dynamic>.from(b)).toList();
  }

  static final _placeholder = RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');

  /// Con nombre (`{{nombre}}`) o numeradas (`{{1}}`). Meta lo informa en
  /// `parameter_format`; si no viene, se deduce del texto.
  bool get isNamed {
    if (parameterFormat != null) return parameterFormat!.toUpperCase() == 'NAMED';
    final text = '${headerText ?? ''} $bodyText';
    return _placeholder
        .allMatches(text)
        .any((m) => int.tryParse(m.group(1)!) == null);
  }

  List<TemplateParam> _params(String text) {
    final keys = _placeholder.allMatches(text).map((m) => m.group(1)!).toList();
    if (keys.isEmpty) return const [];
    if (!isNamed) {
      // Meta espera {{1}}..{{n}} en orden, aunque el texto las use desordenadas.
      final last = keys.map((k) => int.tryParse(k) ?? 0).fold(0, math.max);
      return [for (var i = 1; i <= last; i++) TemplateParam('$i', named: false)];
    }
    final seen = <String>{};
    return [
      for (final k in keys)
        if (seen.add(k)) TemplateParam(k, named: true),
    ];
  }

  List<TemplateParam> get headerParams => _params(headerText ?? '');

  List<TemplateParam> get bodyParams => _params(bodyText);

  List<TemplateButtonParam> get buttonParams {
    final out = <TemplateButtonParam>[];
    final all = buttons;
    for (var i = 0; i < all.length; i++) {
      final b = all[i];
      final url = b['url'] as String? ?? '';
      if ((b['type'] as String?)?.toUpperCase() == 'URL' && url.contains('{{')) {
        out.add(TemplateButtonParam(i, (b['text'] as String?) ?? 'Enlace'));
      }
    }
    return out;
  }

  /// Por qué WhatHero no puede enviar esta plantilla, o `null` si puede.
  String? get unsupportedReason {
    if (category == 'AUTHENTICATION') {
      return 'Es de autenticación (códigos de un solo uso): WhatHero no la envía.';
    }
    final format = headerFormat;
    if (format != null && format != 'TEXT') {
      return 'Lleva ${_headerFormatLabel(format)} en el encabezado: WhatHero todavía no puede enviarla.';
    }
    for (final c in components) {
      final type = (c['type'] as String?)?.toUpperCase();
      if (type == 'HEADER' || type == 'BODY' || type == 'FOOTER' || type == 'BUTTONS') {
        continue;
      }
      return 'Usa un formato ($type) que WhatHero todavía no puede enviar.';
    }
    for (final b in buttons) {
      final type = (b['type'] as String?)?.toUpperCase();
      if (type != 'QUICK_REPLY' && type != 'URL' && type != 'PHONE_NUMBER') {
        return 'Tiene un botón de tipo $type: WhatHero todavía no puede enviarla.';
      }
    }
    return null;
  }

  static String _headerFormatLabel(String format) => switch (format) {
        'IMAGE' => 'una imagen',
        'VIDEO' => 'un video',
        'GIF' => 'un GIF',
        'DOCUMENT' => 'un documento',
        'LOCATION' => 'una ubicación',
        _ => format.toLowerCase(),
      };

  /// Los `components` del envío, con un valor por cada parámetro en el mismo
  /// orden que [headerParams], [bodyParams] y [buttonParams].
  List<Map<String, dynamic>> buildComponents({
    List<String> header = const [],
    List<String> body = const [],
    List<String> buttons = const [],
  }) {
    String at(List<String> values, int i) => i < values.length ? values[i] : '';
    Map<String, dynamic> textParam(TemplateParam p, String value) => {
          'type': 'text',
          if (p.named) 'parameter_name': p.key,
          'text': value,
        };

    final hp = headerParams;
    final bp = bodyParams;
    final btn = buttonParams;
    return [
      if (hp.isNotEmpty)
        {
          'type': 'header',
          'parameters': [for (var i = 0; i < hp.length; i++) textParam(hp[i], at(header, i))],
        },
      if (bp.isNotEmpty)
        {
          'type': 'body',
          'parameters': [for (var i = 0; i < bp.length; i++) textParam(bp[i], at(body, i))],
        },
      for (var i = 0; i < btn.length; i++)
        {
          'type': 'button',
          'sub_type': 'url',
          'index': '${btn[i].index}',
          'parameters': [
            {'type': 'text', 'text': at(buttons, i)},
          ],
        },
    ];
  }

  /// El texto que queda en la burbuja del chat: encabezado, cuerpo y pie con
  /// las variables llenas (las vacías se ven como `{{nombre}}`).
  String renderPreview({
    List<String> header = const [],
    List<String> body = const [],
  }) {
    String fill(String input, List<TemplateParam> params, List<String> values) {
      var out = input;
      for (var i = 0; i < params.length && i < values.length; i++) {
        final v = values[i].trim();
        if (v.isNotEmpty) out = out.replaceAll(params[i].placeholder, v);
      }
      return out;
    }

    final parts = <String>[];
    final h = headerText;
    if (h != null && h.trim().isNotEmpty) {
      parts.add(fill(h.trim(), headerParams, header));
    }
    if (bodyText.trim().isNotEmpty) {
      parts.add(fill(bodyText.trim(), bodyParams, body));
    }
    final f = footerText;
    if (f != null && f.trim().isNotEmpty) parts.add(f.trim());
    if (parts.isEmpty) return '📋 Plantilla: $name ($language)';
    return parts.join('\n\n');
  }
}

/// El motivo de rechazo de Meta (`rejected_reason`) en palabras del operador.
String? describeRejectedReason(String? reason) => switch (reason?.toUpperCase()) {
      null || '' || 'NONE' => null,
      'INVALID_FORMAT' => 'Formato inválido: revisa las variables, las llaves y los ejemplos.',
      'INCORRECT_CATEGORY' ||
      'TAG_CONTENT_MISMATCH' =>
        'La categoría no corresponde al contenido (por ejemplo, una promoción marcada como Utilidad).',
      'PROMOTIONAL' => 'Tiene contenido promocional en una categoría que no lo permite.',
      'ABUSIVE_CONTENT' => 'Meta lo consideró contenido abusivo o amenazante.',
      'SCAM' => 'Meta lo marcó como posible fraude.',
      _ => 'Motivo de Meta: $reason',
    };
