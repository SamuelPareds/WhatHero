// Llevarse una foto o un video desde el navegador. Chrome/Edge son el objetivo.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../utils/media_file_name.dart';
import 'media_transfer_types.dart';

export 'media_transfer_types.dart';

const String saveMediaLabel = 'Descargar';
const String saveMediaDoneLabel = 'Descargado';
const bool canCopyImage = true;

/// Baja el archivo a la carpeta de Descargas con el nombre que le dimos.
///
/// Por qué el fetch y no un `<a href="<url>" download>` directo: el atributo
/// `download` **se ignora en URLs cross-origin**, y Storage es otro origen que
/// el Hosting. Sin bajar los bytes nosotros, el navegador abriría la foto en
/// una pestaña en vez de descargarla. El endpoint de Storage responde
/// `access-control-allow-origin: *`, así que el fetch no exige tocar el CORS
/// del bucket.
Future<void> saveMedia({
  required String url,
  required MediaFileName fileName,
  required bool isVideo,
}) async {
  final blob = await _fetchBlob(url);
  final objectUrl = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = objectUrl
    ..download = fileName.full
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // La descarga ya arrancó, pero soltamos el blob un segundo después en vez de
  // en el mismo turno: revocar de inmediato funciona en Chrome pero no está
  // garantizado. Fire-and-forget a propósito, no hay nada que esperar.
  Future.delayed(const Duration(seconds: 1), () {
    web.URL.revokeObjectURL(objectUrl);
  });
}

/// Pone la imagen —el bitmap, no el enlace— en el portapapeles del sistema,
/// para pegarla con Ctrl+V en un correo o un documento.
///
/// Se hace `await` de los bytes y recién después `write`. La alternativa es
/// pasarle al `ClipboardItem` una `Promise<Blob>` sin resolver, que es lo
/// único que acepta Safari (ahí el `await` consume el gesto del usuario y el
/// write se rechaza). No la usamos porque con la promesa cualquier fallo
/// —descarga cortada, transcodificación— vuelve como un rechazo genérico del
/// write y perdemos el diagnóstico. Si algún día entra Safari de escritorio al
/// alcance, el cambio son dos líneas: `_asPng(...)` sin await, `.toJS`.
Future<void> copyImageToClipboard(String url) async {
  final png = await _asPng(await _fetchBlob(url));
  final item = JSObject()..setProperty('image/png'.toJS, png);
  await web.window.navigator.clipboard
      .write(<web.ClipboardItem>[web.ClipboardItem(item)].toJS)
      .toDart;
}

Future<web.Blob> _fetchBlob(String url) async {
  final web.Response res;
  try {
    res = await web.window.fetch(url.toJS).toDart;
  } catch (_) {
    throw const MediaTransferException('Se cortó la descarga. Probá de nuevo.');
  }
  if (!res.ok) {
    throw MediaTransferException(
        'El archivo ya no está disponible (${res.status})');
  }
  return await res.blob().toDart;
}

/// Chrome sólo admite `image/png` en el portapapeles y las fotos de WhatsApp
/// son JPEG, así que hay que recodificar. El Blob salió de un fetch nuestro,
/// o sea que el canvas no queda *tainted* y `convertToBlob` puede leerlo.
Future<web.Blob> _asPng(web.Blob src) async {
  if (src.type == 'image/png') return src;
  final bitmap = await web.window.createImageBitmap(src).toDart;
  final canvas = web.OffscreenCanvas(bitmap.width, bitmap.height);
  final ctx = canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D;
  ctx.drawImage(bitmap, 0, 0);
  bitmap.close(); // libera la memoria del bitmap ya dibujado
  return await canvas
      .convertToBlob(web.ImageEncodeOptions(type: 'image/png'))
      .toDart;
}
