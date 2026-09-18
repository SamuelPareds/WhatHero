import 'package:flutter_test/flutter_test.dart';
import 'package:crm_whatsapp/core/utils/media_file_name.dart';

const _bucket =
    'https://firebasestorage.googleapis.com/v0/b/whathero-73605.firebasestorage.app/o/';

/// Arma una URL como la que escribe `mediaService.ts`: el path del objeto va
/// percent-encodeado entero y el token viaja en el query.
String storageUrl(String path) =>
    '$_bucket${Uri.encodeComponent(path)}'
    '?alt=media&token=8f1c3d2e-0000-4a1b-9c7d-1234567890ab';

void main() {
  group('la extensión sale de la URL, no del tipo de medio', () {
    test('foto y video de un chat', () {
      expect(
          storageExtension(storageUrl('media/5215512345678/ABC123.jpg')), 'jpg');
      expect(
          storageExtension(storageUrl('media/5215512345678/ABC123.mp4')), 'mp4');
    });

    test('el path viene percent-encodeado y hay que decodificarlo', () {
      // Las barras del path viajan como %2F. Si no se decodifica, el "último
      // segmento" es el path entero y cualquier punto anterior gana.
      expect(storageExtension(storageUrl('media/a.b/ABC123.jpg')), 'jpg');
    });

    test('el token del query no se confunde con extensión', () {
      expect(storageExtension(storageUrl('media/x/ABC123.jpeg')), 'jpeg');
    });

    test('mayúsculas se normalizan', () {
      expect(storageExtension(storageUrl('media/x/FOTO.JPG')), 'jpg');
    });

    test('sin extensión reconocible devuelve null, no inventa', () {
      expect(storageExtension(storageUrl('media/x/ABC123')), isNull);
      // Carpeta con punto: el `2` no es una extensión.
      expect(storageExtension(storageUrl('media/v1.2/ABC123')), isNull);
      expect(storageExtension(storageUrl('media/x/ABC.')), isNull);
      expect(storageExtension(storageUrl('media/x/.oculto')), isNull);
      // Cinco caracteres es el techo: más que eso no es una extensión.
      expect(storageExtension(storageUrl('media/x/ABC.demasiadolargo')), isNull);
      expect(storageExtension(''), isNull);
    });

    test('una URL que no es de Storage también funciona', () {
      expect(storageExtension('https://cdn.example.com/a/b/foto.png'), 'png');
    });
  });

  group('el nombre del archivo', () {
    final ts = DateTime(2026, 9, 17, 14, 32);

    test('sin hint usa la fecha del mensaje y ordena bien', () {
      final n = mediaFileName(
          url: storageUrl('media/x/A.jpg'), isVideo: false, timestamp: ts);
      expect(n.base, 'WhatHero_20260917_1432');
      expect(n.full, 'WhatHero_20260917_1432.jpg');
    });

    test('el hint manda para el nombre, la URL para la extensión', () {
      final n = mediaFileName(
        url: storageUrl('media/x/A.jpg'),
        isVideo: false,
        hint: 'comprobante.pdf', // extensión mentirosa del hint: se descarta
        timestamp: ts,
      );
      expect(n.base, 'comprobante');
      expect(n.ext, 'jpg');
    });

    test('el hint se limpia de lo que rompe un filesystem', () {
      final n = mediaFileName(
        url: storageUrl('media/x/A.jpg'),
        isVideo: false,
        hint: 'pago 5/9 "final": <2>|x',
        timestamp: ts,
      );
      expect(n.base.contains(RegExp(r'[\\/:*?"<>|]')), isFalse);
      expect(n.base, isNotEmpty);
    });

    test('un hint vacío o sólo basura cae en la fecha', () {
      expect(
        mediaFileName(
                url: storageUrl('media/x/A.jpg'),
                isVideo: false,
                hint: '   ',
                timestamp: ts)
            .base,
        'WhatHero_20260917_1432',
      );
    });

    test('un hint larguísimo se recorta', () {
      final n = mediaFileName(
          url: storageUrl('media/x/A.jpg'),
          isVideo: false,
          hint: 'a' * 300,
          timestamp: ts);
      expect(n.base.length, 60);
    });

    test('sin extensión en la URL, el fallback lo da el tipo', () {
      expect(
          mediaFileName(
                  url: storageUrl('media/x/A'), isVideo: true, timestamp: ts)
              .ext,
          'mp4');
      expect(
          mediaFileName(
                  url: storageUrl('media/x/A'), isVideo: false, timestamp: ts)
              .ext,
          'jpg');
    });

    test('un GIF de WhatsApp se guarda como .mp4, que es lo que realmente es',
        () {
      expect(
          mediaFileName(
                  url: storageUrl('media/x/A.mp4'), isVideo: true, timestamp: ts)
              .ext,
          'mp4');
    });

    test('la base nunca arrastra la extensión: Gal.putImageBytes la rechaza',
        () {
      // Sólo se corta el último punto: los internos son parte del nombre.
      expect(
          mediaFileName(
                  url: storageUrl('media/x/A.jpg'),
                  isVideo: false,
                  hint: 'foto.final.jpg',
                  timestamp: ts)
              .base,
          'foto.final');
    });
  });
}
