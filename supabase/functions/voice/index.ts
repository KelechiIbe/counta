// Counta voice: Martina places phone calls through ElevenLabs Agents.
//
// Signed-in callers (Authorization: Bearer <user JWT>):
//   { action: 'status' }                         -> is calling switched on, which number calls out
//   { action: 'call_vendor', po_id }              -> phones the vendor on a purchase order
//   { action: 'call_member', member_id, topic }   -> phones a team member about waiting work
//   { action: 'sync', call_id }                   -> refreshes one call from ElevenLabs
// Database cron (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'sync_pending' }                    -> refreshes every call still in progress
//
// Needs ELEVENLABS_API_KEY (Edge Function secret or Supabase Vault) and a phone number connected
// to the ElevenLabs account (Twilio or SIP trunk). ELEVENLABS_PHONE_NUMBER_ID picks one number
// when there are several; ELEVENLABS_VOICE_ID sets Martina's voice.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const XI = 'https://api.elevenlabs.io';
const AGENT_VERSION = 1;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const NOT_CONFIGURED = 'Phone calls are not switched on yet. Add the ElevenLabs API key and connect a phone number in ElevenLabs.';

async function secret(name: string): Promise<string> {
  const env = Deno.env.get(name);
  if (env) return env.trim();
  const { data } = await admin.rpc('app_secret', { p_name: name });
  return typeof data === 'string' ? data.trim() : '';
}

class NotConfigured extends Error {}

async function xi(path: string, init: RequestInit = {}): Promise<any> {
  const key = await secret('ELEVENLABS_API_KEY');
  if (!key) throw new NotConfigured(NOT_CONFIGURED);
  const res = await fetch(XI + path, { ...init, headers: { 'xi-api-key': key, 'Content-Type': 'application/json', ...(init.headers || {}) } });
  const text = await res.text();
  let body: any = text;
  try { body = JSON.parse(text); } catch { /* plain text */ }
  if (!res.ok) {
    const detail = typeof body === 'string' ? body : body?.detail?.message || body?.detail?.[0]?.msg || JSON.stringify(body);
    const err = new Error(`ElevenLabs ${res.status}: ${String(detail).slice(0, 300)}`) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return body;
}

// ------------------------------------------------------------------ agents
const RULES = `Speak clear, warm Nigerian English and understand Nigerian Pidgin. Keep sentences short; this is a phone call.
You are an AI assistant. Say so if anyone asks, and never pretend to be a person.
Never ask for or discuss bank details, card numbers, passwords or one-time codes. If payment comes up, say the owner will follow up.
If the person is busy or asks you to call back, ask for a good time, thank them and end the call.`;

const AGENTS: Record<string, { name: string; prompt: string; first: string; maxSecs: number; data: Record<string, unknown>; criteria: unknown[] }> = {
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
};

function hashNum(s: string) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) % 100000; return h; }

function agentBody(kind: string, voiceId: string) {
  const a = AGENTS[kind];
  return {
    name: a.name,
    tags: ['counta'],
    conversation_config: {
      agent: { first_message: a.first, language: 'en', prompt: { prompt: a.prompt, temperature: 0.3 } },
      conversation: { max_duration_seconds: a.maxSecs },
      ...(voiceId ? { tts: { voice_id: voiceId } } : {}),
    },
    platform_settings: { data_collection: a.data, evaluation: { criteria: a.criteria } },
  };
}

async function ensureAgent(kind: string): Promise<string> {
  const voiceId = await secret('ELEVENLABS_VOICE_ID');
  const version = AGENT_VERSION * 100000 + hashNum(voiceId);
  const { data: row } = await admin.from('voice_agents').select('*').eq('kind', kind).maybeSingle();
  const body = JSON.stringify(agentBody(kind, voiceId));
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
  phoneCache = { at: Date.now(), num };
  return num;
}

async function ready(): Promise<{ ok: true; num: any } | { ok: false; error: string }> {
  if (!(await secret('ELEVENLABS_API_KEY'))) return { ok: false, error: NOT_CONFIGURED };
  const num = await phoneNumber();
  if (!num) return { ok: false, error: 'The ElevenLabs account has no phone number yet. Connect a Twilio number (or a SIP trunk) under Phone Numbers in ElevenLabs.' };
  return { ok: true, num };
}

// ------------------------------------------------------------------ calls
async function place(kind: 'vendor_order' | 'reminder', prep: { call_id: string; to_number: string; variables: Record<string, unknown> }, num: any) {
  try {
    const agentId = await ensureAgent(kind);
    const path = num.provider === 'sip_trunk' ? '/v1/convai/sip-trunk/outbound-call' : '/v1/convai/twilio/outbound-call';
    const r = await xi(path, {
      method: 'POST',
      body: JSON.stringify({
        agent_id: agentId, agent_phone_number_id: num.phone_number_id, to_number: prep.to_number,
        conversation_initiation_client_data: { dynamic_variables: prep.variables },
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

// ------------------------------------------------------------------ handler
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const hook = req.headers.get('x-counta-hook');
    if (hook) {
      if (hook !== (await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
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
        if (!key) return json({ ok: true, configured: false, reason: 'no_key', message: NOT_CONFIGURED });
        try {
          const num = await phoneNumber();
          return json({ ok: true, configured: Boolean(num), reason: num ? null : 'no_number', phone: num ? { label: num.label, number: num.phone_number, provider: num.provider } : null });
        } catch (e) {
          return json({ ok: true, configured: false, reason: 'error', message: (e as Error).message });
        }
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
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
