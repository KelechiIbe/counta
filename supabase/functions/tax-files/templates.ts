// The official templates, served with the Counta web app (public/tax-templates) so the function bundle stays small. Each file
// is pinned by its SHA-256: a changed or swapped file is refused, never filled.
export const TEMPLATES = {
  cit: { file: 'rev360-cit-v2.xlsx', sha256: '88bb12435f8316e38dc9b26d299b5dcf4734192716c51c1b09b84628b734a2d3', title: 'Rev360 companies income tax template (V2)' },
  nrs_wht: { file: 'nrs-wht-v1.xlsx', sha256: '1748d864246d3240c952cc7cfb55fd9f1376cffdb957dccc0ddd03084030eea7', title: 'NRS withholding tax schedule' },
  sirs_wht: { file: 'sirs-wht-v1.xlsx', sha256: '9108debfdc6f805dbf79beee1d54192cf5af6356d182ae81e831302386e4c9e3', title: 'State withholding tax schedule' },
} as const;
export type TemplateName = keyof typeof TEMPLATES;

const cache = new Map<TemplateName, Uint8Array>();

export async function sha256Hex(bytes: Uint8Array) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(bytes)));
  return Array.from(d).map((x) => x.toString(16).padStart(2, '0')).join('');
}

export function templatesBase() {
  const explicit = Deno.env.get('TAX_TEMPLATES_URL');
  if (explicit) return explicit.replace(/\/$/, '');
  return (Deno.env.get('APP_URL') || 'https://counta-taxstreem.netlify.app').replace(/\/$/, '') + '/tax-templates';
}

export async function template(name: TemplateName): Promise<Uint8Array> {
  const hit = cache.get(name);
  if (hit) return hit.slice();
  const t = TEMPLATES[name];
  const r = await fetch(`${templatesBase()}/${t.file}`);
  if (!r.ok) throw new Error(`Could not fetch the ${t.title} (${r.status}).`);
  const bytes = new Uint8Array(await r.arrayBuffer());
  const got = await sha256Hex(bytes);
  if (got !== t.sha256) throw new Error(`The ${t.title} on the server is not the approved version (sha256 ${got.slice(0, 12)}…).`);
  cache.set(name, bytes);
  return bytes.slice();
}
