import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'welcome_screen.dart';

class AuthWrapper extends StatelessWidget {
  final Widget Function(String accountId) onUserAuthenticated;

  const AuthWrapper({required this.onUserAuthenticated, super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScaffold();
        }

        final user = snapshot.data;
        if (user == null) {
          return const WelcomeScreen();
        }

        // Antes de pasar accountId río abajo, resolvemos el contexto
        // (uid → ownedAccountId vía users/{uid}). Esto soporta sub-users
        // y migra transparente a usuarios existentes.
        return _AccountContextResolver(
          user: user,
          onResolved: onUserAuthenticated,
        );
      },
    );
  }
}

/// Pantalla puente que resuelve `AccountContextService` para el usuario actual
/// antes de delegar a `onResolved(accountId)`. Si la resolución falla
/// (Firestore caído, reglas mal configuradas), desloguea para evitar quedar
/// atrapado en una pantalla de carga.
class _AccountContextResolver extends StatefulWidget {
  final User user;
  final Widget Function(String accountId) onResolved;

  const _AccountContextResolver({
    required this.user,
    required this.onResolved,
  });

  @override
  State<_AccountContextResolver> createState() =>
      _AccountContextResolverState();
}

class _AccountContextResolverState extends State<_AccountContextResolver> {
  late Future<bool> _resolveFuture;

  @override
  void initState() {
    super.initState();
    _resolveFuture = AccountContextService().initFor(widget.user);
  }

  @override
  void didUpdateWidget(covariant _AccountContextResolver oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si Firebase emite un nuevo User (ej. tras refresh de claims), re-resolver.
    if (oldWidget.user.uid != widget.user.uid) {
      _resolveFuture = AccountContextService().initFor(widget.user);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _resolveFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingScaffold();
        }

        final ok = snapshot.data ?? false;
        final accountId = AccountContextService().activeAccountId;

        if (!ok || accountId == null) {
          // Falla: desloguear para no quedar pegado. El próximo authStateChanges
          // emitirá null y AuthWrapper mostrará WelcomeScreen.
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await AccountContextService().clear();
            await FirebaseAuth.instance.signOut();
          });
          return const _LoadingScaffold();
        }

        return widget.onResolved(accountId);
      },
    );
  }
}

class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(color: primaryAqua),
      ),
    );
  }
}
