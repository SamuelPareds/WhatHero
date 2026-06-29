import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

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
/// el usuario note nada.
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
      final snap = await docRef.get();

      if (!snap.exists) {
        // Migración transparente: usuario existente sin doc users/{uid}.
        // Lo creamos como owner de su propia cuenta (== comportamiento previo).
        debugPrint(
          '[AccountContext] users/${user.uid} no existe, bootstrap como owner',
        );
        await docRef.set({
          'email': user.email,
          'displayName': user.displayName,
          'ownedAccountId': user.uid,
          'memberOfAccounts': [user.uid],
          'role': 'owner',
          'mustChangePassword': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
        _activeAccountId = user.uid;
        _role = 'owner';
        _mustChangePassword = false;
      } else {
        final data = snap.data()!;
        // ownedAccountId es la fuente de verdad: para owners == uid;
        // para sub-users == uid del owner. Si el doc tiene memberOfAccounts
        // con varias cuentas (futuro), por ahora tomamos la primera o la
        // ownedAccountId. En Fase futura: selector de cuenta activa.
        _activeAccountId =
            data['ownedAccountId'] as String? ?? user.uid;
        _role = (data['role'] as String?) ?? 'owner';
        _mustChangePassword =
            (data['mustChangePassword'] as bool?) ?? false;
      }

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
