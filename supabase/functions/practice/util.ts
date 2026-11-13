// Small helpers of the practice function: who is calling (IP address and browser), fingerprints, link tokens, a drawn
// signature, and which of a business's stored files leave in an export.

// An error whose message is for the person (shown as it is); anything else is answered "Something went wrong".
export class UserError extends Error {}

// The caller's IP address: the first address in x-forwarded-for (the client, as Supabase's gateway records it), else
// x-real-ip, else nothing.
export function clientIp(req: Request): string {
  const first = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim();
  return (first || (req.headers.get('x-real-ip') || '').trim()).slice(0, 64);
}

// The caller's browser as it names itself, at most 300 characters (what the records keep).
export function userAgent(req: Request): string {
  return (req.headers.get('user-agent') || '').slice(0, 300);
}

// The SHA-256 of some bytes, as 64 lower-case hex characters.
export async function sha256Hex(b: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new Uint8Array(b));
  return Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, '0')).join('');
}

// A link token as the database mints them (private.token_new): the prefix, an underscore and 48 lower-case hex characters.
// Checked before anything else is done with it.
export function tokenOk(t: string, prefix: 'es' | 'dc'): boolean {
  return typeof t === 'string' && new RegExp(`^${prefix}_[0-9a-f]{48}$`).test(t);
}

const PNG_PREFIX = 'data:image/png;base64,';
const PNG_MAX = 300 * 1024;
const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];

// A drawn signature sent as a PNG data URL: its bytes when it is a PNG of at most 300 KB, else null.
export function pngFromDataUrl(s: string): Uint8Array | null {
  if (typeof s !== 'string' || !s.startsWith(PNG_PREFIX)) return null;
  const b64 = s.slice(PNG_PREFIX.length);
  if (b64.length > Math.ceil(PNG_MAX / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return null;
  let bin: string;
  try { bin = atob(b64); } catch { return null; }
  if (bin.length < PNG_SIGNATURE.length || bin.length > PNG_MAX) return null;
  const bytes = Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
  return PNG_SIGNATURE.every((v, i) => bytes[i] === v) ? bytes : null;
}

// Whether a stored file (a documents-bucket path) leaves in the business's export: anything under the business's own
// folder, <org id>/..., except its kyc/ folder (CAC documents and NIN slips stay with the owner and never leave).
export function exportable(path: string, orgId: string): boolean {
  if (typeof path !== 'string' || typeof orgId !== 'string' || !orgId) return false;
  const parts = path.split('/');
  if (parts.length < 2 || parts[0] !== orgId) return false;
  if (parts.some((p) => p === '' || p === '.' || p === '..')) return false;
  return parts[1].toLowerCase() !== 'kyc';
}
