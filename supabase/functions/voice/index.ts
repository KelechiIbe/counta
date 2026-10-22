// Counta voice, through ElevenLabs: Nigerian voices that announce payments and sales, Martina the onboarding guide, and
// the phone calls Martina places (vendor orders, reminders, onboarding follow-ups).
//
// Signed-in callers (Authorization: Bearer <user JWT>):
//   { action: 'status' }                               -> is calling switched on, which number calls out
//   { action: 'voices' }                               -> the Nigerian voices to choose from (filled from the voice library on first use)
//   { action: 'speak', kind, org_id?, ... }            -> an announcement as audio, in the business's voice and language:
//        payment_received {org_id, request_id} | sale_recorded {org_id, item_id, qty, amount} | payment_demo {org_id}
//        | preview {voice_id, lang}
//   { action: 'guide_token', text? }                   -> a signed token (or, for typing only, a signed URL) to talk to Martina from
//                                                         the web app, with her opening line and what she knows about the person's progress
//   { action: 'assistant_token', org_id, text?, page? } -> the same for Martina everywhere else, told what the person's role allows
//   { action: 'forget' }                               -> deletes from ElevenLabs the person's conversations in which an NIN was said
//   { action: 'call_vendor', po_id }                   -> phones the vendor on a purchase order
//   { action: 'call_member', member_id, topic }        -> phones a team member about waiting work
//   { action: 'sync', call_id }                        -> refreshes one call from ElevenLabs
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'sync_pending' }                         -> refreshes every call still in progress
//   { action: 'guide_followups' }                      -> phones the people who asked Martina to call when they stopped mid-setup,
//                                                         and deletes conversations in which an NIN was said
//   { action: 'forget_pending' }                       -> only the deleting
//   { action: 'refresh_voices' }                       -> reloads the Nigerian voices
//   { action: 'place_due' }                            -> places the calls the morning alerts queued: Martina reminding an owner of a
//                                                         tax return due tomorrow, and following up a customer's overdue invoice
//
// Secrets: ELEVENLABS_API_KEY (Edge Function secret or Vault). Optional: ELEVENLABS_VOICE_IDS (comma-separated voice ids to
// offer instead of searching the voice library for Nigerian voices), ELEVENLABS_VOICE_ID (Martina's default voice),
// ELEVENLABS_TTS_MODEL (announcements; default eleven_flash_v2_5), ELEVENLABS_PHONE_NUMBER_ID (the number calls come from
// when there are several). ELEVENLABS_BASE_URL is for tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';
import { FOLLOWUP_DATA, FOLLOWUP_PROMPT, firstMessage, GUIDE_PROMPT, GUIDE_TOOLS, stepLabel, TALK, toolConfig, type ToolDef, whatWeKnow } from './guide.ts';
import { ASSISTANT_PROMPT, ASSISTANT_TOOLS, assistantFirst, handsFreeFirst, PERM_WORDS } from './assistant.ts';
import { wordingNote, wordsFor } from './wording.ts';
import { cacheable, phrase, shortName } from './phrases.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const XI = (Deno.env.get('ELEVENLABS_BASE_URL') || 'https://api.elevenlabs.io').replace(/\/$/, '');
const AGENT_VERSION = 2;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
// What a business sees. TaxStreem's admin portal tests the ElevenLabs key and phone number itself.
const NOT_CONFIGURED = 'Phone calls are not switched on yet. TaxStreem is setting them up; send orders and reminders by WhatsApp or email for now.';
const VOICE_OFF = 'Nigerian voices are not switched on yet. TaxStreem is setting them up; the device\'s own voice speaks meanwhile.';
const MARTINA_OFF = 'Martina is paused for now by TaxStreem. Everything on the screens works without her.';

// Keys set in the admin portal (Supabase Vault) come first; the Edge Function secrets are the fallback.
const secrets = new Map<string, { v: string; at: number }>();
async function secret(name: string): Promise<string> {
  // The database's hook secret keeps its old order: the Edge Function secret first.
  if (name === 'PUSH_HOOK_SECRET' && Deno.env.get(name)) return Deno.env.get(name)!.trim();
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('app_secret', { p_name: name });
  const v = (typeof data === 'string' ? data.trim() : '') || (Deno.env.get(name) || '').trim();
  secrets.set(name, { v, at: Date.now() });
  return v;
}
// What TaxStreem set in the admin portal for Martina (tone, default voice), read again once a minute.
let plat: { at: number; v: any } | null = null;
const PLATFORM_MS = Number(Deno.env.get('SECRET_CACHE_MS') || 60_000);
async function platform(): Promise<any> {
  if (plat && Date.now() - plat.at < PLATFORM_MS) return plat.v;
  const { data } = await admin.rpc('svc_platform');
  plat = { at: Date.now(), v: data && typeof data === 'object' ? data : {} };
  return plat.v;
}
// A feature TaxStreem has paused for everyone, or for one business.
async function featureOn(orgId: string | null, feature: string) {
  const { data } = await admin.rpc('svc_feature', { p_org: orgId, p_feature: feature });
  return data !== false;
}
function sameSecret(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}
async function sha256(s: string) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return Array.from(h).map((b) => b.toString(16).padStart(2, '0')).join('');
}
function hashNum(s: string) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 100000; return h; }
const VOICE_ID = /^[A-Za-z0-9]{8,40}$/;

class NotConfigured extends Error {}

async function xiFetch(path: string, init: RequestInit = {}, timeoutMs = 30_000): Promise<Response> {
  const key = await secret('ELEVENLABS_API_KEY');
  if (!key) throw new NotConfigured(NOT_CONFIGURED);
  return await fetch(XI + path, { ...init, headers: { 'xi-api-key': key, 'Content-Type': 'application/json', ...(init.headers || {}) }, signal: AbortSignal.timeout(timeoutMs) });
}
async function xiError(res: Response) {
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* plain text */ }
  const detail = typeof body === 'string' ? body : body?.detail?.message || body?.detail?.[0]?.msg || JSON.stringify(body);
  const err = new Error(`ElevenLabs ${res.status}: ${String(detail).slice(0, 300)}`) as Error & { status?: number };
  err.status = res.status;
  return err;
}
async function xi(path: string, init: RequestInit = {}): Promise<any> {
  const res = await xiFetch(path, init);
  if (!res.ok) throw await xiError(res);
  const text = await res.text();
  try { return JSON.parse(text); } catch { return text; }
}

// ------------------------------------------------------------------ voices
// The voices on offer: the ones pinned in ELEVENLABS_VOICE_IDS, or the most used Nigerian voices in the ElevenLabs voice
// library (three female, three male), added to the account so they can speak.
let refreshedAt = 0;
async function refreshVoices() {
  refreshedAt = Date.now();
  const pinned = (await secret('ELEVENLABS_VOICE_IDS')).split(/[\s,]+/).filter((x) => VOICE_ID.test(x)).slice(0, 12);
  const rows: Record<string, unknown>[] = [];
  if (pinned.length) {
    for (const [i, id] of pinned.entries()) {
      const v = await xi(`/v1/voices/${id}`);
      rows.push({ voice_id: id, name: shortName(v?.name), gender: v?.labels?.gender ?? null, age: v?.labels?.age ?? null,
        accent: v?.labels?.accent ?? null, description: String(v?.description || v?.labels?.description || '').slice(0, 200) || null,
        preview_url: v?.preview_url ?? null, source: 'pinned', owner_id: null, sort: i + 1, active: true });
    }
  } else {
    const { data: have } = await admin.from('tts_voices').select('voice_id, owner_id, active');
    for (const [g, gender] of ['female', 'male'].entries()) {
      const q = new URLSearchParams({ accent: 'nigerian', language: 'en', gender, sort: 'usage_character_count_1y', page_size: '12',
        include_custom_rates: 'false', include_live_moderated: 'false' });
      const list = await xi(`/v1/shared-voices?${q}`);
      const voices = (Array.isArray(list?.voices) ? list.voices : []).filter((v: any) => VOICE_ID.test(String(v?.voice_id || '')) && v?.public_owner_id);
      for (const [i, v] of voices.slice(0, 3).entries()) {
        // A library voice speaks for the account only once it is added; adding returns the id it speaks under.
        let id = (have || []).find((h) => h.owner_id === v.public_owner_id && h.voice_id === v.voice_id)?.voice_id as string | undefined;
        if (!id) {
          const added = await xi(`/v1/voices/add/${encodeURIComponent(v.public_owner_id)}/${encodeURIComponent(v.voice_id)}`,
            { method: 'POST', body: JSON.stringify({ new_name: `Counta ${shortName(v.name)}` }) });
          id = String(added?.voice_id || v.voice_id);
        }
        if (!VOICE_ID.test(id)) continue;
        rows.push({ voice_id: id, name: shortName(v.name), gender, age: v.age ?? null, accent: v.accent ?? 'nigerian',
          description: String(v.description || v.descriptive || '').slice(0, 200) || null, preview_url: v.preview_url ?? null,
          source: 'library', owner_id: v.public_owner_id, sort: g * 10 + i + 1, active: true });
      }
    }
  }
  if (!rows.length) return { added: 0, voices: 0 };
  const now = new Date().toISOString();
  if (pinned.length) {
    const { error } = await admin.from('tts_voices').upsert(rows.map((r) => ({ ...r, updated_at: now })), { onConflict: 'voice_id' });
    if (error) throw new Error(error.message);
    // Voices no longer offered stay on record (a business may still use one) but are not offered to new choices.
    await admin.from('tts_voices').update({ active: false, updated_at: now }).not('voice_id', 'in', `(${rows.map((r) => r.voice_id).join(',')})`);
    return { added: rows.length, voices: rows.length };
  }
  // From the library: voices already known keep the choice TaxStreem made in the admin portal; new ones go on offer only
  // when nothing is on offer yet.
  const { data: known } = await admin.from('tts_voices').select('voice_id, active');
  const knownIds = new Set((known || []).map((k: any) => k.voice_id));
  const anyActive = (known || []).some((k: any) => k.active);
  const fresh = rows.filter((r) => !knownIds.has(r.voice_id)).map((r) => ({ ...r, active: !anyActive, updated_at: now }));
  if (fresh.length) {
    const { error } = await admin.from('tts_voices').insert(fresh);
    if (error) throw new Error(error.message);
  }
  for (const r of rows.filter((x) => knownIds.has(x.voice_id))) {
    const { active: _a, ...rest } = r;
    await admin.from('tts_voices').update({ ...rest, updated_at: now }).eq('voice_id', r.voice_id);
  }
  return { added: fresh.length, voices: rows.length };
}

async function activeVoices() {
  const { data } = await admin.from('tts_voices').select('voice_id, name, gender, age, accent, description, sort').eq('active', true).order('sort');
  return data || [];
}
// Martina's voice when a business has not chosen one: the one chosen in the admin portal, ELEVENLABS_VOICE_ID, else the first
// Nigerian voice on offer.
async function defaultVoice(): Promise<string> {
  const chosen = String((await platform())?.martina?.default_voice_id || '');
  if (VOICE_ID.test(chosen)) return chosen;
  const pinned = await secret('ELEVENLABS_VOICE_ID');
  if (VOICE_ID.test(pinned)) return pinned;
  return String((await activeVoices())[0]?.voice_id || '');
}

// ------------------------------------------------------------------ speech
const take = async (subject: string, chars: number, cached: boolean) =>
  Boolean((await admin.rpc('svc_tts_take', { p_subject: subject, p_chars: chars, p_cached: cached })).data);

async function speak(sb: SupabaseClient, userId: string, body: any) {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, reason: 'not_configured', error: VOICE_OFF };
  const kind = String(body.kind || '');
  let text = '', voice = '', subject = '';
  let lang: 'en' | 'pcm' = 'en';
  if (kind === 'preview') {
    voice = String(body.voice_id || '');
    const { data: v } = await admin.from('tts_voices').select('voice_id, name').eq('voice_id', voice).eq('active', true).maybeSingle();
    if (!v) return { ok: false, error: 'Choose one of the voices on the list.' };
    lang = body.lang === 'pcm' ? 'pcm' : 'en';
    text = phrase('preview', lang, {}, { voiceName: v.name });
    subject = `user:${userId}`;
  } else if (['payment_received', 'sale_recorded', 'payment_demo'].includes(kind)) {
    const p: Record<string, unknown> = kind === 'payment_received' ? { request_id: body.request_id }
      : kind === 'sale_recorded' ? { item_id: body.item_id, qty: body.qty, amount: body.amount } : {};
    // Checks the caller belongs to the business and builds the facts from its own records.
    const { data: say, error } = await sb.rpc('voice_say', { p_org: body.org_id, p_kind: kind, p });
    if (error) return { ok: false, error: error.message };
    if (!say?.enabled) return { ok: true, enabled: false };
    voice = say.voice_id && VOICE_ID.test(say.voice_id) ? say.voice_id : await defaultVoice();
    lang = say.lang === 'pcm' ? 'pcm' : 'en';
    text = phrase(kind, lang, say.vars || {}, { business: say.business });
    subject = `org:${body.org_id}`;
  } else {
    return { ok: false, error: 'Unknown announcement.' };
  }
  if (!voice) return { ok: false, reason: 'no_voice', error: 'No Nigerian voice is set up yet.', text, lang };
  const model = (await secret('ELEVENLABS_TTS_MODEL')) || 'eleven_flash_v2_5';
  const keep = cacheable(kind);
  const path = keep ? `tts/${await sha256(`${model}|${voice}|${text}`)}.mp3` : '';
  if (keep) {
    const { data: blob } = await admin.storage.from('voice-cache').download(path);
    if (blob && blob.size > 0) {
      if (!(await take(subject, text.length, true))) return { ok: false, reason: 'limit', error: 'Counta has spoken a lot today.', text, lang };
      return { ok: true, enabled: true, text, lang, voice_id: voice, mime: 'audio/mpeg', audio: encodeBase64(new Uint8Array(await blob.arrayBuffer())), cached: true };
    }
  }
  if (!(await take(subject, text.length, false))) return { ok: false, reason: 'limit', error: 'Counta has spoken a lot today.', text, lang };
  const res = await xiFetch(`/v1/text-to-speech/${voice}?output_format=mp3_44100_64`, {
    method: 'POST', headers: { accept: 'audio/mpeg' },
    body: JSON.stringify({ text, model_id: model, voice_settings: { stability: 0.45, similarity_boost: 0.8, style: 0.15, speed: 1 } }),
  }, 20_000);
  if (!res.ok) {
    const err = await xiError(res);
    console.warn('tts', err.message);
    return { ok: false, reason: 'error', error: 'The voice did not answer just now.', text, lang };
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (keep) await admin.storage.from('voice-cache').upload(path, bytes, { contentType: 'audio/mpeg', upsert: true }).catch(() => null);
  return { ok: true, enabled: true, text, lang, voice_id: voice, mime: 'audio/mpeg', audio: encodeBase64(bytes), cached: false };
}

// ------------------------------------------------------------------ agents
const RULES = `Speak clear, warm Nigerian English and understand Nigerian Pidgin. Keep sentences short; this is a phone call.
You are an AI assistant. Say so if anyone asks, and never pretend to be a person.
Never ask for or discuss bank details, card numbers, passwords or one-time codes. If payment comes up, say the owner will follow up.
If the person is busy or asks you to call back, ask for a good time, thank them and end the call.
${TALK}`;

// How Martina's voice carries. Calm is steady with no expressive audio tags; warm lets a few gentle tags through; lively is
// the old, more animated delivery.
const TONES: Record<string, Record<string, unknown>> = {
  calm: { expressive_mode: false, stability: 0.62, similarity_boost: 0.8, speed: 0.97 },
  warm: { expressive_mode: true, stability: 0.52, similarity_boost: 0.8, speed: 1,
    suggested_audio_tags: [{ tag: 'warm', description: 'Greeting someone or thanking them' }, { tag: 'calm', description: 'Explaining a figure or a next step' },
      { tag: 'reassuring', description: 'When something went wrong or the person is worried' }] },
  lively: { expressive_mode: true, stability: 0.45, similarity_boost: 0.8, speed: 1.02 },
};

// The voice model Martina speaks with (admin portal, Martina and voices). Eleven v4 Turbo sounds the most natural and is
// the only one that takes expressive cues; Turbo v2.5 and Flash v2.5 read plainly and never add sighs or laughs.
export const VOICE_MODELS = ['eleven_v4_turbo', 'eleven_turbo_v2_5', 'eleven_flash_v2_5'];
export function ttsConfig(tone: string, model: string, voiceId: string) {
  const t: Record<string, unknown> = { ...(TONES[tone] || TONES.calm) };
  const m = VOICE_MODELS.includes(model) ? model : VOICE_MODELS[0];
  if (!m.startsWith('eleven_v4')) { delete t.expressive_mode; delete t.suggested_audio_tags; }
  return { model_id: m, ...t, ...(voiceId ? { voice_id: voiceId } : {}) };
}
// Martina stops when the person says a word ("ok", "got it", "next"); a listening noise alone does not cut her off.
export const IGNORE_WHILE_SPEAKING = ['mm', 'mmm', 'mhm', 'mm-hmm', 'uh-huh', 'hmm'];

type Agent = { name: string; prompt: string; first: string; maxSecs: number; data: Record<string, unknown>; criteria: unknown[]; web?: boolean; temperature?: number;
  tools?: ToolDef[] };
const AGENTS: Record<string, Agent> = {
  vendor_order: {
    name: 'Counta · vendor orders',
    first: 'Good day. This is Martina, an automated assistant calling for {{business_name}} with a stock order. Am I speaking with {{vendor_name}}?',
    maxSecs: 300,
    prompt: `You are Martina, the ordering assistant for {{business_name}}, a shop in Nigeria that buys stock from {{vendor_name}}.
You are calling to place purchase order {{po_ref}}.

The order:
{{order_lines}}
Order total at the last agreed prices: {{order_total}}.
Deliver to: {{delivery_branch}}. Their usual lead time is {{lead_time_days}} days.
Contact at the shop: {{contact_name}}, {{contact_phone}}.

How to run the call:
1. Confirm you are speaking with {{vendor_name}} or someone who takes orders for them. If not, ask for the right person or a better time.
2. Read the order slowly, one line at a time, with clear quantities and units.
3. Ask whether they can supply everything, and on what day they can deliver.
4. Write down any item they cannot supply, any substitution and any new price exactly as they say it. Do not accept a new price or a substitution for the shop; say {{contact_name}} will confirm it.
5. Before you end, repeat back what was agreed: the items, the delivery day and any changes. Then thank them.
${RULES}`,
    data: {
      order_confirmed: { type: 'boolean', description: 'True if the vendor agreed to supply the order, even with some changes. False if they refused, could not be reached properly, or asked to call back before agreeing.' },
      delivery_date: { type: 'string', description: 'The delivery day or date the vendor promised, in their words, for example "Tuesday 21 October" or "tomorrow afternoon". Empty if none.' },
      unavailable_items: { type: 'string', description: 'Items the vendor cannot supply or will supply short, with quantities. Empty if none.' },
      price_changes: { type: 'string', description: 'Any item whose price the vendor said has changed, with the new price in naira. Empty if none.' },
      callback_time: { type: 'string', description: 'When the vendor asked to be called back, if they did. Empty otherwise.' },
      notes: { type: 'string', description: 'Anything else the shop owner should know from the call, in one or two sentences.' },
    },
    criteria: [{ id: 'order_placed', name: 'Order placed', type: 'prompt', conversation_goal_prompt: 'Did the vendor clearly agree to supply the order and give a delivery day?' }],
  },
  reminder: {
    name: 'Counta · reminders',
    first: 'Hello {{person_first_name}}, this is Martina, the Counta assistant for {{business_name}}. Do you have a quick minute?',
    maxSecs: 150,
    prompt: `You are Martina, the automated assistant inside {{business_name}}'s Counta inventory app. {{caller_name}} asked you to call {{person_name}}, who works at the business, about something waiting for them in the app.

What is waiting: {{task_details}}
What they need to do: {{task_action}}

How to run the call:
1. Greet them by first name and say in one or two sentences why you are calling.
2. Answer simple questions using only the details above. Do not invent numbers or items.
3. You cannot change anything in the app yourself; they need to open Counta to act.
4. Ask when they will take care of it, thank them and end the call. Keep the whole call under a minute.
${RULES}`,
    data: {
      will_act: { type: 'boolean', description: 'True if the person said they will take care of it.' },
      when: { type: 'string', description: 'When they said they will do it, in their words. Empty if they did not say.' },
      notes: { type: 'string', description: 'Anything they said that the person who sent the reminder should know.' },
    },
    criteria: [{ id: 'reminder_heard', name: 'Reminder heard', type: 'prompt', conversation_goal_prompt: 'Did the person hear and understand what is waiting for them?' }],
  },
  tax_deadline: {
    name: 'Counta · tax deadline reminders',
    first: 'Hello {{person_first_name}}, this is Martina, the Counta assistant for {{business_name}}. I am calling about your {{tax_name}} for {{period}}, due {{due_date}}. Do you have a quick minute?',
    maxSecs: 150,
    prompt: `You are Martina, the automated assistant inside {{business_name}}'s Counta accounting app. You are calling {{person_name}}, who runs the business, because a tax return is due very soon.

What is due: the {{tax_name}} for {{period}}, due on {{due_date}}. Amount: {{amount}}.
What to do: {{what_to_do}}

How to run the call:
1. Greet them by first name and say in one or two sentences why you are calling: the return is due {{due_date}}, and filing late brings penalties and interest.
2. Say what to do, simply, using only the details above. Do not invent figures, dates or penalties.
3. You cannot file or pay anything yourself. They need to open Counta to finish it.
4. Ask when they will do it, and whether anything is stopping them. If something is, write it down so the Counta team can help.
5. Thank them and end the call. Keep it under a minute.
${RULES}`,
    data: {
      will_file: { type: 'boolean', description: 'True if the person said they will file or pay before the due date.' },
      when: { type: 'string', description: 'When they said they will do it, in their words. Empty if they did not say.' },
      blocker: { type: 'string', description: 'Anything they said is stopping them filing or paying (missing figures, no money, a question about the return). Empty if none.' },
      notes: { type: 'string', description: 'Anything else they said that matters, in one sentence.' },
    },
    criteria: [{ id: 'reminder_heard', name: 'Reminder heard', type: 'prompt', conversation_goal_prompt: 'Did the person hear that the return is due and what to do about it?' }],
  },
  customer_followup: {
    name: 'Counta · overdue invoice follow-ups',
    first: 'Good day. This is Martina, an automated assistant calling on behalf of {{business_name}}. Am I speaking with {{customer_name}}, or someone who handles their payments?',
    maxSecs: 180,
    prompt: `You are Martina, an automated assistant calling on behalf of {{business_name}}, a business in Nigeria, about an invoice its customer {{customer_name}} has not paid.

The invoice: {{invoice_number}}, {{amount_due}} still to pay, due on {{due_date}} ({{days_overdue}} days ago).
For questions about the invoice: {{contact_name}} at {{business_name}}, {{contact_phone}}.

How to run the call:
1. Confirm you are speaking with {{customer_name}} or someone who handles their payments. If not, ask for the right person or a good time to call back, then end politely.
2. Say, politely and without pressure, that invoice {{invoice_number}} for {{amount_due}} was due on {{due_date}}, and ask when they expect to pay.
3. If they say they have already paid, thank them and ask when and how they paid, so {{business_name}} can match it. Do not argue.
4. If they disagree with the invoice or something on it, listen, write down exactly what they say, and say {{contact_name}} will get back to them. Do not discuss the details yourself.
5. If they want the invoice again, say {{business_name}} will resend it with its payment link. Never read out links or account numbers on the call.
6. Before you end, repeat back what they said (the date they will pay, or that they paid, or their query), thank them and end.
Be courteous throughout. Never threaten, never mention penalties, legal action or credit reports, and never discuss anyone else's account.
${RULES}`,
    data: {
      will_pay: { type: 'boolean', description: 'True if the customer said they will pay.' },
      promised_date: { type: 'string', description: 'The day or date they said they will pay, in their words, for example "Friday" or "end of the month". Empty if none.' },
      paid_already: { type: 'boolean', description: 'True if they said they have already paid.' },
      paid_how: { type: 'string', description: 'If they said they paid: when and how, in their words. Empty otherwise.' },
      dispute: { type: 'string', description: 'What they disagree with about the invoice, in their words. Empty if nothing.' },
      resend_invoice: { type: 'boolean', description: 'True if they asked for the invoice or payment link to be sent again.' },
      notes: { type: 'string', description: 'Anything else the business should know, in one sentence.' },
    },
    criteria: [{ id: 'answer', name: 'Customer answered', type: 'prompt', conversation_goal_prompt: 'Did the customer say when they will pay, that they have paid, or what they dispute?' }],
  },
  guide_followup: {
    name: 'Counta · onboarding follow-up',
    first: 'Hello {{first_name}}, this is Martina from Counta. You asked me to give you a quick call to help you finish setting up. Is now a good time?',
    maxSecs: 240,
    prompt: FOLLOWUP_PROMPT,
    data: FOLLOWUP_DATA,
    criteria: [{ id: 'helped', name: 'Helped', type: 'prompt', conversation_goal_prompt: 'Did the person agree to finish setting up Counta, or get an answer that helps them finish?' }],
  },
  guide: {
    name: 'Counta · Martina onboarding guide',
    first: 'Hi, I\'m Martina. What\'s your business called?',
    maxSecs: 1500,
    prompt: GUIDE_PROMPT,
    temperature: 0.6,
    web: true,
    tools: GUIDE_TOOLS,
    data: {
      finished_profile: { type: 'boolean', description: 'True if the business profile was submitted in this conversation.' },
      sticking_point: { type: 'string', description: 'Anything that confused or blocked the person, in one sentence. Empty if nothing.' },
    },
    criteria: [{ id: 'progress', name: 'Progress made', type: 'prompt', conversation_goal_prompt: 'Did the person complete at least one onboarding step in this conversation?' }],
  },
  assistant: {
    name: 'Counta · Martina assistant',
    first: 'Hi, Martina here. What can I help you with?',
    maxSecs: 900,
    prompt: ASSISTANT_PROMPT,
    temperature: 0.4,
    web: true,
    tools: [...ASSISTANT_TOOLS, ...GUIDE_TOOLS.filter((t) => t.name === 'celebrate' || t.name === 'set_language')],
    data: {
      answered: { type: 'boolean', description: 'True if Martina answered what the person asked, or prepared what they wanted.' },
      gap: { type: 'string', description: 'Anything the person wanted that Martina could not do, in one sentence. Empty if nothing.' },
    },
    criteria: [{ id: 'helped', name: 'Helped', type: 'prompt', conversation_goal_prompt: 'Did Martina answer the question or prepare what the person asked for, using the tools?' }],
  },
};

// Martina's tools live in the ElevenLabs workspace; each is created once and updated when its definition changes. The guide
// and the assistant share the tools they have in common.
async function ensureTools(list: ToolDef[]): Promise<string[]> {
  const { data: rows } = await admin.from('voice_tools').select('*');
  const ids: string[] = [];
  for (const t of list) {
    const cfg = toolConfig(t);
    const version = hashNum(JSON.stringify(cfg));
    const row = (rows || []).find((r) => r.name === t.name);
    if (row && row.version === version) { ids.push(row.tool_id); continue; }
    let id: string | null = null;
    if (row) {
      try { await xi(`/v1/convai/tools/${row.tool_id}`, { method: 'PATCH', body: JSON.stringify({ tool_config: cfg }) }); id = row.tool_id; } catch (e) {
        if ((e as any).status !== 404) throw e;
      }
    }
    if (!id) id = String((await xi('/v1/convai/tools', { method: 'POST', body: JSON.stringify({ tool_config: cfg }) })).id);
    await admin.from('voice_tools').upsert({ name: t.name, tool_id: id, version, updated_at: new Date().toISOString() });
    ids.push(id);
  }
  return ids;
}

export function agentBody(kind: string, voiceId: string, toolIds: string[] = [], tone = 'calm', model = VOICE_MODELS[0]) {
  const a = AGENTS[kind];
  return {
    name: a.name,
    tags: ['counta'],
    conversation_config: {
      agent: { first_message: a.first, language: 'en',
        prompt: { prompt: a.prompt, temperature: a.temperature ?? 0.3, ...(toolIds.length ? { tool_ids: toolIds } : {}) } },
      conversation: { max_duration_seconds: a.maxSecs },
      turn: { interruption_ignore_terms: IGNORE_WHILE_SPEAKING },
      tts: ttsConfig(tone, model, voiceId),
    },
    platform_settings: {
      data_collection: a.data,
      evaluation: { criteria: a.criteria },
      // Each conversation may use the business's own voice; the guide also gets its opening line and may run as text.
      overrides: { conversation_config_override: { tts: { voice_id: true },
        ...(a.web || kind === 'guide_followup' ? { agent: { first_message: true } } : {}),
        ...(a.web ? { conversation: { text_only: true } } : {}) } },
      // The guide is only started with a token from this function; recordings are not kept and transcripts go after 30 days.
      ...(a.web ? { auth: { enable_auth: true } } : {}),
      privacy: { record_voice: false, retention_days: 30 },
    },
  };
}

// The same agent without the newer settings, for when ElevenLabs refuses them: first without the words that do not
// interrupt her, then without the voice model too. Martina keeps working as she did, and the refusal is logged.
function withoutTurn(b: ReturnType<typeof agentBody>) {
  const { turn: _turn, ...cc } = b.conversation_config;
  return { ...b, conversation_config: cc };
}
function plainBody(b: ReturnType<typeof agentBody>) {
  const cc = withoutTurn(b).conversation_config;
  const { model_id: _m, ...tts } = cc.tts as Record<string, unknown>;
  return { ...b, conversation_config: { ...cc, tts } };
}

async function ensureAgent(kind: string): Promise<string> {
  const voiceId = await defaultVoice();
  const toolIds = AGENTS[kind].tools ? await ensureTools(AGENTS[kind].tools!) : [];
  const m = (await platform())?.martina || {};
  const bodyObj = agentBody(kind, voiceId, toolIds, String(m.tone || 'calm'), String(m.voice_model || VOICE_MODELS[0]));
  const body = JSON.stringify(bodyObj);
  const version = AGENT_VERSION * 100000 + hashNum(body);
  const { data: row } = await admin.from('voice_agents').select('*').eq('kind', kind).maybeSingle();
  if (row && row.version === version) return row.agent_id;
  // Sends the agent (update or create), falling back to the plain one if ElevenLabs refuses the settings as invalid.
  const send = async (path: string, method: string) => {
    const tries = [body, JSON.stringify(withoutTurn(bodyObj)), JSON.stringify(plainBody(bodyObj))];
    for (let i = 0; ; i++) {
      try { return await xi(path, { method, body: tries[i] }); } catch (e) {
        const st = (e as any).status;
        if ((st !== 400 && st !== 422) || i === tries.length - 1) throw e;
        console.error('voice agent settings refused, trying with fewer', kind, i, String((e as Error).message).slice(0, 300));
      }
    }
  };
  if (row) {
    try {
      await send(`/v1/convai/agents/${row.agent_id}`, 'PATCH');
      await admin.from('voice_agents').update({ version, updated_at: new Date().toISOString() }).eq('kind', kind);
      return row.agent_id;
    } catch (e) {
      if ((e as any).status !== 404) throw e;
    }
  }
  const created = await send('/v1/convai/agents/create', 'POST');
  await admin.from('voice_agents').upsert({ kind, agent_id: created.agent_id, version, updated_at: new Date().toISOString() });
  return created.agent_id;
}

let phoneCache: { at: number; num: any } | null = null;
async function phoneNumber(): Promise<any> {
  if (phoneCache && Date.now() - phoneCache.at < 5 * 60_000) return phoneCache.num;
  const wanted = await secret('ELEVENLABS_PHONE_NUMBER_ID');
  const list = await xi('/v1/convai/phone-numbers');
  const nums: any[] = Array.isArray(list) ? list : list?.phone_numbers || [];
  const num = (wanted && nums.find((n) => n.phone_number_id === wanted))
    || nums.find((n) => n.provider === 'twilio' || n.provider === 'sip_trunk') || nums[0] || null;
  // Only a number found is remembered, so a number connected a minute ago is seen at once.
  phoneCache = num ? { at: Date.now(), num } : null;
  return num;
}

async function ready(): Promise<{ ok: true; num: any } | { ok: false; error: string }> {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, error: NOT_CONFIGURED };
  const num = await phoneNumber();
  if (!num) return { ok: false, error: 'Phone calls are not switched on yet: TaxStreem has not connected a phone number.' };
  return { ok: true, num };
}

// ------------------------------------------------------------------ calls
// The business's chosen voice, when it has one, so its calls sound like its announcements.
async function businessVoice(orgId: string | null | undefined): Promise<string | null> {
  if (!orgId) return null;
  const { data } = await admin.from('orgs').select('voice_id').eq('id', orgId).maybeSingle();
  return data?.voice_id && VOICE_ID.test(data.voice_id) ? data.voice_id : null;
}

type Kind = 'vendor_order' | 'reminder' | 'guide_followup' | 'tax_deadline' | 'customer_followup';
async function place(kind: Kind, prep: { call_id: string; to_number: string; variables: Record<string, unknown>; voice_id?: string | null }, num: any) {
  try {
    const agentId = await ensureAgent(kind);
    const path = num.provider === 'sip_trunk' ? '/v1/convai/sip-trunk/outbound-call' : '/v1/convai/twilio/outbound-call';
    const { data: call } = await admin.from('voice_calls').select('org_id').eq('id', prep.call_id).maybeSingle();
    const voice = prep.voice_id && VOICE_ID.test(prep.voice_id) ? prep.voice_id : await businessVoice(call?.org_id);
    const r = await xi(path, {
      method: 'POST',
      body: JSON.stringify({
        agent_id: agentId, agent_phone_number_id: num.phone_number_id, to_number: prep.to_number,
        conversation_initiation_client_data: { dynamic_variables: prep.variables,
          ...(voice ? { conversation_config_override: { tts: { voice_id: voice } } } : {}) },
      }),
    });
    if (r?.success === false || !r?.conversation_id) {
      await admin.rpc('voice_call_update', { p_call: prep.call_id, p_patch: { status: 'failed', error: r?.message || 'The phone service did not start the call.' } });
      return { ok: false, call_id: prep.call_id, error: r?.message || 'The phone service did not start the call.' };
    }
    await admin.rpc('voice_call_update', { p_call: prep.call_id, p_patch: { status: 'ringing', conversation_id: r.conversation_id, call_sid: r.callSid || r.sip_call_id || null } });
    return { ok: true, call_id: prep.call_id, conversation_id: r.conversation_id, to_number: prep.to_number };
  } catch (e) {
    const msg = (e as Error).message;
    await admin.rpc('voice_call_update', { p_call: prep.call_id, p_patch: { status: 'failed', error: msg } });
    return { ok: false, call_id: prep.call_id, error: msg };
  }
}

const FINAL = ['completed', 'no_answer', 'busy', 'voicemail', 'failed'];

async function syncCall(call: any) {
  if (FINAL.includes(call.status)) return call.status;
  // Queued for calling hours by the morning alerts: not placed yet, so there is nothing to ask ElevenLabs.
  if (!call.conversation_id && call.status === 'queued' && call.call_after) return call.status;
  if (!call.conversation_id) {
    if (Date.now() - new Date(call.created_at).getTime() > 30 * 60_000) {
      await admin.rpc('voice_call_update', { p_call: call.id, p_patch: { status: 'failed', error: 'The call never started.' } });
      return 'failed';
    }
    return call.status;
  }
  let c: any;
  try { c = await xi(`/v1/convai/conversations/${call.conversation_id}`); } catch (e) {
    if ((e as any).status === 404 && Date.now() - new Date(call.created_at).getTime() > 60 * 60_000) {
      await admin.rpc('voice_call_update', { p_call: call.id, p_patch: { status: 'failed', error: 'ElevenLabs has no record of this call.' } });
      return 'failed';
    }
    throw e;
  }
  const result = c?.metadata?.phone_call?.call_result as string | undefined;
  let status: string = call.status;
  if (c.status === 'initiated') status = 'ringing';
  else if (c.status === 'in-progress') status = 'in_progress';
  else if (c.status === 'processing') status = 'processing';
  else if (c.status === 'done') status = result && result !== 'answered' ? (result === 'failed' ? 'failed' : result) : 'completed';
  else if (c.status === 'failed') status = result === 'no_answer' || result === 'busy' || result === 'voicemail' ? result : 'failed';
  if (status === 'completed' && !(c.transcript || []).some((t: any) => t.role === 'user' && t.message)) status = 'no_answer';
  const outcome: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(c?.analysis?.data_collection_results || {})) outcome[k] = (v as any)?.value ?? null;
  const transcript = (c.transcript || []).filter((t: any) => t.message).slice(0, 80)
    .map((t: any) => ({ role: t.role, text: String(t.message).slice(0, 500), t: t.time_in_call_secs }));
  const patch: Record<string, unknown> = { status, duration_secs: c?.metadata?.call_duration_secs ?? null };
  if (FINAL.includes(status)) {
    patch.outcome = outcome;
    patch.transcript = transcript;
    patch.summary = c?.analysis?.transcript_summary || null;
    if (status === 'failed') patch.error = c?.metadata?.error?.message || c?.metadata?.termination_reason || 'The call failed.';
  }
  await admin.rpc('voice_call_update', { p_call: call.id, p_patch: patch });
  return status;
}

// The people who asked Martina to call when they stopped part-way, within the hours the database allows.
async function guideFollowups() {
  const r = await ready();
  if (!r.ok) return { ok: false, reason: 'not_configured', error: r.error };
  const { data: due, error } = await admin.rpc('svc_guide_followups_due', { p_limit: 10 });
  if (error) return { ok: false, error: error.message };
  const out: unknown[] = [];
  for (const d of (due as any[]) || []) {
    // The follow-up agent speaks in the business's own words too (revenue and clients for a law firm, sales and customers for a shop).
    d.variables = { ...(d.variables || {}), wording: wordingNote(await businessWords(d.org_id || null, null)) };
    out.push(await place('guide_followup', d, r.num));
  }
  return { ok: true, placed: out };
}

// The calls the morning alerts queued, now inside calling hours (the database decides which are due and moves the rest on).
async function placeDue() {
  // Checked first, so calls are not taken off the queue when they cannot be placed.
  const r = await ready();
  if (!r.ok) return { ok: false, reason: 'not_configured', error: r.error };
  const { data: due, error } = await admin.rpc('svc_calls_due', { p_limit: 10 });
  if (error) return { ok: false, error: error.message };
  const out: unknown[] = [];
  for (const d of (due as any[]) || []) {
    if (d.kind !== 'tax_deadline' && d.kind !== 'customer_followup') continue;
    out.push(await place(d.kind, { call_id: d.call_id, to_number: d.to_number, variables: d.variables || {} }, r.num));
  }
  return { ok: true, placed: out };
}

// ------------------------------------------------------------------ the guide
const lagosToday = () => new Date(Date.now() + 3600_000).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });

// Voice runs over WebRTC with a conversation token; typing only (no microphone, or the person prefers it) over a
// websocket with a signed URL. Both expire within minutes and only start this agent.
async function startToken(agentId: string, userId: string, textOnly: boolean) {
  const t = textOnly
    ? await xi(`/v1/convai/conversation/get-signed-url?${new URLSearchParams({ agent_id: agentId })}`)
    : await xi(`/v1/convai/conversation/token?${new URLSearchParams({ agent_id: agentId, participant_name: userId })}`);
  if (textOnly ? !t?.signed_url : !t?.token) return null;
  return t;
}

// The business's words and kind, from what it recorded (or what the person answered in onboarding so far).
async function businessWords(orgId: string | null, answers?: any) {
  const { data: o } = orgId ? await admin.from('orgs').select('offering, category_id').eq('id', orgId).maybeSingle() : { data: null };
  const offering = o?.offering || answers?.offering || null;
  const category_id = o?.category_id || answers?.category || null;
  const { data: c } = category_id ? await admin.from('business_categories').select('label').eq('id', category_id).maybeSingle() : { data: null };
  return { offering, category_id, category_label: c?.label || null };
}

async function guideToken(sb: SupabaseClient, userId: string, textOnly = false, orgId: string | null = null) {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, reason: 'not_configured', error: VOICE_OFF };
  // The business the person has open (they must belong to it), else the newest one they own.
  const { data: g, error } = await sb.rpc('guide_state', orgId ? { p_org: orgId } : {});
  if (error) return { ok: false, error: error.message };
  if (!(await featureOn(g?.org?.id || null, 'martina'))) return { ok: false, reason: 'paused', error: MARTINA_OFF };
  const { data: k } = await sb.rpc('kyc_draft', g?.org?.id && g.org.is_owner ? { p_org: g.org.id } : {});
  const { data: session } = await admin.rpc('svc_guide_session', { p_user: userId, p_kind: 'guide' });
  if (!session) return { ok: false, reason: 'limit', error: 'You have talked with Martina a lot today. Carry on by typing, or come back tomorrow.' };
  const agentId = await ensureAgent('guide');
  const t = await startToken(agentId, userId, textOnly);
  if (!t) return { ok: false, error: 'Martina is not available just now. Try again in a minute.' };
  if (t.conversation_id) await admin.rpc('svc_guide_session_set', { p_session: session, p_conversation: String(t.conversation_id) });
  const lang = g?.language === 'pcm' ? 'pcm' : 'en';
  const voice = g?.org?.voice_id && VOICE_ID.test(g.org.voice_id) ? g.org.voice_id : await defaultVoice();
  const next = String(g?.next || '');
  const phase = (g?.steps || []).find((s: any) => s.id === next)?.phase;
  const bw = await businessWords(g?.org?.id || null, k?.answers);
  const dynamic_variables = {
    first_name: String(g?.first_name || '').slice(0, 40) || 'friend',
    business_name: String(g?.org?.name || k?.business?.name || 'not found yet').slice(0, 120),
    stage: g?.completed ? 'all done' : phase === 'first_steps' ? 'first steps in Counta' : 'setting up the business profile',
    next_step: next ? stepLabel(next, 'en', bw.offering) : 'nothing left',
    steps_done: Number(g?.done || 0),
    steps_total: Number(g?.total || 0),
    language_style: lang === 'pcm' ? 'pidgin' : 'english',
    returning: g?.marks?.intro_heard || Number(g?.done || 0) > 0 ? 'yes' : 'no',
    what_we_know: whatWeKnow(k),
    wording: wordingNote(bw),
    today: lagosToday(),
  };
  return {
    ok: true, agent: 'guide', ...(textOnly ? { signed_url: t.signed_url } : { token: t.token }), conversation_id: t.conversation_id || null, agent_id: agentId,
    session_id: session, language: lang, text_only: textOnly,
    dynamic_variables,
    overrides: { agent: { firstMessage: firstMessage(g, lang, bw.offering) }, ...(voice && !textOnly ? { tts: { voiceId: voice } } : {}),
      ...(textOnly ? { conversation: { textOnly: true } } : {}) },
  };
}

// Martina for everyday work in a business the person belongs to, told what their role allows.
async function assistantToken(sb: SupabaseClient, userId: string, textOnly: boolean, orgId: string | null, page: string, hands?: { request: boolean }) {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, reason: 'not_configured', error: VOICE_OFF };
  if (!orgId) return { ok: false, error: 'Open a business first.' };
  if (!(await featureOn(orgId, 'martina'))) return { ok: false, reason: 'paused', error: MARTINA_OFF };
  // get_team answers only to a member, with their own permissions.
  const { data: team, error } = await sb.rpc('get_team', { p_org: orgId });
  if (error) return { ok: false, error: error.message };
  const me = (team?.members || []).find((m: any) => m.is_me) || {};
  const perms: Record<string, boolean> = team?.my_perms || {};
  const { data: org } = await admin.from('orgs').select('name, voice_id, voice_lang').eq('id', orgId).maybeSingle();
  const { data: session } = await admin.rpc('svc_guide_session', { p_user: userId, p_kind: 'assistant' });
  if (!session) return { ok: false, reason: 'limit', error: 'You have talked with Martina a lot today. Come back tomorrow.' };
  const agentId = await ensureAgent('assistant');
  const t = await startToken(agentId, userId, textOnly);
  if (!t) return { ok: false, error: 'Martina is not available just now. Try again in a minute.' };
  if (t.conversation_id) await admin.rpc('svc_guide_session_set', { p_session: session, p_conversation: String(t.conversation_id) });
  const lang = org?.voice_lang === 'pcm' ? 'pcm' : 'en';
  const voice = org?.voice_id && VOICE_ID.test(org.voice_id) ? org.voice_id : await defaultVoice();
  const bw = await businessWords(orgId);
  const first = String(me.display_name || '').trim().split(/\s+/)[0] || 'friend';
  const can = Object.keys(PERM_WORDS).filter((k) => perms[k]).map((k) => PERM_WORDS[k]);
  const cannot = Object.keys(PERM_WORDS).filter((k) => !perms[k]).map((k) => PERM_WORDS[k]);
  const where = String(page || '').toLowerCase().replace(/[^a-z_ -]/g, '').slice(0, 40) || 'home';
  const dynamic_variables = {
    first_name: first.slice(0, 40), role: String(me.role_label || me.role || 'team member').slice(0, 30),
    business_name: String(org?.name || 'the business').slice(0, 120),
    can_do: can.length ? can.join('; ') : 'look things up',
    cannot_do: cannot.length ? cannot.join('; ') : 'nothing: they hold every permission',
    wording: wordingNote(bw), language_style: lang === 'pcm' ? 'pidgin' : 'english',
    channel: textOnly ? 'typing' : hands ? 'hands-free voice' : 'voice', page: where, today: lagosToday(),
  };
  return {
    ok: true, agent: 'assistant', ...(textOnly ? { signed_url: t.signed_url } : { token: t.token }), conversation_id: t.conversation_id || null, agent_id: agentId,
    session_id: session, language: lang, text_only: textOnly, dynamic_variables,
    overrides: { agent: { firstMessage: hands && !textOnly ? handsFreeFirst(first, lang, hands.request) : assistantFirst(first, lang, where.split(/[ /]/)[0], wordsFor(bw)) },
      ...(voice && !textOnly ? { tts: { voiceId: voice } } : {}),
      ...(textOnly ? { conversation: { textOnly: true } } : {}) },
  };
}

// True when ElevenLabs says the conversation is with Martina (the guide or the assistant). A conversation ElevenLabs does
// not know is not queued; a passing error queues it, and the schedule tries again.
async function martinaConversation(id: string): Promise<boolean> {
  const { data: rows } = await admin.from('voice_agents').select('agent_id').in('kind', ['guide', 'assistant']);
  const ours = new Set((rows || []).map((r: any) => r.agent_id));
  try {
    const c = await xi(`/v1/convai/conversations/${encodeURIComponent(id)}`);
    return ours.has(c?.agent_id);
  } catch (e) {
    return (e as any).status !== 404 && (e as any).status !== 400 && (e as any).status !== 422;
  }
}

// Conversations in which an NIN was said are deleted from ElevenLabs. One person's now, or everyone's due on the schedule.
async function forgetConversations(userId: string | null) {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: true, deleted: 0 };
  const { data: ids } = await admin.rpc('svc_forget_due', { p_user: userId, p_limit: 20 });
  let deleted = 0;
  for (const id of (ids as string[]) || []) {
    let ok = false;
    try { await xi(`/v1/convai/conversations/${encodeURIComponent(id)}`, { method: 'DELETE' }); ok = true; }
    catch (e) { ok = (e as any).status === 404; if (!ok) console.warn('forget', id, (e as Error).message); }
    await admin.rpc('svc_forget_done', { p_conversation: id, p_ok: ok });
    if (ok) deleted++;
  }
  return { ok: true, deleted };
}

// ------------------------------------------------------------------ the admin portal
// Voices in the ElevenLabs library TaxStreem may add to the list on offer, and adding one.
async function isAdmin(sb: SupabaseClient) {
  const { data } = await sb.rpc('admin_me');
  return Boolean(data?.admin && data?.aal2);
}
async function libraryVoices(body: any) {
  const gender = ['female', 'male'].includes(body.gender) ? body.gender : '';
  const accent = /^[a-z -]{2,30}$/.test(String(body.accent || '')) ? String(body.accent) : 'nigerian';
  const q = new URLSearchParams({ accent, language: 'en', sort: 'usage_character_count_1y', page_size: '24', include_custom_rates: 'false', include_live_moderated: 'false',
    ...(gender ? { gender } : {}), ...(body.search ? { search: String(body.search).slice(0, 40) } : {}) });
  const list = await xi(`/v1/shared-voices?${q}`);
  const { data: have } = await admin.from('tts_voices').select('voice_id, owner_id, name');
  const voices = (Array.isArray(list?.voices) ? list.voices : []).filter((v: any) => VOICE_ID.test(String(v?.voice_id || '')) && v?.public_owner_id)
    .map((v: any) => ({ voice_id: v.voice_id, public_owner_id: v.public_owner_id, name: shortName(v.name), gender: v.gender ?? null, age: v.age ?? null,
      accent: v.accent ?? null, description: String(v.description || v.descriptive || '').slice(0, 200) || null, preview_url: v.preview_url ?? null,
      added: (have || []).some((h: any) => h.owner_id === v.public_owner_id && h.voice_id === v.voice_id) }));
  return { ok: true, voices };
}
async function addLibraryVoice(body: any) {
  const owner = String(body.public_owner_id || ''), id = String(body.voice_id || '');
  if (!/^[A-Za-z0-9]{8,80}$/.test(owner) || !VOICE_ID.test(id)) return { ok: false, error: 'Choose a voice from the library.' };
  const name = shortName(body.name);
  const added = await xi(`/v1/voices/add/${encodeURIComponent(owner)}/${encodeURIComponent(id)}`, { method: 'POST', body: JSON.stringify({ new_name: `Counta ${name}` }) });
  const vid = String(added?.voice_id || id);
  if (!VOICE_ID.test(vid)) return { ok: false, error: 'ElevenLabs did not add the voice.' };
  const { data: last } = await admin.from('tts_voices').select('sort').order('sort', { ascending: false }).limit(1).maybeSingle();
  const row = { voice_id: vid, name, gender: ['female', 'male'].includes(body.gender) ? body.gender : null, age: body.age ? String(body.age).slice(0, 20) : null,
    accent: body.accent ? String(body.accent).slice(0, 30) : 'nigerian', description: body.description ? String(body.description).slice(0, 200) : null,
    preview_url: /^https:\/\//.test(String(body.preview_url || '')) ? String(body.preview_url) : null, source: 'library', owner_id: owner,
    sort: Number(last?.sort || 0) + 1, active: true, updated_at: new Date().toISOString() };
  const { error } = await admin.from('tts_voices').upsert(row, { onConflict: 'voice_id' });
  if (error) return { ok: false, error: error.message };
  return { ok: true, voice: row };
}

// ------------------------------------------------------------------ handler
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const hook = req.headers.get('x-counta-hook');
    if (hook) {
      const expected = await secret('PUSH_HOOK_SECRET');
      if (!expected || !sameSecret(hook, expected)) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.action === 'guide_followups') {
        const calls = await guideFollowups();
        return json({ ...calls, forgotten: (await forgetConversations(null).catch(() => ({ deleted: 0 }))).deleted });
      }
      if (body.action === 'forget_pending') return json(await forgetConversations(null));
      if (body.action === 'place_due') return json(await placeDue());
      if (body.action === 'refresh_voices') return json({ ok: true, ...(await refreshVoices()) });
      if (body.action !== 'sync_pending') return json({ ok: false, error: 'Unknown action.' }, 400);
      const since = new Date(Date.now() - 3 * 3600_000).toISOString();
      const { data: calls } = await admin.from('voice_calls').select('*').in('status', ['queued', 'ringing', 'in_progress', 'processing']).gte('created_at', since).limit(20);
      const out: Record<string, string> = {};
      for (const c of calls || []) { try { out[c.id] = await syncCall(c); } catch (e) { out[c.id] = 'error: ' + (e as Error).message; } }
      return json({ ok: true, synced: out });
    }

    const sb: SupabaseClient = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);

    switch (body.action) {
      case 'status': {
        const key = Boolean(await secret('ELEVENLABS_API_KEY'));
        if (!key) return json({ ok: true, configured: false, voices: false, reason: 'no_key', message: NOT_CONFIGURED });
        try {
          const num = await phoneNumber();
          return json({ ok: true, configured: Boolean(num), voices: true, reason: num ? null : 'no_number', phone: num ? { label: num.label, number: num.phone_number, provider: num.provider } : null });
        } catch (e) {
          return json({ ok: true, configured: false, voices: true, reason: 'error', message: (e as Error).message });
        }
      }
      case 'voices': {
        if (!(await secret('ELEVENLABS_API_KEY'))) return json({ ok: true, configured: false, voices: [] });
        let voices = await activeVoices();
        // The first time anyone asks, the Nigerian voices are fetched from the voice library (at most every ten minutes).
        if (!voices.length && Date.now() - refreshedAt > 10 * 60_000) {
          try { await refreshVoices(); voices = await activeVoices(); } catch (e) { console.warn('voices', (e as Error).message); }
        }
        return json({ ok: true, configured: true, voices });
      }
      case 'speak':
        return json(await speak(sb, u.user.id, body));
      case 'guide_token':
        return json(await guideToken(sb, u.user.id, body.text === true, typeof body.org_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.org_id) ? body.org_id : null));
      case 'assistant_token':
        return json(await assistantToken(sb, u.user.id, body.text === true, typeof body.org_id === 'string' && /^[0-9a-f-]{36}$/i.test(body.org_id) ? body.org_id : null,
          String(body.page || ''), body.hands_free === true ? { request: body.has_request === true } : undefined));
      case 'forget': {
        // The app names the conversation in which an NIN was typed or said; it must be one of Martina's own.
        const conv = typeof body.conversation_id === 'string' && /^[A-Za-z0-9_-]{6,80}$/.test(body.conversation_id) ? body.conversation_id : null;
        if (conv && (await martinaConversation(conv))) await admin.rpc('svc_forget_add', { p_user: u.user.id, p_conversation: conv });
        return json(await forgetConversations(u.user.id));
      }
      case 'call_vendor': {
        const r = await ready();
        if (!r.ok) return json({ ok: false, reason: 'not_configured', error: r.error });
        const { data: prep, error } = await sb.rpc('prepare_vendor_call', { p_po: body.po_id });
        if (error) return json({ ok: false, error: error.message });
        return json(await place('vendor_order', prep, r.num));
      }
      case 'call_member': {
        const r = await ready();
        if (!r.ok) return json({ ok: false, reason: 'not_configured', error: r.error });
        const { data: prep, error } = await sb.rpc('prepare_reminder_call', { p_member: body.member_id, p_topic: body.topic });
        if (error) return json({ ok: false, error: error.message });
        return json(await place('reminder', prep, r.num));
      }
      case 'admin_library':
        if (!(await isAdmin(sb))) return json({ ok: false, error: 'This is only for TaxStreem\'s admins.' }, 403);
        return json(await libraryVoices(body));
      case 'admin_add_voice':
        if (!(await isAdmin(sb))) return json({ ok: false, error: 'This is only for TaxStreem\'s admins.' }, 403);
        return json(await addLibraryVoice(body));
      case 'sync': {
        const { data: call } = await sb.from('voice_calls').select('*').eq('id', body.call_id).maybeSingle();
        if (!call) return json({ ok: false, error: 'Call not found.' }, 404);
        const status = await syncCall(call);
        const { data: fresh } = await sb.from('voice_calls').select('*').eq('id', call.id).maybeSingle();
        return json({ ok: true, status, call: fresh });
      }
      default:
        return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    if (e instanceof NotConfigured) return json({ ok: false, reason: 'not_configured', error: e.message });
    console.error(e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
