// Global LID-to-Phone mapping cache
// Baileys may receive messages with @lid format instead of phone numbers
// This map stores discovered mappings from the "lid-mapping.update" event
const lidToPhoneMap = new Map<string, string>();

// Helper function to extract and clean phone number from Baileys JID
// Handles formats:
//   - "5215561642726:50@s.whatsapp.net" -> "5215561642726"
//   - "115767152529428@lid" -> resolved via mapping or stored as-is
export function extractPhoneNumber(jid: string | undefined): string {
  if (!jid) return '';

  // Check if it's an @lid format that we've mapped
  if (jid.includes('@lid')) {
    const lidOnly = jid.split('@')[0];
    const mappedPhone = lidToPhoneMap.get(lidOnly);
    if (mappedPhone) {
      console.log(`[LID-Mapping] Resolved LID ${lidOnly} to ${mappedPhone}`);
      return mappedPhone;
    }
    // If no mapping exists, return the LID as fallback
    console.warn(`[LID-Mapping] No mapping found for LID ${lidOnly}, using as-is`);
    return lidOnly;
  }

  // Remove WhatsApp domain suffixes (standard format)
  let cleaned = jid.replace('@s.whatsapp.net', '').replace('@g.us', '');

  // Remove device suffix (e.g., ":50")
  const phoneOnly = cleaned.split(':')[0];

  return phoneOnly || '';
}

// Store a discovered LID-to-Phone mapping
// Called when Baileys emits lid-mapping.update event
export function storeLIDMapping(lid: string, phoneNumber: string): void {
  const normalizedLid = lid.includes('@') ? lid.split('@')[0] : lid;
  const normalizedPhone = phoneNumber.includes('@') ? phoneNumber.split('@')[0] : phoneNumber;
  lidToPhoneMap.set(normalizedLid, normalizedPhone);
  console.log(`[LID-Mapping] Stored mapping: ${normalizedLid} -> ${normalizedPhone}`);
}

// Get a stored mapping (for debugging or external use)
export function getLIDMapping(lid: string): string | undefined {
  const normalizedLid = lid.includes('@') ? lid.split('@')[0] : lid;
  return lidToPhoneMap.get(normalizedLid);
}

// Clear all mappings (useful for testing)
export function clearLIDMappings(): void {
  lidToPhoneMap.clear();
  console.log('[LID-Mapping] Cleared all LID mappings');
}

// Attempt to resolve a LID by searching through Baileys contacts
// This is a fallback when lid-mapping.update hasn't been received yet
export async function resolveLIDFromContacts(lid: string, sock: any): Promise<string | null> {
  try {
    const normalizedLid = lid.includes('@') ? lid.split('@')[0] : lid;

    // Check if we already have a mapping
    const cached = lidToPhoneMap.get(normalizedLid);
    if (cached) return cached;

    // Try to get all contacts from Baileys
    if (!sock?.contacts) {
      console.warn(`[LID-Resolve] Socket doesn't have contacts property`);
      return null;
    }

    // Search through contacts to find matching LID
    // This attempts to match by contact properties
    for (const [jid, contact] of Object.entries(sock.contacts)) {
      const contactJid = typeof jid === 'string' ? jid : '';
      if (contactJid.includes('@lid') && contactJid.includes(normalizedLid)) {
        const phoneNumber = extractPhoneNumber(contactJid);
        if (phoneNumber && phoneNumber !== normalizedLid) {
          storeLIDMapping(normalizedLid, phoneNumber);
          console.log(`[LID-Resolve] Resolved ${normalizedLid} to ${phoneNumber} via contacts`);
          return phoneNumber;
        }
      }
    }

    console.warn(`[LID-Resolve] Could not resolve LID ${normalizedLid} from contacts`);
    return null;
  } catch (error) {
    console.error(`[LID-Resolve] Error resolving LID:`, error);
    return null;
  }
}
