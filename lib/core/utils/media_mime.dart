/// Extensión y MIME de un archivo que vamos a mandar por WhatsApp.
///
/// La misma tabla estaba escrita dos veces (el composer del chat y el editor
/// de respuestas rápidas) y las dos copias no coincidían: la del editor no
/// conocía ningún tipo de video, así que un adjunto se subía a Storage como
/// `application/octet-stream`. Vive acá para que agregar un formato sea un
/// lugar, no tres.
///
/// El MIME importa en dos momentos distintos: como `contentType` del objeto en
/// Storage (de eso depende que el navegador lo muestre en vez de bajarlo) y
/// como el `mimetype` que viaja al backend y de ahí a Baileys.
///
/// Funciones puras sin dependencias.
library;

/// La extensión de [name], en minúsculas y sin el punto.
///
/// Vacío si no hay nada que parezca una: un nombre sin punto, o uno que
/// empieza o termina con él.
String fileExtension(String name) {
  final i = name.lastIndexOf('.');
  return (i > 0 && i < name.length - 1) ? name.substring(i + 1).toLowerCase() : '';
}

const Map<String, String> _mimeByExtension = {
  // Imagen
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
  'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
  'heif': 'image/heif', 'bmp': 'image/bmp',
  // Video
  'mp4': 'video/mp4', 'mov': 'video/quicktime', '3gp': 'video/3gpp',
  'webm': 'video/webm', 'mkv': 'video/x-matroska', 'm4v': 'video/x-m4v',
  'avi': 'video/x-msvideo',
  // Documento
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'txt': 'text/plain', 'csv': 'text/csv', 'zip': 'application/zip',
  'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
  // Audio
  'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'm4a': 'audio/mp4',
  'wav': 'audio/wav', 'aac': 'audio/aac',
};

/// El MIME de [ext], o [fallback] si no la conocemos.
///
/// El fallback lo decide quien llama porque depende de lo que esté mandando:
/// `image/jpeg` para una foto, `video/mp4` para un video,
/// `application/octet-stream` para un archivo cualquiera. Adivinar acá daría
/// el genérico siempre y WhatsApp trataría el video como documento.
String mimeForExtension(String ext, {required String fallback}) =>
    _mimeByExtension[ext.toLowerCase()] ?? fallback;
