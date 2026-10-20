// The NRS VAT return (Form VAT 002) for a month: what goes on each schedule, the form's lines and how they tie to Counta's VAT,
// what to fix first (places, NRS descriptions), and the filled workbook. And customs entries: goods imported and the VAT paid
// at the port, which schedule D needs.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../../state/session';
import { rpc, supabase } from '../../../lib/supabase';
import { edge, money, today } from '../../../lib/api';
import { N2, fmtDay } from '../../../lib/format';
import { monthName, monthShort, useCustoms, useVatSchedule } from '../../../lib/tax';
import { COUNTRIES, countryName } from '../../../lib/countries';
import { Icon } from '../../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../../components/ui';
import { NrsLabelSelect, StateLga } from '../../../components/Places';
import { PayFrom } from './VatTab';
import { downloadUrl, useTaxRefresh } from './CitTab';
import { vatPct, vatRateOn } from '../../../lib/vat';
import { FluxPayments, FluxSend } from '../../payments/FluxPayments';

const LINES: [string, string, 'in' | 'sub' | 'total'][] = [
  ['10', 'Total sales and income, excluding VAT', 'in'], ['15', 'Less exempt sales', 'in'], ['20', 'Less zero-rated sales', 'in'], ['22', 'Less sales adjustments (credit notes)', 'in'],
  ['25', 'Sales subject to VAT', 'sub'], ['35', 'Output VAT at 7.5%', 'total'],
  ['40', 'Standard-rated local purchases', 'in'], ['45', 'Inventory adjustments (stock written off)', 'in'], ['55', 'VAT on local purchases', 'sub'],
  ['85', 'Imports', 'in'], ['90', 'VAT on imports', 'sub'], ['95', 'Total input VAT', 'total'],
  ['100', 'VAT balance for the month', 'sub'], ['105', 'Input tax on VAT self-charged', 'in'], ['110', 'VAT withheld by MDAs and agents', 'in'],
  ['115', 'Net VAT for the month', 'total'],
];
const SCHEDULES: [string, string][] = [['a', 'A · Sales'], ['b', 'B · Sales adjustments'], ['c2', 'C · Purchases'], ['c1', 'C1 · Stock written off'], ['d', 'D · Imports'],
  ['e', 'E · Self-charged VAT'], ['f', 'F · VAT withheld by agents']];

export function VatReturnModal({ period, onClose }: { period: string; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const q = useVatSchedule(period);
  const s = q.data;
  const [busy, setBusy] = useState(false);
  const [ties, setTies] = useState<any[] | null>(null);
  const count = (k: string) => k === 'c2' ? ['goods', 'services', 'fixed_assets'].reduce((n, x) => n + (s?.c2?.[x]?.length || 0), 0) : (s?.[k]?.length || 0);
  const checks: any[] = s?.checks || [];
  async function download() {
    setBusy(true);
    try {
      const r = await edge<any>('tax-files', { action: 'vat_file', org_id: orgId, period: period.slice(0, 7) });
      if (r.ok === false) throw new Error(r.error || 'Could not make the file.');
      setTies(r.ties || []);
      downloadUrl(r.url);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const off = (ties || []).filter((t) => !t.ok);
  return (
    <Modal onClose={onClose} width={820}>
      <ModalHead title={`NRS VAT return for ${monthName(period)}`} sub="Form VAT 002 with schedules A to F, as the NRS template takes it" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {q.isLoading ? <SkeletonRows n={6} /> : q.error ? <Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert> : s && (
          <>
            {checks.length > 0 && (
              <div className="stack" style={{ gap: 6 }}>
                {checks.map((c, i) => <Check key={i} c={c} />)}
              </div>
            )}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,1fr)', gap: 14 }}>
              <div className="card" style={{ overflow: 'hidden' }}>
                <div className="card-hd"><b>The form</b><span className="faint" style={{ fontSize: 12 }}>lines the template works out</span></div>
                {LINES.map(([n, label, kind]) => (
                  <div key={n} className="row" style={{ justifyContent: 'space-between', padding: '6px 14px', fontSize: 13, borderTop: '1px solid #F1F2F4',
                    fontWeight: kind === 'total' ? 700 : kind === 'sub' ? 600 : undefined, background: kind === 'total' ? '#FAFAFA' : undefined }}>
                    <span><span className="faint" style={{ display: 'inline-block', width: 34 }}>{n}</span>{label}</span>
                    <span className="num">{N2(Number(s.lines?.[n] || 0))}</span>
                  </div>
                ))}
              </div>
              <div className="stack" style={{ gap: 10 }}>
                <div className="card card-pad stack" style={{ gap: 6, fontSize: 13 }}>
                  <b>Against Counta's VAT for the month</b>
                  <Line label="Output VAT" v={s.counta.output} /><Line label="Less VAT withheld by customers" v={s.counta.wvat_credit} />
                  <Line label={`Less input VAT${Number(s.counta.import_vat) ? ', with customs' : ''}${Number(s.counta.stock_writeoff_vat) ? ', less stock written off' : ''}`} v={s.counta.input} />
                  <Line label="Counta's net" v={s.counta.net} strong />
                  <Line label="Line 115" v={s.lines['115']} strong />
                  <div style={{ fontSize: 12, color: Math.abs(Number(s.difference)) <= Number(s.tolerance) ? '#15803D' : '#B45309' }}>
                    {Math.abs(Number(s.difference)) < 0.005 ? 'They agree.' : Math.abs(Number(s.difference)) <= Number(s.tolerance)
                      ? `${N2(Math.abs(Number(s.difference)))} apart: the template works VAT out on totals, Counta line by line.`
                      : Number(s.wvat_gap || 0) && Math.abs(Number(s.difference) + Number(s.wvat_gap)) <= Number(s.tolerance)
                        ? `${N2(Math.abs(Number(s.difference)))} apart: line 110 credits 7.5% of the invoice value where an agent kept ${Number(s.wvat_gap) > 0 ? 'less' : 'more'}. See the checks above.`
                        : `${N2(Number(s.difference))} apart. Look before filing.`}
                  </div>
                  <div className="faint" style={{ fontSize: 12 }}>Lines 116 to 150 (credit brought forward, credit, payable) are worked out by the portal.{s.counta.filed ? ' This month is filed in Counta.' : ''}</div>
                </div>
                <div className="card card-pad stack" style={{ gap: 4, fontSize: 13 }}>
                  <b>Rows on each schedule</b>
                  {SCHEDULES.map(([k, l]) => <div key={k} className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{l}</span><span className="num">{count(k)}</span></div>)}
                  {Number(s.zero_share) > 0 && <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>{(Number(s.zero_share) * 100).toFixed(1)}% of VATable sales were zero-rated, so that share of purchases is shown as relating to them.</div>}
                </div>
              </div>
            </div>
            {off.length > 0 && <Alert kind="red" icon="alert">The template's own formulas differ from Counta on line{off.length > 1 ? 's' : ''} {off.map((t) => t.line).join(', ')}. Do not upload this file; tell TaxStreem.</Alert>}
            <FluxSend tax="vat" period={period} ready={!!s.counta?.filed && !s.blocked}
              notReady={s.blocked ? 'Fix the points above first.' : 'File the month in Counta first: filing freezes the figures Flux files.'} />
            <FluxPayments taxes={['vat']} period={period.slice(0, 7) + '-01'} />
            {ties && !off.length && <Alert kind="green" icon="check">Downloaded. Every line of the form agrees with Counta. Upload it on the NRS portal with the month's VAT payment.</Alert>}
          </>
        )}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        <button className="btn btn-primary" disabled={!s || s.blocked || busy} onClick={download}>{busy ? <Spinner small /> : <Icon name="download" size={14} color="#fff" />}NRS VAT file</button>
      </div>
    </Modal>
  );
}

function Line({ label, v, strong }: { label: string; v: unknown; strong?: boolean }) {
  return <div className="row" style={{ justifyContent: 'space-between', fontWeight: strong ? 700 : undefined }}><span>{label}</span><span className="num">{N2(Number(v || 0))}</span></div>;
}

// One thing to fix, with the fix right there: a branch's or a customer's place, or the NRS description of a sale.
function Check({ c }: { c: any }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [place, setPlace] = useState({ state: c.fix?.state || '', lga: '' });
  const [busy, setBusy] = useState(false);
  const kind = c.severity === 'block' ? 'red' : c.severity === 'warn' ? 'amber' : 'blue';
  async function go(fn: () => Promise<unknown>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); await qc.invalidateQueries({ queryKey: ['vat-schedule'] }); await qc.invalidateQueries({ queryKey: ['customers'] }); await qc.invalidateQueries({ queryKey: ['inv'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const f = c.fix;
  return (
    <Alert kind={kind as any} icon={c.severity === 'info' ? 'info' : 'alert'}>
      {c.text}
      {f && (f.kind === 'branch' || f.kind === 'customer') && (
        <div className="row wrap" style={{ gap: 6, marginTop: 8 }}>
          <StateLga state={place.state} lga={place.lga} onChange={(state, lga) => setPlace({ state, lga })} compact />
          <button className="btn btn-secondary btn-xs" disabled={busy || !place.state || !place.lga} onClick={() => go(async () => {
            if (f.kind === 'branch') {
              // Only the owner may change a branch; for anyone else no row comes back.
              const { data, error } = await supabase.from('locations').update({ state: place.state, lga: place.lga }).eq('id', f.id).select('id');
              if (error) throw new Error(/row-level|permission/i.test(error.message) ? 'Only the owner changes a branch.' : error.message);
              if (!data?.length) throw new Error('Only the owner changes a branch.');
            } else await rpc('save_customer', { p_org: orgId, p_customer: { id: f.id, name: f.name, state: place.state, lga: place.lga } });
          }, `${f.name} is in ${place.lga}, ${place.state}`)}>Save</button>
        </div>
      )}
      {f && (f.kind === 'item' || f.kind === 'line') && (
        <div className="row wrap" style={{ gap: 6, marginTop: 8 }}>
          <NrsLabelSelect treatment={f.treatment} value="" compact onChange={(v) => v && go(() => f.kind === 'item'
            ? rpc('set_item_nrs_label', { p_item: f.id, p_label: v }) : rpc('set_sale_line_nrs_label', { p_line: f.id, p_label: v }), 'NRS description saved')} />
          {f.kind === 'item' && <span className="faint" style={{ fontSize: 12 }}>Saved on the item, for every sale of it.</span>}
        </div>
      )}
    </Alert>
  );
}

// ---- Customs entries ----
export function CustomsPanel({ canEdit }: { canEdit: boolean }) {
  const q = useCustoms();
  const [adding, setAdding] = useState(false);
  const [voiding, setVoiding] = useState<any>(null);
  const rows: any[] = q.data || [];
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="muted" style={{ fontSize: 13, maxWidth: 640 }}>Goods you import and the VAT paid at the port. The import VAT is input VAT; each entry goes on schedule D of the month's NRS return.</div>
        {canEdit && <button className="btn btn-primary btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} color="#fff" />Add a customs entry</button>}
      </div>
      <div className="card" style={{ overflow: 'auto' }}>
        <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '100px 110px minmax(180px,1.4fr) 130px 130px 120px 80px', minWidth: 880 }}>
          <span>Entry</span><span>Date</span><span>Goods</span><span>Form M</span><span className="right">VAT base</span><span className="right">Import VAT</span><span />
        </div>
        {q.isLoading ? <SkeletonRows n={3} /> : !rows.length ? <div style={{ padding: 20 }}><Empty>No customs entries yet.</Empty></div> : rows.map((e) => (
          <div key={e.id} className="tr" style={{ gridTemplateColumns: '100px 110px minmax(180px,1.4fr) 130px 130px 120px 80px', minWidth: 880, fontSize: 13, opacity: e.status === 'void' ? 0.55 : 1 }}>
            <b>{e.number}</b>
            <span>{fmtDay(e.entry_date)}</span>
            <span className="ellipsis" title={e.description}>{e.description}<span className="faint"> · {e.currency} {N2(e.invoice_value).replace('₦', '')} at {Number(e.fx_rate)}{e.country ? ` · ${countryName(e.country)}` : ''}</span>
              {e.status === 'void' && <span className="chip t-grey" style={{ marginLeft: 4 }}>void</span>}</span>
            <span className="faint">{e.form_m || '—'}</span>
            <span className="right num">{N2(e.vat_base)}</span>
            <span className="right num">{N2(e.import_vat)}</span>
            <span className="right">{canEdit && e.status === 'posted' && !e.filed && <button className="btn btn-ghost btn-xs" onClick={() => setVoiding(e)}>Void</button>}</span>
          </div>
        ))}
      </div>
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Customs duty, levies and clearing charges belong in the cost of the goods: add them to the stock receipt as landed costs. Here they only count towards the base the import VAT was worked out on.</div>
      {adding && <CustomsModal onClose={() => setAdding(false)} />}
      {voiding && <VoidCustoms e={voiding} onClose={() => setVoiding(null)} />}
    </div>
  );
}

function CustomsModal({ onClose }: { onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [f, setF] = useState({ entry_date: today(), description: '', hs_code: '', country: '', vessel: '', form_m: '', bill_of_lading: '', quantity: '', currency: 'USD',
    invoice_value: '', fx_rate: '', value_ngn: '', other_charges: '', import_vat: '', vendor_id: '', paid: 'account', bank_account_id: '', reference: '', journal_ref: '' });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f, v: string) => setF((x) => ({ ...x, [k]: v }));
  // The currencies TaxStreem takes, and Counta's rate for the day as the starting point; the customs assessment's own rate wins.
  const currencies = useQuery({ queryKey: ['currencies'], staleTime: 10 * 60_000, queryFn: async () => {
    const { data, error } = await supabase.from('currencies').select('code, name').eq('allowed', true).order('sort');
    return error || !data?.length ? ['USD', 'EUR', 'GBP', 'CNY', 'AED', 'INR', 'JPY', 'ZAR', 'NGN'].map((code) => ({ code, name: code })) : data as { code: string; name: string }[];
  } });
  const suggested = useQuery({ queryKey: ['fx-on', f.currency, f.entry_date], enabled: f.currency !== 'NGN', staleTime: 10 * 60_000,
    queryFn: () => rpc<{ rate: number; day: string; source: string } | null>('fx_rate_on', { p_currency: f.currency, p_day: f.entry_date || null }).catch(() => null) });
  const dayRate = Number(suggested.data?.rate) || 0;
  const fx = f.currency === 'NGN' ? 1 : money(f.fx_rate) || dayRate;
  const valueNgn = money(f.value_ngn) ?? Math.round((money(f.invoice_value) || 0) * fx * 100) / 100;
  const base = valueNgn + (money(f.other_charges) || 0);
  const vat = money(f.import_vat) ?? Math.round(base * vatRateOn(f.entry_date) * 100) / 100;
  const ready = f.description.trim() && (money(f.invoice_value) || 0) > 0 && fx > 0 && (f.paid === 'account' ? !!f.bank_account_id : !!f.journal_ref.trim());
  async function save() {
    setBusy(true);
    try {
      await rpc('save_customs_entry', { p_org: orgId, p: { entry_date: f.entry_date, description: f.description, hs_code: f.hs_code || null, country: f.country || null,
        vessel: f.vessel || null, form_m: f.form_m || null, bill_of_lading: f.bill_of_lading || null, quantity: money(f.quantity), currency: f.currency,
        invoice_value: money(f.invoice_value), fx_rate: fx, value_ngn: money(f.value_ngn), other_charges: money(f.other_charges) || 0, import_vat: money(f.import_vat),
        vendor_id: f.vendor_id || null,
        ...(f.paid === 'account' ? { bank_account_id: f.bank_account_id, reference: f.reference || null, paid_at: f.entry_date + 'T12:00:00+01:00' } : { journal_ref: f.journal_ref.trim() }) } });
      toast('Customs entry saved'); await refresh(); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const grid = (n: number) => ({ display: 'grid', gridTemplateColumns: `repeat(${n},minmax(0,1fr))`, gap: 10 });
  return (
    <Modal onClose={onClose} width={680}>
      <ModalHead title="Customs entry" sub="From the customs assessment (SGD) and the payment receipt" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="m-stack" style={grid(3)}>
          <Field label="VAT paid on" req><input className="input" type="date" max={today()} value={f.entry_date} onChange={(e) => set('entry_date', e.target.value)} /></Field>
          <Field label="Form M number"><input className="input" value={f.form_m} onChange={(e) => set('form_m', e.target.value)} placeholder="MF2026…" /></Field>
          <Field label="Bill of lading or airway bill"><input className="input" value={f.bill_of_lading} onChange={(e) => set('bill_of_lading', e.target.value)} /></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 10 }}>
          <Field label="Goods" req><input className="input" value={f.description} onChange={(e) => set('description', e.target.value)} placeholder="e.g. Diesel generators 20kVA" /></Field>
          <Field label="HS code"><input className="input" value={f.hs_code} onChange={(e) => set('hs_code', e.target.value)} placeholder="8502.11" /></Field>
        </div>
        <div className="m-stack" style={grid(3)}>
          <Field label="Country of origin"><select className="input" value={f.country} onChange={(e) => set('country', e.target.value)}><option value="">Choose</option>{COUNTRIES.filter((c) => c.code !== 'NG').map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select></Field>
          <Field label="Vessel or flight"><input className="input" value={f.vessel} onChange={(e) => set('vessel', e.target.value)} /></Field>
          <Field label="Quantity"><input className="input num" inputMode="decimal" value={f.quantity} onChange={(e) => set('quantity', e.target.value)} /></Field>
        </div>
        <div className="m-stack" style={grid(4)}>
          <Field label="Currency"><select className="input" value={f.currency} onChange={(e) => set('currency', e.target.value)}>{(currencies.data || [{ code: 'USD', name: 'US dollar' }]).map((c) => <option key={c.code} value={c.code}>{c.code}</option>)}</select></Field>
          <Field label="Invoice value" req><input className="input num" inputMode="decimal" value={f.invoice_value} onChange={(e) => set('invoice_value', e.target.value)} /></Field>
          <Field label="Customs exchange rate" req={f.currency !== 'NGN' && !dayRate} hint={f.currency !== 'NGN' && dayRate ? `Blank uses Counta's rate for the day, ${N2(dayRate)}. Enter the rate on the assessment if it differs.` : undefined}>
            <input className="input num" inputMode="decimal" disabled={f.currency === 'NGN'} value={f.currency === 'NGN' ? '1' : f.fx_rate} placeholder={dayRate ? String(dayRate) : ''} onChange={(e) => set('fx_rate', e.target.value)} /></Field>
          <Field label="Value in naira"><input className="input num" inputMode="decimal" value={f.value_ngn} onChange={(e) => set('value_ngn', e.target.value)} placeholder={N2(valueNgn).replace('₦', '')} /></Field>
        </div>
        <div className="m-stack" style={grid(3)}>
          <Field label="Duty, levies and charges" hint="The part of the VAT base on top of the value"><input className="input num" inputMode="decimal" value={f.other_charges} onChange={(e) => set('other_charges', e.target.value)} /></Field>
          <Field label="VAT base"><div className="input num" style={{ background: '#FAFAFA' }}>{N2(base)}</div></Field>
          <Field label="Import VAT paid" hint={`${vatPct(f.entry_date)} of the base, unless customs charged otherwise`}><input className="input num" inputMode="decimal" value={f.import_vat} onChange={(e) => set('import_vat', e.target.value)} placeholder={N2(vat).replace('₦', '')} /></Field>
        </div>
        <Field label="Supplier abroad (optional)"><select className="input" value={f.vendor_id} onChange={(e) => set('vendor_id', e.target.value)}><option value="">None</option>{(inv?.vendors || []).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>
        <div className="row" style={{ gap: 16, fontSize: 14 }}>
          <label className="row" style={{ gap: 6 }}><input type="radio" checked={f.paid === 'account'} onChange={() => set('paid', 'account')} />Paid from an account</label>
          <label className="row" style={{ gap: 6 }}><input type="radio" checked={f.paid === 'books'} onChange={() => set('paid', 'books')} />Already in the books (from a bank line)</label>
        </div>
        {f.paid === 'account' ? (
          <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <PayFrom value={f.bank_account_id} onChange={(v) => set('bank_account_id', v)} />
            <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => set('reference', e.target.value)} placeholder="Customs receipt or Remita RRR" /></Field>
          </div>
        ) : <Field label="Entry in the books" hint="The journal that put the VAT in 1402, e.g. JE-1234"><input className="input" value={f.journal_ref} onChange={(e) => set('journal_ref', e.target.value)} /></Field>}
        <div className="faint" style={{ fontSize: 12 }}>{f.paid === 'account' ? `Posts Dr 1402 Input VAT ${N2(vat)}, Cr the account.` : 'Nothing new is posted; the entry only puts the import on the VAT return.'}</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={busy || !ready} onClick={save}>Save</button></div>
    </Modal>
  );
}

function VoidCustoms({ e, onClose }: { e: any; onClose: () => void }) {
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title={`Void ${e.number}`} sub={`${e.description} · ${monthShort(e.entry_date)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="muted" style={{ fontSize: 13 }}>{e.journal_ref ? `${e.journal_ref} is reversed and the` : 'The'} import leaves the month's VAT return.</div>
        <Field label="Why"><input className="input" autoFocus value={reason} onChange={(x) => setReason(x.target.value)} /></Field>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={async () => {
          setBusy(true);
          try { await rpc('void_customs_entry', { p_entry: e.id, p_reason: reason }); toast(`${e.number} voided`); await refresh(); onClose(); }
          catch (x) { toast((x as Error).message, 'err'); }
          setBusy(false);
        }}>Void</button></div>
    </Modal>
  );
}

