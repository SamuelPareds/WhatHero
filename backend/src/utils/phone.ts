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

// Attempt to resolve a LID to a phone number using Baileys v7.0+ LIDMappingStore
// The store reads from persisted auth state files and can fetch from WhatsApp if needed
export async function resolveLIDViaSock(lid: string, sock: any): Promise<string | null> {
  try {
    const lidNum = lid.includes('@') ? lid.split('@')[0] : lid;

    // 1. Check in-memory cache first
    const cached = lidToPhoneMap.get(lidNum);
    if (cached) return cached;

    // 2. Use Baileys v7.0 LIDMappingStore (reads from auth_info files + WhatsApp USYNC)
    if (sock?.signalRepository?.lidMapping) {
      const pnJid = await sock.signalRepository.lidMapping.getPNForLID(`${lidNum}@lid`);
      if (pnJid) {
        const pnNum = extractPhoneNumber(pnJid);
        storeLIDMapping(lidNum, pnNum);
        console.log(`[LID-Resolve] Resolved via lidMapping store: ${lidNum} → ${pnNum}`);
        return pnNum;
      }
    }

    console.warn(`[LID-Resolve] Could not resolve LID ${lidNum}`);
    return null;
  } catch (error) {
    console.error(`[LID-Resolve] Error resolving LID:`, error);
    return null;
  }
}
