/// Rastreador del chat que el operador tiene abierto en este momento.
///
/// Para qué: `ForegroundPushHost` vive arriba de `ChatsScreen` y no sabe qué
/// chat estás viendo. Si llega un push de "atención humana" del MISMO chat que
/// ya tienes abierto, la notificación sobra — ya estás leyendo esos mensajes.
/// Este singleton es un simple contenedor de valores (sin listeners, no dispara
/// rebuilds): `ChatsScreen` lo mantiene al día y el host lo consulta al vuelo.
///
/// Solo afecta el caso foreground (estás dentro de la app). Con la ventana
/// minimizada el sonido sale por el puente del Service Worker, que no pasa por
/// aquí — y así debe ser, porque minimizado sí quieres enterarte.
class ActiveChatTracker {
  static final ActiveChatTracker instance = ActiveChatTracker._();
  ActiveChatTracker._();

  // phone de la sesión de WhatsApp activa (= doc id en whatsapp_sessions).
  String? _sessionPhone;
  // chatId (contactPhone) del chat abierto, o null si estás en la lista.
  String? _chatId;

  /// `ChatsScreen` llama esto para reportar qué tiene abierto. `chatId` null
  /// significa "en la lista de chats, ninguno abierto".
  void update({required String? sessionPhone, required String? chatId}) {
    _sessionPhone = sessionPhone;
    _chatId = chatId;
  }

  /// Limpia el estado (al salir de la pantalla de chats).
  void clear() {
    _sessionPhone = null;
    _chatId = null;
  }

  /// ¿El operador está viendo justo este chat? Exige sesión + chat coincidentes.
  bool isViewing(String sessionPhone, String chatId) {
    if (_chatId == null || _sessionPhone == null) return false;
    return _sessionPhone == sessionPhone && _chatId == chatId;
  }
}
