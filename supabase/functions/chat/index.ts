// Counta chat: Martina on WhatsApp (TaxStreem's number on its OpenWA server) and on Siri (an iPhone shortcut).
//
//   POST /chat/openwa   OpenWA's webhook for messages people send to TaxStreem's number. Header X-OpenWA-Signature must be
//                       the HMAC of the body with OPENWA_WEBHOOK_SECRET. Answered at once; the reply goes out on WhatsApp.
//                       "LINK 123456" links the number (the code comes from Counta, Settings, Martina on WhatsApp and Siri);
//                       "UNLINK" ends the link. Voice notes are written down by Gemini first.
//   POST /chat/siri     The shortcut: Authorization: Bearer <personal key from Counta>, body {"text": "..."} (or the text
//                       itself). Answers {"reply": "..."}; with ?format=text, the reply alone as text for Siri to speak.
//
// Martina runs on Gemini here (Vertex AI with ADC, or the Gemini API key: google.ts is a copy of ai/google.ts), with the
// tools in martina.ts. Every step runs as the person, in the business the link is for, through svc_chat_rpc.
// Secrets (Vault first, then Edge Function secrets): OPENWA_URL, OPENWA_API_KEY, OPENWA_WEBHOOK_SECRET, the Gemini keys.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';
import { accessProblem, CredentialError, fallbackModels, type GeminiConfig, geminiConfig, generateContent, quotaMessage } from './google.ts';
import { chatId, downloadMedia, type OpenWa, senderPhone, sendText, signatureOk, typing } from './openwa.ts';
import { type Ctx, type Env, systemPrompt, TOOLS, tools } from './martina.ts';
import { isUnlink, linkCode } from './words.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

const cache = new Map<string, { v: string; at: number }>();
const CACHE_MS = Number(Deno.env.get('SECRET_CACHE_MS') || 60_000);
async function secret(name: string): Promise<string> {
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.v;
  const { data } = await admin.rpc('svc_secret', { p_name: name });
  const v = (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
  cache.set(name, { v, at: Date.now() });
  return v;
}
async function svc(fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}
async function openwaCfg(): Promise<OpenWa | null> {
  const url = await secret('OPENWA_URL'), key = await secret('OPENWA_API_KEY');
  return url && key ? { url, key } : null;
}

// ------------------------------------------------------------------ Gemini
let CFG: GeminiConfig = { mode: 'none' };
let MODEL = 'gemini-3.8-flash';
let cfgAt = 0;
async function loadGemini() {
  if (Date.now() - cfgAt < 60_000) return;
  cfgAt = Date.now();
  CFG = await geminiConfig(secret);
  MODEL = (await secret('GEMINI_MODEL')) || 'gemini-3.8-flash';
}
const resting = new Map<string, number>();

// One generateContent call, trying the next model when one is busy or missing. Returns the model's content and usage.
async function gemini(body: Record<string, unknown>, timeoutMs = 45_000): Promise<{ content: any; model: string; usage: any }> {
  await loadGemini();
  if (CFG.mode === 'none') throw new CredentialError('Martina is not connected to Gemini yet.');
  let last = '';
  const all = [MODEL, ...fallbackModels(CFG).filter((m) => m !== MODEL)];
  const ready = all.filter((m) => (resting.get(m) || 0) < Date.now());
  for (const model of ready.length ? ready : all) {
    let res: Response;
    try { res = await generateContent(CFG, model, body, timeoutMs); }
    catch (e) { if (e instanceof CredentialError) throw e; last = `${model} did not answer`; resting.set(model, Date.now() + 120_000); continue; }
    const text = await res.clone().text();
    const refused = accessProblem(CFG, res.status, text);
    if (refused) throw new CredentialError(refused);
    if (res.status === 404 || (res.status === 400 && text.includes('not found'))) { last = `${model} unavailable`; resting.set(model, Date.now() + 3600_000); continue; }
    if (res.status === 429 || res.status >= 500) { last = res.status === 429 && /quota|exhaust/i.test(text) ? quotaMessage(CFG) : `${model} busy`; resting.set(model, Date.now() + 120_000); continue; }
    if (!res.ok) throw new Error(`Gemini ${res.status}: ${text.slice(0, 300)}`);
    const out = JSON.parse(text);
    const content = out?.candidates?.[0]?.content;
    if (!content?.parts?.length) throw new Error('Gemini returned nothing' + (out?.promptFeedback?.blockReason ? ` (${out.promptFeedback.blockReason})` : ''));
    return { content, model, usage: out?.usageMetadata || {} };
  }
  throw new Error(last || 'No Gemini model available');
}
function meter(org: string | null, kind: string, model: string, usage: any) {
  const tin = Number(usage?.promptTokenCount) || 0, tout = (Number(usage?.candidatesTokenCount) || 0) + (Number(usage?.thoughtsTokenCount) || 0);
  if (!tin && !tout) return;
  admin.rpc('svc_usage', { p: { org_id: org, service: 'gemini', kind, item: model, qty_in: tin, qty_out: tout } }).then(() => {}, () => {});
}

// A voice note, written down.
async function transcribe(org: string, bytes: Uint8Array, mime: string): Promise<string> {
  const { content, model, usage } = await gemini({
    systemInstruction: { parts: [{ text: 'Write down exactly what is said in this voice note, in the words used (Nigerian English or Pidgin). Answer with the words only. If nothing is said, answer with nothing.' }] },
    contents: [{ role: 'user', parts: [{ inlineData: { mimeType: mime.split(';')[0] || 'audio/ogg', data: encodeBase64(bytes) } }] }],
  }, 40_000);
  meter(org, 'transcribe', model, usage);
  return (content.parts || []).map((p: any) => p.text || '').join('').trim().slice(0, 2000);
}

// ------------------------------------------------------------------ a turn of conversation
const DECLS = [{ functionDeclarations: TOOLS.map((t) => ({ name: t.name, description: t.description, ...(t.parameters ? { parameters: t.parameters } : {}) })) }];

export async function converse(ctx: Ctx, said: string): Promise<string> {
  const org = ctx.org_id;
  const feature = await svc('svc_feature', { p_org: org, p_feature: 'martina' }).catch(() => true);
  if (feature === false) return 'Martina is paused for this business for now. Everything still works in Counta.';
  const ent = await svc('svc_entitle', { p_org: org, p_meter: 'assistant' }).catch(() => null);
  if (ent && ent.ok === false) return String(ent.message || 'Your plan has no more questions for Martina this month.');
  const history: { role: string; text: string }[] = (await svc('svc_chat_history', { p_link: ctx.link_id })) || [];
  const count = await svc('svc_chat_log', { p_link: ctx.link_id, p_role: 'user', p_text: said });
  if (Number(count) > 60) return 'That is a lot of messages in an hour. Give me a little while, or open Counta.';
  const pending = await svc('svc_chat_pending', { p_link: ctx.link_id });
  const env: Env = { ctx, said, svc: (fn, args = {}) => svc(fn, args),
    rpc: (fn, args = {}) => svc('svc_chat_rpc', { p_link: ctx.link_id, p_fn: fn, p: args }) };
  const impl = tools(env);
  const contents: any[] = history.map((h) => ({ role: h.role === 'assistant' ? 'model' : 'user', parts: [{ text: h.text }] }));
  contents.push({ role: 'user', parts: [{ text: said }] });
  let reply = '';
  for (let step = 0; step < 6; step++) {
    const { content, model, usage } = await gemini({
      systemInstruction: { parts: [{ text: systemPrompt(env.ctx, pending && !pending.expired ? pending : null) }] }, contents, tools: DECLS,
      toolConfig: { functionCallingConfig: { mode: 'AUTO' } },
    });
    meter(org, 'chat', model, usage);
    contents.push({ role: 'model', parts: content.parts });
    const calls = content.parts.filter((p: any) => p.functionCall);
    if (!calls.length) { reply = content.parts.map((p: any) => p.text || '').join('').trim(); break; }
    const answers = [];
    for (const c of calls) {
      const name = String(c.functionCall.name || ''), fn = impl[name];
      let out: unknown;
      try { out = fn ? await fn(c.functionCall.args || {}) : { error: `No tool called ${name}.` }; }
      catch (e) { out = { error: (e as Error).message.slice(0, 300) }; }
      answers.push({ functionResponse: { name, response: { result: out } } });
    }
    contents.push({ role: 'user', parts: answers });
  }
  if (!reply) reply = 'Sorry, I could not finish that. Try again, or open Counta.';
  await svc('svc_chat_log', { p_link: env.ctx.link_id, p_role: 'assistant', p_text: reply });
  return reply;
}

// ------------------------------------------------------------------ WhatsApp
const later = (p: Promise<unknown>) => {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) { rt.waitUntil(p); return Promise.resolve(); }
  return p;
};

async function inbound(session: string, d: any) {
  const cfg = await openwaCfg();
  if (!cfg) return;
  const phone = senderPhone(d);
  if (!phone) return;
  const reply = async (text: string) => { try { await sendText(cfg, session, phone, text); } catch (e) { console.warn('chat reply', (e as Error).message); } };
  const type = String(d.type || 'text');
  let said = String(d.body || '').trim();
  const code = linkCode(said);
  if (code) {
    const r = await svc('svc_chat_claim', { p_phone: phone, p_code: code });
    if (r?.ok) {
      const c = r.context;
      return await reply(`Linked. Hello ${c.first_name}, I'm Martina, your Counta assistant for ${c.business}.\n\nAsk me how sales are going, who owes you, what is running low, or say something like "record a sale of 2 Milo, paid cash". I'll read it back and wait for your yes before I do anything. Voice notes work too.\n\nSend UNLINK at any time to stop.`);
    }
    return await reply(r?.reason === 'wrong_code' ? 'That code is not right. Check the six digits Counta showed you, or get a new code in Counta, Settings, Martina on WhatsApp and Siri.'
      : r?.reason === 'not_member' ? 'That code is for a business you are no longer on.'
      : 'That code has expired or was made for another number. Get a new one in Counta, Settings, Martina on WhatsApp and Siri, from this phone number.');
  }
  const link = await svc('svc_chat_link', { p_phone: phone, p_key_hash: null });
  if (!link) {
    if (await svc('svc_chat_stranger', { p_phone: phone })) {
      await reply('Hello, this is Martina from Counta by TaxStreem. This number is not linked to a Counta account yet. To talk to me here, open Counta, go to Settings, Martina on WhatsApp and Siri, and follow the steps.');
    }
    return;
  }
  if (link.inactive) return await reply('You are no longer on the team of the business this number was linked to, so I cannot help here. Ask the owner, or link again in Counta.');
  if (isUnlink(said)) {
    await admin.from('chat_links').update({ status: 'revoked', revoked_at: new Date().toISOString() }).eq('id', link.link_id);
    return await reply('Done. This number is no longer linked to Counta, and I will not answer here. You can link it again in Counta, Settings, Martina on WhatsApp and Siri.');
  }
  await typing(cfg, session, phone, true).catch(() => null);
  let heard = '';
  if (type === 'voice' || type === 'audio' || type === 'ptt') {
    let bytes: Uint8Array | null = null;
    const mime = String(d.media?.mimetype || 'audio/ogg');
    if (d.media?.data && !d.media?.omitted) { try { bytes = Uint8Array.from(atob(String(d.media.data)), (ch) => ch.charCodeAt(0)); } catch { bytes = null; } }
    if (!bytes && d.id) bytes = await downloadMedia(cfg, session, String(d.chatId || chatId(phone)), String(d.id));
    if (!bytes) return await reply('I could not hear that voice note. Try again, or type it.');
    try { said = await transcribe(link.org_id, bytes, mime); } catch (e) { console.warn('transcribe', (e as Error).message); return await reply('I could not make out that voice note just now. Try typing it.'); }
    if (!said) return await reply('I did not catch any words in that voice note. Try again, or type it.');
    heard = `_"${said.replace(/[_*]/g, '').slice(0, 300)}"_\n\n`;
  } else if (type !== 'text' && type !== 'chat') {
    return await reply('I can read text and voice notes here. For pictures and documents, use Counta: invoices from suppliers go in Purchases, Bills, Upload.');
  }
  if (!said) return;
  let answer: string;
  try { answer = await converse(link as Ctx, said); }
  catch (e) { console.error('chat', e); answer = e instanceof CredentialError ? 'Martina is not available on WhatsApp right now. Everything still works in Counta.' : 'Something went wrong on my side. Try again in a minute.'; }
  await typing(cfg, session, phone, false).catch(() => null);
  await reply(heard + answer);
}

async function openwaWebhook(req: Request) {
  const raw = await req.text();
  if (!(await signatureOk(raw, req.headers.get('x-openwa-signature'), await secret('OPENWA_WEBHOOK_SECRET')))) return new Response('Forbidden', { status: 403 });
  let b: any;
  try { b = JSON.parse(raw); } catch { return new Response('Bad request', { status: 400 }); }
  if (b?.timestamp && Date.parse(b.timestamp) < Date.now() - 2 * 86400_000) return json({ ok: true, stale: true });
  if (String(b?.event || req.headers.get('x-openwa-event')) !== 'message.received') return json({ ok: true, ignored: true });
  const d = b?.data || {}, session = String(b?.sessionId || '');
  if (d.fromMe || d.isGroup || d.isStatusBroadcast || /@(g\.us|broadcast|newsletter)$/.test(String(d.from || d.chatId || ''))) return json({ ok: true, ignored: true });
  // Only TaxStreem's own number talks to Martina; a business's own linked number is for sending.
  const s = await svc('svc_wa_session', { p_id: session });
  if (s?.kind !== 'counta') return json({ ok: true, ignored: true });
  const fresh = await svc('svc_openwa_seen', { p_id: `msg:${d.id || req.headers.get('x-openwa-delivery-id') || ''}` });
  if (fresh === false) return json({ ok: true, duplicate: true });
  await later(inbound(session, d).catch((e) => console.error('chat inbound', e)));
  return json({ ok: true });
}

// ------------------------------------------------------------------ Siri
async function sha256hex(s: string) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))).map((x) => x.toString(16).padStart(2, '0')).join('');
}
async function siri(req: Request) {
  const asText = new URL(req.url).searchParams.get('format') === 'text';
  const out = (reply: string, status = 200) => asText ? new Response(reply, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }) : json({ ok: status === 200, reply }, status);
  const key = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!/^ck_[0-9a-f]{48}$/.test(key)) return out('This shortcut needs your Counta key. Make one in Counta, Settings, Martina on WhatsApp and Siri.', 401);
  const raw = await req.text();
  let said = raw.trim();
  try { const j = JSON.parse(raw); if (j && typeof j === 'object') said = String(j.text ?? j.said ?? '').trim(); } catch { /* the text itself */ }
  said = said.slice(0, 1000);
  const link = await svc('svc_chat_link', { p_phone: null, p_key_hash: await sha256hex(key) });
  if (!link) return out('That Counta key does not work any more. Make a new one in Counta, Settings, Martina on WhatsApp and Siri.', 401);
  if (link.inactive) return out('You are no longer on that business\'s team, so this key does not work.', 403);
  if (!said) return out(`Hi ${link.first_name}. What can I do for you?`);
  try { return out(await converse(link as Ctx, said)); }
  catch (e) { console.error('siri', e); return out(e instanceof CredentialError ? 'Martina is not available right now.' : 'Something went wrong on my side. Try again in a minute.', 200); }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' } });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const path = new URL(req.url).pathname;
  try {
    if (/\/openwa\/?$/.test(path)) return await openwaWebhook(req);
    if (/\/siri\/?$/.test(path)) return await siri(req);
    return json({ ok: false, error: 'Unknown address.' }, 404);
  } catch (e) {
    console.error('chat', e);
    return json({ ok: false, error: 'Something went wrong.' }, 500);
  }
});
