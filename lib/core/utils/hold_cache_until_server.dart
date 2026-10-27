import 'dart:async';

/// Retiene los snapshots del caché local hasta que el servidor confirme uno.
///
/// Un listener nuevo de Firestore entrega primero lo que haya en el caché y
/// después lo del servidor. Ese primer snapshot no es "la colección, un poco
/// vieja": son sólo los docs que OTRO listener dejó cacheados. Con el badge de
/// Mis Cuentas escuchando los chats con pendientes, la lista de una sesión
/// aparecía medio segundo con puros pendientes. Ver CLAUDE.md, "📋 La lista de
/// chats sólo se pinta con lo que confirma el servidor".
///
/// [source] tiene que venir con `includeMetadataChanges: true`. Si el caché ya
/// estaba completo, el servidor sólo confirma metadata, y sin esa opción ese
/// aviso nunca llega: nos quedaríamos esperando todo el [grace].
///
/// Desde el primer snapshot que pasa, pasa todo, incluido uno `fromCache` por
/// una caída de red posterior. Si en [grace] el servidor no contestó (sin
/// conexión), suelta lo retenido: mejor lo guardado que un spinner eterno.
Stream<T> holdCacheUntilServer<T>(
  Stream<T> source, {
  required bool Function(T) isFromCache,
  Duration grace = const Duration(seconds: 2),
}) {
  late final StreamController<T> controller;
  StreamSubscription<T>? sub;
  Timer? timer;
  T? held;
  var hasHeld = false;
  var open = false;

  void openGate() {
    open = true;
    timer?.cancel();
    if (hasHeld) {
      hasHeld = false;
      controller.add(held as T);
      held = null;
    }
  }

  controller = StreamController<T>(
    onListen: () {
      timer = Timer(grace, openGate);
      sub = source.listen(
        (snap) {
          if (open || !isFromCache(snap)) {
            // Un snapshot del servidor deja viejo lo retenido: se descarta.
            hasHeld = false;
            held = null;
            open = true;
            timer?.cancel();
            controller.add(snap);
          } else {
            held = snap;
            hasHeld = true;
          }
        },
        onError: controller.addError,
        onDone: () {
          timer?.cancel();
          controller.close();
        },
      );
    },
    onCancel: () {
      timer?.cancel();
      return sub?.cancel();
    },
  );
  return controller.stream;
}
