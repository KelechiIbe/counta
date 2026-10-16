// Counta FX: keeps a daily USD/NGN rate for the reorder timing advice.
// Latest rate from open.er-api.com; missing recent days back-filled from the fawazahmed0 currency API.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function rateOn(day: string): Promise<number | null> {
  for (const url of [
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const auth = req.headers.get('Authorization') || '';
  const user = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await user.auth.getUser();
  if (!u?.user) return json({ ok: false, error: 'Sign in first.' }, 401);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const today = new Date().toISOString().slice(0, 10);
  const { data: have } = await admin.from('fx_rates').select('day').gte('day', new Date(Date.now() - 15 * 864e5).toISOString().slice(0, 10));
  const got = new Set((have || []).map((r: any) => r.day));
  const rows: { day: string; usd_ngn: number; source: string }[] = [];

  if (!got.has(today)) {
    try {
      const r = await fetch('https://open.er-api.com/v6/latest/USD');
      const j = await r.json();
      const v = Number(j?.rates?.NGN);
      if (v > 0) rows.push({ day: today, usd_ngn: v, source: 'open.er-api.com' });
    } catch { /* fall back below */ }
    if (!rows.length) { const v = await rateOn(today); if (v) rows.push({ day: today, usd_ngn: v, source: 'currency-api' }); }
  }
  for (let i = 1; i <= 14; i++) {
    const day = new Date(Date.now() - i * 864e5).toISOString().slice(0, 10);
    if (got.has(day)) continue;
    const v = await rateOn(day);
    if (v) rows.push({ day, usd_ngn: v, source: 'currency-api' });
  }
  if (rows.length) await admin.from('fx_rates').upsert(rows, { onConflict: 'day' });
  return json({ ok: true, added: rows.length });
});
