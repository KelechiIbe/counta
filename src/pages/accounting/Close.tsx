// Period close: a checklist that must pass before a month locks (banks reconciled, suspense empty, questions answered,
// payments confirmed, ledgers agreeing, VAT tied out). Blocking steps can only be waived by the owner, with a reason.
// Closing accrues draft bills, runs depreciation, closes stock (IAS 2 review) and locks the month. The year closes
// once all twelve months are closed, moving profit to retained earnings.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { lastMonthEnd, money, useChecklist, useOverview } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, SkeletonRows } from '../../components/ui';

const LINK: Record<string, string> = {
  bank_reconciled: '/accounting/banking', suspense_clear: '/accounting/inbox', inbox_clear: '/accounting/inbox', payments_confirmed: '/sell/sales?tab=confirm',
  till_sales: '/sell/sales', bills_approved: '/purchases/bills', assets_confirmed: '/accounting/assets', subledgers: '/accounting/ledgers', vat_tieout: '/accounting/ledgers',
  stock_close: '/inventory/month-end', ecl: '/accounting/close',
};

export default function Close() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [end, setEnd] = useState(lastMonthEnd());
  const cl = useChecklist(end);
  const ov = useOverview();
  const [waive, setWaive] = useState<any>(null);
  const [reason, setReason] = useState('');
  const [closing, setClosing] = useState(false);
  const [note, setNote] = useState('');
  const [rates, setRates] = useState({ current: '1', d1_30: '3', d31_60: '10', d61_90: '25', d90_plus: '50' });
  const [ecl, setEcl] = useState<any>(null);
  const [yearEnd, setYearEnd] = useState(`${Number(end.slice(0, 4)) - (end.slice(5, 7) === '12' ? 0 : 1)}-12-31`);
  if (!inv) return null;
  const owner = can(inv, 'owner');
  const keep = can(inv, 'keep_books');
  const refresh = () => Promise.all(['checklist', 'report', 'inbox', 'overview'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function act(fn: () => Promise<any>, ok: string | ((r: any) => string)) {
    try { const r = await fn(); toast(typeof ok === 'function' ? ok(r) : ok); await refresh(); return r; } catch (e) { toast((e as Error).message, 'err'); }
  }
  const d = cl.data;
  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="row"><span className="muted" style={{ fontSize: 14 }}>Close the month ending</span><input className="input input-sm" type="date" value={end} onChange={(e) => setEnd(e.target.value)} style={{ width: 160 }} /></div>
        {ov.data?.closed_through && <span className="muted" style={{ fontSize: 13 }}>Closed up to {fmtDay(ov.data.closed_through)}</span>}
      </div>
      {cl.isLoading ? <SkeletonRows n={8} /> : cl.error ? <Alert kind="yellow" icon="shield">{(cl.error as Error).message}</Alert> : d && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {(d.steps || []).map((s: any) => (
            <div key={s.key} className="tr" style={{ gridTemplateColumns: '28px minmax(0,1fr) auto', gap: 12 }}>
              <span style={{ width: 24, height: 24, borderRadius: 12, display: 'grid', placeItems: 'center', background: s.ok ? '#F0FDF4' : s.waived ? '#FEFCE8' : s.blocking ? '#FEF2F2' : '#F3F4F6' }}>
                <Icon name={s.ok ? 'check' : s.waived ? 'shield' : s.blocking ? 'x' : 'info'} size={13} color={s.ok ? '#15803D' : s.waived ? '#A16207' : s.blocking ? '#DC2626' : '#6B7280'} />
              </span>
              <span style={{ minWidth: 0 }}><b>{s.title}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{s.detail}{s.waived && s.waiver ? ` · waived by ${s.waiver.by}: ${s.waiver.reason}` : ''}{!s.blocking && !s.ok ? ' · does not stop the close' : ''}</span></span>
              <span className="row" style={{ gap: 4 }}>
                {!s.ok && LINK[s.key] && <Link className="btn btn-ghost btn-xs" to={LINK[s.key]}>Fix</Link>}
                {!s.ok && s.blocking && !s.waived && owner && <button className="btn btn-ghost btn-xs" onClick={() => setWaive(s)}>Waive</button>}
              </span>
            </div>
          ))}
        </div>
      )}
      {keep && (
        <div className="card card-pad stack" style={{ gap: 10 }}>
          <b>Expected credit losses on receivables (IFRS 9)</b>
          <div className="muted" style={{ fontSize: 13 }}>Loss rates by how late customers are. The allowance is adjusted to match; run it before closing.</div>
          <div className="row wrap" style={{ gap: 8 }}>
            {([['current', 'Not due'], ['d1_30', '1-30 days'], ['d31_60', '31-60'], ['d61_90', '61-90'], ['d90_plus', 'Over 90']] as const).map(([k, l]) => (
              <Field key={k} label={l}><input className="input input-sm" inputMode="decimal" value={rates[k]} onChange={(e) => setRates({ ...rates, [k]: e.target.value })} style={{ width: 80 }} /></Field>
            ))}
            <button className="btn btn-secondary btn-sm" style={{ alignSelf: 'flex-end' }} onClick={async () => {
              const r = await act(() => rpc('run_ecl', { p_org: orgId, p_as_of: end, p_rates: Object.fromEntries(Object.entries(rates).map(([k, v]) => [k, (money(v) ?? 0) / 100])) }), (x) => `Allowance now ${N2(x.allowance)}`);
              if (r) setEcl(r);
            }}>Update the allowance</button>
          </div>
          {ecl && <div className="faint" style={{ fontSize: 12 }}>Allowance {N2(ecl.allowance)} (was {N2(ecl.before)}){ecl.journal_ref ? ` · ${ecl.journal_ref}` : ''}</div>}
        </div>
      )}
      {d && (
        <div className="card card-pad stack" style={{ gap: 10 }}>
          {d.ready ? <Alert kind="green" icon="check">Ready to close {fmtDay(end)}.</Alert> : <Alert kind="yellow" icon="alert">Not ready: fix or waive the steps marked in red.</Alert>}
          <div className="muted" style={{ fontSize: 13 }}>Closing accrues the draft bills, runs depreciation, closes stock with the IAS 2 review, and locks the month. Anything dated in a closed month after that lands on the first open day.</div>
          {owner ? (
            <div className="row wrap">
              <input className="input input-sm" style={{ flex: '1 1 260px' }} placeholder="Note for the record (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
              <button className="btn btn-dark" disabled={!d.ready || closing} onClick={async () => { setClosing(true); await act(() => rpc('close_books', { p_org: orgId, p_period_end: end, p_policy: {}, p_overrides: [], p_note: note || null }), `Closed to ${fmtDay(end)}`); setClosing(false); }}>
                <Icon name="lock" size={14} color="#fff" />{closing ? 'Closing…' : `Close ${fmtDay(end)}`}</button>
            </div>
          ) : <Alert kind="grey" icon="shield">The owner closes the month. You can get everything ready.</Alert>}
        </div>
      )}
      {owner && (
        <div className="card card-pad stack" style={{ gap: 10 }}>
          <b>Close the financial year</b>
          <div className="muted" style={{ fontSize: 13 }}>Once all twelve months are closed, the year's profit or loss moves to retained earnings and the income and expense accounts start the new year at zero.</div>
          <div className="row wrap"><input className="input input-sm" type="date" value={yearEnd} onChange={(e) => setYearEnd(e.target.value)} style={{ width: 160 }} />
            <button className="btn btn-secondary btn-sm" onClick={() => act(() => rpc('close_year', { p_org: orgId, p_year_end: yearEnd }), (r) => `Year closed${r?.journal_ref ? ` · ${r.journal_ref}` : ''}`)}>Close the year</button></div>
        </div>
      )}
      {waive && (
        <Modal onClose={() => setWaive(null)} width={460}>
          <ModalHead title="Waive this step" sub={waive.title} onClose={() => setWaive(null)} />
          <div className="modal-body"><Field label="Why it is safe to close anyway" hint="Kept on the record with your name. Applies to this month only."><textarea className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
          <div className="modal-ft"><button className="btn btn-primary" disabled={reason.trim().length < 10} onClick={async () => { await act(() => rpc('waive_close_step', { p_org: orgId, p_period_end: end, p_step: waive.key, p_reason: reason }), 'Waived'); setWaive(null); setReason(''); }}>Waive</button></div>
        </Modal>
      )}
    </div>
  );
}
