// Counta's side: the next job and the reports back, through the taxstreem function, signed with LIRS_BOT_SECRET.
// The bot never holds a Supabase key: Counta hands it one job at a time, with the person's login and links to the
// files that job needs.
import { cfg } from './config.js';
import { sign } from './sign.js';

export type Job = { id: string; kind: 'check' | 'file' | 'bill' | 'pay_account' | 'status'; attempt: number; max_attempts: number; org_id: string; year: number | null; person_id: string };
export type Next = { job: Job | null; context?: any; files?: Record<string, string> };

async function post(path: string, body: unknown, timeoutMs = 60_000): Promise<any> {
  const raw = JSON.stringify(body);
  const res = await fetch(`${cfg.countaUrl}${path}`, {
    method: 'POST', body: raw, signal: AbortSignal.timeout(timeoutMs),
    headers: { 'Content-Type': 'application/json', 'x-counta-signature': sign(raw, cfg.secret) },
  });
  const out: any = await res.json().catch(() => ({}));
  if (!res.ok || out.ok === false) throw new Error(`Counta answered ${res.status}: ${String(out.error || 'no reason given').slice(0, 300)}`);
  return out;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// Counta can be slow for a moment (a busy database cancels a statement): a call that matters is tried again after a pause.
// Both calls are safe to repeat: a job is claimed once, and a report on a job that has ended is ignored.
export async function again<T>(what: () => Promise<T>, tries = 3, pauseMs = Number(process.env.COUNTA_RETRY_MS || 3000)): Promise<T> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    if (i) await sleep(pauseMs * i);
    try { return await what(); } catch (e) { last = e; }
  }
  throw last;
}

export async function next(): Promise<Next> {
  const out = await again(() => post('/next', { worker: cfg.worker }));
  return { job: out.job ?? null, context: out.context, files: out.files || {} };
}

// p: {step, note} | {login: verified|failed, login_message} | {tax_station: {code, name}} | {portal: {...}}
//    | {done: true, result} | {failed: true, error, retry} (a refused sign-in comes with login: 'failed' in the same report)
export async function report(jobId: string, p: Record<string, unknown>) {
  return post('/report', { job_id: jobId, ...p });
}
// A report that must arrive (the outcome, the sign-in): tried again when Counta does not take it.
export async function reportSure(jobId: string, p: Record<string, unknown>) {
  return again(() => report(jobId, p));
}

export async function download(url: string): Promise<{ bytes: Buffer; type: string }> {
  const res = await fetch(url, { signal: AbortSignal.timeout(120_000) });
  if (!res.ok) throw new Error(`could not fetch a file from Counta (${res.status})`);
  return { bytes: Buffer.from(await res.arrayBuffer()), type: (res.headers.get('content-type') || '').split(';')[0].trim() };
}
