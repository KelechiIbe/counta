// Recurring invoices: a customer billed on a schedule (a retainer, a rent, a subscription). Monthly on a day from 1 to 28,
// quarterly or yearly, from a start date to an optional end date. Counta issues each invoice on its day, dated that day,
// and sends it when the schedule says so; three failures in a row pause it. Prices are before VAT; a line marked once
// (a deposit, a set-up fee) goes on the first invoice only. Invoices are issued on the authority of whoever saved the
// schedule last, so saving it is also how someone takes it over.
//
// /sell/recurring?customer=<id>&client=<practice client id> opens a new schedule for that customer (the accountant
// portal's Fees page links here for a client's fees).
import { useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { cleanError, rpc } from '../../lib/supabase';
import { money, type RecurringLine, type RecurringSchedule, useCustomers, useRecurring } from '../../lib/api';
import { N2, fmtDay, lagosToday } from '../../lib/format';
import { useVatRate } from '../../lib/vat';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, SkeletonRows, Spinner } from '../../components/ui';
import { decidedText, waitsFor } from '../../lib/approvals';

const FREQ: Record<RecurringSchedule['frequency'], string> = { monthly: 'Monthly', quarterly: 'Every three months', annually: 'Every year' };
const STATUS: Record<RecurringSchedule['status'], [string, string]> = { active: ['Active', 't-green'], paused: ['Paused', 't-amber'], ended: ['Ended', 't-grey'] };
const RUN: Record<string, [string, string]> = {
  issued: ['Issued', 't-blue'], waiting_nrs: ['Waiting for NRS', 't-amber'], sent: ['Sent', 't-green'], failed: ['Failed', 't-red'], void: ['Not sent', 't-grey'],
};
const ord = (n: number) => `${n}${n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th'}`;
const month = (day: string) => new Date(day + 'T12:00:00Z').toLocaleDateString('en-GB', { month: 'long', timeZone: 'UTC' });

export function scheduleText(s: Pick<RecurringSchedule, 'frequency' | 'day_of_month' | 'next_run'>) {
  return s.frequency === 'annually' ? `Every year on ${s.day_of_month} ${month(s.next_run)}` : `${FREQ[s.frequency]} on the ${ord(s.day_of_month)}`;
}
// Each repeat invoice, VAT included where the business charges it (lines marked once are on the first only).
function eachTotal(lines: Pick<RecurringLine, 'qty' | 'unit_price' | 'vat_treatment' | 'once'>[], vat: boolean, rate: number) {
  return lines.filter((l) => !l.once).reduce((t, l) => {
    const net = Math.round(Number(l.qty) * Number(l.unit_price) * 100) / 100;
    return t + Math.round(net * (1 + (vat && l.vat_treatment === 'standard' ? rate : 0)) * 100) / 100;
  }, 0);
}

export default function Recurring() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const [params, setParams] = useSearchParams();
  const q = useRecurring(can(inv, 'record_sales') ? orgId : null);
  const vat = useVatRate();
  const [open, setOpen] = useState<RecurringSchedule | 'new' | null>(() => (params.get('customer') ? 'new' : null));
  if (!inv) return null;
  if (!can(inv, 'record_sales')) return <div className="container" style={{ maxWidth: 1000 }}><Alert kind="yellow" icon="shield">Only someone who records sales sees and sets up recurring invoices.</Alert></div>;
  const list = q.data || [];
  function close() {
    setOpen(null);
    if (params.get('customer') || params.get('client')) { params.delete('customer'); params.delete('client'); setParams(params, { replace: true }); }
  }
  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="muted" style={{ fontSize: 14, maxWidth: 620, lineHeight: 1.5 }}>
          Bill a customer the same amount on a schedule, such as a monthly retainer. Counta issues each invoice on its day and, if you choose, sends it.
        </div>
        <button className="btn btn-primary btn-sm" onClick={() => setOpen('new')} data-testid="recurring-new"><Icon name="plus" size={14} color="#fff" />New recurring invoice</button>
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {q.isLoading ? <SkeletonRows n={4} /> : q.isError ? <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{cleanError(q.error)}</Alert></div>
          : !list.length ? <div style={{ padding: 20 }}><Empty>No recurring invoices yet.</Empty></div> : (
          <>
            <div className="tr head shade th rsp" style={{ gridTemplateColumns: 'minmax(0,1.5fr) 150px 150px 110px' }}><span>Customer</span><span>Next invoice</span><span className="right">Each invoice</span><span className="right">Status</span></div>
            {list.map((s) => {
              const [label, tone] = STATUS[s.status];
              return (
                <button key={s.id} type="button" className="tr click rsp" onClick={() => setOpen(s)} data-testid="recurring-row"
                  style={{ gridTemplateColumns: 'minmax(0,1.5fr) 150px 150px 110px', width: '100%', textAlign: 'left', background: 'none', border: 0, borderTop: '1px solid var(--row)', font: 'inherit', color: 'inherit' }}>
                  <span className="m-main" style={{ minWidth: 0 }}><b>{s.customer_name}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{scheduleText(s)}{s.end_date ? ` · until ${fmtDay(s.end_date)}` : ''}</span></span>
                  <span className="muted">{s.status === 'ended' ? '—' : fmtDay(s.next_run)}</span>
                  <span className="right num">{N2(eachTotal(s.lines, !!inv.org.vat_registered, vat.on(s.next_run)))}</span>
                  <span className="right"><span className={'chip ' + (s.approval_state === 'pending' ? 't-amber' : s.approval_state === 'rejected' ? 't-red' : tone)}>
                    {s.approval_state === 'pending' ? 'To approve' : s.approval_state === 'rejected' ? 'Not approved' : s.failures > 0 && s.status === 'active' ? `${s.failures} failed` : label}</span></span>
                </button>
              );
            })}
          </>
        )}
      </div>
      {open && <Editor key={open === 'new' ? 'new' : open.id} s={open === 'new' ? null : open} preset={{ customer: params.get('customer'), client: params.get('client') }}
        onClose={close} onSaved={(x) => setOpen(x)} />}
    </div>
  );
}

type LineDraft = { key: string; description: string; qty: string; unit_price: string; vat_treatment: RecurringLine['vat_treatment']; once: boolean; saved: boolean };
const blankLine = (): LineDraft => ({ key: crypto.randomUUID(), description: '', qty: '1', unit_price: '', vat_treatment: 'standard', once: false, saved: false });

function Editor({ s, preset, onClose, onSaved }: { s: RecurringSchedule | null; preset: { customer: string | null; client: string | null }; onClose: () => void;
  onSaved: (s: RecurringSchedule) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const vat = useVatRate();
  const customers = (useCustomers().data?.customers || []).filter((c) => !c.is_walk_in && (!c.archived || c.id === s?.customer_id));
  const downloadOnly = inv?.org.send_mode === 'download_only';
  const today = lagosToday();
  const [f, setF] = useState(() => ({
    customer_id: s?.customer_id || preset.customer || '', frequency: s?.frequency || 'monthly', day_of_month: String(s?.day_of_month || 1),
    start_date: s?.start_date || today, end_date: s?.end_date || '', due_days: String(s?.due_days ?? 14),
    auto_send: s ? s.auto_send && !downloadOnly : !downloadOnly, send_channel: s?.send_channel || 'email', notes: s?.notes || '',
  }));
  const [lines, setLines] = useState<LineDraft[]>(() => s ? s.lines.map((l) => ({ ...l, key: crypto.randomUUID(), qty: String(l.qty), unit_price: String(l.unit_price), saved: true })) : [blankLine()]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [ending, setEnding] = useState(false);
  const issued = !!s?.runs.some((r) => ['issued', 'waiting_nrs', 'sent'].includes(r.status));
  const vatOn = !!inv?.org.vat_registered;
  const preview = useMemo(() => eachTotal(lines.map((l) => ({ ...l, qty: Number(l.qty) || 0, unit_price: money(l.unit_price) || 0 })), vatOn, vat.on(s?.next_run || f.start_date)),
    [lines, vatOn, vat, s?.next_run, f.start_date]);
  if (!inv) return null;
  const patch = (key: string, p: Partial<LineDraft>) => setLines((xs) => xs.map((x) => (x.key === key ? { ...x, ...p } : x)));
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['recurring'] }), qc.invalidateQueries({ queryKey: ['sales'] })]);

  async function save() {
    setErr(null);
    if (!f.customer_id) { setErr('Choose the customer.'); return; }
    const clean = lines.filter((l) => l.description.trim() || l.unit_price.trim());
    if (!clean.length) { setErr('Add at least one line.'); return; }
    for (const l of clean) {
      if (!l.description.trim()) { setErr('Every line needs a description.'); return; }
      if (!(Number(l.qty) > 0)) { setErr(`Give "${l.description.trim()}" a quantity above 0.`); return; }
      if (money(l.unit_price) == null || (money(l.unit_price) as number) < 0) { setErr(`Give "${l.description.trim()}" a price.`); return; }
    }
    setBusy('save');
    try {
      const x = await rpc<RecurringSchedule>('recurring_save', { p_org: orgId, p: {
        ...(s ? { id: s.id } : {}), customer_id: f.customer_id, frequency: f.frequency, day_of_month: Number(f.day_of_month), start_date: f.start_date,
        end_date: f.end_date || null, due_days: Number(f.due_days) || 0, auto_send: downloadOnly ? false : f.auto_send, send_channel: f.send_channel,
        notes: f.notes.trim() || null, practice_client_id: s?.practice_client_id || preset.client || null,
        lines: clean.map((l) => ({ description: l.description.trim(), qty: Number(l.qty), unit_price: money(l.unit_price), vat_treatment: l.vat_treatment, once: l.once })),
      } });
      await refresh();
      toast(x.approval_state === 'pending' ? `Saved. It runs once ${waitsFor(x.approval || { approver: 'owner' })} approves it.`
        : s ? 'Saved' : `Set up: the first invoice is on ${fmtDay(x.next_run)}`);
      onSaved(x);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function status(to: RecurringSchedule['status']) {
    if (!s) return;
    setErr(null); setBusy(to);
    try { const x = await rpc<RecurringSchedule>('recurring_set_status', { p_id: s.id, p_status: to }); await refresh(); onSaved(x); setEnding(false); toast(to === 'active' ? 'Resumed' : to === 'paused' ? 'Paused' : 'Ended'); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function runNow() {
    if (!s) return;
    setErr(null); setBusy('run');
    try {
      const r = await rpc<{ sale_id: string; number: string; status: string; send_error: string | null; schedule: RecurringSchedule }>('recurring_run_now', { p_id: s.id });
      await refresh(); onSaved(r.schedule);
      toast(r.send_error ? `Invoice ${r.number} issued, but it was not sent: ${r.send_error}` : r.status === 'sent' ? `Invoice ${r.number} issued and sent` : `Invoice ${r.number} issued`,
        r.send_error ? 'err' : undefined);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }

  const missed = s?.status === 'paused' && s.next_run < today;
  const disabled = busy !== null;
  return (
    <Drawer onClose={onClose} width={780}>
      <div className="drawer-hd">
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="drawer-title">{s ? s.customer_name : 'New recurring invoice'}</div>
          {s && <div className="faint" style={{ fontSize: 12 }}>{scheduleText(s)} · <span className={'chip ' + STATUS[s.status][1]}>{STATUS[s.status][0]}</span></div>}
        </div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button>
      </div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        {s?.approval_state === 'pending' && <Alert kind="amber" icon="clock"><span data-testid="recurring-approval">Waiting for {waitsFor(s.approval || { approver: 'owner' })} to approve this
          schedule. Once approved it runs on its own; it waits again only if the firm changes it.</span></Alert>}
        {s?.approval_state === 'rejected' && s.approval && <Alert kind="red" icon="alert"><span data-testid="recurring-approval">{decidedText(s.approval)}. The schedule is paused.
          Change it and save it to ask again.</span></Alert>}
        {s?.status === 'paused' && s.last_error && (
          <Alert kind="amber" icon="alert">
            Paused after {s.failures >= 3 ? 'three failures in a row' : 'a failure'}: {s.last_error} Put the cause right and save the schedule (whoever saves it issues its invoices), then resume it.
          </Alert>
        )}
        {s?.status === 'active' && s.failures > 0 && s.last_error && <Alert kind="amber" icon="alert">The last try failed: {s.last_error} Counta tries again on the next run; three failures in a row pause it.</Alert>}
        {missed && (
          <Alert kind="blue" icon="clock">
            The invoice due on {fmtDay(s!.next_run)} was not issued while the schedule was paused. Resuming skips it. If it is owed, issue it first.
            <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-sm" disabled={disabled} onClick={runNow}>{busy === 'run' ? <Spinner small /> : null}Issue the missed invoice</button></div>
          </Alert>
        )}
        <Field label="Customer">
          <select className="input" value={f.customer_id} onChange={(e) => setF({ ...f, customer_id: e.target.value })} data-testid="recurring-customer">
            <option value="">Choose the customer</option>
            {customers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0,1fr))', gap: 12 }}>
          <Field label="How often">
            <select className="input" value={f.frequency} onChange={(e) => setF({ ...f, frequency: e.target.value as RecurringSchedule['frequency'] })} data-testid="recurring-frequency">
              <option value="monthly">Monthly</option><option value="quarterly">Every three months</option><option value="annually">Every year</option>
            </select>
          </Field>
          <Field label="On day" hint="1 to 28, so every month has it.">
            <select className="input" value={f.day_of_month} onChange={(e) => setF({ ...f, day_of_month: e.target.value })} data-testid="recurring-day">
              {Array.from({ length: 28 }, (_, i) => <option key={i + 1} value={String(i + 1)}>{ord(i + 1)}</option>)}
            </select>
          </Field>
          <Field label="Days to pay">
            <input className="input num" inputMode="numeric" value={f.due_days} maxLength={3} onChange={(e) => setF({ ...f, due_days: e.target.value.replace(/\D/g, '') })} data-testid="recurring-due-days" />
          </Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0,1fr))', gap: 12 }}>
          <Field label="Starts"><input className="input" type="date" value={f.start_date} onChange={(e) => setF({ ...f, start_date: e.target.value })} data-testid="recurring-start" /></Field>
          <Field label="Ends (optional)"><input className="input" type="date" min={f.start_date} value={f.end_date} onChange={(e) => setF({ ...f, end_date: e.target.value })} data-testid="recurring-end" /></Field>
        </div>

        <div className="label">Lines (prices before VAT)</div>
        <div className="card" style={{ overflow: 'visible' }}>
          {lines.map((l) => (
            <div key={l.key} className="rec-line" data-testid="recurring-line">
              <input className="input input-sm rec-desc" placeholder="Description, e.g. Monthly bookkeeping retainer" maxLength={300} value={l.description}
                onChange={(e) => patch(l.key, { description: e.target.value })} aria-label="Description" />
              <input className="input input-sm num rec-qty" inputMode="decimal" value={l.qty} onChange={(e) => patch(l.key, { qty: e.target.value })} aria-label="Quantity" />
              <input className="input input-sm num rec-price" inputMode="decimal" placeholder="0.00" value={l.unit_price} onChange={(e) => patch(l.key, { unit_price: e.target.value })} aria-label="Unit price before VAT" />
              <select className="input input-sm rec-vat" value={l.vat_treatment} disabled={!vatOn} onChange={(e) => patch(l.key, { vat_treatment: e.target.value as RecurringLine['vat_treatment'] })}
                aria-label="VAT" data-testid="recurring-line-vat">
                <option value="standard">VAT {vat.pct(s?.next_run || f.start_date)}</option><option value="zero">Zero-rated</option><option value="exempt">Exempt</option>
              </select>
              <label className="check rec-once" title={issued && !l.saved ? 'This schedule has issued an invoice already: a new line marked once would never be billed.' : 'On the first invoice only'}>
                <input type="checkbox" checked={l.once} disabled={issued && !l.saved && !l.once} onChange={(e) => patch(l.key, { once: e.target.checked })} data-testid="recurring-line-once" />First invoice only
              </label>
              <button type="button" className="btn btn-ghost btn-xs rec-x" disabled={lines.length === 1} onClick={() => setLines((xs) => xs.filter((x) => x.key !== l.key))} aria-label="Remove the line"><Icon name="trash" size={13} /></button>
            </div>
          ))}
          <div className="row wrap" style={{ padding: 12, gap: 8, justifyContent: 'space-between', alignItems: 'center' }}>
            <button type="button" className="btn btn-secondary btn-sm" disabled={lines.length >= 50} onClick={() => setLines((xs) => [...xs, blankLine()])}><Icon name="plus" size={14} />Add a line</button>
            <span style={{ fontSize: 14 }}>Each invoice <b className="num">{N2(preview)}</b>{vatOn ? <span className="faint"> VAT included</span> : null}</span>
          </div>
        </div>
        {!vatOn && <div className="faint" style={{ fontSize: 12 }}>The business is not registered for VAT, so no VAT is charged on any line.</div>}

        <div className="stack" style={{ gap: 8 }}>
          <label className="check"><input type="checkbox" checked={f.auto_send} disabled={downloadOnly} onChange={(e) => setF({ ...f, auto_send: e.target.checked })} data-testid="recurring-auto-send" />
            Send each invoice to the customer
          </label>
          {downloadOnly ? <div className="faint" style={{ fontSize: 12 }}>This business downloads its documents and sends them itself, so each invoice is issued for you to send.</div> : f.auto_send && (
            <Field label="Send by" style={{ maxWidth: 240 }}>
              <select className="input" value={f.send_channel} onChange={(e) => setF({ ...f, send_channel: e.target.value as 'email' | 'whatsapp' })}><option value="email">Email</option><option value="whatsapp">WhatsApp</option></select>
            </Field>
          )}
        </div>
        <Field label="Note printed on each invoice" hint="The customer sees it.">
          <textarea className="input" rows={2} maxLength={1000} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
        </Field>
        {s && <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Invoices are issued on the authority of {s.created_by_name || 'the person who set it up'}. Whoever saves the schedule takes that over.</div>}
        {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}

        {s && (
          <div className="stack" style={{ gap: 8 }} data-testid="recurring-runs">
            <div className="label">Invoices made{s.status !== 'ended' ? ` · next on ${fmtDay(s.next_run)}` : ''}</div>
            {!s.runs.length ? <div className="faint" style={{ fontSize: 14 }}>None yet.</div> : (
              <div className="card" style={{ overflow: 'hidden' }}>
                {s.runs.map((r) => (
                  <div key={r.id} className="tr rsp" style={{ gridTemplateColumns: '120px minmax(0,1fr) 130px 130px' }}>
                    <span className="muted">{fmtDay(r.run_date)}</span>
                    <span className="m-main" style={{ minWidth: 0 }}>
                      {r.sale_id && r.number ? <Link to={`/sell/sales?open=${r.sale_id}`}>{r.number}</Link> : '—'}
                      {(r.error || r.send_error) && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{r.error || `Not sent: ${r.send_error}`}</span>}
                    </span>
                    <span className="right num">{r.total != null ? N2(r.total) : ''}</span>
                    <span className="right"><span className={'chip ' + (RUN[r.status] || ['', 't-grey'])[1]}>{(RUN[r.status] || [r.status])[0]}</span></span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
      <div className="drawer-ft" style={{ flexWrap: 'wrap', gap: 8 }}>
        {s && s.status !== 'ended' && (
          <>
            {s.status === 'active' && <button className="btn btn-ghost btn-sm" disabled={disabled} onClick={() => status('paused')} data-testid="recurring-pause">{busy === 'paused' ? <Spinner small /> : null}Pause</button>}
            {s.status === 'paused' && s.approval_state !== 'rejected' && <button className="btn btn-ghost btn-sm" disabled={disabled} onClick={() => status('active')} data-testid="recurring-resume">{busy === 'active' ? <Spinner small /> : null}Resume</button>}
            {!ending ? <button className="btn btn-ghost btn-sm" disabled={disabled} onClick={() => setEnding(true)}>End it</button>
              : <button className="btn btn-danger btn-sm" disabled={disabled} onClick={() => status('ended')}>{busy === 'ended' ? <Spinner small /> : null}Yes, end it</button>}
            {!missed && (s.approval_state ?? 'approved') === 'approved' && <button className="btn btn-secondary btn-sm" disabled={disabled} onClick={runNow} data-testid="recurring-run-now">{busy === 'run' ? <Spinner small /> : <Icon name="zap" size={14} />}Issue the next invoice now</button>}
          </>
        )}
        <span className="grow" />
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        <button className="btn btn-primary" disabled={disabled} onClick={save} data-testid="recurring-save">{busy === 'save' ? <Spinner small /> : null}{s ? 'Save changes' : 'Set it up'}</button>
      </div>
    </Drawer>
  );
}
