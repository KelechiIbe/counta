// What it costs TaxStreem to run Counta: every service it pays for, priced from Counta's own records of what was used,
// by business and by plan, with the fixed monthly bills shared out. For pricing plans and managing what each one includes.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, Field, Modal, ModalHead, SkeletonRows } from '../../components/ui';
import { pct, tidyError } from '../api';
import { Card, grid, PageHead, Tile } from '../ui';

const SERVICE: Record<string, string> = { gemini: 'Google Gemini', elevenlabs: 'ElevenLabs', twilio: 'Twilio', whatsapp: 'WhatsApp (Meta)', resend: 'Resend', mono: 'Mono',
  flutterwave: 'Flutterwave', supabase: 'Supabase', netlify: 'Netlify', digitalocean: 'DigitalOcean' };
const svc = (s: string) => SERVICE[s] || s;
const thisMonth = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 7);
const qty = (n: number) => (Math.abs(n) >= 1000 ? Math.round(n).toLocaleString('en-NG') : String(Math.round(n * 100) / 100));

export default function Costs() {
  const [month, setMonth] = useState(thisMonth());
  const [sort, setSort] = useState<'total_ngn' | 'revenue_ngn' | 'margin'>('total_ngn');
  const q = useQuery({ queryKey: ['admin-costs', month], queryFn: () => rpc<any>('admin_costs', { p_month: month }) });
  const d = q.data;
  const t = d?.totals || {};
  const taxstreem = Number(t.variable_ngn || 0) + Number(t.fixed_ngn || 0);
  const margin = Number(t.revenue_ngn) > 0 ? (Number(t.revenue_ngn) - taxstreem) / Number(t.revenue_ngn) : null;
  const businesses: any[] = (d?.businesses || []).map((b: any) => ({ ...b, margin: Number(b.revenue_ngn) > 0 ? (Number(b.revenue_ngn) - Number(b.total_ngn)) / Number(b.revenue_ngn) : null }))
    .sort((a: any, b: any) => (sort === 'margin' ? (a.margin ?? -99) - (b.margin ?? -99) : Number(b[sort]) - Number(a[sort])));
  return (
    <div className="stack" style={{ gap: 18 }}>
      <PageHead title="Cost of service" sub="What TaxStreem pays to run Counta, priced from what each business used. Rates start from the providers' published prices and are marked until someone checks them against the bills. Fees businesses pay themselves are shown apart."
        right={<input className="input" type="month" value={month} max={thisMonth()} onChange={(e) => setMonth(e.target.value || thisMonth())} aria-label="Month" style={{ width: 170 }} />} />
      {q.isLoading ? <SkeletonRows n={8} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
        <>
          {(Number(d.to_check?.rates) > 0 || Number(d.to_check?.fixed_missing) > 0 || d.to_check?.no_usd_rate) && (
            <Alert kind="amber" icon="alert">
              {Number(d.to_check.rates) > 0 && <>{d.to_check.rates} rate{Number(d.to_check.rates) === 1 ? ' has' : 's have'} not been checked against the providers' bills. </>}
              {Number(d.to_check.fixed_missing) > 0 && <>{d.to_check.fixed_missing} fixed monthly bill{Number(d.to_check.fixed_missing) === 1 ? ' has' : 's have'} no amount yet. </>}
              {d.to_check.no_usd_rate && <>There is no dollar rate for the month, so dollar prices count as nothing; set one under Currency.</>}
            </Alert>
          )}
          <div style={grid(170)}>
            <Tile label="TaxStreem's cost" value={N2(taxstreem)} sub={`${N2(t.variable_ngn)} from use, ${N2(t.fixed_ngn)} fixed`} />
            <Tile label="Plan revenue, without VAT" value={N2(t.revenue_ngn)} sub={margin == null ? 'No plan payments this month' : `Margin ${pct(margin, 1)}`} tone={margin != null && margin < 0 ? '#B91C1C' : undefined} />
            <Tile label="Businesses" value={Number(t.businesses || 0).toLocaleString()} sub={`Fixed bills ${N2(t.fixed_share_ngn)} each`} />
            <Tile label="Paid by businesses" value={N2(t.passthrough_ngn)} sub="Flutterwave fees on their sales and payouts" />
            <Tile label="Not tied to a business" value={N2(t.unattributed_ngn)} sub="Sign-ups and lookups before a business exists" />
          </div>
          <div className="faint" style={{ fontSize: 12 }}>Dollars at ₦{d.usd_rate ? Number(d.usd_rate.rate).toLocaleString('en-NG') : '—'} ({d.usd_rate ? `${d.usd_rate.source === 'manual' ? 'set by hand' : 'fetched'} for ${fmtDay(d.usd_rate.day)}` : 'no rate'}).</div>

          <Card title="Every cost element" sub="What was used this month and what it cost. Open Rates below to change a price." pad={false}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(200px,1.6fr) 150px 140px 90px 110px', minWidth: 700 }}>
              <span>Element</span><span className="right">Used</span><span className="right">Cost</span><span>Businesses</span><span>Rate</span></div>
              {!(d.elements || []).length ? <div style={{ padding: 16 }} className="faint">Nothing used this month.</div> : (d.elements || []).map((e: any) => (
                <div key={e.service + e.measure} className="tr" style={{ gridTemplateColumns: 'minmax(200px,1.6fr) 150px 140px 90px 110px', minWidth: 700 }}>
                  <span><b>{e.label}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{svc(e.service)}{e.borne_by === 'business' ? ' · paid by the business' : ''}</span></span>
                  <span className="right num">{qty(Number(e.qty))}</span>
                  <span className="right num">{e.priced ? N2(e.cost_ngn) : <span className="faint">no rate</span>}</span>
                  <span className="num">{e.businesses}</span>
                  <span>{e.checked ? <span className="chip t-green">checked</span> : <span className="chip t-amber">to check</span>}</span>
                </div>
              ))}
            </div>
          </Card>

          <Card title="By plan" sub="Revenue without VAT against what the plan's businesses cost, fixed bills included." pad={false}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(160px,1.2fr) 90px 130px 130px 130px 100px 100px', minWidth: 780 }}>
              <span>Plan</span><span>Businesses</span><span className="right">Revenue</span><span className="right">Cost of use</span><span className="right">Fixed share</span><span className="right">Margin</span><span className="right">Target</span></div>
              {(d.plans || []).map((p: any) => (
                <div key={p.code} className="tr" style={{ gridTemplateColumns: 'minmax(160px,1.2fr) 90px 130px 130px 130px 100px 100px', minWidth: 780 }}>
                  <span><b>{p.plan}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{Number(p.price_month) > 0 ? `${N2(p.price_month)} a month` : 'Free'}</span></span>
                  <span className="num">{p.businesses}</span><span className="right num">{N2(p.revenue_ngn)}</span><span className="right num">{N2(p.variable_ngn)}</span>
                  <span className="right num">{N2(p.fixed_ngn)}</span>
                  <span className="right num" style={{ color: p.margin != null && Number(p.margin) < Number(p.target_margin) ? '#B91C1C' : undefined }}>{p.margin == null ? '—' : pct(p.margin, 1)}</span>
                  <span className="right num faint">{pct(p.target_margin, 0)}</span>
                </div>
              ))}
            </div>
          </Card>

          <Card title="By business" right={<select className="input input-sm" value={sort} onChange={(e) => setSort(e.target.value as any)} aria-label="Sort" style={{ width: 170 }}>
            <option value="total_ngn">Dearest first</option><option value="revenue_ngn">Most revenue first</option><option value="margin">Lowest margin first</option></select>} pad={false}>
            <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 110px 120px 120px 120px 90px minmax(160px,1fr)', minWidth: 900 }}>
              <span>Business</span><span>Plan</span><span className="right">Cost</span><span className="right">Revenue</span><span className="right">Paid by them</span><span className="right">Margin</span><span>Biggest costs</span></div>
              {businesses.slice(0, 100).map((b: any) => (
                <div key={b.org_id} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1.4fr) 110px 120px 120px 120px 90px minmax(160px,1fr)', minWidth: 900 }}>
                  <Link to={`/admin/businesses/${b.org_id}`} className="ellipsis" style={{ fontWeight: 600 }}>{b.name}</Link>
                  <span className="muted">{b.plan}</span><span className="right num">{N2(b.total_ngn)}</span><span className="right num">{N2(b.revenue_ngn)}</span>
                  <span className="right num faint">{N2(b.passthrough_ngn)}</span>
                  <span className="right num" style={{ color: b.margin != null && b.margin < 0 ? '#B91C1C' : undefined }}>{b.margin == null ? '—' : pct(b.margin, 0)}</span>
                  <span className="faint ellipsis" style={{ fontSize: 12 }}>{Object.entries(b.by_service || {}).filter(([, v]) => Number(v) > 0).sort((a, c) => Number(c[1]) - Number(a[1])).slice(0, 3).map(([k, v]) => `${svc(k)} ${N2(Number(v))}`).join(' · ') || '—'}</span>
                </div>
              ))}
            </div>
          </Card>

          <Rates rates={d.rates || []} />
          <Fixed rows={d.fixed || []} />
        </>
      )}
    </div>
  );
}

function Rates({ rates }: { rates: any[] }) {
  const [editing, setEditing] = useState<any | null>(null);
  return (
    <Card title="Rates" sub="One price for each thing used. A model's own rate wins over the general one; a rate applies from its date, so a price change is a new rate." right={<button className="btn btn-secondary btn-sm" onClick={() => setEditing({ currency: 'USD', unit_qty: 1, item: '*', borne_by: 'taxstreem', effective_from: new Date().toISOString().slice(0, 10) })}>Add a rate</button>} pad={false}>
      <div className="tbl"><div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(200px,1.6fr) 150px 110px 110px 120px 80px', minWidth: 780 }}>
        <span>What</span><span className="right">Price</span><span>From</span><span>Paid by</span><span>Checked</span><span /></div>
        {rates.map((r) => (
          <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(200px,1.6fr) 150px 110px 110px 120px 80px', minWidth: 780 }}>
            <span><b>{r.label}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{svc(r.service)} · {r.measure}{r.item !== '*' ? ` · ${r.item}` : ''}</span>
              {r.note && <span className="faint" style={{ display: 'block', fontSize: 11 }}>{r.note}</span>}</span>
            <span className="right num">{r.currency === 'NGN' ? '₦' : r.currency === 'USD' ? '$' : r.currency + ' '}{Number(r.price).toLocaleString('en-NG', { maximumFractionDigits: 6 })}<span className="faint" style={{ display: 'block', fontSize: 11 }}>per {r.unit_label}</span></span>
            <span className="muted">{fmtDay(r.effective_from)}</span>
            <span className="muted">{r.borne_by === 'business' ? 'the business' : 'TaxStreem'}</span>
            <span>{r.checked ? <span className="chip t-green" title={r.checked_at ? `${when(r.checked_at)}${r.checked_by_email ? ` by ${r.checked_by_email}` : ''}` : undefined}>checked</span> : <span className="chip t-amber">to check</span>}</span>
            <span><button className="btn btn-ghost btn-xs" onClick={() => setEditing(r)}>Edit</button></span>
          </div>
        ))}
      </div>
      {editing && <RateModal rate={editing} onClose={() => setEditing(null)} />}
    </Card>
  );
}

function RateModal({ rate, onClose }: { rate: any; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState<any>({ ...rate, price: rate.price != null ? String(Number(rate.price)) : '', unit_qty: String(Number(rate.unit_qty || 1)) });
  const [busy, setBusy] = useState(false);
  const set = (k: string, v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const isNew = !rate.id;
  async function save(remove = false) {
    setBusy(true);
    try {
      if (remove) await rpc('admin_remove_cost_rate', { p_id: rate.id });
      else await rpc('admin_save_cost_rate', { p: { id: rate.id || null, service: f.service, item: f.item, measure: f.measure, label: f.label, unit_qty: f.unit_qty, unit_label: f.unit_label,
        price: f.price, currency: f.currency, effective_from: f.effective_from, borne_by: f.borne_by, source_url: f.source_url || '', note: f.note || '', checked: !!f.checked } });
      toast(remove ? 'Rate removed' : 'Rate saved'); await qc.invalidateQueries({ queryKey: ['admin-costs'] }); onClose();
    } catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={isNew ? 'Add a rate' : rate.label} sub={isNew ? undefined : `${svc(rate.service)} · ${rate.measure}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        {isNew && <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
          <Field label="Service"><input className="input" value={f.service || ''} onChange={(e) => set('service', e.target.value)} placeholder="gemini" /></Field>
          <Field label="What is measured"><input className="input" value={f.measure || ''} onChange={(e) => set('measure', e.target.value)} placeholder="input_tokens" /></Field>
          <Field label="Model or product" hint="* for any"><input className="input" value={f.item || '*'} onChange={(e) => set('item', e.target.value)} /></Field>
        </div>}
        <Field label="Name"><input className="input" value={f.label || ''} onChange={(e) => set('label', e.target.value)} /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 90px 1fr 1fr', gap: 10 }}>
          <Field label="Price"><input className="input num" inputMode="decimal" value={f.price} onChange={(e) => set('price', e.target.value)} /></Field>
          <Field label="In"><select className="input" value={f.currency} onChange={(e) => set('currency', e.target.value)}>{['USD', 'NGN', 'EUR', 'GBP'].map((c) => <option key={c}>{c}</option>)}</select></Field>
          <Field label="For this many"><input className="input num" inputMode="decimal" value={f.unit_qty} onChange={(e) => set('unit_qty', e.target.value)} /></Field>
          <Field label="Of"><input className="input" value={f.unit_label || ''} onChange={(e) => set('unit_label', e.target.value)} placeholder="1M tokens" /></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Applies from"><input className="input" type="date" value={String(f.effective_from || '').slice(0, 10)} onChange={(e) => set('effective_from', e.target.value)} /></Field>
          <Field label="Paid by"><select className="input" value={f.borne_by} onChange={(e) => set('borne_by', e.target.value)}><option value="taxstreem">TaxStreem</option><option value="business">The business</option></select></Field>
        </div>
        <Field label="Where the price comes from"><input className="input" value={f.source_url || ''} onChange={(e) => set('source_url', e.target.value)} placeholder="https://" /></Field>
        <Field label="Note"><input className="input" value={f.note || ''} onChange={(e) => set('note', e.target.value)} /></Field>
        <label className="check"><input type="checkbox" checked={!!f.checked} onChange={(e) => set('checked', e.target.checked)} />Checked against the provider's bill or agreement</label>
      </div>
      <div className="modal-ft">
        {!isNew && <button className="btn btn-ghost" disabled={busy} onClick={() => { if (window.confirm('Remove this rate? Use of it then shows with no price.')) void save(true); }}>Remove</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || f.price === '' || !f.label} onClick={() => save()}>Save</button>
      </div>
    </Modal>
  );
}

function Fixed({ rows }: { rows: any[] }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [editing, setEditing] = useState<any | null>(null);
  const [busy, setBusy] = useState(false);
  async function save(p: any, remove = false) {
    setBusy(true);
    try { await rpc('admin_save_fixed_cost', { p: remove ? { id: p.id, remove: true } : p }); toast(remove ? 'Removed' : 'Saved'); await qc.invalidateQueries({ queryKey: ['admin-costs'] }); setEditing(null); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Card title="Fixed monthly bills" sub="Plans and servers TaxStreem pays for each month whatever the use. Shared equally across the month's businesses." right={<button className="btn btn-secondary btn-sm" onClick={() => setEditing({ currency: 'USD' })}>Add a bill</button>} pad={false}>
      <div className="tbl">
        {rows.map((r) => (
          <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(200px,1.6fr) 150px 140px 140px 80px', minWidth: 700 }}>
            <span><b>{r.label}</b><span className="faint" style={{ display: 'block', fontSize: 11 }}>{svc(r.service)}{r.note ? ` · ${r.note}` : ''}</span></span>
            <span className="right num">{r.monthly_amount == null ? <span className="chip t-amber">enter it</span> : `${r.currency === 'NGN' ? '₦' : r.currency === 'USD' ? '$' : r.currency + ' '}${Number(r.monthly_amount).toLocaleString('en-NG')}`}</span>
            <span className="right num faint">{r.ngn != null ? N2(r.ngn) : ''}</span>
            <span className="muted" style={{ fontSize: 12 }}>from {fmtDay(r.from_month)}{r.to_month ? ` to ${fmtDay(r.to_month)}` : ''}</span>
            <span><button className="btn btn-ghost btn-xs" onClick={() => setEditing({ ...r, monthly_amount: r.monthly_amount == null ? '' : String(Number(r.monthly_amount)) })}>Edit</button></span>
          </div>
        ))}
      </div>
      {editing && (
        <Modal onClose={() => setEditing(null)} width={500}>
          <ModalHead title={editing.id ? editing.label : 'Add a monthly bill'} onClose={() => setEditing(null)} />
          <div className="modal-body stack" style={{ gap: 10 }}>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1.6fr', gap: 10 }}>
              <Field label="Service"><input className="input" value={editing.service || ''} onChange={(e) => setEditing({ ...editing, service: e.target.value })} placeholder="supabase" /></Field>
              <Field label="Name"><input className="input" value={editing.label || ''} onChange={(e) => setEditing({ ...editing, label: e.target.value })} /></Field>
            </div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 100px', gap: 10 }}>
              <Field label="Each month"><input className="input num" inputMode="decimal" value={editing.monthly_amount ?? ''} onChange={(e) => setEditing({ ...editing, monthly_amount: e.target.value })} /></Field>
              <Field label="In"><select className="input" value={editing.currency} onChange={(e) => setEditing({ ...editing, currency: e.target.value })}>{['USD', 'NGN', 'EUR', 'GBP'].map((c) => <option key={c}>{c}</option>)}</select></Field>
            </div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
              <Field label="From"><input className="input" type="month" value={String(editing.from_month || '').slice(0, 7)} onChange={(e) => setEditing({ ...editing, from_month: e.target.value ? e.target.value + '-01' : '' })} /></Field>
              <Field label="Until" hint="Leave empty while it runs"><input className="input" type="month" value={String(editing.to_month || '').slice(0, 7)} onChange={(e) => setEditing({ ...editing, to_month: e.target.value ? e.target.value + '-01' : '' })} /></Field>
            </div>
            <Field label="Note"><input className="input" value={editing.note || ''} onChange={(e) => setEditing({ ...editing, note: e.target.value })} /></Field>
          </div>
          <div className="modal-ft">
            {editing.id && <button className="btn btn-ghost" disabled={busy} onClick={() => save(editing, true)}>Remove</button>}
            <button className="btn btn-secondary" onClick={() => setEditing(null)}>Cancel</button>
            <button className="btn btn-primary" disabled={busy || !editing.label || !editing.service} onClick={() => save({ id: editing.id || null, service: editing.service, label: editing.label, currency: editing.currency,
              monthly_amount: editing.monthly_amount, from_month: editing.from_month || null, to_month: editing.to_month || null, note: editing.note || '' })}>Save</button>
          </div>
        </Modal>
      )}
    </Card>
  );
}
