// LIRS e-Tax, as the person: sign in on the login page with their Payer ID and password, then make the same calls the
// taxpayer screens make, from e-Tax's own origin with the session cookie. Only the calls those screens make are used:
// a call the taxpayer role cannot make ends the session.
//
// Calling convention (observed): every call is POST /api/v1/<resource> with a JSON body naming the real method:
//   reads  {method: 'GET', params: 'filters=[...]&embeds=[...]...'}  (params are not URL-encoded; encoding them breaks)
//   writes {method: 'POST' | 'PUT', body: {...}}
//   uploads multipart/form-data, no wrapper.
// Errors come back HTTP 200 with {status: 'error', code: NO_AUTH | INVALID_INPUT | INTERNAL_ERROR, message, error: true}.
import type { Browser, BrowserContext, Page } from 'playwright';
import { cfg } from './config.js';
import { LoginRefused, Refused, SessionLost, Transient, scrub } from './errors.js';

export type Me = { taxPayerId: number; individualId: number; payerId: string; name: string; profile: any };
const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function newContext(browser: Browser): Promise<BrowserContext> {
  const ctx = await browser.newContext({ userAgent: UA, locale: 'en-NG', timezoneId: 'Africa/Lagos', viewport: { width: 1366, height: 900 } });
  // The chat widget and analytics are not needed to file.
  await ctx.route(/embed\.tawk\.to|googletagmanager\.com|google-analytics\.com/, (r) => r.abort());
  return ctx;
}

function fullName(e: any) {
  if (!e || typeof e !== 'object') return '';
  return [e.first_name, e.middle_name, e.last_name || e.surname].filter((x) => x && String(x).trim()).join(' ').trim() || String(e.name || '').trim();
}

export class Etax {
  me!: Me;
  private last = 0;
  private constructor(readonly ctx: BrowserContext, readonly page: Page, private readonly secrets: string[]) {}

  static async signIn(browser: Browser, payerId: string, password: string): Promise<Etax> {
    const ctx = await newContext(browser);
    const page = await ctx.newPage();
    page.setDefaultTimeout(cfg.navTimeoutMs);
    const et = new Etax(ctx, page, [password]);
    try {
      await et.login(payerId, password);
    } catch (e) {
      await ctx.close().catch(() => {});
      throw e;
    }
    return et;
  }

  private async login(payerId: string, password: string) {
    const page = this.page;
    // The login screen asks e-Tax for its CSRF token as it opens; the bot waits for that before signing in.
    const csrf = page.waitForResponse((r) => /\/api\/v1\/get_csrf/.test(r.url()), { timeout: cfg.navTimeoutMs }).catch(() => null);
    try {
      await page.goto(`${cfg.etaxBase}/login`, { waitUntil: 'domcontentloaded' });
    } catch (e) {
      throw new Transient(`e-Tax's login page did not open (${(e as Error).message.split('\n')[0]}).`);
    }
    const id = page.locator('input[placeholder*="prefix"]').first();
    const pw = page.locator('input[type="password"]').first();
    try { await id.waitFor({ state: 'visible' }); } catch { throw new Transient('e-Tax\'s login page did not show the sign-in form.'); }
    await csrf;
    await this.pickTaxpayer();
    await id.fill(payerId);
    await pw.fill(password);
    const auth = page.waitForResponse((r) => /\/api\/v1\/auth\/local\/[a-z_-]+\/authenticate/.test(r.url()), { timeout: cfg.navTimeoutMs });
    await page.locator('button[type="submit"]').first().click();
    let res;
    try { res = await auth; } catch { throw new Transient('e-Tax did not answer the sign-in.'); }
    // The sign-in went as another kind of login (an agent's, say): that is the bot's choice on the page, not the password.
    if (!/\/auth\/local\/payers\/authenticate/.test(res.url())) {
      throw new Transient('Counta could not choose the taxpayer login on e-Tax\'s sign-in page, so the password was not tried. It tries again shortly.');
    }
    let data: any;
    try { data = await res.json(); } catch (e) { throw new Transient('e-Tax did not answer the sign-in.'); }
    if (!data || data.error || data.status === 'error' || !data.user) {
      const msg = scrub(String(data?.message || ''), this.secrets);
      if (data?.code === 'INTERNAL_ERROR') throw new Transient(`e-Tax could not sign in just now${msg ? `: ${msg}` : ''}.`);
      throw new LoginRefused(msg ? `e-Tax refused the sign-in: ${msg}` : 'e-Tax did not accept the Payer ID and password.');
    }
    const perms = Object.keys(data.auth_data?.permissions || {});
    if (perms.includes('auth.updatepassword') || data.auth_data?.extra_details?.force_password_reset) {
      throw new LoginRefused('e-Tax wants a new password on this account before anything else. Sign in to e-Tax, set a new password, then save it in Counta.');
    }
    if (data.auth_data?.type && data.auth_data.type !== 'payers') throw new LoginRefused('That login is not a taxpayer login on e-Tax.');
    const user = data.user;
    // From here the bot works from a plain page on e-Tax's address, so the app's own screens do not move under it.
    await page.goto(`${cfg.etaxBase}${cfg.etaxApiPage}`, { waitUntil: 'domcontentloaded' }).catch(() => {});
    const individualId = Number(user.entity_id ?? user.entity?.id);
    let profile: any = null;
    if (individualId) {
      profile = await this.get(`tax/payers/individuals/${individualId}`, 'embeds=["address", "taxPayer", "taxPayer.entity", "title"]').catch(() => null);
    }
    const taxPayerId = Number(profile?.tax_payer?.id ?? user.id);
    if (!taxPayerId || !individualId) throw new Refused('e-Tax signed in but did not say who the taxpayer is. Is this an individual\'s Payer ID?');
    if (user.entity_type_id && profile?.tax_payer?.entity_type_id && String(profile.tax_payer.entity_type_id) !== String(user.entity_type_id)) {
      throw new LoginRefused('This Payer ID belongs to a company on e-Tax, not a person. Save the person\'s own Payer ID, which starts with N-.');
    }
    this.me = { taxPayerId, individualId, payerId: String(user.reg_no || profile?.tax_payer?.reg_no || payerId), name: fullName(profile) || fullName(user.entity), profile };
  }

  // The sign-in page can ask what kind of login this is (a taxpayer, or someone acting for one). The person's own Payer ID
  // is a taxpayer login: choose it when the page asks, and do nothing when it does not.
  private async pickTaxpayer() {
    const page = this.page;
    const name = /^\s*(individual\s+)?tax\s*-?\s*payers?\s*$/i;
    try {
      const radio = page.getByRole('radio', { name }).first();
      if (await radio.count()) {
        // A styled radio often hides the input itself: a click on it from the page works when a click at its place cannot.
        if (!(await radio.isChecked().catch(() => false))) {
          await radio.check({ force: true, timeout: 3000 }).catch(() => radio.evaluate((el) => (el as HTMLElement).click()));
        }
        return;
      }
      const label = page.locator('label, .md-radio-label, [role="tab"], button[type="button"]', { hasText: name }).first();
      if (await label.count()) await label.click({ timeout: 5000 });
    } catch { /* no chooser, or one the bot cannot read: the sign-in below says which login e-Tax took */ }
  }

  // One call to e-Tax from its own origin.
  async call(resource: string, body: unknown): Promise<any> {
    const wait = this.last + cfg.gapMs - Date.now();
    if (wait > 0) await sleep(wait);
    this.last = Date.now();
    let r: { status: number; text: string };
    try {
      r = await this.page.evaluate(async ({ url, body }) => {
        const res = await fetch(url, { method: 'POST', credentials: 'include', body: JSON.stringify(body),
          headers: { Accept: 'application/json, text/plain, */*', 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } });
        return { status: res.status, text: await res.text() };
      }, { url: `${cfg.etaxBase}/api/v1/${resource}`, body });
    } catch (e) {
      throw new Transient(`e-Tax did not answer (${(e as Error).message.split('\n')[0].slice(0, 160)}).`);
    }
    return this.answer(resource, r);
  }

  async upload(resource: string, fields: Record<string, string | number>, file: { name: string; type: string; bytes: Buffer }): Promise<any> {
    const wait = this.last + cfg.gapMs - Date.now();
    if (wait > 0) await sleep(wait);
    this.last = Date.now();
    let r: { status: number; text: string };
    try {
      r = await this.page.evaluate(async ({ url, fields, name, type, b64 }) => {
        const bin = atob(b64); const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        // The parts go in the order the screens send them; the file goes where fields.file says (the end otherwise).
        const fd = new FormData(); let placed = false;
        for (const [k, v] of Object.entries(fields)) {
          if (k === 'file') { fd.append('file', new File([bytes], name, { type })); placed = true; } else fd.append(k, String(v));
        }
        if (!placed) fd.append('file', new File([bytes], name, { type }));
        const res = await fetch(url, { method: 'POST', credentials: 'include', body: fd, headers: { Accept: 'application/json, text/plain, */*', 'X-Requested-With': 'XMLHttpRequest' } });
        return { status: res.status, text: await res.text() };
      }, { url: `${cfg.etaxBase}/api/v1/${resource}`, fields, name: file.name, type: file.type, b64: file.bytes.toString('base64') });
    } catch (e) {
      throw new Transient(`e-Tax did not take the file (${(e as Error).message.split('\n')[0].slice(0, 160)}).`);
    }
    return this.answer(resource, r);
  }

  private answer(resource: string, r: { status: number; text: string }) {
    let data: any = null;
    try { data = r.text ? JSON.parse(r.text) : null; } catch { /* not JSON */ }
    if (r.status >= 500) throw new Transient(`e-Tax answered ${r.status} on ${resource}.`);
    if (r.status === 401 || r.status === 403) throw new SessionLost('e-Tax ended the session.');
    if (r.status >= 400 || data === null) throw new Transient(`e-Tax answered ${r.status} on ${resource}${data === null ? ' without data' : ''}.`);
    // Uploads wrap e-Tax's error in body.
    const err = data.error === true || data.status === 'error' ? data : data.body && data.body.status === 'error' ? data.body : null;
    if (err) {
      const code = String(err.code || '');
      const msg = scrub(String((err.data && (err.data.message || (typeof err.data === 'string' ? err.data : ''))) || err.message || 'no reason given'), this.secrets).slice(0, 400);
      if (code === 'NO_AUTH' || code === 'ACCESS_DENIED') throw new SessionLost('e-Tax ended the session (usually because someone signed in to this account elsewhere).');
      if (code === 'INTERNAL_ERROR') throw new Transient(`e-Tax had an internal error on ${resource}: ${msg}`);
      throw new Refused(`e-Tax refused ${resource.replace(/\/\d+/g, '/…')}: ${msg}`);
    }
    return data;
  }

  get(resource: string, params?: string) { return this.call(resource, params ? { method: 'GET', params } : { method: 'GET' }); }
  post(resource: string, body?: unknown) { return this.call(resource, body === undefined ? { method: 'POST' } : { method: 'POST', body }); }
  put(resource: string, body: unknown) { return this.call(resource, { method: 'PUT', body }); }

  async signOut() {
    await this.post('auth/logout').catch(() => {});
    await this.ctx.close().catch(() => {});
  }
}

// The list in an e-Tax answer: {list: [...]} for pages, a bare array for some reads.
export const listOf = (x: any): any[] => (Array.isArray(x) ? x : Array.isArray(x?.list) ? x.list : []);
