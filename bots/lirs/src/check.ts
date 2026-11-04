// Checking a person's e-Tax login as soon as it is saved: sign in, see whose account it is and which tax station their
// profile names, then sign out. Nothing on e-Tax is changed. What looks wrong (another name on the account, no tax
// station) comes back as a warning for the person to see; a login e-Tax refuses is marked as not working.
import { Etax } from './etax.js';
import { Refused } from './errors.js';
import { taxStation } from './bill.js';
import type { Reporter } from './file.js';

const TITLES = new Set(['mr', 'mrs', 'miss', 'ms', 'dr', 'chief', 'engr', 'barr', 'prof', 'alhaji', 'alhaja', 'pastor', 'rev', 'sir', 'lady', 'hon', 'otunba', 'oba', 'esq']);

export function nameWords(s: string): string[] {
  return String(s || '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z\s'-]+/g, ' ').replace(/['-]/g, '')
    .split(/\s+/).filter((w) => w.length >= 2 && !TITLES.has(w));
}

// The same person if the two names share a word. Lenient on purpose: e-Tax often has a middle name, the surname first,
// or a maiden name.
export function namesMatch(a: string, b: string): boolean {
  const x = new Set(nameWords(a)), y = nameWords(b);
  if (!x.size || !y.length) return true;
  return y.some((w) => x.has(w));
}

export async function checkLogin(et: Etax, c: any, rep: Reporter) {
  const me = et.me;
  const who = String(c.taxpayer?.name || '').trim();
  const first = who.split(/\s+/)[0] || 'This person';
  const warnings: string[] = [];
  const saved = String(c.login?.payer_id || '').trim().toUpperCase();
  if (me.payerId && saved && me.payerId.toUpperCase() !== saved) warnings.push(`e-Tax shows this account's Payer ID as ${me.payerId}.`);
  const matches = namesMatch(who, me.name);
  if (!matches) warnings.push(`e-Tax has this Payer ID in the name ${me.name}. Make sure it is ${who}'s own login.`);
  let station: { code: string; name: string } | null = null;
  try {
    const st = await taxStation(et, c);
    station = { code: st.code, name: st.name };
  } catch (e) {
    if (!(e instanceof Refused)) throw e;
    warnings.push(/names no tax station/.test(e.message)
      ? `${first}'s e-Tax profile names no tax station yet. Choose one on e-Tax (Profile) before the bill is raised.`
      : e.message);
  }
  await rep.step('checked', `Signed in as ${me.name || 'the taxpayer'}${station ? `, tax station ${station.name}` : ''}. Nothing on e-Tax was changed.`);
  return {
    result: { payer_id: me.payerId, name: me.name || null, name_matches: matches, tax_station: station, warning: warnings.join(' ') || null },
    tax_station: station || undefined,
  };
}
