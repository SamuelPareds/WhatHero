// Helper function to extract and clean phone number from Baileys JID
// Handles format: "5215561642726:50@s.whatsapp.net" -> "5215561642726"
export function extractPhoneNumber(jid: string | undefined): string {
  if (!jid) return '';

  // Remove WhatsApp domain suffixes
  let cleaned = jid.replace('@s.whatsapp.net', '').replace('@g.us', '');

  // Remove device suffix (e.g., ":50")
  const phoneOnly = cleaned.split(':')[0];

  return phoneOnly || '';
}
