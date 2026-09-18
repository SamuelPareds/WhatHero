// Lo único que comparten las dos ramas de `media_transfer`.
//
// Vive en su propio archivo y no duplicado en cada implementación porque si
// cada rama declarara su propia clase serían DOS tipos distintos, y el
// `on MediaTransferException catch` de la UI sólo cazaría el de una plataforma.

/// Fallo con un mensaje ya escrito para el operador: en español, sin stack y
/// diciéndole qué hacer. Cada plataforma traduce lo suyo —`GalException`, un
/// HTTP feo, un timeout— a uno de estos antes de que llegue a la pantalla.
class MediaTransferException implements Exception {
  final String message;
  const MediaTransferException(this.message);

  @override
  String toString() => message;
}
