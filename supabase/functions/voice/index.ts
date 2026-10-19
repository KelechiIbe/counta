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
//
// Secrets: ELEVENLABS_API_KEY (Edge Function secret or Vault). Optional: ELEVENLABS_VOICE_IDS (comma-separated voice ids to
// offer instead of searching the voice library for Nigerian voices), ELEVENLABS_VOICE_ID (Martina's default voice),
// ELEVENLABS_TTS_MODEL (announcements; default eleven_flash_v2_5), ELEVENLABS_PHONE_NUMBER_ID (the number calls come from
// when there are several). ELEVENLABS_BASE_URL is for tests.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';
import { FOLLOWUP_DATA, FOLLOWUP_PROMPT, firstMessage, GUIDE_PROMPT, GUIDE_TOOLS, stepLabel, toolConfig, type ToolDef, whatWeKnow } from './guide.ts';
import { ASSISTANT_PROMPT, ASSISTANT_TOOLS, assistantFirst, PERM_WORDS } from './assistant.ts';
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
const NOT_CONFIGURED = 'Phone calls are not switched on yet. Add the ElevenLabs API key and connect a phone number in ElevenLabs.';
const VOICE_OFF = 'Nigerian voices are not switched on yet. Add the ElevenLabs API key to the Supabase Edge Function secrets.';

const secrets = new Map<string, { v: string; at: number }>();
async function secret(name: string): Promise<string> {
  const env = Deno.env.get(name);
  if (env) return env.trim();
  const hit = secrets.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('app_secret', { p_name: name });
  const v = typeof data === 'string' ? data.trim() : '';
  secrets.set(name, { v, at: Date.now() });
  return v;
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
    const { data: have } = await admin.from('tts_voices').select('voice_id, owner_id');
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
  const { error } = await admin.from('tts_voices').upsert(rows.map((r) => ({ ...r, updated_at: now })), { onConflict: 'voice_id' });
  if (error) throw new Error(error.message);
  // Voices no longer offered stay on record (a business may still use one) but are not offered to new choices.
  await admin.from('tts_voices').update({ active: false, updated_at: now }).not('voice_id', 'in', `(${rows.map((r) => r.voice_id).join(',')})`);
  return { added: rows.length, voices: rows.length };
}

async function activeVoices() {
  const { data } = await admin.from('tts_voices').select('voice_id, name, gender, age, accent, description, sort').eq('active', true).order('sort');
  return data || [];
}
// Martina's voice when a business has not chosen one: ELEVENLABS_VOICE_ID, else the first Nigerian voice.
async function defaultVoice(): Promise<string> {
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
If the person is busy or asks you to call back, ask for a good time, thank them and end the call.`;

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
    first: 'Hi! I am Martina, your Counta guide. What is your business called?',
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
    first: 'Hi! Martina here. What can I help you with?',
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

function agentBody(kind: string, voiceId: string, toolIds: string[] = []) {
  const a = AGENTS[kind];
  return {
    name: a.name,
    tags: ['counta'],
    conversation_config: {
      agent: { first_message: a.first, language: 'en',
        prompt: { prompt: a.prompt, temperature: a.temperature ?? 0.3, ...(toolIds.length ? { tool_ids: toolIds } : {}) } },
      conversation: { max_duration_seconds: a.maxSecs },
      ...(voiceId ? { tts: { voice_id: voiceId } } : {}),
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

async function ensureAgent(kind: string): Promise<string> {
  const voiceId = await defaultVoice();
  const toolIds = AGENTS[kind].tools ? await ensureTools(AGENTS[kind].tools!) : [];
  const bodyObj = agentBody(kind, voiceId, toolIds);
  const body = JSON.stringify(bodyObj);
  const version = AGENT_VERSION * 100000 + hashNum(body);
  const { data: row } = await admin.from('voice_agents').select('*').eq('kind', kind).maybeSingle();
  if (row && row.version === version) return row.agent_id;
  if (row) {
    try {
      await xi(`/v1/convai/agents/${row.agent_id}`, { method: 'PATCH', body });
      await admin.from('voice_agents').update({ version, updated_at: new Date().toISOString() }).eq('kind', kind);
      return row.agent_id;
    } catch (e) {
      if ((e as any).status !== 404) throw e;
    }
  }
  const created = await xi('/v1/convai/agents/create', { method: 'POST', body });
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
  if (!num) return { ok: false, error: 'The ElevenLabs account has no phone number yet. Connect a Twilio number (or a SIP trunk) under Phone Numbers in ElevenLabs.' };
  return { ok: true, num };
}

// ------------------------------------------------------------------ calls
// The business's chosen voice, when it has one, so its calls sound like its announcements.
async function businessVoice(orgId: string | null | undefined): Promise<string | null> {
  if (!orgId) return null;
  const { data } = await admin.from('orgs').select('voice_id').eq('id', orgId).maybeSingle();
  return data?.voice_id && VOICE_ID.test(data.voice_id) ? data.voice_id : null;
}

type Kind = 'vendor_order' | 'reminder' | 'guide_followup';
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
async function assistantToken(sb: SupabaseClient, userId: string, textOnly: boolean, orgId: string | null, page: string) {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, reason: 'not_configured', error: VOICE_OFF };
  if (!orgId) return { ok: false, error: 'Open a business first.' };
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
    channel: textOnly ? 'typing' : 'voice', page: where, today: lagosToday(),
  };
  return {
    ok: true, agent: 'assistant', ...(textOnly ? { signed_url: t.signed_url } : { token: t.token }), conversation_id: t.conversation_id || null, agent_id: agentId,
    session_id: session, language: lang, text_only: textOnly, dynamic_variables,
    overrides: { agent: { firstMessage: assistantFirst(first, lang, where.split(/[ /]/)[0], wordsFor(bw)) }, ...(voice && !textOnly ? { tts: { voiceId: voice } } : {}),
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
          String(body.page || '')));
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
