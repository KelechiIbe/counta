// The pay bill for a filed return: Payments, Generate/Pay Bill, at the person's tax station, revenue Direct Assessment,
// the person as the one recipient. One bill per person, so each pays and gets a receipt in their own name.
import { Etax, listOf } from './etax.js';
import { Refused } from './errors.js';
import { Agency, matchAgency } from './match.js';
import type { Reporter } from './file.js';

const UNPAID = 25, PAID = 26;
const n = (v: unknown) => { const x = Number(String(v ?? '').replace(/,/g, '')); return Number.isFinite(x) ? x : 0; };

export async function agencies(et: Etax): Promise<Agency[]> {
  return listOf(await et.get('abc/agencies/internal', '&no_pages=1&order_by=name&is_asc=1'));
}

// The person's tax station on e-Tax's agency list: the one saved with their login, or the one their profile names.
export async function taxStation(et: Etax, c: any): Promise<{ agency: Agency; code: string; name: string }> {
  const list = await agencies(et);
  const saved = String(c.login?.tax_station || '');
  if (saved) {
    const a = list.find((x) => String(x.orcAgency2) === saved || String(x.AgencyRef) === saved);
    if (a) return { agency: a, code: String(a.orcAgency2), name: String(a.FullName || '') };
  }
  const officeId = et.me.profile?.tax_payer?.preferred_tax_office_id;
  let office = '';
  if (officeId) {
    const o = await et.get(`tax/offices/${officeId}`).catch(() => null);
    office = String(o?.name || '');
    // An office that carries its own agency code.
    for (const k of ['agency_code', 'orc_code', 'code', 'orcAgency2']) {
      const v = o?.[k];
      const a = v ? list.find((x) => String(x.orcAgency2) === String(v) || String(x.AgencyRef) === String(v)) : null;
      if (a) return { agency: a, code: String(a.orcAgency2), name: String(a.FullName || '') };
    }
  }
  if (!office) throw new Refused(`${c.taxpayer?.name || 'This person'}'s e-Tax profile names no tax station, so Counta cannot tell where to raise the bill. Choose a tax station on e-Tax (Profile), then try again.`);
  const a = matchAgency(office, list);
  if (!a) throw new Refused(`Counta could not find the tax station "${office}" on e-Tax's list for bills. Ask TaxStreem to set the tax station for ${c.taxpayer?.name || 'this person'}.`);
  return { agency: a, code: String(a.orcAgency2), name: String(a.FullName || '') };
}

export async function raiseBill(et: Etax, c: any, rep: Reporter) {
  const me = et.me, tp = me.taxPayerId;
  const b = c.bill || {};
  const amount = Math.round(n(b.amount) * 100) / 100;
  if (!(amount > 0)) throw new Refused('There is no tax to pay, so there is no bill to raise.');
  const year = Number(c.year);
  // A bill already raised (by an earlier try that stopped before it reported back) is used again.
  const params = `filters=${JSON.stringify([{ field: 'tax_payer_id', value: tp }, { field: 'status_id', value: [UNPAID, PAID] }])}`
    + '&embeds=["status", "taxPayer", "taxPayer.entity", "scheduleDocument"]&order_by=created_at&is_asc=false&page_size=20&page=1';
  const bills = listOf(await et.get('tax/bills', params));
  const ref = String(b.existing?.reference || '');
  let bill = (ref && bills.find((x) => String(x.system_reference) === ref)) || bills.find((x) => Number(x.status_id) === UNPAID
    && String(x.revenue_code) === String(b.revenue_code || '32102') && Math.abs(n(x.amount_due ?? x.amount) - amount) < 0.005
    && String(x.start_date || '').slice(0, 4) === String(year));
  const st = await taxStation(et, c);
  let revenueName = 'Direct Assessment';
  if (!bill) {
    const revenues = listOf(await et.get(`abc/agencies/revenues?HeadRef=${encodeURIComponent(String(st.agency.HeadRef ?? ''))}`));
    const rev = revenues.find((r: any) => String(r.orcRev) === String(b.revenue_code || '32102'))
      || revenues.find((r: any) => /direct\s*assessment/i.test(String(r.RevName || '')));
    if (!rev) throw new Refused(`e-Tax's ${st.name} has no Direct Assessment revenue to bill.`);
    revenueName = String(rev.RevName || revenueName);
    bill = await et.post('tax/bills', {
      agency_code: st.code, revenue_code: String(rev.orcRev), tax_payer_id: tp,
      recipients: [{ tax_payer_number: me.payerId, name: me.name || c.taxpayer?.name || '', amount }],
      amount: amount.toFixed(2), generate_now: true, start_date: String(b.start_date || `${year}-01-01`).slice(0, 10),
      end_date: String(b.end_date || `${year}-12-31`).slice(0, 10), payment_currency_id: 1, remark: String(b.remark || '').slice(0, 200),
    });
  } else if (bill.revenue_name) revenueName = String(bill.revenue_name);
  const reference = String(bill?.system_reference || '');
  if (!reference) throw new Refused('e-Tax raised the bill but did not give its reference.');
  await rep.step('bill', `Bill ${reference} for ₦${amount.toLocaleString('en-NG', { minimumFractionDigits: 2 })} at ${st.name}.`);
  return {
    tax_station: { code: st.code, name: st.name },
    result: { bill_id: String(bill.id ?? ''), reference, amount: n(bill.amount_due ?? amount) || amount, agency: st.name, revenue: revenueName,
      payer_id: me.payerId, generated_at: bill.created_at || new Date().toISOString(), paid: Number(bill.status_id) === PAID },
  };
}
