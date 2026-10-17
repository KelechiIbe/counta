// Atlas: the agents that keep Counta's books.
//   Bookkeeper: explains bank and wallet lines that matching, the statutory registry and learned rules could not. Posts what it
//   is sure of (at or above the business's threshold, never below 80%); everything else waits in suspense (9001) with one
//   question for the owner in the books inbox.
//   Analyst: writes the CFO commentary over numbers the database computed (it never computes numbers itself).
//
// Database (header x-counta-hook: <PUSH_HOOK_SECRET>):
//   { action: 'classify_lines', org_id }   -> one business, after new lines arrive
//   { action: 'classify_all' }              -> every business with lines waiting (every three minutes)
// Signed-in callers:
//   { action: 'status' }
//   { action: 'run', org_id }               -> run the bookkeeper now (people who keep the books)
//   { action: 'commentary', org_id, from, to } -> CFO commentary for a period (people who can see the financial reports)
// Gemini runs on Vertex AI with Application Default Credentials (GOOGLE_APPLICATION_CREDENTIALS_JSON, GOOGLE_CLOUD_PROJECT,
// GOOGLE_CLOUD_LOCATION; see google.ts), or with GEMINI_API_KEY when no ADC credential is set. GEMINI_MODEL is optional.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { gemini, S } from './gemini.ts';
import { geminiConfig } from './google.ts';
import { calibrate, type Ctx, SCHEMA, systemPrompt, userPrompt } from './bookkeeper.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const admin = createClient(SUPABASE_URL, SERVICE, { auth: { persistSession: false } });

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const cache = new Map<string, { v: string; at: number }>();
async function secret(name: string): Promise<string> {
  const env = Deno.env.get(name);
  if (env) return env.trim();
  const hit = cache.get(name);
  if (hit && Date.now() - hit.at < 60_000) return hit.v;
  const { data } = await admin.rpc('app_secret', { p_name: name });
  const v = typeof data === 'string' ? data.trim() : '';
  cache.set(name, { v, at: Date.now() });
  return v;
}
async function geminiCfg() {
  return { g: await geminiConfig(secret), model: (await secret('GEMINI_MODEL')) || 'gemini-3.8-flash' };
}
async function svc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
function same(a: string, b: string) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let r = 0;
  for (let i = 0; i < ea.length; i++) r |= ea[i] ^ eb[i];
  return r === 0;
}

// ------------------------------------------------------------------ bookkeeper
const running = new Set<string>();
export async function bookkeep(orgId: string) {
  if (running.has(orgId)) return { org_id: orgId, skipped: 'already running' };
  running.add(orgId);
  const run = { items: 0, posted: 0, asked: 0, model: '', error: null as string | null };
  try {
    const cfg = await geminiCfg();
    if (cfg.g.mode === 'none') {
      // No AI yet: lines older than an hour go to suspense with a question, so nothing sits unexplained.
      run.asked = await svc<number>('svc_suspend_rest', { p_org: orgId });
      run.error = cfg.g.problem || 'Gemini is not connected (GOOGLE_APPLICATION_CREDENTIALS_JSON is not set)';
      return { org_id: orgId, ...run };
    }
    for (let round = 0; round < 5; round++) {
      const ctx = await svc<Ctx>('svc_lines_for_ai', { p_org: orgId, p_limit: 40 });
      if (!ctx?.lines?.length) break;
      let answers;
      try {
        const res = await gemini(cfg, systemPrompt(ctx), userPrompt(ctx), SCHEMA, 0.1);
        run.model = res.model;
        answers = calibrate(ctx, res.data?.results || []);
      } catch (e) {
        run.error = (e as Error).message;
        break;
      }
      const answered = new Set<string>();
      for (const a of answers) {
        if (answered.has(a.line_id)) continue;
        answered.add(a.line_id);
        const r = await svc('svc_classify_line', { p_line: a.line_id, p: { ...a, model: run.model } });
        if (!r?.ok) continue;
        run.items++;
        if (r.posted) run.posted++; else run.asked++;
      }
      // A line the model passed over still gets a question rather than going round again.
      for (const l of ctx.lines) {
        if (answered.has(l.id)) continue;
        const r = await svc('svc_classify_line', { p_line: l.id, p: { account_code: null, confidence: 0, title: l.narration || 'Bank line',
          rationale: 'The bookkeeper could not explain this line', model: run.model } });
        if (r?.ok) { run.items++; run.asked++; }
      }
    }
    if (run.error) run.asked += await svc<number>('svc_suspend_rest', { p_org: orgId });
    return { org_id: orgId, ...run };
  } finally {
    running.delete(orgId);
    await admin.rpc('svc_agent_run', { p_org: orgId, p_agent: 'bookkeeper', p_action: 'classify_lines', p: run });
  }
}

// ------------------------------------------------------------------ analyst
const COMMENTARY = {
  type: 'OBJECT',
  properties: {
    headline: { type: 'STRING', description: 'One sentence, the single most important thing about this period' },
    points: { type: 'ARRAY', items: { type: 'OBJECT', properties: { title: S.str, detail: S.str, tone: { type: 'STRING', enum: ['good', 'watch', 'bad'] } },
      required: ['title', 'detail', 'tone'] } },
    actions: { type: 'ARRAY', items: S.str },
    questions: { type: 'ARRAY', items: S.str },
  },
  required: ['headline', 'points', 'actions'],
};

async function commentary(sb: SupabaseClient, orgId: string, from: string | null, to: string | null) {
  const cfg = await geminiCfg();
  if (cfg.g.mode === 'none') return { ok: false, reason: 'not_configured', error: cfg.g.problem || 'AI commentary is not switched on yet.' };
  const rep = async (report: string) => {
    const { data, error } = await sb.rpc('accounting_report', { p_org: orgId, p_report: report, p_from: from, p_to: to, p_options: {} });
    if (error) throw new Error(error.message);
    return data;
  };
  // The numbers come from the ledger; the reader's own permissions apply.
  const [kpis, sopl, ratios, trends, ar, ap] = await Promise.all([rep('kpis'), rep('sopl'), rep('ratios'), rep('trends'), rep('ar_aging'), rep('ap_aging')]);
  const pack = { period: { from, to }, kpis: kpis.rows, profit_or_loss: sopl.rows, ratios: ratios.rows, last_12_months: trends.rows,
    receivables_ageing: (ar.rows || []).slice(0, 15), payables_ageing: (ap.rows || []).slice(0, 15) };
  const { data, model } = await gemini(cfg, `You are the finance director of a Nigerian business writing the monthly commentary for its owner.
Use only the numbers in the pack; never invent or recompute a figure. Quote naira as ₦ with commas and compare with the prior period or the trend where the pack shows it.
Write for a busy owner: plain words, no jargon, short sentences. Three to six points, at most four actions, and questions only where the numbers raise one.`,
    JSON.stringify(pack), COMMENTARY, 0.3);
  await admin.rpc('svc_agent_run', { p_org: orgId, p_agent: 'analyst', p_action: 'commentary', p: { items: 1, model } });
  return { ok: true, commentary: data, model };
}

// ------------------------------------------------------------------ entry
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ ok: false, error: 'Invalid request.' }, 400); }
  try {
    const hook = req.headers.get('x-counta-hook') || '';
    if (hook) {
      if (!same(hook, await secret('PUSH_HOOK_SECRET'))) return json({ ok: false, error: 'Not allowed.' }, 401);
      if (body.action === 'classify_lines' && body.org_id) return json({ ok: true, result: await bookkeep(String(body.org_id)) });
      if (body.action === 'classify_all') {
        const orgs = ((await svc<string[]>('svc_orgs_with_lines', {})) || []).slice(0, 20);
        const results = [];
        for (const o of orgs) results.push(await bookkeep(o));
        return json({ ok: true, results });
      }
      return json({ ok: false, error: 'Unknown action.' }, 400);
    }

    const sb = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
    const { data: u } = await sb.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
    switch (body.action) {
      case 'status': {
        const cfg = await geminiCfg();
        return json({ ok: true, configured: cfg.g.mode !== 'none', model: cfg.model, auth: cfg.g.mode, problem: cfg.g.problem });
      }
      case 'run': {
        const { data: m } = await sb.from('members').select('role, p_keep_books').eq('org_id', body.org_id).eq('user_id', u.user.id).eq('status', 'active').maybeSingle();
        if (!m || !(m.role === 'owner' || m.p_keep_books)) return json({ ok: false, error: 'Only someone who keeps the books runs the bookkeeper.' });
        return json({ ok: true, result: await bookkeep(String(body.org_id)) });
      }
      case 'commentary': return json(await commentary(sb, String(body.org_id), body.from || null, body.to || null));
      default: return json({ ok: false, error: 'Unknown action.' }, 400);
    }
  } catch (e) {
    console.error('atlas', e);
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});
