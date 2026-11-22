// Counta chat: Martina on WhatsApp (TaxStreem's number on its OpenWA server) and on Siri (an iPhone shortcut).
//
//   POST /chat/openwa   OpenWA's webhook for messages people send to TaxStreem's number (and to a business's own linked
//                       number, for its customers). Header X-OpenWA-Signature must be the HMAC of the body with
//                       OPENWA_WEBHOOK_SECRET. Answered at once; the reply goes out on WhatsApp.
//                       On TaxStreem's number: "LINK 123456" links the number (the code comes from Counta, Settings, Martina on
//                       WhatsApp and Siri); "UNLINK" ends the link. Voice notes are written down by Gemini first; pictures and
//                       PDFs are read (a supplier's invoice goes to Counta's reader, a product photo becomes a product). While a
//                       tax return waits for the person's approval PIN, a message of digits alone is checked here, never
//                       shown to Gemini or kept in the conversation.
//                       From anyone else: a customer of the business that last sent that number an invoice, receipt or order,
//                       answered by Martina for that business (customer.ts); on a business's own number, only when it turned
//                       that on.
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
import { type Ctx, type Env, run, systemPrompt, TOOLS, tools } from './martina.ts';
import { CUSTOMER_TOOLS, type CustCtx, type CustEnv, customerPrompt, customerTools } from './customer.ts';
import { cleanLook, customerPictureWords, extOf, type Look, LOOK_SCHEMA, LOOK_SYSTEM } from './media.ts';
import { isUnlink, linkCode, naira } from './words.ts';

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
// Another of Counta's functions, with the hook secret: messaging (a daily report), tax-files (a return to Flux), ai (reading a
// supplier's invoice or a product photo), payments (a customer's word that they paid).
async function hookSecret() {
  const env = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
  if (env) return env;
  const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' });
  return typeof data === 'string' && data.trim() ? data.trim() : await secret('PUSH_HOOK_SECRET');
}
async function callFn(fn: string, body: Record<string, unknown>, timeoutMs = 60_000): Promise<any> {
  try {
    const r = await fetch(`${SUPABASE_URL}/functions/v1/${fn}`, { method: 'POST', signal: AbortSignal.timeout(timeoutMs),
      headers: { 'Content-Type': 'application/json', 'x-counta-hook': await hookSecret(), Authorization: `Bearer ${SERVICE}` }, body: JSON.stringify(body) });
    return await r.json().catch(() => ({ ok: false, error: `${fn} answered ${r.status}` }));
  } catch (e) { return { ok: false, error: `${fn} did not answer: ${(e as Error).message}` }; }
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

function chatEnv(ctx: Ctx, said: string): Env {
  return { ctx, said, svc: (fn, args = {}) => svc(fn, args), call: (fn, body) => callFn(fn, body, 90_000),
    rpc: (fn, args = {}) => svc('svc_chat_rpc', { p_link: ctx.link_id, p_fn: fn, p: args }) };
}

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
  const env = chatEnv(ctx, said);
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

// The bytes of the media on a message (a voice note, a picture, a PDF): inline, or fetched from OpenWA.
async function mediaOf(cfg: OpenWa, session: string, phone: string, d: any): Promise<{ bytes: Uint8Array; mime: string; name: string } | null> {
  const mime = String(d.media?.mimetype || d.mimetype || '').split(';')[0] || 'application/octet-stream';
  let bytes: Uint8Array | null = null;
  if (d.media?.data && !d.media?.omitted) { try { bytes = Uint8Array.from(atob(String(d.media.data)), (ch) => ch.charCodeAt(0)); } catch { bytes = null; } }
  if (!bytes && d.id) bytes = await downloadMedia(cfg, session, String(d.chatId || chatId(phone)), String(d.id));
  return bytes ? { bytes, mime, name: String(d.media?.filename || d.filename || '').slice(0, 120) } : null;
}

// What a picture or PDF is (media.ts).
async function look(org: string, bytes: Uint8Array, mime: string, caption: string, kind: string): Promise<Look> {
  const { content, model, usage } = await gemini({
    systemInstruction: { parts: [{ text: LOOK_SYSTEM }] },
    contents: [{ role: 'user', parts: [{ text: caption ? `Caption: ${caption.slice(0, 300)}` : 'No caption.' }, { inlineData: { mimeType: mime, data: encodeBase64(bytes) } }] }],
    generationConfig: { responseMimeType: 'application/json', responseSchema: LOOK_SCHEMA },
  }, 45_000);
  meter(org, kind, model, usage);
  try { return cleanLook(JSON.parse((content.parts || []).map((p: any) => p.text || '').join(''))); } catch { return cleanLook({}); }
}

// A picture or PDF from someone on the team: a supplier's invoice goes to Counta's reader, a product photo is read for its
// details, a payment slip is described (never taken as a payment), a statement belongs in Banking.
// What comes back is the reply; `note`, when there is one, is added only to what Martina remembers of the reply (a product
// photo's reference, so add_product can put the photo on the new item).
async function teamMedia(link: Ctx, m: { bytes: Uint8Array; mime: string; name: string }, caption: string): Promise<string | { text: string; note: string }> {
  const ext = extOf(m.mime);
  if (!ext) return 'I can read photos (JPEG, PNG, WebP) and PDFs. Send it as one of those.';
  if (m.bytes.length > 8 * 1024 * 1024) return 'That file is larger than 8 MB. Send a smaller photo or PDF.';
  const l = await look(link.org_id, m.bytes, m.mime, caption, 'whatsapp_media');
  const base = link.app_url.replace(/\/$/, '');
  if (l.kind === 'supplier_invoice') {
    const path = `${link.org_id}/bills/whatsapp-${crypto.randomUUID()}.${ext}`;
    const up = await admin.storage.from('documents').upload(path, m.bytes, { contentType: m.mime, upsert: false });
    if (up.error) return 'I could not save that invoice just now. Try again, or upload it in Counta, Purchases, Bills.';
    const r = await callFn('ai', { action: 'si_upload', org_id: link.org_id, user_id: link.user_id, path, file_name: m.name || `WhatsApp ${ext.toUpperCase()}` });
    if (!r?.ok) return `I could not pass it to Counta: ${r?.error || 'try again'}. You can upload it in Counta, Purchases, Bills.`;
    return `Got it: ${l.summary}${l.total != null ? ` (${naira(l.total)})` : ''}. Counta is reading it into a bill now. It will be in Purchases, Supplier invoices for you to check, and I will tell you here if anything needs fixing.`;
  }
  if (l.kind === 'product') {
    if (!link.perms?.add_items && !link.perms?.edit_prices) return 'That looks like a product. Your role does not add products; the owner can allow it in Settings.';
    const r = await callFn('ai', { action: 'read_product_hook', org_id: link.org_id, user_id: link.user_id, images: [{ mime: m.mime, data: encodeBase64(m.bytes) }] });
    const p = r?.product;
    if (!r?.ok || !p?.name) return r?.error || 'I could not read the product clearly. Take the photo closer, front and back, or add it in Counta.';
    const unit = p.selling_unit || 'piece';
    const text = `That looks like *${p.name}*, sold by the ${unit}${p.barcode ? `, barcode ${p.barcode}` : ''}${p.category ? `, in ${p.category}` : ''}. To add it, tell me what one ${unit} sells for and what it costs you.`;
    if (ext === 'pdf') return text;
    // Kept as the item's picture if they add it (public bucket, like a photo taken in the app).
    const photo = `wa-${crypto.randomUUID()}.${ext}`;
    const up = await admin.storage.from('item-photos').upload(`${link.org_id}/${photo}`, m.bytes, { contentType: m.mime, cacheControl: '31536000', upsert: false });
    return up.error ? text : { text, note: `(Product photo kept as ${photo}: pass it as photo to add_product.)` };
  }
  if (l.kind === 'payment_slip') {
    return `This shows ${l.amount != null ? naira(l.amount) : 'a transfer'}${l.payer_name ? ` from ${l.payer_name}` : ''}${l.date ? ` on ${l.date}` : ''}. A slip is not proof the money arrived, so Counta records the payment when it reaches your bank or wallet and matches it there. If it has not shown by tomorrow, check the bank in Counta: ${base}/accounting/banking`;
  }
  if (l.kind === 'bank_statement') return `That looks like a bank statement. Upload it in Counta so every line is read into the books: ${base}/accounting/banking`;
  return `I see ${l.summary.replace(/\.$/, '')}. Here I take supplier invoices and receipts, and product photos. For anything else, use Counta: ${base}/home`;
}

// The approval PIN for a tax return: digits alone while one waits. Checked here; Gemini never sees it and it is not kept.
async function pinTurn(link: Ctx, said: string): Promise<string | null> {
  if (!/^\s*\d[\d\s]{3,10}\s*$/.test(said)) return null;
  const pending = await svc('svc_chat_pending', { p_link: link.link_id });
  if (!pending?.needs_pin) return null;
  await svc('svc_chat_log', { p_link: link.link_id, p_role: 'user', p_text: '(typed the approval PIN)', p_meta: { pin: true } });
  let reply: string;
  if (pending.expired) {
    await svc('svc_chat_pending_take', { p_link: link.link_id, p_action: null });
    reply = 'That waited more than ten minutes, so I dropped it. Ask me again to approve it.';
  } else {
    const r = await svc('svc_check_pin', { p_link: link.link_id, p_pin: said });
    if (r?.ok) {
      const taken = await svc('svc_chat_pending_take', { p_link: link.link_id, p_action: pending.action_id });
      if (!taken) reply = 'That was already done or dropped.';
      else {
        let out: any;
        try { out = await run(chatEnv(link, said), taken.kind, taken.payload, taken.action_id); } catch (e) { out = { error: (e as Error).message }; }
        reply = out?.summary ? String(out.summary) : `Counta could not do that: ${out?.error || 'try again from Counta'}.`;
      }
    } else if (r?.reason === 'not_set') {
      reply = 'You have no approval PIN yet. Set one in Counta, Settings, Martina on WhatsApp and Siri, then ask me again.';
    } else if (r?.reason === 'locked') {
      reply = 'Your approval PIN is locked for an hour after too many wrong tries. Approve it in Counta, or try again later.';
    } else {
      reply = `That PIN is not right. ${Number(r?.left) > 0 ? `${r.left} more ${Number(r.left) === 1 ? 'try' : 'tries'} before it locks for an hour.` : ''}`.trim();
    }
  }
  await svc('svc_chat_log', { p_link: link.link_id, p_role: 'assistant', p_text: reply });
  return reply;
}

// ------------------------------------------------------------------ a customer of the business
async function customerConverse(cx: CustCtx, said: string, media: string | null): Promise<string | null> {
  const chat = cx.chat_id;
  const history: { role: string; text: string }[] = (await svc('svc_customer_chat_history', { p_chat: chat })) || [];
  const count = Number(await svc('svc_customer_chat_log', { p_chat: chat, p_role: 'customer', p_text: said, p_media: media }));
  // The team answering this chat, or Martina switched off for the business: the team hears; nobody answers automatically.
  const feature = await svc('svc_feature', { p_org: cx.org_id, p_feature: 'martina' }).catch(() => true);
  if (cx.paused || feature === false) { await svc('svc_customer_handoff', { p_chat: chat, p_reason: said.slice(0, 300) }); return null; }
  if (count > 30) { if (count === 31) await svc('svc_customer_handoff', { p_chat: chat, p_reason: 'Many messages in an hour: Martina stopped answering.' }); return null; }
  const env: CustEnv = { ctx: cx, said, media, svc: (fn, args = {}) => svc(fn, args),
    paid: (token, amount, name) => callFn('payments', { action: 'public_paid', token, amount, name }, 30_000) };
  const impl = customerTools(env);
  const decls = [{ functionDeclarations: CUSTOMER_TOOLS.map((t) => ({ name: t.name, description: t.description, ...(t.parameters ? { parameters: t.parameters } : {}) })) }];
  const contents: any[] = history.map((h) => ({ role: h.role === 'customer' ? 'user' : 'model', parts: [{ text: h.role === 'team' ? `(A person from ${cx.business} wrote:) ${h.text}` : h.text }] }));
  contents.push({ role: 'user', parts: [{ text: said }] });
  let reply = '';
  for (let step = 0; step < 6; step++) {
    const { content, model, usage } = await gemini({ systemInstruction: { parts: [{ text: customerPrompt(env.ctx, history.length === 0) }] }, contents, tools: decls,
      toolConfig: { functionCallingConfig: { mode: 'AUTO' } } });
    meter(cx.org_id, 'customer_chat', model, usage);
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
  if (!reply) { await svc('svc_customer_handoff', { p_chat: env.ctx.chat_id, p_reason: said.slice(0, 300) }); reply = `Someone from ${env.ctx.business} will reply here shortly.`; }
  await svc('svc_customer_chat_log', { p_chat: env.ctx.chat_id, p_role: 'martina', p_text: reply });
  return reply;
}

async function customerInbound(cfg: OpenWa, session: string, kind: string, phone: string, d: any, type: string) {
  const name = String(d.notifyName || d.pushName || d.senderName || d._data?.notifyName || '').slice(0, 120);
  const cx: CustCtx | null = await svc('svc_customer_chat_find', { p_phone: phone, p_session: session, p_name: name || null });
  const reply = async (text: string) => { try { await sendText(cfg, session, phone, text); } catch (e) { console.warn('customer reply', (e as Error).message); } };
  if (!cx) {
    if (kind === 'counta' && await svc('svc_chat_stranger', { p_phone: phone })) {
      await reply('Hello, this is Martina from Counta by TaxStreem. This number sends invoices and receipts for businesses that use Counta. If you are a customer, reply to the message the business sent you; for anything else, contact the business directly.');
    }
    return;
  }
  // TaxStreem's switch for WhatsApp in this business: nothing goes out.
  if ((await svc('svc_feature', { p_org: cx.org_id, p_feature: 'whatsapp' }).catch(() => true)) === false) return;
  let said = String(d.body || d.caption || '').trim().slice(0, 2000);
  let media: string | null = null;
  if (type === 'voice' || type === 'audio' || type === 'ptt') {
    const m = await mediaOf(cfg, session, phone, d);
    if (!m) return await reply('I could not hear that voice note. Please type it.');
    try { said = await transcribe(cx.org_id, m.bytes, m.mime); } catch { return await reply('I could not make out that voice note. Please type it.'); }
    if (!said) return await reply('I did not catch any words in that voice note. Please type it.');
  } else if (type === 'image' || type === 'document') {
    const m = await mediaOf(cfg, session, phone, d);
    const ext = m ? extOf(m.mime) : null;
    if (m && ext && m.bytes.length <= 8 * 1024 * 1024) {
      media = `${cx.org_id}/chats/${cx.chat_id}/${crypto.randomUUID()}.${ext}`;
      const up = await admin.storage.from('documents').upload(media, m.bytes, { contentType: m.mime, upsert: false });
      if (up.error) media = null;
      try { said = `${said ? said + ' ' : ''}${customerPictureWords(await look(cx.org_id, m.bytes, m.mime, said, 'customer_media'), naira)}`; }
      catch { said = `${said ? said + ' ' : ''}[The customer sent a picture.]`; }
    } else {
      said = `${said ? said + ' ' : ''}[The customer sent a file Martina cannot open.]`;
    }
  } else if (type !== 'text' && type !== 'chat') {
    return;
  }
  if (!said) return;
  await typing(cfg, session, phone, true).catch(() => null);
  let answer: string | null;
  try { answer = await customerConverse(cx, said, media); }
  catch (e) {
    console.error('customer chat', e);
    await svc('svc_customer_handoff', { p_chat: cx.chat_id, p_reason: said.slice(0, 300) }).catch(() => null);
    answer = `Thank you. Someone from ${cx.business} will reply here shortly.`;
  }
  await typing(cfg, session, phone, false).catch(() => null);
  if (answer) await reply(answer);
}

// ------------------------------------------------------------------ WhatsApp
const later = (p: Promise<unknown>) => {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) { rt.waitUntil(p); return Promise.resolve(); }
  return p;
};

async function inbound(session: string, kind: string, d: any) {
  const cfg = await openwaCfg();
  if (!cfg) return;
  const phone = senderPhone(d);
  if (!phone) return;
  const type = String(d.type || 'text');
  // A business's own number: only its customers, when it turned that on.
  if (kind === 'business') return await customerInbound(cfg, session, kind, phone, d, type);
  const reply = async (text: string) => { try { await sendText(cfg, session, phone, text); } catch (e) { console.warn('chat reply', (e as Error).message); } };
  let said = String(d.body || '').trim();
  const code = linkCode(said);
  if (code) {
    const r = await svc('svc_chat_claim', { p_phone: phone, p_code: code });
    if (r?.ok) {
      const c = r.context;
      return await reply(`Linked. Hello ${c.first_name}, I'm Martina, your Counta assistant for ${c.business}.\n\nAsk me how sales are going, who owes you, what is running low, or say something like "record a sale of 2 Milo, paid cash". I'll read it back and wait for your yes before I do anything. Voice notes, photos of supplier invoices and product photos work too.\n\nSend UNLINK at any time to stop.`);
    }
    return await reply(r?.reason === 'wrong_code' ? 'That code is not right. Check the six digits Counta showed you, or get a new code in Counta, Settings, Martina on WhatsApp and Siri.'
      : r?.reason === 'not_member' ? 'That code is for a business you are no longer on.'
      : 'That code has expired or was made for another number. Get a new one in Counta, Settings, Martina on WhatsApp and Siri, from this phone number.');
  }
  const link = await svc('svc_chat_link', { p_phone: phone, p_key_hash: null });
  // Not on a team: perhaps a customer writing back to a business.
  if (!link) return await customerInbound(cfg, session, kind, phone, d, type);
  if (link.inactive) return await reply('You are no longer on the team of the business this number was linked to, so I cannot help here. Ask the owner, or link again in Counta.');
  if (isUnlink(said)) {
    await admin.from('chat_links').update({ status: 'revoked', revoked_at: new Date().toISOString() }).eq('id', link.link_id);
    return await reply('Done. This number is no longer linked to Counta, and I will not answer here. You can link it again in Counta, Settings, Martina on WhatsApp and Siri.');
  }
  if ((type === 'text' || type === 'chat') && said) {
    const pinReply = await pinTurn(link as Ctx, said);
    if (pinReply !== null) return await reply(pinReply);
  }
  await typing(cfg, session, phone, true).catch(() => null);
  let heard = '';
  if (type === 'voice' || type === 'audio' || type === 'ptt') {
    const m = await mediaOf(cfg, session, phone, d);
    if (!m) return await reply('I could not hear that voice note. Try again, or type it.');
    try { said = await transcribe(link.org_id, m.bytes, m.mime); } catch (e) { console.warn('transcribe', (e as Error).message); return await reply('I could not make out that voice note just now. Try typing it.'); }
    if (!said) return await reply('I did not catch any words in that voice note. Try again, or type it.');
    heard = `_"${said.replace(/[_*]/g, '').slice(0, 300)}"_\n\n`;
  } else if (type === 'image' || type === 'document') {
    const m = await mediaOf(cfg, session, phone, d);
    if (!m) return await reply('I could not open that file. Send it again, or upload it in Counta.');
    const caption = String(d.caption || d.body || '').trim().slice(0, 300);
    let answer: string, note = '';
    try { const r = await teamMedia(link as Ctx, m, caption); if (typeof r === 'string') answer = r; else { answer = r.text; note = r.note; } }
    catch (e) { console.error('chat media', e); answer = e instanceof CredentialError ? 'Martina is not available on WhatsApp right now. Upload it in Counta.' : 'I could not read that just now. Try again, or upload it in Counta.'; }
    await svc('svc_chat_log', { p_link: link.link_id, p_role: 'user', p_text: `(sent ${type === 'image' ? 'a photo' : 'a file'}${caption ? `: ${caption}` : ''})` });
    await svc('svc_chat_log', { p_link: link.link_id, p_role: 'assistant', p_text: note ? `${answer}\n${note}` : answer });
    await typing(cfg, session, phone, false).catch(() => null);
    return await reply(answer);
  } else if (type !== 'text' && type !== 'chat') {
    return await reply('I can read text, voice notes, photos and PDFs here.');
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
  // TaxStreem's own number talks to the team and to customers; a business's own number only to its customers (customer.ts).
  const s = await svc('svc_wa_session', { p_id: session });
  if (s?.kind !== 'counta' && s?.kind !== 'business') return json({ ok: true, ignored: true });
  const fresh = await svc('svc_openwa_seen', { p_id: `msg:${d.id || req.headers.get('x-openwa-delivery-id') || ''}` });
  if (fresh === false) return json({ ok: true, duplicate: true });
  await later(inbound(session, String(s.kind), d).catch((e) => console.error('chat inbound', e)));
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
