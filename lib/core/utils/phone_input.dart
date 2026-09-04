/// Núcleo de entrada telefónica: catálogo de países y normalización de lo que
/// el usuario escribe o pega.
///
/// Todo lo de aquí son funciones puras sin dependencias — la UI vive en
/// `features/chat/widgets/new_chat_sheet.dart` y los tests en
/// `test/phone_input_test.dart`.
///
/// Regla de oro de este archivo: **nunca adivinamos el JID de WhatsApp**. Aquí
/// sólo separamos "código de país" de "número nacional" para que el operador
/// escriba sus 10 dígitos de siempre. Cuál de las variantes de ese número
/// existe realmente en WhatsApp (el `521` mexicano, el `549` argentino) lo
/// responde el backend preguntándole a WhatsApp con `onWhatsApp`, no una tabla.
library;

/// Un país en el selector: bandera, código internacional y cuántos dígitos
/// esperamos del número nacional.
///
/// [minLen]/[maxLen] son del número SIN código de país. Se usan para tres
/// cosas: habilitar el botón, decidir si algo pegado trae código incluido, y
/// el texto de ayuda. Son deliberadamente permisivos donde no tenemos certeza:
/// un rango de más nunca bloquea a nadie, un rango de menos sí.
class Country {
  final String iso2;
  final String name;

  /// Código internacional sin `+`.
  final String dial;

  final int minLen;
  final int maxLen;

  /// Dígito que algunos países insertan entre el código y el número nacional
  /// para líneas móviles: México ('1') y Argentina ('9'). Sólo lo usamos para
  /// RECONOCER y quitar ese prefijo cuando viene pegado — nunca para armar el
  /// número que mandamos a verificar.
  final String? mobilePrefix;

  /// Agrupación visual del número nacional ('#' = dígito). Sólo para mostrar;
  /// el campo de texto siempre guarda dígitos pelados.
  final String? pattern;

  const Country(
    this.iso2,
    this.name,
    this.dial,
    this.minLen,
    this.maxLen, {
    this.mobilePrefix,
    this.pattern,
  });

  /// Bandera derivada del ISO2 con regional indicator symbols (cero assets).
  /// En plataformas que no las renderizan (Windows) se ve el par de letras,
  /// que sigue siendo legible — por eso el selector muestra SIEMPRE también
  /// el `+código` al lado: el significado no depende del emoji.
  String get flag =>
      String.fromCharCodes(iso2.codeUnits.map((c) => 0x1F1E6 + c - 0x41));

  @override
  String toString() => '$iso2 +$dial';
}

/// Países con metadata verificada: son los mercados del producto, donde el
/// largo exacto del número nacional nos importa para no dejar enviar un
/// número incompleto.
const Country _mexico =
    Country('MX', 'México', '52', 10, 10, mobilePrefix: '1', pattern: '## #### ####');

const List<Country> _primary = [
  _mexico,
  Country('CO', 'Colombia', '57', 10, 10, pattern: '### ### ####'),
  Country('AR', 'Argentina', '54', 10, 10, mobilePrefix: '9', pattern: '## #### ####'),
  Country('CL', 'Chile', '56', 9, 9, pattern: '# #### ####'),
  Country('PE', 'Perú', '51', 9, 9, pattern: '### ### ###'),
  // +1 es todo el plan de numeración norteamericano (EE.UU., Canadá y buena
  // parte del Caribe: República Dominicana, Puerto Rico…). Son 10 dígitos en
  // todos, así que una sola entrada los cubre sin mentirle a nadie: el E.164
  // que resulta es idéntico.
  Country('US', 'EE.UU. / Canadá / Caribe', '1', 10, 10, pattern: '### ### ####'),
  Country('ES', 'España', '34', 9, 9, pattern: '### ## ## ##'),
  Country('EC', 'Ecuador', '593', 9, 9),
  Country('VE', 'Venezuela', '58', 10, 10),
  Country('BO', 'Bolivia', '591', 8, 8),
  Country('PY', 'Paraguay', '595', 9, 9),
  Country('UY', 'Uruguay', '598', 8, 9),
  Country('BR', 'Brasil', '55', 10, 11, pattern: '## ##### ####'),
  Country('CR', 'Costa Rica', '506', 8, 8),
  Country('PA', 'Panamá', '507', 7, 8),
  Country('GT', 'Guatemala', '502', 8, 8),
  Country('SV', 'El Salvador', '503', 8, 8),
  Country('HN', 'Honduras', '504', 8, 8),
  Country('NI', 'Nicaragua', '505', 8, 8),
  Country('CU', 'Cuba', '53', 8, 8),
];

/// El resto del mundo, con rango permisivo. No los validamos con precisión
/// (no es nuestro mercado y equivocarnos bloquearía un envío legítimo), pero
/// están para que nadie quede sin poder escribirle a un número.
const List<Country> _secondary = [
  Country('DE', 'Alemania', '49', 6, 13),
  Country('AD', 'Andorra', '376', 6, 9),
  Country('AO', 'Angola', '244', 9, 9),
  Country('SA', 'Arabia Saudita', '966', 8, 10),
  Country('DZ', 'Argelia', '213', 8, 9),
  Country('AU', 'Australia', '61', 8, 10),
  Country('AT', 'Austria', '43', 7, 13),
  Country('BE', 'Bélgica', '32', 8, 9),
  Country('BD', 'Bangladés', '880', 8, 10),
  Country('BY', 'Bielorrusia', '375', 9, 9),
  Country('BA', 'Bosnia y Herzegovina', '387', 8, 8),
  Country('BG', 'Bulgaria', '359', 8, 9),
  Country('BF', 'Burkina Faso', '226', 8, 8),
  Country('KH', 'Camboya', '855', 8, 9),
  Country('CM', 'Camerún', '237', 9, 9),
  Country('QA', 'Catar', '974', 8, 8),
  Country('CZ', 'Chequia', '420', 9, 9),
  Country('CN', 'China', '86', 8, 11),
  Country('CY', 'Chipre', '357', 8, 8),
  Country('VA', 'Ciudad del Vaticano', '379', 6, 12),
  Country('CI', "Costa de Marfil", '225', 8, 10),
  Country('HR', 'Croacia', '385', 8, 9),
  Country('DK', 'Dinamarca', '45', 8, 8),
  Country('EG', 'Egipto', '20', 9, 10),
  Country('AE', 'Emiratos Árabes Unidos', '971', 8, 9),
  Country('SK', 'Eslovaquia', '421', 9, 9),
  Country('SI', 'Eslovenia', '386', 8, 8),
  Country('EE', 'Estonia', '372', 7, 8),
  Country('ET', 'Etiopía', '251', 9, 9),
  Country('PH', 'Filipinas', '63', 8, 10),
  Country('FI', 'Finlandia', '358', 6, 12),
  Country('FR', 'Francia', '33', 9, 9),
  Country('GA', 'Gabón', '241', 7, 8),
  Country('GH', 'Ghana', '233', 9, 9),
  Country('GR', 'Grecia', '30', 10, 10),
  Country('GN', 'Guinea', '224', 8, 9),
  Country('GQ', 'Guinea Ecuatorial', '240', 9, 9),
  Country('GY', 'Guyana', '592', 7, 7),
  Country('HT', 'Haití', '509', 8, 8),
  Country('HU', 'Hungría', '36', 8, 9),
  Country('IN', 'India', '91', 10, 10),
  Country('ID', 'Indonesia', '62', 8, 12),
  Country('IQ', 'Irak', '964', 8, 10),
  Country('IR', 'Irán', '98', 9, 10),
  Country('IE', 'Irlanda', '353', 7, 9),
  Country('IS', 'Islandia', '354', 7, 9),
  Country('IL', 'Israel', '972', 8, 9),
  Country('IT', 'Italia', '39', 6, 11),
  Country('JM', 'Jamaica', '1876', 7, 7),
  Country('JP', 'Japón', '81', 9, 10),
  Country('JO', 'Jordania', '962', 8, 9),
  Country('KZ', 'Kazajistán', '7', 10, 10),
  Country('KE', 'Kenia', '254', 9, 9),
  Country('KW', 'Kuwait', '965', 8, 8),
  Country('LV', 'Letonia', '371', 8, 8),
  Country('LB', 'Líbano', '961', 7, 8),
  Country('LY', 'Libia', '218', 9, 9),
  Country('LT', 'Lituania', '370', 8, 8),
  Country('LU', 'Luxemburgo', '352', 6, 9),
  Country('MK', 'Macedonia del Norte', '389', 8, 8),
  Country('MY', 'Malasia', '60', 8, 10),
  Country('ML', 'Malí', '223', 8, 8),
  Country('MT', 'Malta', '356', 8, 8),
  Country('MA', 'Marruecos', '212', 9, 9),
  Country('MU', 'Mauricio', '230', 7, 8),
  Country('MD', 'Moldavia', '373', 8, 8),
  Country('MC', 'Mónaco', '377', 8, 9),
  Country('MN', 'Mongolia', '976', 8, 8),
  Country('ME', 'Montenegro', '382', 8, 8),
  Country('MZ', 'Mozambique', '258', 9, 9),
  Country('NG', 'Nigeria', '234', 8, 10),
  Country('NO', 'Noruega', '47', 8, 8),
  Country('NZ', 'Nueva Zelanda', '64', 8, 10),
  Country('NL', 'Países Bajos', '31', 9, 9),
  Country('PK', 'Pakistán', '92', 10, 10),
  Country('PL', 'Polonia', '48', 9, 9),
  Country('PT', 'Portugal', '351', 9, 9),
  Country('GB', 'Reino Unido', '44', 9, 10),
  Country('RW', 'Ruanda', '250', 9, 9),
  Country('RO', 'Rumanía', '40', 9, 9),
  Country('RU', 'Rusia', '7', 10, 10),
  Country('RS', 'Serbia', '381', 8, 9),
  Country('SG', 'Singapur', '65', 8, 8),
  Country('SY', 'Siria', '963', 8, 9),
  Country('SO', 'Somalia', '252', 7, 9),
  Country('LK', 'Sri Lanka', '94', 9, 9),
  Country('ZA', 'Sudáfrica', '27', 9, 9),
  Country('SD', 'Sudán', '249', 9, 9),
  Country('SE', 'Suecia', '46', 7, 10),
  Country('CH', 'Suiza', '41', 9, 9),
  Country('TH', 'Tailandia', '66', 8, 9),
  Country('TZ', 'Tanzania', '255', 9, 9),
  Country('TN', 'Túnez', '216', 8, 8),
  Country('TR', 'Turquía', '90', 10, 10),
  Country('UA', 'Ucrania', '380', 9, 9),
  Country('UG', 'Uganda', '256', 9, 9),
  Country('VN', 'Vietnam', '84', 9, 10),
  Country('YE', 'Yemen', '967', 7, 9),
  Country('ZM', 'Zambia', '260', 9, 9),
  Country('ZW', 'Zimbabue', '263', 9, 9),
];

/// Catálogo completo. Los mercados del producto van primero para que el
/// selector los muestre arriba sin necesidad de buscar.
const List<Country> kCountries = [..._primary, ..._secondary];

/// País por defecto si todo lo demás falla (no se pudo derivar de la sesión).
const Country kFallbackCountry = _mexico;

/// Busca un país por su código ISO2. Devuelve null si no está en el catálogo.
Country? countryForIso(String iso2) {
  final upper = iso2.toUpperCase();
  for (final c in kCountries) {
    if (c.iso2 == upper) return c;
  }
  return null;
}

/// País cuyo código internacional prefija a [digits], con match más largo
/// (así '1876' gana sobre '1' para Jamaica).
///
/// Con esto derivamos el país por defecto del NÚMERO DE LA PROPIA SESIÓN: un
/// cliente mexicano abre el panel ya en 🇲🇽 y uno colombiano en 🇨🇴, sin
/// configurar nada. Nótese que `5215561642726` empieza con `52`, así que el
/// prefijo móvil mexicano no estorba aquí.
Country? countryForE164(String digits) {
  final clean = digits.replaceAll(RegExp(r'\D'), '');
  if (clean.isEmpty) return null;
  Country? best;
  for (final c in kCountries) {
    if (!clean.startsWith(c.dial)) continue;
    if (best == null || c.dial.length > best.dial.length) best = c;
  }
  return best;
}

/// Lo que quedó después de interpretar lo que el usuario escribió o pegó.
class PhoneInput {
  /// País resultante (puede haber cambiado si pegaron un número extranjero).
  final Country country;

  /// Número nacional, sólo dígitos, sin código de país.
  final String national;

  /// Qué le quitamos, para poder avisarlo en la UI ('+52', '0'…).
  /// null = no tocamos nada.
  final String? stripped;

  const PhoneInput(this.country, this.national, {this.stripped});

  /// E.164 sin `+` — lo que viaja al backend para verificar.
  String get e164 => '${country.dial}$national';

  /// ¿Alcanza para intentar? El largo lo decide el país.
  bool get isComplete =>
      national.length >= country.minLen && national.length <= country.maxLen;

  @override
  String toString() => '+$e164';
}

/// Interpreta [raw] (lo tecleado o pegado) contra el país [current] y devuelve
/// el número nacional limpio.
///
/// El orden de las reglas importa y está pensado para NO mutilar un número
/// legítimo: **primero manda el largo**. Un número que ya cabe en el rango
/// nacional del país seleccionado se respeta tal cual, aunque por casualidad
/// empiece con los mismos dígitos que el código de país. Sólo cuando NO cabe
/// buscamos qué prefijo sobra.
PhoneInput normalizeTyped(String raw, Country current) {
  final hadPlus = raw.trimLeft().startsWith('+');
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return PhoneInput(current, '');

  // Con '+' explícito no hay ambigüedad posible: es E.164 completo.
  if (hadPlus) {
    final match = countryForE164(digits);
    if (match != null) {
      final national = digits.substring(match.dial.length);
      return PhoneInput(
        match,
        _dropMobilePrefix(match, national),
        stripped: '+${match.dial}',
      );
    }
    // Código no catalogado: lo dejamos crudo bajo el país actual antes que
    // inventarnos un recorte.
    return PhoneInput(current, digits);
  }

  // 1. Ya es un número nacional válido para el país actual → intacto.
  if (digits.length >= current.minLen && digits.length <= current.maxLen) {
    return PhoneInput(current, digits);
  }

  // 2. Trae el código del país actual (con o sin su prefijo móvil).
  //    Probamos primero el prefijo largo: '521' antes que '52'.
  final mobile = current.mobilePrefix;
  if (mobile != null) {
    final withMobile = '${current.dial}$mobile';
    if (digits.startsWith(withMobile)) {
      final rest = digits.substring(withMobile.length);
      if (_fits(current, rest)) {
        return PhoneInput(current, rest, stripped: '+$withMobile');
      }
    }
  }
  if (digits.startsWith(current.dial)) {
    final rest = digits.substring(current.dial.length);
    if (_fits(current, rest)) {
      return PhoneInput(current, rest, stripped: '+${current.dial}');
    }
  }

  // 3. Cero de marcado nacional (hábito colombiano/argentino: 0351…).
  if (digits.startsWith('0')) {
    final rest = digits.replaceFirst(RegExp(r'^0+'), '');
    if (_fits(current, rest)) {
      return PhoneInput(current, rest, stripped: '0');
    }
  }

  // 4. Es de otro país: buscamos el código que deje un nacional coherente,
  //    con match más largo. Aquí es donde pegar un +57 estando en 🇲🇽 mueve
  //    el selector solo.
  Country? best;
  String? bestNational;
  for (final c in kCountries) {
    if (!digits.startsWith(c.dial)) continue;
    var rest = digits.substring(c.dial.length);
    rest = _dropMobilePrefix(c, rest);
    if (!_fits(c, rest)) continue;
    if (best == null || c.dial.length > best.dial.length) {
      best = c;
      bestNational = rest;
    }
  }
  if (best != null) {
    return PhoneInput(best, bestNational!, stripped: '+${best.dial}');
  }

  // 5. No entendimos: no tocamos nada. Preferimos que el operador vea su
  //    número raro y lo corrija a recortarle dígitos por nuestra cuenta.
  return PhoneInput(current, digits);
}

/// Quita el prefijo móvil ('1' mexicano / '9' argentino) si al hacerlo el
/// número encaja en el rango nacional. Sin ese chequeo estaríamos comiéndonos
/// el primer dígito de un número legítimo.
String _dropMobilePrefix(Country c, String national) {
  final mobile = c.mobilePrefix;
  if (mobile == null || !national.startsWith(mobile)) return national;
  if (_fits(c, national)) return national; // ya cabía: ese '1' es del número
  final rest = national.substring(mobile.length);
  return _fits(c, rest) ? rest : national;
}

bool _fits(Country c, String national) =>
    national.length >= c.minLen && national.length <= c.maxLen;

/// Agrupa el número nacional según el patrón del país, para mostrarlo.
/// Sin patrón, lo devuelve tal cual: preferimos crudo antes que una
/// agrupación inventada que confunda.
String formatNational(Country c, String national) {
  final pattern = c.pattern;
  if (pattern == null || national.isEmpty) return national;
  final buffer = StringBuffer();
  var i = 0;
  for (final ch in pattern.split('')) {
    if (i >= national.length) break;
    if (ch == '#') {
      buffer.write(national[i]);
      i++;
    } else {
      buffer.write(ch);
    }
  }
  // Sobrantes (número más largo que el patrón): van pegados al final.
  if (i < national.length) buffer.write(national.substring(i));
  return buffer.toString();
}

/// Cómo se le muestra al operador el número al que se va a escribir.
String formatE164(Country c, String national) =>
    '+${c.dial} ${formatNational(c, national)}'.trimRight();
