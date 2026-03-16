import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:crm_whatsapp/core.dart';
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
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: primaryAqua),
            ),
          );
        }

        if (snapshot.hasData) {
          return onUserAuthenticated(snapshot.data!.uid);
        }

        return const WelcomeScreen();
      },
    );
  }
}
