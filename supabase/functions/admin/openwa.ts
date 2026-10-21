// OpenWA (github.com/rmyndharis/OpenWA), the WhatsApp gateway TaxStreem runs on its own server. Counta talks to its HTTP API
// with an Operator key: sessions (one WhatsApp number each), sending, and the webhooks that bring messages and delivery
// receipts back. The same file lives in supabase/functions/messaging, chat and admin; keep the three identical.
//
// OpenWA drives WhatsApp Web; it is not Meta's official API, and WhatsApp may restrict a number linked to it. Counta sends
// only what a person or the books asked for, one message at a time.

export type OpenWa = { url: string; key: string };
export type OwaResult = { status: number; ok: boolean; body: any };

export const COUNTA_SESSION = 'counta';
// The events each webhook asks for: delivery receipts and session changes go to the messaging function; messages people
// send to TaxStreem's number go to the chat function.
export const RECEIPT_EVENTS = ['message.ack', 'message.failed', 'session.status', 'session.authenticated', 'session.disconnected', 'session.restriction'];
export const INBOUND_EVENTS = ['message.received'];

export async function owa(cfg: OpenWa, path: string, init: { method?: string; body?: unknown; timeoutMs?: number } = {}): Promise<OwaResult> {
  try {
    const res = await fetch(`${cfg.url.replace(/\/+$/, '')}/api${path}`, {
      method: init.method || (init.body === undefined ? 'GET' : 'POST'),
      headers: { 'X-API-Key': cfg.key, 'Content-Type': 'application/json', Accept: 'application/json' },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
      signal: AbortSignal.timeout(init.timeoutMs ?? 25_000),
    });
    const text = await res.text();
    let body: any = text;
    try { body = text ? JSON.parse(text) : null; } catch { /* not json */ }
    return { status: res.status, ok: res.ok, body };
  } catch (e) {
    return { status: 0, ok: false, body: { message: (e as Error).name === 'TimeoutError' ? 'OpenWA did not answer in time.' : (e as Error).message } };
  }
}

export const owaError = (r: OwaResult) => String(r.body?.message || r.body?.error || (typeof r.body === 'string' && r.body) || (r.status ? `OpenWA answered ${r.status}` : 'OpenWA did not answer'))
  .replace(/\s+/g, ' ').slice(0, 300);

// A phone number as WhatsApp writes it (2348012345678), from what a person or a business typed.
export function waDigits(raw: unknown): string | null {
  const d = String(raw ?? '').replace(/[^0-9]/g, '');
  if (/^0\d{10}$/.test(d)) return '234' + d.slice(1);
  if (/^[789]\d{9}$/.test(d)) return '234' + d;
  return /^\d{8,15}$/.test(d) ? d : null;
}
export const chatId = (phone: string) => `${phone}@c.us`;

// The sender's number on a message that arrived: the chat id when it is a phone number, else the number OpenWA resolved
// for a privacy id (RESOLVE_LID_TO_PHONE=true on the server).
export function senderPhone(d: any): string | null {
  const from = String(d?.from || d?.chatId || '');
  const m = from.match(/^(\d{8,15})@c\.us$/);
  if (m) return m[1];
  return waDigits(d?.senderPhone);
}

export async function sendText(cfg: OpenWa, session: string, phone: string, text: string): Promise<string> {
  const r = await owa(cfg, `/sessions/${encodeURIComponent(session)}/messages/send-text`, { body: { chatId: chatId(phone), text: text.slice(0, 4000) } });
  if (!r.ok) throw new Error(`WhatsApp (OpenWA): ${owaError(r)}`);
  return String(r.body?.messageId || r.body?.id || '');
}

export async function sendDocument(cfg: OpenWa, session: string, phone: string, doc: { url: string; filename: string; mimetype: string; caption?: string }): Promise<string> {
  const r = await owa(cfg, `/sessions/${encodeURIComponent(session)}/messages/send-document`,
    { body: { chatId: chatId(phone), url: doc.url, filename: doc.filename, mimetype: doc.mimetype, ...(doc.caption ? { caption: doc.caption.slice(0, 1000) } : {}) }, timeoutMs: 45_000 });
  if (!r.ok) throw new Error(`WhatsApp (OpenWA): ${owaError(r)}`);
  return String(r.body?.messageId || r.body?.id || '');
}

// "Typing…" in the person's chat while Martina works. Best effort.
export async function typing(cfg: OpenWa, session: string, phone: string, on: boolean) {
  await owa(cfg, `/sessions/${encodeURIComponent(session)}/chats/typing`, { body: { chatId: chatId(phone), state: on ? 'typing' : 'paused' }, timeoutMs: 5_000 });
}

// The bytes of a message's media (a voice note), when the webhook did not carry them inline.
export async function downloadMedia(cfg: OpenWa, session: string, chat: string, messageId: string): Promise<Uint8Array | null> {
  try {
    const res = await fetch(`${cfg.url.replace(/\/+$/, '')}/api/sessions/${encodeURIComponent(session)}/messages/${encodeURIComponent(chat)}/${encodeURIComponent(messageId)}/media`,
      { headers: { 'X-API-Key': cfg.key }, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) { await res.body?.cancel(); return null; }
    const bytes = new Uint8Array(await res.arrayBuffer());
    return bytes.length && bytes.length <= 8_000_000 ? bytes : null;
  } catch { return null; }
}

// A session by name: found, or made and started. Returns OpenWA's record of it.
export async function ensureSession(cfg: OpenWa, name: string): Promise<any> {
  const list = await owa(cfg, '/sessions');
  if (!list.ok) throw new Error(owaError(list));
  const all: any[] = Array.isArray(list.body) ? list.body : list.body?.data || list.body?.sessions || [];
  let s = all.find((x) => x?.name === name || x?.id === name);
  if (!s) {
    const made = await owa(cfg, '/sessions', { body: { name } });
    if (!made.ok) throw new Error(owaError(made));
    s = made.body?.data || made.body;
  }
  if (!['ready', 'qr_ready', 'authenticating', 'initializing'].includes(String(s?.status))) {
    const st = await owa(cfg, `/sessions/${encodeURIComponent(s.id)}/start`, { method: 'POST', body: {} });
    if (!st.ok && st.status !== 409) throw new Error(owaError(st));
    const again = await owa(cfg, `/sessions/${encodeURIComponent(s.id)}`);
    if (again.ok) s = again.body?.data || again.body;
  }
  return s;
}

export async function sessionState(cfg: OpenWa, id: string): Promise<{ status: string; phone: string | null; push_name: string | null; error?: string; qr?: string | null }> {
  const r = await owa(cfg, `/sessions/${encodeURIComponent(id)}`);
  if (!r.ok) return { status: r.status === 404 ? 'missing' : 'unreachable', phone: null, push_name: null, error: owaError(r) };
  const s = r.body?.data || r.body;
  const out = { status: String(s?.status || 'unknown'), phone: waDigits(s?.phone), push_name: s?.pushName ? String(s.pushName) : null,
    error: s?.lastError ? String(s.lastError) : undefined, qr: null as string | null };
  if (out.status === 'qr_ready') {
    const q = await owa(cfg, `/sessions/${encodeURIComponent(id)}/qr`);
    const code = q.body?.qrCode || q.body?.data?.qrCode;
    if (q.ok && typeof code === 'string' && code.startsWith('data:image/')) out.qr = code;
  }
  return out;
}

// The webhooks a session sends to Counta: ours are replaced (any other webhooks on the server are left alone).
export async function setWebhooks(cfg: OpenWa, session: string, base: string, secret: string, hooks: { url: string; events: string[] }[]) {
  const list = await owa(cfg, `/sessions/${encodeURIComponent(session)}/webhooks`);
  if (!list.ok) throw new Error(owaError(list));
  const all: any[] = Array.isArray(list.body) ? list.body : list.body?.data || [];
  for (const w of all.filter((x) => String(x?.url || '').startsWith(base))) {
    await owa(cfg, `/sessions/${encodeURIComponent(session)}/webhooks/${encodeURIComponent(w.id)}`, { method: 'DELETE' });
  }
  for (const h of hooks) {
    const r = await owa(cfg, `/sessions/${encodeURIComponent(session)}/webhooks`, { body: { url: h.url, events: h.events, secret, retryCount: 5 } });
    if (!r.ok) throw new Error(`OpenWA would not add the webhook: ${owaError(r)}`);
  }
}

// X-OpenWA-Signature: sha256=<hex HMAC-SHA256 of the raw body with the webhook's secret>.
export async function signatureOk(raw: string, header: string | null, secret: string): Promise<boolean> {
  const got = String(header || '').replace(/^sha256=/i, '').trim().toLowerCase();
  if (!secret || !/^[0-9a-f]{64}$/.test(got)) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const want = Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)))).map((x) => x.toString(16).padStart(2, '0')).join('');
  let d = 0;
  for (let i = 0; i < 64; i++) d |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return d === 0;
}

// WhatsApp's own formatting for a message: *bold* heading, short lines, the link on its own line.
export function waFormat(heading: string, lines: string[], link?: string | null, button?: string | null, footer?: string | null) {
  const safe = (s: string) => String(s || '').replace(/[*_~`]/g, '').trim();
  return [`*${safe(heading)}*`, '', ...lines.map((l) => String(l || '').trim()).filter(Boolean), ...(link ? ['', `${button || 'Open'}: ${link}`] : []),
    ...(footer ? ['', `_${safe(footer)}_`] : [])].join('\n').slice(0, 4000);
}
