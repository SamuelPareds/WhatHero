import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/features/auth/login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  bool isLoading = false;
  bool showPassword = false;
  bool showConfirm = false;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final fullName = nameController.text.trim();
    if (fullName.isEmpty ||
        emailController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty ||
        confirmController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Completa todos los campos')),
      );
      return;
    }

    if (passwordController.text != confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Las contraseñas no coinciden')),
      );
      return;
    }

    if (passwordController.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La contraseña debe tener al menos 6 caracteres')),
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      // Crear documento de cuenta en Firestore inmediatamente
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // Sincronizar el displayName en el perfil de Firebase Auth para que
        // todo el ecosistema (incluyendo el helper resolveHumanSender en el
        // backend) tenga acceso al nombre desde el primer login.
        await user.updateDisplayName(fullName);

        await FirebaseFirestore.instance
          .collection(accountsCollection)
          .doc(user.uid)
          .set({
            'email': user.email,
            'createdAt': Timestamp.now(),
            'accountId': user.uid,
          }, SetOptions(merge: true));

        // Crear doc users/{uid} como owner de su propia cuenta. Este doc
        // es la fuente de verdad para AccountContextService y para las
        // Firestore Rules (campo memberOfAccounts). Vive fuera del switch
        // de entorno (accounts vs accounts_dev) porque la membresía es
        // global al usuario Firebase, no dependiente del entorno.
        await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({
            'email': user.email,
            'displayName': fullName,
            'ownedAccountId': user.uid,
            'memberOfAccounts': [user.uid],
            'role': 'owner',
            'mustChangePassword': false,
            'createdAt': FieldValue.serverTimestamp(),
          });
      }

      // Pequeño delay para asegurar que Firebase haya actualizado el estado
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 500));
      // Pop esta pantalla - AuthWrapper mostrará AccountsScreen automáticamente
      if (mounted) Navigator.of(context).pop();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_authErrorMessage(e.code))),
      );
      setState(() => isLoading = false);
    }
  }

  String _authErrorMessage(String code) {
    switch (code) {
      case 'weak-password':
        return 'Contraseña muy débil';
      case 'email-already-in-use':
        return 'Este email ya está registrado';
      case 'invalid-email':
        return 'Email inválido';
      default:
        return 'Error al registrarse';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        title: const Text('Crear Cuenta'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: nameController,
              enabled: !isLoading,
              textCapitalization: TextCapitalization.words,
              keyboardType: TextInputType.name,
              decoration: InputDecoration(
                hintText: 'Nombre completo',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailController,
              enabled: !isLoading,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              enabled: !isLoading,
              obscureText: !showPassword,
              decoration: InputDecoration(
                hintText: 'Contraseña',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    showPassword ? Icons.visibility : Icons.visibility_off,
                    color: lightText,
                  ),
                  onPressed: !isLoading
                      ? () => setState(() => showPassword = !showPassword)
                      : null,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: confirmController,
              enabled: !isLoading,
              obscureText: !showConfirm,
              decoration: InputDecoration(
                hintText: 'Confirmar contraseña',
                hintStyle: const TextStyle(color: lightText),
                filled: true,
                fillColor: surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    showConfirm ? Icons.visibility : Icons.visibility_off,
                    color: lightText,
                  ),
                  onPressed: !isLoading
                      ? () => setState(() => showConfirm = !showConfirm)
                      : null,
                ),
              ),
              style: const TextStyle(color: white),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAqua,
                  foregroundColor: darkBg,
                  disabledBackgroundColor: Colors.grey,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: isLoading ? null : _register,
                child: isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(darkBg),
                        ),
                      )
                    : const Text(
                        'Registrarse',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LoginScreen(),
                        ),
                      );
                    },
              child: const Text(
                '¿Ya tienes cuenta? Inicia sesión',
                style: TextStyle(color: primaryAqua),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
