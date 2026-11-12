import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'user_prefs_service.dart';

/// Resuelve el "accountId activo" para el usuario logueado.
///
/// Antes de esta capa, todo el código tomaba `accountId == firebase.uid`
/// directamente. Con multi-usuario, un sub-user (uid distinto) debe operar
/// sobre la cuenta del owner. Este servicio centraliza esa traducción
/// leyendo `users/{uid}` y exponiendo `activeAccountId`.
///
/// Migración transparente: si `users/{uid}` no existe (cuenta creada antes
/// de esta feature), el servicio lo crea on-demand con
/// `ownedAccountId = uid`. Esto preserva el comportamiento actual sin que
/// el usuario note nada. Es también como nace el doc de un usuario recién
/// registrado: **éste es el único lugar de la app que crea users/{uid}**
/// (ver [prepareSignup]).
///
/// Singleton + ChangeNotifier: el AuthWrapper escucha cambios para
/// re-renderizar si el contexto cambia (ej. tras login/logout).
class AccountContextService extends ChangeNotifier {
  static final AccountContextService _instance =
      AccountContextService._internal();
  factory AccountContextService() => _instance;
  AccountContextService._internal();

  String? _currentUid;
  String? _activeAccountId;
  String _role = 'owner';
  bool _mustChangePassword = false;
  bool _isReady = false;

  // Permisos por sesión del usuario actual (sub-user). El owner siempre tiene
  // acceso total. Default true para preservar el comportamiento legacy de
  // miembros sin campo `access`.
  bool _allSessionsAccess = true;
  Set<String> _grantedSessions = {};

  // Lo que el usuario escribió al registrarse, para el doc users/{uid}. Ver
  // [prepareSignup].
  PendingSignup? _pendingSignup;

  String? get currentUid => _currentUid;
  String? get activeAccountId => _activeAccountId;
  String get role => _role;
  bool get mustChangePassword => _mustChangePassword;
  bool get isOwner => _role == 'owner';
  bool get isReady => _isReady;

  /// ¿El usuario actual ve TODAS las sesiones de la cuenta? (owner o miembro
  /// con allSessions / legacy). Si es false, solo ve [grantedSessions].
  bool get hasAllSessionsAccess => isOwner || _allSessionsAccess;

  /// Teléfonos de sesión a los que el sub-user tiene acceso explícito.
  /// Solo relevante cuando [hasAllSessionsAccess] es false.
  Set<String> get grantedSessions => _grantedSessions;

  /// Las sesiones que este usuario puede LISTAR. Toda consulta a la colección
  /// `whatsapp_sessions` pasa por aquí.
  ///
  /// Las reglas no son filtros: Firestore rechaza ENTERA una consulta que no
  /// pueda probar para todos sus resultados, y un miembro restringido sólo
  /// puede listar con `allowedUids arrayContains uid`. El dispatcher consultaba
  /// `status == connected` a secas: al owner le pasaba y a cada miembro
  /// restringido le fallaba en silencio (pantalla de bienvenida en cada
  /// arranque). Lo fijan los tests de `rules-tests/`.
  ///
  /// Sin más filtros ni `orderBy` a propósito: combinarlos con `arrayContains`
  /// puede exigir un índice compuesto. Son pocas sesiones: quien llama filtra
  /// y ordena en memoria.
  Query<Map<String, dynamic>> visibleSessionsQuery(String accountId) {
    final sessions = FirebaseFirestore.instance
        .collection(accountsCollection)
        .doc(accountId)
        .collection('whatsapp_sessions');
    if (hasAllSessionsAccess) return sessions;
    final uid = _currentUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    return sessions.where('allowedUids', arrayContains: uid);
  }

  /// Llamar ANTES de `createUserWithEmailAndPassword`, con el nombre que
  /// escribió el usuario.
  ///
  /// Firebase avisa del usuario nuevo (authStateChanges → [initFor]) en el
  /// mismo instante en que lo crea, y [initFor] crea users/{uid} antes de que
  /// la pantalla de registro alcance a guardar nada. Por eso el doc lo crea
  /// SÓLO [initFor] y el nombre le llega por aquí. La pantalla de registro
  /// también lo creaba, y como las reglas sólo dejan crear ese doc (nunca
  /// editarlo), el segundo `set` era un update rechazado. Del 04-may al
  /// 12-nov-2026 eso dejó el botón "Registrarse" cargando para siempre.
  void prepareSignup({required String email, required String displayName}) {
    _pendingSignup = PendingSignup(email: email, displayName: displayName);
  }

  /// El registro falló: el nombre no puede quedar esperando a otro usuario.
  void cancelSignup() => _pendingSignup = null;

  /// Resuelve el contexto para un usuario Firebase recién logueado.
  /// Idempotente: si ya estamos resueltos para este uid, no hace nada.
  /// Retorna `true` si la resolución fue exitosa, `false` si falló (y la UI
  /// debería deslogear al usuario para evitar estados inconsistentes).
  Future<bool> initFor(User user) async {
    if (_currentUid == user.uid && _isReady) {
      debugPrint('[AccountContext] Ya resuelto para uid=${user.uid}');
      return true;
    }

    _currentUid = user.uid;
    _isReady = false;

    try {
      final docRef =
          FirebaseFirestore.instance.collection('users').doc(user.uid);
      // Las preferencias (vista de la lista de chats) se cargan en paralelo:
      // así la lista abre en la vista guardada sin pasar por Todos, y sin
      // sumar latencia. `load` nunca lanza.
      final results = await Future.wait([
        docRef.get(),
        UserPrefs().load(user.uid),
      ]);
      final snap = results.first as DocumentSnapshot<Map<String, dynamic>>;
      // Usuario recién registrado (o de antes de multi-usuario): no tiene
      // doc todavía y lo creamos como owner de su propia cuenta.
      final data = snap.data() ?? await _createOwnerDoc(docRef, user);

      // ownedAccountId es la fuente de verdad: para owners == uid;
      // para sub-users == uid del owner. Si el doc tiene memberOfAccounts
      // con varias cuentas (futuro), por ahora tomamos la primera o la
      // ownedAccountId. En Fase futura: selector de cuenta activa.
      _activeAccountId = data['ownedAccountId'] as String? ?? user.uid;
      _role = (data['role'] as String?) ?? 'owner';
      _mustChangePassword = (data['mustChangePassword'] as bool?) ?? false;

      // Permisos por sesión. El owner siempre tiene acceso total; para
      // sub-users leemos su doc de miembro. Default (sin campo access o si
      // falla la lectura) = acceso total, para no bloquear miembros legacy.
      _allSessionsAccess = true;
      _grantedSessions = {};
      if (_role != 'owner' && _activeAccountId != null) {
        await _loadMemberAccess(_activeAccountId!, user.uid);
      }

      _isReady = true;
      notifyListeners();
      debugPrint(
        '[AccountContext] ✅ Resuelto: uid=${user.uid}, accountId=$_activeAccountId, role=$_role',
      );

      // Refresh de custom claims en background. No bloqueamos la UI: si esto
      // falla, el siguiente acceso a Storage simplemente puede fallar y la
      // UI ya está navegable. Es eventual-consistent.
      _refreshClaimsInBackground(user);

      return true;
    } catch (e, st) {
      debugPrint('[AccountContext] ❌ Error resolviendo contexto: $e\n$st');
      _activeAccountId = null;
      _isReady = false;
      return false;
    }
  }

  /// Crea users/{uid} como owner de su propia cuenta y devuelve lo que quedó
  /// guardado.
  ///
  /// Es una transacción porque las reglas sólo dejan CREAR este doc: un `set`
  /// sobre uno que ya existe es un update y se rechaza. Si otro lo crea entre
  /// la lectura y la escritura (un segundo [initFor], otro dispositivo), la
  /// transacción se repite, ve el doc y lo usa en vez de fallar.
  Future<Map<String, dynamic>> _createOwnerDoc(
    DocumentReference<Map<String, dynamic>> docRef,
    User user,
  ) async {
    debugPrint('[AccountContext] users/${user.uid} no existe, se crea como owner');
    final displayName =
        signupDisplayNameFor(_pendingSignup, user.email) ?? user.displayName;
    final data = await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (snap.exists) return snap.data()!;
      final fresh = <String, dynamic>{
        'email': user.email,
        'displayName': displayName,
        'ownedAccountId': user.uid,
        'memberOfAccounts': [user.uid],
        'role': 'owner',
        'mustChangePassword': false,
        'createdAt': FieldValue.serverTimestamp(),
      };
      tx.set(docRef, fresh);
      return fresh;
    });
    _pendingSignup = null;
    return data;
  }

  /// Lee accounts/{accountId}/members/{uid}.access para resolver los permisos
  /// por sesión del sub-user. Si el doc no tiene `access` (miembro legacy) o
  /// la lectura falla, dejamos el default de acceso total ya seteado por el
  /// caller — fallamos abierto para no dejar a un miembro sin ver nada.
  Future<void> _loadMemberAccess(String accountId, String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(accountId)
          .collection('members')
          .doc(uid)
          .get();
      final access = snap.data()?['access'] as Map<String, dynamic>?;
      if (access == null) {
        // Miembro legacy sin permisos configurados → acceso total.
        return;
      }
      _allSessionsAccess = access['allSessions'] == true;
      final sessions = access['sessions'] as Map<String, dynamic>?;
      _grantedSessions = sessions?.keys.toSet() ?? {};
      debugPrint(
        '[AccountContext] Permisos: allSessions=$_allSessionsAccess, '
        'sesiones=$_grantedSessions',
      );
    } catch (e) {
      debugPrint('[AccountContext] No se pudo leer member access: $e');
      // Mantener default de acceso total.
    }
  }

  /// Llama al backend para que sincronice memberOfAccounts → custom claims
  /// (memberOf), y luego fuerza un refresh local del idToken para que las
  /// nuevas claims tomen efecto sin reloguear. Necesario porque las
  /// Storage Rules no pueden leer Firestore — usan claims del token.
  Future<void> _refreshClaimsInBackground(User user) async {
    try {
      final token = await user.getIdToken();
      final response = await http.post(
        Uri.parse('$backendUrl/auth/refresh-claims'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({}),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        // Forzar refresh para que el nuevo token traiga la claim memberOf.
        await user.getIdToken(true);
        debugPrint('[AccountContext] Custom claims refrescadas');
      } else {
        debugPrint(
          '[AccountContext] /auth/refresh-claims devolvió ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[AccountContext] No se pudo refrescar claims: $e');
    }
  }

  /// Limpiar todo el estado al hacer logout. Llamar ANTES de FirebaseAuth.signOut()
  /// para que cualquier listener que reaccione al signOut ya vea contexto limpio.
  Future<void> clear() async {
    debugPrint('[AccountContext] Limpiando contexto');
    UserPrefs().clear();
    _pendingSignup = null;
    _currentUid = null;
    _activeAccountId = null;
    _role = 'owner';
    _mustChangePassword = false;
    _isReady = false;
    _allSessionsAccess = true;
    _grantedSessions = {};
    notifyListeners();
  }
}

/// Nombre y correo que el usuario escribió en la pantalla de registro.
@immutable
class PendingSignup {
  final String email;
  final String displayName;
  const PendingSignup({required this.email, required this.displayName});
}

/// El nombre para el doc users/{uid} de un usuario recién creado, si viene de
/// la pantalla de registro.
///
/// Se compara el correo para que el nombre no le quede a otro usuario: un
/// registro que falla con "ya registrado", seguido de un login con una cuenta
/// vieja sin doc. Firebase guarda el correo en minúsculas, así que la
/// comparación ignora mayúsculas y espacios.
@visibleForTesting
String? signupDisplayNameFor(PendingSignup? pending, String? userEmail) {
  if (pending == null || userEmail == null) return null;
  final sameEmail = pending.email.trim().toLowerCase() ==
      userEmail.trim().toLowerCase();
  final name = pending.displayName.trim();
  return sameEmail && name.isNotEmpty ? name : null;
}
