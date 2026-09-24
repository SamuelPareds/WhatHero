/// Guarda de choque: "alguien le respondió a este cliente mientras yo escribía".
///
/// Es el caso que la presencia del equipo no alcanza a cubrir: dos personas
/// escriben a la vez, una envía primero y la otra, que ya tenía su respuesta
/// armada, pulsa Enter sin mirar arriba. El cliente recibe dos respuestas.
///
/// La guarda es sólo del cliente y no le cuesta nada al backend. Mira los
/// mensajes que llegan por el stream que `MessagesView` ya tiene suscrito.
///
/// **Se detecta por llegada, nunca por reloj.** "Más nuevo que cuando empecé a
/// escribir" compararía el timestamp de WhatsApp con el reloj del teléfono, y
/// hay teléfonos desfasados por minutos. En su lugar: un mensaje es nuevo si
/// aparece ARRIBA del primer id que ya conocíamos en el snapshot anterior.
/// Eso descarta también los dos falsos positivos obvios:
///   - paginar hacia atrás agrega ids ABAJO, no arriba;
///   - borrar el mensaje más reciente "asciende" a uno viejo que ya conocíamos.
library;

/// De dónde vino la respuesta que se cruzó con la mía.
enum ReplyCollisionSource {
  /// Un compañero desde WhatHero (otro `senderUid`).
  teammate,

  /// Mi mismo usuario desde otro dispositivo o pestaña. Pasa en equipos que
  /// comparten login: para WhatHero es la misma persona, pero no lo es.
  sameUser,

  /// El asistente de IA.
  ai,

  /// Alguien desde la app de WhatsApp (teléfono o WhatsApp Web).
  whatsapp,

  /// Mensaje saliente sin campos de remitente (docs viejos).
  unknown,
}

/// Una respuesta ajena que llegó mientras el composer tenía texto.
class ReplyCollision {
  final String messageId;
  final ReplyCollisionSource source;

  /// Nombre de pila del compañero. Sólo en [ReplyCollisionSource.teammate].
  final String? name;

  /// Lo que se envió: texto, o el rótulo de media ("📷 Imagen").
  final String preview;

  const ReplyCollision({
    required this.messageId,
    required this.source,
    required this.preview,
    this.name,
  });

  /// Frase corta para la franja y el título del diálogo.
  String get headline => switch (source) {
        ReplyCollisionSource.teammate =>
          '${name ?? 'Un compañero'} acaba de responder',
        ReplyCollisionSource.sameUser =>
          'Respondieron desde otro dispositivo con tu usuario',
        ReplyCollisionSource.ai => 'La IA acaba de responder',
        ReplyCollisionSource.whatsapp => 'Respondieron desde WhatsApp',
        ReplyCollisionSource.unknown => 'Alguien acaba de responder',
      };
}

/// Lo mínimo de un doc de mensaje que la guarda necesita mirar.
class CollisionCandidate {
  final String id;
  final bool fromMe;
  final String? senderType;
  final String? senderName;
  final String? senderUid;
  final String preview;

  const CollisionCandidate({
    required this.id,
    required this.fromMe,
    required this.preview,
    this.senderType,
    this.senderName,
    this.senderUid,
  });
}

class ReplyCollisionDetector {
  ReplyCollisionDetector({DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  /// Tras abrir el chat, el primer snapshot puede venir del cache local y el
  /// segundo, del servidor, con lo que llegó mientras la app estaba cerrada.
  /// Ese segundo snapshot no son "respuestas nuevas": es la conversación
  /// poniéndose al día. Durante esta ventana sólo aprendemos la baseline.
  /// No basta con mirar `isFromCache`: si el cache ya estaba al día, Firestore
  /// no manda el snapshot del servidor (sólo cambió metadata) y la baseline
  /// nunca se fijaría.
  static const settle = Duration(seconds: 3);

  /// Un mensaje con MI `senderUid` es mío si esta vista envió algo hace
  /// menos que esto. Con un envío más viejo, es mi usuario en otro
  /// dispositivo. No sirve buscar el id en `PendingMessagesService`: los
  /// adjuntos no llevan `tempId` y la burbuja optimista se purga en cuanto
  /// llega el doc.
  static const ownSendWindow = Duration(minutes: 2);

  final DateTime Function() _now;
  Set<String>? _known;
  DateTime? _firstSnapshotAt;
  DateTime? _lastLocalSendAt;

  /// Llamar en CADA camino de envío de la vista (texto, respuesta rápida).
  void noteLocalSend() => _lastLocalSendAt = _now();

  /// Procesa un snapshot del stream de mensajes (orden más nuevo primero).
  ///
  /// [read] sólo se invoca para los ids nuevos, así que el costo de
  /// deserializar docs no escala con el largo de la conversación.
  /// Devuelve null si no hubo choque en ESTE snapshot. Eso no apaga un choque
  /// anterior: lo limpia quien lo muestra, al vaciarse el composer.
  ReplyCollision? onSnapshot({
    required List<String> idsNewestFirst,
    required bool fromCache,
    required CollisionCandidate Function(String id) read,
    required bool composing,
    required String? myUid,
  }) {
    final now = _now();
    _firstSnapshotAt ??= now;
    final known = _known;
    // La baseline se actualiza SIEMPRE, aunque no evaluemos: lo que se vio
    // estando ocupado en otra cosa no puede volverse "nuevo" más tarde.
    _known = idsNewestFirst.toSet();

    if (known == null) return null;
    if (fromCache) return null;
    if (now.difference(_firstSnapshotAt!) < settle) return null;
    if (!composing) return null;

    final fresh = <String>[];
    var overlaps = false;
    for (final id in idsNewestFirst) {
      if (known.contains(id)) {
        overlaps = true;
        break;
      }
      fresh.add(id);
    }
    // La ventana cambió entera (una ráfaga más larga que el límite de la
    // página): no sabemos qué es nuevo y qué no. Preferimos callar a avisar
    // de algo que quizás no pasó.
    if (!overlaps) return null;

    for (final id in fresh) {
      final collision = _classify(read(id), myUid, now);
      if (collision != null) return collision;
    }
    return null;
  }

  ReplyCollision? _classify(CollisionCandidate c, String? myUid, DateTime now) {
    // Escribió el cliente: es justo lo que esperábamos, no un choque.
    if (!c.fromMe) return null;
    // Reglas por palabra clave y recordatorios: salen solos y el operador
    // ya cuenta con ellos. Avisar de cada uno sería ruido.
    if (c.senderType == 'bot') return null;

    ReplyCollision build(ReplyCollisionSource source, {String? name}) =>
        ReplyCollision(
          messageId: c.id,
          source: source,
          name: name,
          preview: c.preview,
        );

    final uid = c.senderUid;
    if (uid != null && myUid != null && uid == myUid) {
      final sent = _lastLocalSendAt;
      final mine = sent != null && now.difference(sent) <= ownSendWindow;
      return mine ? null : build(ReplyCollisionSource.sameUser);
    }
    if (c.senderType == 'ai') return build(ReplyCollisionSource.ai);
    if (uid != null) {
      return build(ReplyCollisionSource.teammate, name: c.senderName);
    }
    if (c.senderName == 'WhatsApp') return build(ReplyCollisionSource.whatsapp);
    return build(ReplyCollisionSource.unknown);
  }
}
