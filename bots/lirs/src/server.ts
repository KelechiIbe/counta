// The bot's door on Cloud Run.
//   GET  /health  -> {ok: true}
//   POST /tick    signed with LIRS_BOT_SECRET (x-counta-signature) -> starts working through the jobs waiting and
//                 answers at once {ok, started: true}, or {ok, busy: true} while a tick is already working. With
//                 {"wait": true} in the body it answers when the tick is done: {ok, ran: [{job_id, kind, status}], ms}.
// Counta calls /tick when someone sends a return or asks for a transfer account, and its database every five minutes
// while a job is due (a retry, a payment check). The service runs with CPU always allocated, so the work carries on
// after the answer. A tick works up to BOT_LANES jobs side by side (src/runner.ts).
import { createServer } from 'node:http';
import { cfg, checkConfig } from './config.js';
import { verify } from './sign.js';
import { isRunning, poke, tick } from './runner.js';

checkConfig();
const send = (res: any, status: number, body: unknown) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };

const server = createServer(async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  if (req.method === 'GET' && (path === '/health' || path === '/')) return send(res, 200, { ok: true, busy: isRunning() });
  if (req.method !== 'POST' || path !== '/tick') return send(res, 404, { ok: false, error: 'Not found.' });
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) { size += (c as Buffer).length; if (size > 64_000) return send(res, 413, { ok: false, error: 'Too large.' }); chunks.push(c as Buffer); }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!verify(raw, req.headers['x-counta-signature'] as string | undefined, cfg.secret)) return send(res, 401, { ok: false, error: 'Bad signature.' });
  if (isRunning()) { poke(); return send(res, 200, { ok: true, busy: true }); }
  let wait = false;
  try { wait = JSON.parse(raw || '{}')?.wait === true; } catch { /* a plain wake-up */ }
  // A tick that stopped for time with work still waiting is followed by another at once, so a busy day has no gaps between
  // wake-ups.
  const go = () => tick().catch((e) => {
    console.error(JSON.stringify({ at: new Date().toISOString(), error: (e as Error).message }));
    return null;
  });
  const run = go();
  void run.then(async (out) => { let o = out; while (o && 'more' in o && o.more) o = await go(); });
  if (!wait) return send(res, 202, { ok: true, started: true });
  const out = await run;
  if (!out) return send(res, 500, { ok: false, error: 'The bot could not reach Counta or start its browser.' });
  send(res, 200, { ok: true, ...out });
});
server.listen(cfg.port, () => console.log(JSON.stringify({ at: new Date().toISOString(), listening: cfg.port, worker: cfg.worker })));
