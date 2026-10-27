import 'package:flutter/material.dart';

import 'package:crm_whatsapp/core.dart';

/// Aviso con "Deshacer" para una acción que ya se aplicó (Listo / Pendiente en
/// la lista de chats: en Pendientes y Listos el chat se va al instante, y un
/// swipe sin querer no puede ser un viaje sin retorno).
///
/// - `persist: false`: Flutter deja fijo todo SnackBar con acción
///   (`persist ?? action != null`). Sin esto el aviso nunca se iría y
///   [onCommit] no correría jamás.
/// - `hideCurrentSnackBar` antes: cinco acciones seguidas serían 20 s de avisos
///   en fila. Sólo la última se deshace; la anterior se confirma al cerrarse.
/// - [onCommit] corre al cerrarse por cualquier motivo que no sea "Deshacer",
///   aunque la pantalla que lo abrió ya no exista: no puede tocar su `context`.
///
/// Tests en `test/undo_snack_bar_test.dart`.
void showUndoSnackBar(
  ScaffoldMessengerState messenger,
  String text, {
  required VoidCallback onUndo,
  VoidCallback? onCommit,
  Duration duration = const Duration(seconds: 4),
}) {
  messenger.hideCurrentSnackBar();
  messenger
      .showSnackBar(SnackBar(
        content: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        duration: duration,
        persist: false,
        action: SnackBarAction(
          label: 'Deshacer',
          textColor: primaryAqua,
          onPressed: onUndo,
        ),
      ))
      .closed
      .then((reason) {
    if (reason != SnackBarClosedReason.action) onCommit?.call();
  });
}
