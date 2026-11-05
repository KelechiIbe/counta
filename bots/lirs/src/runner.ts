// One tick: take jobs from Counta until there are none, the tick's time is up, or it has done enough. Up to BOT_LANES jobs
// run side by side (eight unless set), each lane in its own browser context: a lane that takes a job wakes one more to look
// for the next, so a quiet queue keeps one lane and a busy deadline day fills them all. Counta hands out one job at a time
// for a person, as e-Tax keeps one session per account. The e-Tax sessions belong to the tick, by person: a filing keeps the
// person signed in for the bill that follows, whichever lane takes it; any other job signs them out when it ends, and the
// tick signs out whoever is left.
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

export async function tick(opts: { budgetMs?: number; maxJobs?: number; browser?: Browser; lanes?: number } = {}) {
  if (running) return { busy: true, ran: [] as Outcome[] };
  running = true; again = false;
  const started = Date.now();
  const ran: Outcome[] = [];
  const own = !opts.browser;
  const budget = opts.budgetMs ?? cfg.budgetMs, most = opts.maxJobs ?? cfg.maxJobs;
  const lanes = Math.max(1, Math.floor(opts.lanes ?? cfg.lanes));
  // One browser for all the lanes, started when the first job needs it.
  let browserP: Promise<Browser> | null = opts.browser ? Promise.resolve(opts.browser) : null;
  const getBrowser = () => (browserP ??= chromium.launch({ headless: cfg.headless }));
  let taken = 0, active = 0, peak = 0, laneNo = 0;
  let fatal: Error | null = null;
  const room = () => Date.now() - started < budget && taken < most && !fatal;
  const live = new Set<Promise<void>>();
  // e-Tax sessions by person. The lane that has a person's job has that person's session to itself (Counta never hands out
  // two jobs for one person at once).
  const pool = new Map<string, Etax>();
  const signOut = async (key: string) => { const et = pool.get(key); pool.delete(key); if (et) await et.signOut().catch(() => {}); };
  const startLane = () => {
    const n = ++laneNo;
    active++; peak = Math.max(peak, active);
    const p: Promise<void> = lane(n).catch((e) => { fatal ??= e as Error; log({ lane: n, error: (e as Error).message }); }).finally(() => { active--; live.delete(p); });
    live.add(p);
  };

  async function lane(n: number) {
    const worker = lanes > 1 ? `${cfg.worker}#${n}` : cfg.worker;
    while (room()) {
      const next = await counta.next(worker);
      if (!next.job) { if (again) { again = false; continue; } break; }
      taken++;
      // There was work: one more lane looks for the next job, up to the limit.
      if (active < lanes && room()) startLane();
      const job = next.job, c = next.context || {};
      const key = `${job.org_id}:${job.person_id}`;
      const browser = await getBrowser();
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
      log({ job: job.id, kind: job.kind, attempt: job.attempt, lane: n });
      try {
        const signIn = async () => {
          const had = pool.get(key);
          if (had) return had;
          if (!c.login?.payer_id || !c.login?.password) throw new LoginRefused('Counta has no e-Tax login for this person.');
          const et = await Etax.signIn(browser, String(c.login.payer_id), String(c.login.password));
          pool.set(key, et);
          await counta.reportSure(job.id, { step: 'signed_in', note: 'Signed in to e-Tax as the taxpayer.', login: 'verified' })
            .catch((e) => log({ job: job.id, warn: `sign-in report: ${e.message}` }));
          return et;
        };
        const work = async () => {
          switch (job.kind) {
            case 'check': { const et = await signIn(); return await checkLogin(et, c, rep); }
            case 'file': { const et = await signIn(); return { result: await fileReturn(et, c, files, rep) }; }
            case 'bill': { const et = await signIn(); const b = await raiseBill(et, c, rep); return { result: b.result, tax_station: b.tax_station }; }
            case 'pay_account': {
              const r = await transferAccount(browser, c, rep);
              if (!('paid' in r)) await rep.step('transfer_account', `Account ${r.account_number.replace(/^(\d{3})\d{4}/, '$1••••')} at ${r.bank_name} for ₦${r.amount.toFixed(2)}.`);
              return { result: r };
            }
            case 'status': { const r = await billStatus(browser, c); await rep.step('checked', r.paid ? 'The bill shows as paid.' : `The bill is ${r.status || 'not paid yet'}.`); return { result: r }; }
            default: throw new Refused(`Unknown job ${job.kind}.`);
          }
        };
        let out: any;
        try { out = await withTimeout(work(), cfg.jobTimeoutMs, 'The job'); }
        catch (e) {
          // A session e-Tax ended part way is tried once more at once with a fresh sign-in; the steps pick up where they were.
          if (e instanceof SessionLost && (job.kind === 'file' || job.kind === 'bill' || job.kind === 'check')) {
            const lost = pool.get(key); pool.delete(key);
            if (lost) await lost.ctx.close().catch(() => {});
            await rep.step('signed_in_again', 'e-Tax ended the session; signing in again.');
            out = await withTimeout(work(), cfg.jobTimeoutMs, 'The job');
          } else throw e;
        }
        await counta.reportSure(job.id, { done: true, result: out.result, ...(out.tax_station ? { tax_station: out.tax_station } : {}) });
        // The bill follows a filing, in the same session; after anything else the person is signed out.
        if (job.kind !== 'file') await signOut(key);
        ran.push({ job_id: job.id, kind: job.kind, status: 'done' });
        log({ job: job.id, kind: job.kind, done: true, lane: n });
      } catch (e) {
        const msg = say((e as Error).message || 'Something went wrong on e-Tax.').slice(0, 1500);
        const retry = retryable(e);
        if (e instanceof SessionLost || !retry) await signOut(key);
        // One report with the outcome, and for a refused sign-in the login's state with it, so neither arrives alone.
        await counta.reportSure(job.id, { failed: true, error: msg, retry, ...(e instanceof LoginRefused ? { login: 'failed', login_message: msg } : {}) })
          .catch((x) => log({ job: job.id, warn: `fail report: ${x.message}` }));
        ran.push({ job_id: job.id, kind: job.kind, status: 'failed', retry, error: msg });
        log({ job: job.id, kind: job.kind, failed: msg, retry, lane: n });
      }
    }
  }

  try {
    startLane();
    while (live.size) await Promise.all([...live]);
  } finally {
    for (const key of [...pool.keys()]) await signOut(key);
    if (own && browserP) { const b = await browserP.catch(() => null); if (b) await b.close().catch(() => {}); }
    running = false;
  }
  // Counta or the browser could not be reached before anything ran: the caller hears of it.
  if (fatal && !ran.length) throw fatal;
  // Stopped for time or the number of jobs rather than an empty queue: the server starts the next tick at once.
  const more = Date.now() - started >= budget || taken >= most;
  return { busy: false, ran, ms: Date.now() - started, lanes: peak, more };
}
