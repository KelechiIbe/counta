// Settings, all from the environment. On Cloud Run the two secrets come from Secret Manager.
const env = (k: string, d = '') => (process.env[k] ?? d).trim();
const num = (k: string, d: number) => { const v = Number(env(k)); return Number.isFinite(v) && v > 0 ? v : d; };

export const cfg = {
  port: num('PORT', 8080),
  // Where the bot takes its jobs and reports back: the taxstreem function's lirs routes,
  // e.g. https://<project>.supabase.co/functions/v1/taxstreem/lirs
  countaUrl: env('COUNTA_BOT_URL').replace(/\/+$/, ''),
  // Shared with Counta (the LIRS_BOT_SECRET of the edge functions). Signs every call both ways.
  secret: env('LIRS_BOT_SECRET'),
  etaxBase: env('ETAX_BASE', 'https://etax.lirs.net').replace(/\/+$/, ''),
  lasgBase: env('LASG_BASE', 'https://payments.lasg-public.com').replace(/\/+$/, ''),
  // A plain page on e-Tax's own address, so the bot's calls go out from e-Tax's origin with its session cookie
  // without the app running beside them.
  etaxApiPage: env('ETAX_API_PAGE', '/js/google-analytics.js'),
  worker: env('WORKER_NAME') || env('K_REVISION') || 'lirs-bot',
  // How long one tick may work before it stops taking jobs, and the most jobs in one tick.
  budgetMs: num('TICK_BUDGET_MS', 9 * 60_000),
  maxJobs: num('TICK_MAX_JOBS', 30),
  // The longest one job may take; Counta takes back a job silent for 20 minutes.
  jobTimeoutMs: num('JOB_TIMEOUT_MS', 8 * 60_000),
  // A pause between calls to e-Tax, so the bot never hurries the portal.
  gapMs: num('ETAX_GAP_MS', 350),
  navTimeoutMs: num('NAV_TIMEOUT_MS', 45_000),
  headless: env('HEADFUL') !== '1',
};

export function checkConfig() {
  const missing = [!cfg.countaUrl && 'COUNTA_BOT_URL', !cfg.secret && 'LIRS_BOT_SECRET'].filter(Boolean);
  if (missing.length) throw new Error(`Set ${missing.join(' and ')} before starting the bot.`);
  if (cfg.secret.length < 32) throw new Error('LIRS_BOT_SECRET must be at least 32 characters.');
}
