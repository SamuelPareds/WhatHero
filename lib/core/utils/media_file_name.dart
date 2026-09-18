// Con qué nombre se le ofrece un archivo al operador cuando se lleva una foto
// o un video del chat.
//
// La extensión NO sale del `mediaType`: sale de la propia URL. El backend
// guarda cada objeto en `…/<messageId>.<ext>` (`mediaService.ts`), así que la
// URL ya sabe si ese "video" es un mp4 y si esa "imagen" es un jpg o un webp.
// Deducirla del tipo daría un `.jpg` con bytes de webp: un archivo que no abre
// en ningún lado, y sin ningún error que lo delate.

/// Nombre de archivo partido en base y extensión, porque cada plataforma pide
/// una mitad distinta: el navegador quiere `base.ext` en el atributo `download`
/// y `Gal.putImageBytes` quiere el `name` SIN extensión. Partirlo acá evita que
/// cada rama lo vuelva a cortar con su propia regla.
class MediaFileName {
  /// Nombre sin extensión.
  final String base;

  /// Extensión sin punto, en minúsculas.
  final String ext;

  const MediaFileName(this.base, this.ext);

  String get full => '$base.$ext';
}

/// Extensión real del archivo leída de la URL pública de Firebase Storage.
///
/// El path del objeto viaja percent-encodeado en el segmento que sigue a `/o/`:
///   `…/o/accounts%2F…%2Fmedia%2F<messageId>.jpg?alt=media&token=<uuid>`
/// `Uri.pathSegments` ya lo decodifica, así que alcanza con mirar el último
/// tramo. El `?alt=media&token=…` queda fuera porque es query, no path.
///
/// Devuelve `null` si no hay nada que parezca una extensión: no inventamos, el
/// llamador decide el fallback según el tipo de medio.
String? storageExtension(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return null;
  }
  if (uri.pathSegments.isEmpty) return null;
  // El segmento viene decodificado, así que un path anidado reaparece con sus
  // barras adentro; nos interesa sólo el nombre del archivo.
  final name = uri.pathSegments.last.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  // Una extensión de verdad son pocos caracteres alfanuméricos. El filtro es lo
  // que evita tomar por extensión el `2` de una carpeta llamada `v1.2`.
  if (ext.length > 5 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return null;
  return ext;
}

/// Arma el nombre con el que se guarda o descarga el medio.
///
/// [hint] es el `mediaFileName` que mandó WhatsApp (viene casi siempre en
/// documentos y casi nunca en fotos). Se le respeta el nombre pero se le
/// descarta la extensión: la buena es la de la URL.
///
/// Sin hint usamos la fecha del mensaje: `WhatHero_20260917_1432` ordena
/// alfabéticamente igual que cronológicamente, que es lo que uno quiere de una
/// carpeta de Descargas llena de evidencias.
MediaFileName mediaFileName({
  required String url,
  required bool isVideo,
  String? hint,
  DateTime? timestamp,
}) {
  final ext = storageExtension(url) ?? (isVideo ? 'mp4' : 'jpg');
  final base = _sanitize(hint) ?? _stamp(timestamp ?? DateTime.now());
  return MediaFileName(base, ext);
}

/// Deja el hint en algo que un filesystem acepte, o `null` si no queda nada.
String? _sanitize(String? raw) {
  if (raw == null) return null;
  var name = raw.trim();
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (name.isEmpty) return null;
  return name.length > 60 ? name.substring(0, 60) : name;
}

String _stamp(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'WhatHero_${d.year}${two(d.month)}${two(d.day)}'
      '_${two(d.hour)}${two(d.minute)}';
}
