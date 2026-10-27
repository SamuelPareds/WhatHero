import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Preferencias de la app de cada usuario, sincronizadas entre sus
/// dispositivos. Hoy sólo la vista con la que abre la lista de chats
/// (Todos / Pendientes / Listos, ver `chat_filter.dart`).
///
/// Viven en `users/{uid}/prefs/ui` y NO en `users/{uid}`: ese doc respalda los
/// custom claims (`memberOfAccounts`) y sólo lo escribe el backend. Estas
/// preferencias son UI pura, no dan acceso a nada, y por eso las escribe el
/// propio usuario. La raíz `users` es compartida entre dev y prod, así que la
/// vista también: es inocuo.
///
/// Se carga en `AccountContextService.initFor`, antes de que exista la UI: la
/// lista abre directo en la vista guardada, sin pasar un instante por Todos.
class UserPrefs {
  static final UserPrefs _instance = UserPrefs._internal();
  factory UserPrefs() => _instance;
  UserPrefs._internal();

  /// `chat_inbox_view` guardado, o null si nunca eligió (o no se pudo leer).
  /// Las pantallas lo escuchan para seguir un cambio hecho en otra pantalla o
  /// en otro dispositivo.
  final ValueNotifier<String?> chatInboxView = ValueNotifier(null);

  String? _uid;
  StreamSubscription? _sub;

  DocumentReference<Map<String, dynamic>> _doc(String uid) => FirebaseFirestore
      .instance
      .collection('users')
      .doc(uid)
      .collection('prefs')
      .doc('ui');

  /// Escucha las preferencias de [uid] y completa con el primer valor o a los
  /// 2 s, lo que pase antes. Nunca lanza: sin red o sin reglas desplegadas la
  /// app abre en Todos y lo deja en el log.
  Future<void> load(String uid) async {
    if (_uid == uid && _sub != null) return;
    clear();
    _uid = uid;
    final first = Completer<void>();
    _sub = _doc(uid).snapshots().listen(
      (snap) {
        chatInboxView.value = snap.data()?['chat_inbox_view'] as String?;
        if (!first.isCompleted) first.complete();
      },
      onError: (Object e) {
        debugPrint('[UserPrefs] No se pudieron leer las preferencias: $e');
        if (!first.isCompleted) first.complete();
      },
    );
    await first.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  /// Guarda la vista elegida. El notifier cambia al instante; si la escritura
  /// falla, la vista sigue en memoria hasta que cierre la app.
  void setChatInboxView(String value) {
    if (chatInboxView.value == value) return;
    chatInboxView.value = value;
    final uid = _uid;
    if (uid == null) return;
    _doc(uid).set({
      'chat_inbox_view': value,
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)).catchError((Object e) {
      debugPrint('[UserPrefs] No se pudo guardar la vista: $e');
    });
  }

  /// Logout o cambio de usuario: soltar el listener (sobre otro uid daría
  /// permission-denied) y que el siguiente no herede la vista del anterior.
  void clear() {
    _sub?.cancel();
    _sub = null;
    _uid = null;
    chatInboxView.value = null;
  }
}
