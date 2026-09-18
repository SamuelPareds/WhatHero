// Llevarse una foto o un video en Android/iOS: al carrete del teléfono.
//
// No hay copiar-imagen acá (`canCopyImage = false`): ver el comentario de
// `media_transfer.dart`. La UI esconde el botón, así que `copyImageToClipboard`
// existe sólo para que las dos ramas expongan la misma API.

import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/media_file_name.dart';
import 'media_transfer_types.dart';

export 'media_transfer_types.dart';

const String saveMediaLabel = 'Guardar en Fotos';
const String saveMediaDoneLabel = 'Guardado en Fotos';
const bool canCopyImage = false;

/// Baja el archivo y lo deja en el carrete, de donde el operador lo adjunta
/// donde quiera.
Future<void> saveMedia({
  required String url,
  required MediaFileName fileName,
  required bool isVideo,
}) async {
  // El permiso se pide ANTES de bajar los bytes: si el operador dice que no,
  // no le gastamos 16 MB de datos para nada.
  if (!await Gal.hasAccess()) {
    if (!await Gal.requestAccess()) {
      throw const MediaTransferException(
          'Necesitás dar permiso de Fotos para guardar el archivo');
    }
  }

  final bytes = await _download(url);

  try {
    if (!isVideo) {
      // `name` va SIN extensión a propósito: gal la deriva de los bytes.
      await Gal.putImageBytes(bytes, name: fileName.base);
      return;
    }
    // No existe `putVideoBytes`: gal necesita un archivo con extensión real.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${fileName.full}');
    try {
      await file.writeAsBytes(bytes, flush: true);
      await Gal.putVideo(file.path);
    } finally {
      // El temporal se borra pase lo que pase. Si el borrado falla da igual
      // (el SO purga ese directorio) y no queremos que tape el error real.
      try {
        await file.delete();
      } catch (_) {}
    }
  } on GalException catch (e) {
    throw MediaTransferException(switch (e.type) {
      GalExceptionType.accessDenied =>
        'Permiso de Fotos denegado. Activalo en Ajustes.',
      GalExceptionType.notEnoughSpace => 'No queda espacio en el dispositivo',
      GalExceptionType.notSupportedFormat =>
        'El formato del archivo no se puede guardar en Fotos',
      _ => 'No se pudo guardar en Fotos',
    });
  }
}

/// Nunca se llama: la UI lo esconde con `canCopyImage == false`. Existe para
/// que la fachada tenga la misma superficie en las dos plataformas.
Future<void> copyImageToClipboard(String url) =>
    throw UnsupportedError('Copiar imagen al portapapeles es sólo para web');

/// Trae los bytes del archivo. La URL de Storage lleva su token de descarga,
/// así que no necesita los headers de auth del backend.
Future<Uint8List> _download(String url) async {
  try {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw MediaTransferException(
          'El archivo ya no está disponible (${res.statusCode})');
    }
    return res.bodyBytes;
  } on MediaTransferException {
    rethrow;
  } catch (_) {
    // SocketException, ClientException, TimeoutException: para el operador son
    // todas la misma cosa, y el mensaje tiene que decirle qué hacer.
    throw const MediaTransferException('Se cortó la descarga. Probá de nuevo.');
  }
}
