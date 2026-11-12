import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:crm_whatsapp/core.dart';
import 'package:crm_whatsapp/core/services/account_context_service.dart';
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

    final email = emailController.text.trim();
    setState(() => isLoading = true);
    // Esta pantalla NO escribe en Firestore. Al crear el usuario, AuthWrapper
    // (debajo de esta ruta) arranca AccountContextService.initFor, que crea
    // users/{uid}; aquí sólo le pasamos el nombre. Cuando las dos creaban el
    // doc, la segunda escritura era rechazada y el botón quedaba cargando.
    AccountContextService().prepareSignup(email: email, displayName: fullName);
    final UserCredential credential;
    try {
      credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: passwordController.text.trim(),
      );
    } catch (e) {
      AccountContextService().cancelSignup();
      debugPrint('[Register] No se pudo crear la cuenta: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_signupErrorMessage(e))),
      );
      setState(() => isLoading = false);
      return;
    }

    // La cuenta ya existe: de aquí en adelante nada puede dejar al usuario
    // en esta pantalla. El nombre también va al perfil de Auth, que es de
    // donde lo toma initFor si el primer intento de crear users/{uid} falla
    // (sin red) y el doc se crea en el siguiente login.
    try {
      await credential.user?.updateDisplayName(fullName);
    } catch (e) {
      debugPrint('[Register] No se pudo guardar el nombre en Auth: $e');
    }

    // Pequeño delay para que AuthWrapper ya muestre la app debajo al cerrar.
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pop();
  }

  String _signupErrorMessage(Object error) {
    if (error is! FirebaseAuthException) return 'Error al registrarse. Intenta de nuevo.';
    switch (error.code) {
      case 'weak-password':
        return 'Contraseña muy débil';
      case 'email-already-in-use':
        return 'Este email ya está registrado';
      case 'invalid-email':
        return 'Email inválido';
      case 'network-request-failed':
        return 'Sin conexión. Revisa tu internet e intenta de nuevo.';
      case 'too-many-requests':
        return 'Demasiados intentos. Espera unos minutos.';
      default:
        return 'Error al registrarse (${error.code})';
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
