import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/quick_response_attachment.dart';

const _img = 'https://firebasestorage.googleapis.com/v0/b/b/o/qr%2Fa.jpg?token=1';
const _vid = 'https://firebasestorage.googleapis.com/v0/b/b/o/qr%2Fa.mp4?token=2';
const _doc = 'https://firebasestorage.googleapis.com/v0/b/b/o/qr%2Fa.pdf?token=3';

void main() {
  group('leer el adjunto de un doc', () {
    test('sin adjunto es una respuesta de sólo texto', () {
      final a = attachmentFromDoc({'title': 'Saludo', 'text': 'Hola'});
      expect(a.kind, QrAttachKind.none);
      expect(a.isEmpty, isTrue);
      expect(a.url, isEmpty);
    });

    test('un doc recién creado por el editor viejo trae las claves vacías', () {
      final a = attachmentFromDoc({
        'imageUrl': '',
        'documentUrl': '',
        'documentName': '',
        'documentMimeType': '',
      });
      expect(a.kind, QrAttachKind.none);
    });

    test('imagen', () {
      final a = attachmentFromDoc({'imageUrl': _img});
      expect(a.kind, QrAttachKind.image);
      expect(a.url, _img);
      // Las imágenes nunca guardaron nombre ni MIME.
      expect(a.name, isEmpty);
      expect(a.mimeType, isEmpty);
    });

    test('video con nombre y mime', () {
      final a = attachmentFromDoc({
        'videoUrl': _vid,
        'videoName': 'demo.mp4',
        'videoMimeType': 'video/mp4',
      });
      expect(a.kind, QrAttachKind.video);
      expect(a.url, _vid);
      expect(a.name, 'demo.mp4');
      expect(a.mimeType, 'video/mp4');
    });

    test('documento', () {
      final a = attachmentFromDoc({
        'documentUrl': _doc,
        'documentName': 'catalogo.pdf',
        'documentMimeType': 'application/pdf',
      });
      expect(a.kind, QrAttachKind.document);
      expect(a.name, 'catalogo.pdf');
    });

    test('un campo que sólo tiene espacios no es un adjunto', () {
      final a = attachmentFromDoc({'imageUrl': '   ', 'videoUrl': _vid});
      expect(a.kind, QrAttachKind.video);
    });

    test('un valor que no es string se ignora en vez de reventar', () {
      final a = attachmentFromDoc({'imageUrl': 42, 'documentUrl': null});
      expect(a.kind, QrAttachKind.none);
    });
  });

  // La prioridad tiene que ser la misma de `performSendMessage` en el backend
  // (documentUrl > videoUrl > imageUrl). Si acá mostráramos otro, el operador
  // confirmaría un envío y le saldría algo distinto.
  group('docs legacy con dos adjuntos: gana el que el backend enviaría', () {
    test('imagen + documento → documento', () {
      expect(
        attachmentFromDoc({'imageUrl': _img, 'documentUrl': _doc}).kind,
        QrAttachKind.document,
      );
    });

    test('imagen + video → video', () {
      expect(
        attachmentFromDoc({'imageUrl': _img, 'videoUrl': _vid}).kind,
        QrAttachKind.video,
      );
    });

    test('video + documento → documento', () {
      expect(
        attachmentFromDoc({'videoUrl': _vid, 'documentUrl': _doc}).kind,
        QrAttachKind.document,
      );
    });

    test('los tres → documento', () {
      final a = attachmentFromDoc({
        'imageUrl': _img,
        'videoUrl': _vid,
        'documentUrl': _doc,
      });
      expect(a.kind, QrAttachKind.document);
    });
  });

  group('escribir el adjunto de vuelta', () {
    test('siempre escribe las siete claves, con los otros tipos en blanco', () {
      final f = attachmentFields(
        const QrAttachment(
          kind: QrAttachKind.video,
          url: _vid,
          name: 'demo.mp4',
          mimeType: 'video/mp4',
        ),
      );
      expect(f.keys, hasLength(7));
      expect(f['videoUrl'], _vid);
      expect(f['videoName'], 'demo.mp4');
      expect(f['videoMimeType'], 'video/mp4');
      // Lo que blanquea es lo que repara: sin esto el backend seguiría
      // prefiriendo el documento viejo.
      expect(f['imageUrl'], '');
      expect(f['documentUrl'], '');
      expect(f['documentName'], '');
      expect(f['documentMimeType'], '');
    });

    test('sin adjunto deja las siete en blanco', () {
      final f = attachmentFields(QrAttachment.none);
      expect(f.values.every((v) => v == ''), isTrue);
    });

    test('guardar un doc legacy con dos adjuntos lo deja con uno', () {
      const legacy = {'imageUrl': _img, 'documentUrl': _doc};
      final fixed = {...legacy, ...attachmentFields(attachmentFromDoc(legacy))};
      expect(fixed['documentUrl'], _doc);
      expect(fixed['imageUrl'], '');
      expect(attachmentFromDoc(fixed).kind, QrAttachKind.document);
    });

    test('lo que se escribe se vuelve a leer igual (ida y vuelta)', () {
      for (final a in [
        const QrAttachment(kind: QrAttachKind.image, url: _img),
        const QrAttachment(kind: QrAttachKind.video, url: _vid, name: 'd.mp4', mimeType: 'video/mp4'),
        const QrAttachment(kind: QrAttachKind.document, url: _doc, name: 'c.pdf', mimeType: 'application/pdf'),
        QrAttachment.none,
      ]) {
        final back = attachmentFromDoc(attachmentFields(a));
        expect(back.kind, a.kind);
        expect(back.url, a.url);
        expect(back.name, a.name);
        expect(back.mimeType, a.mimeType);
      }
    });
  });

  group('objetos de Storage que quedan huérfanos al guardar', () {
    test('reemplazar el adjunto marca el anterior para borrar', () {
      final orphans = orphanAttachmentUrls(
        {'imageUrl': _img},
        const QrAttachment(kind: QrAttachKind.video, url: _vid),
      );
      expect(orphans, [_img]);
    });

    test('un doc legacy con dos deja huérfano al perdedor', () {
      final orphans = orphanAttachmentUrls(
        {'imageUrl': _img, 'documentUrl': _doc},
        const QrAttachment(kind: QrAttachKind.document, url: _doc),
      );
      expect(orphans, [_img]);
    });

    test('quitar el adjunto deja huérfano al que había', () {
      expect(
        orphanAttachmentUrls({'videoUrl': _vid}, QrAttachment.none),
        [_vid],
      );
    });

    // Cambiar de archivo dentro del mismo tipo también cambia el path en
    // Storage (otra extensión), así que se compara por URL, no por kind.
    test('mismo tipo, otro archivo: el viejo se borra igual', () {
      const otro = 'https://firebasestorage.googleapis.com/v0/b/b/o/qr%2Fa.mov?t=9';
      expect(
        orphanAttachmentUrls(
          {'videoUrl': _vid},
          const QrAttachment(kind: QrAttachKind.video, url: otro),
        ),
        [_vid],
      );
    });

    test('guardar sin tocar el adjunto no borra nada', () {
      expect(
        orphanAttachmentUrls(
          {'documentUrl': _doc},
          const QrAttachment(kind: QrAttachKind.document, url: _doc),
        ),
        isEmpty,
      );
    });

    test('un doc sin adjuntos no deja huérfanos', () {
      expect(orphanAttachmentUrls({'text': 'hola'}, QrAttachment.none), isEmpty);
    });
  });
}
