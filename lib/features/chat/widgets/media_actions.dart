// Los botones de "llevarme esta foto/video" y lo que hacen.
//
// Un solo archivo para los cuatro puntos donde aparecen (los dos visores
// fullscreen del chat, el menú de long-press y la galería de medios), pero con
// dos formas distintas a propósito: los AppBar necesitan un botón con estado
// propio ("bajando…") y las hojas se cierran al tocar, así que ahí no hay
// dónde poner un spinner y el feedback sale por SnackBar.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/media_transfer.dart';
import 'package:crm_whatsapp/core/utils/media_file_name.dart';

// La etiqueta cambia por plataforma ('Descargar' vs 'Guardar en Fotos') y las
// pantallas que arman su propio botón la necesitan. Se reexporta para que el
// resto de la app tenga un solo import: este archivo.
export 'package:crm_whatsapp/core/services/media_transfer.dart'
    show saveMediaLabel, saveMediaDoneLabel, canCopyImage;

/// ¿Se puede llevar este medio? Sólo foto o video que ya estén en Storage.
///
/// La condición **espeja la que la burbuja usa para habilitar el tap al visor**
/// (`hasFullRes` en `message_bubble.dart`): si hay URL, hay archivo del otro
/// lado. Exigir `mediaStatus == 'ready'` estricto dejaría fotos que se abren a
/// pantalla completa pero sin botón para guardarlas —y el operador no tendría
/// cómo entender por qué—, además de romperse con los docs viejos que no
/// tienen el campo.
bool canTransferMedia({
  String? mediaType,
  String? mediaUrl,
  String? mediaStatus,
}) =>
    (mediaType == 'image' || mediaType == 'video') &&
    mediaUrl != null &&
    mediaUrl.isNotEmpty &&
    mediaStatus != 'failed';

// ---------------------------------------------------------------------------
// Acciones.
//
// Todas reciben el `ScaffoldMessengerState` YA resuelto en vez del
// `BuildContext`: bajar un video son 16 MB y para cuando termina, la hoja se
// cerró y el visor puede estar cerrado también. Capturado antes del await, el
// toast sale igual sobre la pantalla que haya quedado, sin `mounted` que
// chequear y sin pelearse con `use_build_context_synchronously`.
//
// Ninguna lanza: todo resultado se comunica por SnackBar.
// ---------------------------------------------------------------------------

/// Baja el archivo y lo entrega: a Descargas en web, al carrete en móvil.
Future<void> runSaveMedia(
  ScaffoldMessengerState messenger, {
  required String url,
  required bool isVideo,
  String? fileNameHint,
  DateTime? timestamp,
}) async {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(_busySnack('$saveMediaLabel…'));
  try {
    await saveMedia(
      url: url,
      isVideo: isVideo,
      fileName: mediaFileName(
        url: url,
        isVideo: isVideo,
        hint: fileNameHint,
        timestamp: timestamp,
      ),
    );
    _toast(messenger, saveMediaDoneLabel);
  } on MediaTransferException catch (e) {
    _toast(messenger, e.message);
  } catch (_) {
    _toast(messenger, 'No se pudo guardar el archivo');
  }
}

/// Pone la imagen en el portapapeles. Si el navegador lo niega —permiso,
/// pestaña sin foco, o sin soporte de `ClipboardItem`— cae en copiar el
/// enlace: un solo fallback cubre los tres casos sin tener que distinguirlos,
/// y el operador siempre se lleva algo.
Future<void> runCopyImage(
  ScaffoldMessengerState messenger, {
  required String url,
}) async {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(_busySnack('Copiando imagen…'));
  try {
    await copyImageToClipboard(url);
    _toast(messenger, 'Imagen copiada');
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: url));
    _toast(messenger, 'No se pudo copiar la imagen; copiamos el enlace');
  }
}

/// Copia la URL del archivo como texto. Ojo: ese enlace lleva el token de
/// Storage y funciona para siempre para quien lo reciba — que es justo lo que
/// el operador quiere al mandar una evidencia, pero conviene saberlo.
Future<void> runCopyLink(
  ScaffoldMessengerState messenger, {
  required String url,
}) async {
  await Clipboard.setData(ClipboardData(text: url));
  _toast(messenger, 'Enlace copiado');
}

// ---------------------------------------------------------------------------
// Presentación
// ---------------------------------------------------------------------------

/// Los botones del AppBar de un visor fullscreen.
///
/// Es StatefulWidget sólo para aguantar el "estoy bajando", y por eso los
/// visores siguen siendo Stateless: ese estado es del botón, no del visor.
class MediaActionButtons extends StatefulWidget {
  final String url;
  final bool isVideo;
  final String? fileNameHint;
  final DateTime? timestamp;

  const MediaActionButtons({
    super.key,
    required this.url,
    required this.isVideo,
    this.fileNameHint,
    this.timestamp,
  });

  @override
  State<MediaActionButtons> createState() => _MediaActionButtonsState();
}

class _MediaActionButtonsState extends State<MediaActionButtons> {
  bool _busy = false;

  Future<void> _run(
      Future<void> Function(ScaffoldMessengerState) action) async {
    if (_busy) return; // taps repetidos mientras baja: se ignoran
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action(messenger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canCopyImage && !widget.isVideo)
          IconButton(
            tooltip: 'Copiar imagen',
            icon: const Icon(Icons.content_copy),
            onPressed: () => _run((m) => runCopyImage(m, url: widget.url)),
          ),
        IconButton(
          tooltip: saveMediaLabel,
          icon: const Icon(Icons.save_alt),
          onPressed: () => _run((m) => runSaveMedia(
                m,
                url: widget.url,
                isVideo: widget.isVideo,
                fileNameHint: widget.fileNameHint,
                timestamp: widget.timestamp,
              )),
        ),
      ],
    );
  }
}

/// Los `ListTile` de "llevarse el medio" para un bottom sheet.
///
/// [sheetContext] es el del builder y se usa SÓLO para cerrar la hoja;
/// [messenger] tiene que venir de afuera porque el toast sale cuando la hoja
/// ya no existe.
List<Widget> mediaActionTiles({
  required BuildContext sheetContext,
  required ScaffoldMessengerState messenger,
  required String url,
  required bool isVideo,
  String? fileNameHint,
  DateTime? timestamp,
}) {
  Widget tile(IconData icon, String label, VoidCallback onTap) => ListTile(
        leading: Icon(icon, size: 20, color: primaryAqua),
        title: Text(label, style: const TextStyle(color: white)),
        onTap: () {
          Navigator.pop(sheetContext);
          onTap();
        },
      );

  return [
    if (canCopyImage && !isVideo)
      tile(Icons.content_copy, 'Copiar imagen',
          () => runCopyImage(messenger, url: url)),
    tile(
      Icons.save_alt,
      saveMediaLabel,
      () => runSaveMedia(
        messenger,
        url: url,
        isVideo: isVideo,
        fileNameHint: fileNameHint,
        timestamp: timestamp,
      ),
    ),
    tile(Icons.link, 'Copiar enlace', () => runCopyLink(messenger, url: url)),
  ];
}

SnackBar _busySnack(String msg) => SnackBar(
      content: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(primaryAqua),
            ),
          ),
          const SizedBox(width: 12),
          Text(msg),
        ],
      ),
      backgroundColor: surfaceDark,
      // Largo a propósito: lo cierra el resultado, no el reloj. Un video de
      // 16 MB con mala señal puede tardar más que cualquier duración fija.
      duration: const Duration(minutes: 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 20, left: 20, right: 20),
    );

void _toast(ScaffoldMessengerState messenger, String msg) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: surfaceDark,
      duration: const Duration(milliseconds: 1800),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(bottom: 20, left: 20, right: 20),
    ));
}
