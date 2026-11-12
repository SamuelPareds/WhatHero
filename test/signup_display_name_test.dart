import 'package:crm_whatsapp/core/services/account_context_service.dart';
import 'package:flutter_test/flutter_test.dart';

// El nombre que el usuario escribe al registrarse llega a users/{uid} por
// AccountContextService, el único que crea ese doc. Si esta regla falla, no
// hay error: el owner nace "Sin nombre" y sus mensajes salen como "Usuario".
void main() {
  const pending = PendingSignup(email: 'ana@ejemplo.com', displayName: 'Ana López');

  test('el usuario que se acaba de registrar recibe su nombre', () {
    expect(signupDisplayNameFor(pending, 'ana@ejemplo.com'), 'Ana López');
  });

  test('Firebase guarda el correo en minúsculas: la comparación las ignora', () {
    const typed = PendingSignup(email: ' Ana@Ejemplo.COM ', displayName: 'Ana López');
    expect(signupDisplayNameFor(typed, 'ana@ejemplo.com'), 'Ana López');
  });

  test('el nombre no le queda a otro usuario', () {
    // Registro fallido ("ya registrado") seguido del login con otra cuenta.
    expect(signupDisplayNameFor(pending, 'beto@ejemplo.com'), isNull);
  });

  test('sin registro pendiente, o sin correo, no hay nombre', () {
    expect(signupDisplayNameFor(null, 'ana@ejemplo.com'), isNull);
    expect(signupDisplayNameFor(pending, null), isNull);
  });

  test('un nombre en blanco no pisa el del perfil de Auth', () {
    const blank = PendingSignup(email: 'ana@ejemplo.com', displayName: '   ');
    expect(signupDisplayNameFor(blank, 'ana@ejemplo.com'), isNull);
  });

  test('se guarda sin espacios sobrantes', () {
    const padded = PendingSignup(email: 'ana@ejemplo.com', displayName: '  Ana López ');
    expect(signupDisplayNameFor(padded, 'ana@ejemplo.com'), 'Ana López');
  });
}
