// ============================================
// Descifrado de ediciones "secretEncryptedMessage" (MESSAGE_EDIT).
//
// Los clientes nuevos de WhatsApp ya NO envían la edición de un mensaje como
// protocolMessage en texto plano: la sellan end-to-end con el `messageSecret`
// del mensaje ORIGINAL (mismo mecanismo criptográfico que los votos de
// encuestas). Baileys 7.0.0-rc.x aún no lo descifra — solo trae el proto —
// así que portamos la receta del PR WhiskeySockets/Baileys#2690, verificada
// contra whatsmeow (msgsecret.go, la implementación de referencia):
//
//   key0   = HMAC-SHA256(key=ceros(32), data=messageSecret)         (extract)
//   decKey = HMAC-SHA256(key=key0,
//              data=origMsgId | authorJid | editorJid | "Message Edit" | 0x01)
//   plaintext = AES-256-GCM(encPayload, decKey, encIv, AAD vacía)
//
// Particularidades vs encuestas/eventos:
//   - las ediciones se sellan SIN additional data (AAD vacía);
//   - el autor pudo derivar la llave con su identidad LID o PN → probamos
//     ambas; GCM autentica, así que la llave equivocada lanza y pasamos a la
//     siguiente candidata.
//
// Cuando Baileys mergee el soporte nativo, este archivo se borra y las
// ediciones llegarán ya en texto plano por el mismo flujo protocolMessage.
// ============================================
import { aesDecryptGCM, hmacSign, jidNormalizedUser, proto } from '@whiskeysockets/baileys';

export const SECRET_ENC_TYPE_MESSAGE_EDIT =
  proto.Message.SecretEncryptedMessage.SecretEncType.MESSAGE_EDIT; // = 2

// Descifra asumiendo UNA identidad de autor. Lanza si la llave no autentica.
function decryptWithAuthor(secretEnc: any, origMsgId: string, authorJid: string, msgEncKey: Buffer): any {
  const sign = Buffer.concat([
    Buffer.from(origMsgId),
    Buffer.from(authorJid),
    Buffer.from(authorJid), // editor == autor: solo el autor puede editar su mensaje
    Buffer.from('Message Edit'),
    Buffer.from([1]),
  ]);
  const key0 = hmacSign(msgEncKey, Buffer.alloc(32));
  const decKey = hmacSign(sign, key0);
  const plaintext = aesDecryptGCM(secretEnc.encPayload, decKey, secretEnc.encIv, Buffer.alloc(0));
  return proto.Message.decode(plaintext);
}

// Descifra la edición y la devuelve en el formato "plano" protocolMessage
// type 14 que saveMessageToFirestore ya sabe mergear. null si ninguna
// identidad candidata logró autenticar (o faltan campos en el sobre).
export function decryptSecretMessageEdit(params: {
  secretEnc: any; // message.message.secretEncryptedMessage
  messageKey: any; // message.key del sobre (para derivar candidatos LID/PN)
  msgEncKeyB64: string; // messageSecret del mensaje original (base64, Firestore)
  meId?: string; // sock.user.id  — para ediciones fromMe (operador desde su teléfono)
  meLid?: string; // sock.user.lid
}): any | null {
  const { secretEnc, messageKey, msgEncKeyB64, meId, meLid } = params;
  const targetKey = secretEnc.targetMessageKey;
  const origMsgId = targetKey?.id;
  if (!origMsgId || !secretEnc.encPayload || !secretEnc.encIv) return null;

  const msgEncKey = Buffer.from(msgEncKeyB64, 'base64');

  // Identidades candidatas del autor (LID y PN), igual que whatsmeow.
  const rawCandidates: (string | null | undefined)[] = messageKey.fromMe
    ? [meId, meLid]
    : [
        messageKey.participant || messageKey.remoteJid,
        messageKey.participantAlt || messageKey.remoteJidAlt,
      ];
  rawCandidates.push(targetKey.remoteJid);

  const candidates = rawCandidates
    .filter((jid): jid is string => !!jid)
    .map((jid) => jidNormalizedUser(jid))
    .filter((jid, i, arr) => !!jid && arr.indexOf(jid) === i);

  for (const authorJid of candidates) {
    try {
      const decoded: any = decryptWithAuthor(secretEnc, origMsgId, authorJid, msgEncKey);
      // El payload descifrado puede venir ya como protocolMessage o ser el
      // contenido editado directo; normalizamos al formato plano type 14.
      if (decoded.protocolMessage) return decoded;
      return {
        protocolMessage: {
          key: targetKey,
          type: proto.Message.ProtocolMessage.Type.MESSAGE_EDIT,
          editedMessage: decoded,
        },
      };
    } catch {
      // Llave equivocada (LID vs PN): GCM no autentica → probar la siguiente.
    }
  }
  return null;
}
