import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Etiqueta de color asignable a chats. Vive en
/// `whatsapp_sessions/{phone}/labels/{labelId}` para que cada negocio (sesión)
/// gestione su propio catálogo, alineado con el modelo multi-tenant.
class ChatLabel {
  final String id;
  final String name;
  final String colorHex;
  final int order;

  const ChatLabel({
    required this.id,
    required this.name,
    required this.colorHex,
    required this.order,
  });

  Color get color {
    final hex = colorHex.replaceFirst('#', '');
    return Color(int.parse('FF$hex', radix: 16));
  }

  factory ChatLabel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return ChatLabel(
      id: doc.id,
      name: (data['name'] as String?) ?? '',
      colorHex: (data['color'] as String?) ?? '#06B6D4',
      order: (data['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'color': colorHex,
        'order': order,
      };
}

/// Paleta curada de 10 colores con buen contraste sobre fondo dark (#0F172A).
/// Mantenerla cerrada evita inconsistencias visuales y casos de baja
/// legibilidad. Si el usuario pide más opciones en el futuro, se amplía
/// aquí — no se abre un picker libre.
const List<ChatLabelColor> kLabelPalette = [
  ChatLabelColor(name: 'Rojo', hex: '#EF4444'),
  ChatLabelColor(name: 'Naranja', hex: '#F97316'),
  ChatLabelColor(name: 'Ámbar', hex: '#F59E0B'),
  ChatLabelColor(name: 'Verde', hex: '#10B981'),
  ChatLabelColor(name: 'Aqua', hex: '#06B6D4'),
  ChatLabelColor(name: 'Azul', hex: '#3B82F6'),
  ChatLabelColor(name: 'Púrpura', hex: '#8B5CF6'),
  ChatLabelColor(name: 'Rosa', hex: '#EC4899'),
  ChatLabelColor(name: 'Gris', hex: '#6B7280'),
  ChatLabelColor(name: 'Marrón', hex: '#92400E'),
];

class ChatLabelColor {
  final String name;
  final String hex;

  const ChatLabelColor({required this.name, required this.hex});

  Color get color {
    final h = hex.replaceFirst('#', '');
    return Color(int.parse('FF$h', radix: 16));
  }
}
