// One tick: take jobs from Counta one at a time until there are none, the tick's time is up, or it has done enough.
// e-Tax keeps one session per account, so the bot works for one person at a time and keeps that person signed in
// across their jobs (filing, then the bill), signing out before it moves to the next person.
import { chromium, type Browser } from 'playwright';
import { cfg } from './config.js';
import * as counta from './counta.js';
import { Etax } from './etax.js';
import { LoginRefused, Refused, SessionLost, retryable, scrub } from './errors.js';
import { fileReturn, type FileStore, type Reporter } from './file.js';
import { raiseBill } from './bill.js';
import { checkLogin } from './check.js';
import { billStatus, transferAccount } from './lasg.js';

export type Outcome = { job_id: string; kind: string; status: 'done' | 'failed'; retry?: boolean; error?: string };
let running = false, again = false;
export const isRunning = () => running;
// A wake-up while a tick is working: the tick looks for jobs once more before it stops.
export const poke = () => { if (running) again = true; };

function log(line: Record<string, unknown>) { console.log(JSON.stringify({ at: new Date().toISOString(), ...line })); }

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let t: NodeJS.Timeout;
  return Promise.race([p, new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error(`${what} took longer than ${Math.round(ms / 60000)} minutes`)), ms); })])
    .finally(() => clearTimeout(t));
}

export async function tick(opts: { budgetMs?: number; maxJobs?: number; browser?: Browser } = {}) {
  if (running) return { busy: true, ran: [] as Outcome[] };
  running = true; again = false;
  const started = Date.now();
  const ran: Outcome[] = [];
  const own = !opts.browser;
  let browser: Browser | null = opts.browser || null;
  let session = null as { key: string; et: Etax } | null;
  const end = async () => { if (session) { await session.et.signOut(); session = null; } };
  try {
    while (Date.now() - started < (opts.budgetMs ?? cfg.budgetMs) && ran.length < (opts.maxJobs ?? cfg.maxJobs)) {
      const next = await counta.next();
      if (!next.job) { if (again) { again = false; continue; } break; }
      const job = next.job, c = next.context || {};
      const key = `${job.org_id}:${job.person_id}`;
      if (session && session.key !== key) await end();
      if (!browser) browser = await chromium.launch({ headless: cfg.headless });
      const secrets = [c.login?.password];
      const say = (s: string) => scrub(s, secrets);
      const rep: Reporter = {
        step: async (step, note) => { await counta.report(job.id, { step, note: note ? say(note) : undefined }).catch((e) => log({ job: job.id, warn: `step report: ${e.message}` })); },
        portal: async (p) => { await counta.report(job.id, { portal: p }).catch((e) => log({ job: job.id, warn: `portal report: ${e.message}` })); },
      };
      const files: FileStore = {
        get: async (path) => {
          const url = next.files?.[path];
          if (!url) throw new Error('no link for a file');
          return counta.download(url);
        },
      };
      log({ job: job.id, kind: job.kind, attempt: job.attempt });
      try {
        const signIn = async () => {
          if (session && session.key === key) return session.et;
          if (!c.login?.payer_id || !c.login?.password) throw new LoginRefused('Counta has no e-Tax login for this person.');
          const et = await Etax.signIn(browser!, String(c.login.payer_id), String(c.login.password));
          session = { key, et };
          await counta.report(job.id, { step: 'signed_in', note: 'Signed in to e-Tax as the taxpayer.', login: 'verified' });
          return et;
        };
        const work = async () => {
          switch (job.kind) {
            case 'check': { const et = await signIn(); return await checkLogin(et, c, rep); }
            case 'file': { const et = await signIn(); return { result: await fileReturn(et, c, files, rep) }; }
            case 'bill': { const et = await signIn(); const b = await raiseBill(et, c, rep); return { result: b.result, tax_station: b.tax_station }; }
            case 'pay_account': {
              const r = await transferAccount(browser!, c, rep);
              if (!('paid' in r)) await rep.step('transfer_account', `Account ${r.account_number.replace(/^(\d{3})\d{4}/, '$1••••')} at ${r.bank_name} for ₦${r.amount.toFixed(2)}.`);
              return { result: r };
            }
            case 'status': { const r = await billStatus(browser!, c); await rep.step('checked', r.paid ? 'The bill shows as paid.' : `The bill is ${r.status || 'not paid yet'}.`); return { result: r }; }
            default: throw new Refused(`Unknown job ${job.kind}.`);
          }
        };
        let out: any;
        try { out = await withTimeout(work(), cfg.jobTimeoutMs, 'The job'); }
        catch (e) {
          // A session e-Tax ended part way is tried once more at once with a fresh sign-in; the steps pick up where they were.
          if (e instanceof SessionLost && (job.kind === 'file' || job.kind === 'bill' || job.kind === 'check')) {
            if (session) { await session.et.ctx.close().catch(() => {}); session = null; }
            await rep.step('signed_in_again', 'e-Tax ended the session; signing in again.');
            out = await withTimeout(work(), cfg.jobTimeoutMs, 'The job');
          } else throw e;
        }
        await counta.report(job.id, { done: true, result: out.result, ...(out.tax_station ? { tax_station: out.tax_station } : {}) });
        ran.push({ job_id: job.id, kind: job.kind, status: 'done' });
        log({ job: job.id, kind: job.kind, done: true });
      } catch (e) {
        const msg = say((e as Error).message || 'Something went wrong on e-Tax.').slice(0, 1500);
        const retry = retryable(e);
        if (e instanceof LoginRefused) {
          await counta.report(job.id, { login: 'failed', login_message: msg }).catch(() => {});
        }
        if (session && (e instanceof SessionLost || !retry)) { await end(); }
        await counta.report(job.id, { failed: true, error: msg, retry }).catch((x) => log({ job: job.id, warn: `fail report: ${x.message}` }));
        ran.push({ job_id: job.id, kind: job.kind, status: 'failed', retry, error: msg });
        log({ job: job.id, kind: job.kind, failed: msg, retry });
      }
    }
  } finally {
    await end().catch(() => {});
    if (own && browser) await browser.close().catch(() => {});
    running = false;
  }
  return { busy: false, ran, ms: Date.now() - started };
}
