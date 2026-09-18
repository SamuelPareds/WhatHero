// Fachada para llevarse una foto o un video fuera de la app, con selección
// por plataforma.
//
// Web → `media_transfer_web.dart`: descarga (fetch → Blob → <a download>) y
//   copia la imagen al portapapeles real, transcodificando a PNG.
// Móvil/otros → `media_transfer_io.dart`: guarda en el carrete con `gal`.
//   Ahí NO hay copiar-imagen: el único paquete serio que lo hace
//   (`super_clipboard`) mete la cadena de compilación de Rust en cada release
//   de iOS y Android, y eso es demasiado peaje para un gesto que en el
//   teléfono casi nadie usa. `canCopyImage` es false y la UI ni lo muestra.
//
// El import condicional resuelve `dart:io` + `path_provider` + `gal` SOLO en
// builds nativos, y `package:web` SOLO en web: ninguna rama ve las APIs de la
// otra. Por eso la elección NO puede ser un `if (kIsWeb)` — con eso el
// compilador tendría que tragarse las dos.
//
// Contrato que ambas ramas exponen (si una agrega un símbolo y la otra no,
// falla el build de esa plataforma, que es exactamente el fallo que queremos):
//   const String saveMediaLabel;      // texto del botón
//   const String saveMediaDoneLabel;  // texto del toast de éxito
//   const bool   canCopyImage;        // ¿hay portapapeles de imágenes?
//   Future<void> saveMedia({url, fileName, isVideo});
//   Future<void> copyImageToClipboard(String url);
//
// Se llama `_io` y no `_stub` a propósito: a diferencia de
// `notification_sound`, acá la rama por defecto no es un no-op, hace el
// trabajo real.
export 'media_transfer_io.dart'
    if (dart.library.js_interop) 'media_transfer_web.dart';
