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

export async function next(): Promise<Next> {
  const out = await post('/next', { worker: cfg.worker });
  return { job: out.job ?? null, context: out.context, files: out.files || {} };
}

// p: {step, note} | {login: verified|failed, login_message} | {tax_station: {code, name}} | {portal: {...}}
//    | {done: true, result} | {failed: true, error, retry}
export async function report(jobId: string, p: Record<string, unknown>) {
  return post('/report', { job_id: jobId, ...p });
}

export async function download(url: string): Promise<{ bytes: Buffer; type: string }> {
  const res = await fetch(url, { signal: AbortSignal.timeout(120_000) });
  if (!res.ok) throw new Error(`could not fetch a file from Counta (${res.status})`);
  return { bytes: Buffer.from(await res.arrayBuffer()), type: (res.headers.get('content-type') || '').split(';')[0].trim() };
}
