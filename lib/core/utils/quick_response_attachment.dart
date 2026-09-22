/// El adjunto de una respuesta rápida: uno solo, nunca dos.
///
/// Una respuesta rápida puede llevar imagen, video o documento — pero **sólo
/// uno**. Es la misma regla que WhatsApp (un media por mensaje) y la misma que
/// ya aplica el backend, que resuelve el payload con una cadena de prioridad
/// (`documentUrl > videoUrl > imageUrl`) y manda el primero que encuentra.
///
/// El problema es que el doc de Firestore **no puede expresar esa regla**: sus
/// campos son planos y paralelos (`imageUrl`, `documentUrl`, `videoUrl`…), así
/// que nada impide que dos estén llenos a la vez. Y de hecho hay respuestas
/// guardadas así, de cuando el editor dejaba elegir imagen y documento por
/// separado: el operador veía las dos, y al enviar salía sólo el documento.
/// La imagen se perdía en silencio.
///
/// Acá vive la traducción entre las dos formas, en las dos direcciones:
/// [attachmentFromDoc] colapsa los campos planos a un adjunto único aplicando
/// la misma prioridad del backend, y [attachmentFields] vuelve a expandirlos
/// **blanqueando los que no están activos**. Esa segunda mitad es la que repara
/// los docs viejos: basta con guardar una vez para que dejen de tener dos.
///
/// Es lógica silenciosa cuando falla —si se equivoca de prioridad, el operador
/// pierde un adjunto sin ver ningún error— así que las reglas viven en
/// `test/quick_response_attachment_test.dart`.
library;

/// Qué tipo de adjunto lleva la respuesta rápida.
enum QrAttachKind { none, image, video, document }

/// El adjunto ya resuelto, listo para pintar o para enviar.
class QrAttachment {
  /// Tipo activo. [QrAttachKind.none] cuando la respuesta es sólo texto.
  final QrAttachKind kind;

  /// URL pública (Storage, o externa en respuestas legacy). Vacía si [kind] es
  /// `none`.
  final String url;

  /// Nombre original del archivo. Vacío para imágenes: nunca se guardó uno, y
  /// al enviarlas WhatsApp tampoco lo usa.
  final String name;

  /// MIME guardado al subir. Vacío en docs viejos, donde el backend cae a su
  /// propio default por tipo.
  final String mimeType;

  const QrAttachment({
    required this.kind,
    this.url = '',
    this.name = '',
    this.mimeType = '',
  });

  /// La respuesta no tiene adjunto: es sólo texto.
  static const QrAttachment none = QrAttachment(kind: QrAttachKind.none);

  bool get isEmpty => kind == QrAttachKind.none;
  bool get isNotEmpty => !isEmpty;
}

/// Lee un campo de texto del doc tolerando `null` y espacios sueltos.
///
/// Un campo blanqueado por [attachmentFields] queda como `''`, y uno de un doc
/// viejo puede directamente no existir: los dos significan "no hay".
String _str(Map<String, dynamic> qr, String key) {
  final v = qr[key];
  return v is String ? v.trim() : '';
}

/// El adjunto único de una respuesta rápida, según sus campos planos.
///
/// Prioridad **documento > video > imagen**, idéntica a la cadena de
/// `performSendMessage` en el backend. Tiene que ser la misma: si acá
/// mostráramos la imagen de un doc que también tiene documento, el operador
/// confirmaría un envío y le saldría otra cosa.
QrAttachment attachmentFromDoc(Map<String, dynamic> qr) {
  final documentUrl = _str(qr, 'documentUrl');
  if (documentUrl.isNotEmpty) {
    return QrAttachment(
      kind: QrAttachKind.document,
      url: documentUrl,
      name: _str(qr, 'documentName'),
      mimeType: _str(qr, 'documentMimeType'),
    );
  }

  final videoUrl = _str(qr, 'videoUrl');
  if (videoUrl.isNotEmpty) {
    return QrAttachment(
      kind: QrAttachKind.video,
      url: videoUrl,
      name: _str(qr, 'videoName'),
      mimeType: _str(qr, 'videoMimeType'),
    );
  }

  final imageUrl = _str(qr, 'imageUrl');
  if (imageUrl.isNotEmpty) {
    // Las imágenes no guardan MIME: el picker las re-encoda a JPEG siempre, y
    // la rama de imagen del backend ni siquiera le pasa el mimetype a Baileys.
    return QrAttachment(kind: QrAttachKind.image, url: imageUrl);
  }

  return QrAttachment.none;
}

/// Los campos de Firestore que describen [a], **incluidos los vacíos**.
///
/// Devuelve siempre las siete claves. Escribir los blancos es el punto: es lo
/// que borra el adjunto anterior al cambiar de tipo y lo que normaliza de una
/// vez los docs legacy que tenían dos. Un `update` parcial dejaría el viejo
/// vivo y el backend seguiría prefiriéndolo.
Map<String, dynamic> attachmentFields(QrAttachment a) => {
      'imageUrl': a.kind == QrAttachKind.image ? a.url : '',
      'videoUrl': a.kind == QrAttachKind.video ? a.url : '',
      'videoName': a.kind == QrAttachKind.video ? a.name : '',
      'videoMimeType': a.kind == QrAttachKind.video ? a.mimeType : '',
      'documentUrl': a.kind == QrAttachKind.document ? a.url : '',
      'documentName': a.kind == QrAttachKind.document ? a.name : '',
      'documentMimeType': a.kind == QrAttachKind.document ? a.mimeType : '',
    };

/// Las URLs de adjunto presentes en [qr] que **no** son la de [keep].
///
/// Son los objetos de Storage que hay que borrar al guardar: el adjunto que se
/// reemplazó, y los sobrantes de un doc legacy con dos. Se comparan por URL y
/// no por tipo porque un mismo tipo puede cambiar de archivo (y de extensión,
/// o sea de path) sin cambiar de `kind`.
///
/// **El llamador tiene que descartar las que resuelvan al mismo objeto que
/// acaba de subir.** Sobrescribir un path en Storage regenera el token de
/// descarga, así que la URL nueva es distinta de la vieja aunque el archivo
/// sea el mismo — y borrar por la vieja borraría lo recién subido.
List<String> orphanAttachmentUrls(Map<String, dynamic> qr, QrAttachment keep) {
  final previous = [
    _str(qr, 'imageUrl'),
    _str(qr, 'videoUrl'),
    _str(qr, 'documentUrl'),
  ];
  return previous
      .where((url) => url.isNotEmpty && url != keep.url)
      .toSet()
      .toList();
}
