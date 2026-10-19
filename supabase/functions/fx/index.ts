// Counta FX: keeps daily exchange rates. The dollar rate feeds the reorder timing advice (fx_rates, with recent days
// back-filled); every currency TaxStreem allows in the admin portal gets the day's rate in exchange_rates. A rate set by hand
// in the portal is never overwritten.
// Latest rates from open.er-api.com; missing recent dollar days from the fawazahmed0 currency API.
// Callers: a signed-in person (the app asks when its rate is stale), or the database's daily schedule (x-counta-hook).
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-counta-hook',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const ER_API = Deno.env.get('ER_API_URL') || 'https://open.er-api.com/v6/latest/USD';

// FX_HISTORY_URL (with {day}) is for tests.
const HISTORY = Deno.env.get('FX_HISTORY_URL');
async function rateOn(day: string): Promise<number | null> {
  for (const url of HISTORY ? [HISTORY.replace('{day}', day)] : [
    `https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@${day}/v1/currencies/usd.json`,
    `https://${day}.currency-api.pages.dev/v1/currencies/usd.json`,
  ]) {
    try {
      const r = await fetch(url);
      if (!r.ok) continue;
      const j = await r.json();
      const v = Number(j?.usd?.ngn);
      if (v > 0) return v;
    } catch { /* try next */ }
  }
  return null;
}

function same(a: string, b: string) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const hook = req.headers.get('x-counta-hook') || '';
  if (hook) {
    let expected = (Deno.env.get('PUSH_HOOK_SECRET') || '').trim();
    if (!expected) { const { data } = await admin.rpc('app_secret', { p_name: 'PUSH_HOOK_SECRET' }); expected = typeof data === 'string' ? data.trim() : ''; }
    if (!expected || !same(hook, expected)) return json({ ok: false, error: 'Not allowed.' }, 401);
  } else {
    const auth = req.headers.get('Authorization') || '';
    const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await user.auth.getUser();
    if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
  }

  const today = new Date(Date.now() + 3600_000).toISOString().slice(0, 10);
  const { data: have } = await admin.from('fx_rates').select('day').gte('day', new Date(Date.now() - 15 * 864e5).toISOString().slice(0, 10));
  const got = new Set((have || []).map((r: any) => r.day));
  const rows: { day: string; usd_ngn: number; source: string }[] = [];

  // Today's rates for every currency, as naira for one unit.
  let latest: Record<string, number> = {};
  try {
    const r = await fetch(ER_API);
    const j = await r.json();
    if (j?.rates && Number(j.rates.NGN) > 0) latest = j.rates;
  } catch { /* fall back below */ }
  const ngnPerUsd = Number(latest.NGN) || 0;
  const { data: wanted } = await admin.rpc('svc_fx_currencies');
  const codes: string[] = Array.isArray(wanted) && wanted.length ? wanted : ['USD'];
  const day: Record<string, number> = {};
  for (const c of codes) {
    if (c === 'USD' && ngnPerUsd > 0) day.USD = ngnPerUsd;
    else if (ngnPerUsd > 0 && Number(latest[c]) > 0) day[c] = Math.round((ngnPerUsd / Number(latest[c])) * 1e6) / 1e6;
  }
  let saved = 0;
  if (Object.keys(day).length) {
    const { data: n } = await admin.rpc('svc_save_rates', { p_day: today, p_rates: day });
    saved = Number(n) || 0;
  }

  if (!got.has(today)) {
    if (ngnPerUsd > 0) rows.push({ day: today, usd_ngn: ngnPerUsd, source: 'open.er-api.com' });
    if (!rows.length) { const v = await rateOn(today); if (v) rows.push({ day: today, usd_ngn: v, source: 'currency-api' }); }
  }
  for (let i = 1; i <= 14; i++) {
    const d = new Date(Date.now() + 3600_000 - i * 864e5).toISOString().slice(0, 10);
    if (got.has(d)) continue;
    const v = await rateOn(d);
    if (v) rows.push({ day: d, usd_ngn: v, source: 'currency-api' });
  }
  // Days already kept (a rate set by hand among them) are left as they are.
  if (rows.length) await admin.from('fx_rates').upsert(rows, { onConflict: 'day', ignoreDuplicates: true });
  return json({ ok: true, added: rows.length, currencies: saved, day: today });
});
