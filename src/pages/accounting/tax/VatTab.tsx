// VAT month by month: output VAT on sales, input VAT on bills and stock (and VAT self-charged on services from abroad), VAT
// customers withheld, what is payable, and the input VAT credit carried forward. A month is filed once it has ended (freezing
// its figures and clearing the VAT accounts), then paid. Whether the business must charge VAT at all is decided here too.
import { useEffect, useState, type ReactNode } from 'react';
import { useInventory, useSession, useToast } from '../../../state/session';
import { rpc } from '../../../lib/supabase';
import { money, moneyAccounts, today } from '../../../lib/api';
import { N2, fmtDay } from '../../../lib/format';
import { addMonths, monthName, monthShort, useVatPosition } from '../../../lib/tax';
import { Icon } from '../../../components/Icon';
import { VatInfo } from '../../../components/VatInfo';
import { PeriodPicker } from '../../../components/PeriodPicker';
import { useScreenPeriod } from '../../../lib/period';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Stat } from '../../../components/ui';
import { ExportMenu, useMeta } from '../../../components/Books';
import { useTaxRefresh } from './CitTab';
import { CustomsPanel, VatReturnModal } from './VatReturn';
import { vatPct } from '../../../lib/vat';
import { PurchasesPanel, ReceiptsVatCard, SchedulesPanel, useVatSources } from './VatSources';

const STATUS: Record<string, { label: string; tone: string }> = {
  open: { label: 'Not filed', tone: 't-grey' }, filed: { label: 'Filed, to pay', tone: 't-amber' }, paid: { label: 'Filed', tone: 't-green' },
};

export default function VatTab() {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const meta = useMeta();
  const { data: inv } = useInventory();
  const [period, setPeriod] = useScreenPeriod(orgId, 'vat-months', 'l12', inv?.org.fiscal_year_start || 1);
  const from = period.from.slice(0, 7);
  const to = period.to.slice(0, 7);
  const q = useVatPosition(from + '-01', to + '-01');
  const [open, setOpen] = useState<any>(null);
  const [modal, setModal] = useState<null | { kind: 'file' | 'pay' | 'reopen' | 'charge'; m?: any; charge?: boolean }>(null);
  const [view, setView] = useState<'months' | 'schedules' | 'purchases' | 'customs'>('months');
  const src = useVatSources(orgId);
  const [nrs, setNrs] = useState<string | null>(null);
  const d = q.data;
  const st = d?.status || {};
  const months: any[] = d?.months || [];
  return (
    <div className="stack" style={{ gap: 14 }}>
      {q.isLoading ? <SkeletonRows n={6} /> : q.error ? <Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert> : d && (
        <>
          <VatStatus st={st} onChange={(charge) => setModal({ kind: 'charge', charge })} />
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(160px,1fr))', gap: 8 }}>
            <Stat label="Input VAT credit carried forward" value={N2(d.credit_cf)} color="#0072F5" />
            <Stat label="Refund can be claimed on" value={N2(d.refundable)} sub="credit from the last 12 months" />
            <Stat label="Withholding VAT to pay over" value={N2(d.wvat_due)} sub="see Withholding" />
            <Stat label="Months not filed" value={String(months.filter((m) => m.ended && m.status === 'open').length)} color={months.some((m) => m.overdue) ? '#DC2626' : undefined} />
          </div>
          {(d.expiring || []).length > 0 && <Alert kind="amber" icon="clock">Input VAT credit from {(d.expiring as any[]).map((l) => `${monthShort(l.from)} (${N2(l.amount)})`).join(', ')} lapses five years after it arose. Use it or claim a refund.</Alert>}
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <Pills value={view} onChange={setView} options={[{ id: 'months', label: 'By month' },
              { id: 'schedules', label: 'Sales from another POS', count: (src.data?.schedules || []).filter((s: any) => s.status === 'draft').length || undefined },
              { id: 'purchases', label: 'Input VAT invoices' }, { id: 'customs', label: 'Customs entries' }]} />
            {view === 'months' && <div className="row wrap" style={{ gap: 8 }}>
            <PeriodPicker value={period} onChange={setPeriod} presets={['qtd', 'lq', 'ytd', 'ly', 'l12', 'all']} label="Months shown" align="end" />
            <ExportMenu name={`VAT ${from} to ${to}`} disabled={!months.length} sheets={() => [{ meta: meta('VAT position', `${monthName(from)} to ${monthName(to)}`),
              cols: [{ key: 'month', label: 'Month' }, { key: 'output', label: 'Output VAT', type: 'money', total: true }, { key: 'input', label: 'Input VAT', type: 'money', total: true },
                { key: 'wvat_credit', label: 'Withheld by customers', type: 'money', total: true }, { key: 'credit_used', label: 'Credit used', type: 'money', total: true },
                { key: 'payable', label: 'Payable', type: 'money', total: true }, { key: 'credit_cf', label: 'Credit c/f', type: 'money' }, { key: 'state', label: 'Status' }],
              rows: months.map((m) => ({ ...m, month: monthName(m.period), state: STATUS[m.status]?.label })) as any }]} />
            </div>}
          </div>
          {view === 'customs' && <CustomsPanel canEdit={!!d.can_file} />}
          {view === 'schedules' && (src.isLoading ? <SkeletonRows n={3} /> : src.error ? <Alert kind="grey" icon="shield">{(src.error as Error).message}</Alert> : <>
            <SchedulesPanel data={src.data} canWork={!!src.data?.can?.work} />
            <ReceiptsVatCard settings={src.data?.settings} canWork={!!src.data?.can?.work} />
          </>)}
          {view === 'purchases' && (src.isLoading ? <SkeletonRows n={3} /> : src.error ? <Alert kind="grey" icon="shield">{(src.error as Error).message}</Alert>
            : <PurchasesPanel data={src.data} canWork={!!src.data?.can?.work} />)}
          {view === 'months' && <>
          <div className="card" style={{ overflow: 'auto' }}>
            <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '120px repeat(5,minmax(100px,1fr)) 120px 170px', minWidth: 1000 }}>
              <span>Month</span><span className="right">Output VAT</span><span className="right">Input VAT</span><span className="right">Withheld</span><span className="right">Payable</span><span className="right">Credit c/f</span><span>Status</span><span />
            </div>
            {!months.length ? <div style={{ padding: 20 }}><Empty>No VAT in these months.</Empty></div> : months.map((m) => {
              const s = STATUS[m.status] || STATUS.open;
              return (
                <div key={m.period} className="tr click" onClick={() => setOpen(m)} style={{ gridTemplateColumns: '120px repeat(5,minmax(100px,1fr)) 120px 170px', minWidth: 1000 }}>
                  <span><b>{monthShort(m.period)}</b>{!m.ended && <span className="faint" style={{ display: 'block', fontSize: 11 }}>running</span>}</span>
                  <span className="right num">{N2(m.output)}</span><span className="right num">{N2(m.input)}</span><span className="right num">{Number(m.wvat_credit) ? N2(m.wvat_credit) : '—'}</span>
                  <span className="right num" style={{ fontWeight: 600, color: Number(m.payable) ? '#C2410C' : undefined }}>{N2(m.payable)}</span>
                  <span className="right num">{N2(m.credit_cf)}</span>
                  <span><span className={'chip ' + s.tone}>{s.label}</span>{m.overdue && <span className="chip t-red" style={{ marginLeft: 4 }}>late</span>}
                    {m.changed_since_filing && <span className="chip t-amber" style={{ marginLeft: 4 }} title="The documents for this month changed after it was filed">changed</span>}</span>
                  <span className="row" style={{ gap: 4, justifyContent: 'flex-end' }} onClick={(e) => e.stopPropagation()}>
                    <button className="btn btn-ghost btn-xs" title="The NRS VAT return (Form VAT 002) for the month" onClick={() => setNrs(m.period)}><Icon name="download" size={12} />NRS</button>
                    {m.ended && m.status === 'open' && d.can_file && <button className="btn btn-primary btn-xs" onClick={() => setModal({ kind: 'file', m })}>File</button>}
                    {m.status === 'filed' && d.can_pay && <button className="btn btn-primary btn-xs" onClick={() => setModal({ kind: 'pay', m })}>Pay</button>}
                  </span>
                </div>
              );
            })}
          </div>
          <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>A month's return and payment are due on the 21st of the next month. Input VAT on bills is claimed in the month of the bill;
            what is left over is carried forward and used in later months, oldest first, for up to five years. VAT on standard-rated stock written off is taken back
            in the month it is written off. NRS gives the month's return on the NRS template, ready to upload.</div>
          </>}
        </>
      )}
      {open && <MonthModal m={open} canFile={!!d?.can_file} onClose={() => setOpen(null)} onAct={(kind) => { setModal({ kind, m: open }); setOpen(null); }}
        onNrs={() => { setNrs(open.period); setOpen(null); }} />}
      {nrs && <VatReturnModal period={nrs} onClose={() => setNrs(null)} />}
      {modal?.kind === 'file' && <FileModal m={modal.m} refundable={Number(d?.refundable || 0)} onClose={() => setModal(null)} />}
      {modal?.kind === 'pay' && <PayModal m={modal.m} onClose={() => setModal(null)} />}
      {modal?.kind === 'reopen' && <ReopenModal m={modal.m} onClose={() => setModal(null)} />}
      {modal?.kind === 'charge' && (
        <Modal onClose={() => setModal(null)} width={480}>
          <ModalHead title={modal.charge ? 'Start charging VAT' : 'Stop charging VAT'} onClose={() => setModal(null)} />
          <div className="modal-body stack" style={{ gap: 10, fontSize: 14 }}>
            {modal.charge ? <div>New invoices and receipts add VAT at {vatPct()} on standard-rated items, and a VAT return is filed every month by the 21st.</div>
              : <div>A small company need not charge VAT or file returns. New invoices and receipts will show no VAT, and input VAT on purchases becomes part of their cost. Returns already filed stay as they are.</div>}
          </div>
          <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn btn-primary" onClick={async () => {
              try { await rpc('set_vat_charging', { p_org: orgId, p: { charge: modal.charge } }); toast(modal.charge ? 'VAT is charged from now on' : 'VAT is no longer charged'); await refresh(); setModal(null); }
              catch (e) { toast((e as Error).message, 'err'); }
            }}>{modal.charge ? 'Start charging VAT' : 'Stop charging VAT'}</button></div>
        </Modal>
      )}
    </div>
  );
}

function VatStatus({ st, onChange }: { st: any; onChange: (charge: boolean) => void }) {
  const basis = st.basis === 'last_year' ? `the last full year (${fmtDay(st.from)} to ${fmtDay(st.to)})` : `this year so far (from ${fmtDay(st.from)})`;
  return (
    <div className="card card-pad stack" style={{ gap: 8 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div>
          <div className="row" style={{ gap: 8 }}><b>{st.charging ? 'The business charges VAT' : 'The business does not charge VAT'}</b>
            <span className={'chip ' + (st.small ? 't-blue' : 't-grey')}>{st.small ? 'Small company' : 'Above the small company limits'}</span>{st.opt_in && <span className="chip t-grey">Opted in</span>}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>Turnover {N2(st.turnover)} and fixed assets {N2(st.fixed_assets)} in {basis}{st.professional_services ? '; provides professional services' : ''}. Sales this year {N2(st.year_to_date)}.</div>
        </div>
        {st.can_change && (st.charging
          ? st.small && !st.crossed && <button className="btn btn-ghost btn-sm" onClick={() => onChange(false)}>Stop charging VAT</button>
          : <button className={'btn btn-sm ' + (st.advice === 'must_start' ? 'btn-primary' : 'btn-secondary')} onClick={() => onChange(true)}>Start charging VAT</button>)}
      </div>
      {st.advice === 'must_start' && <Alert kind="red" icon="alert">{st.crossed ? `Sales this year have passed ₦100 million (${N2(st.year_to_date)}).` : 'The business is above the small company limits (turnover up to ₦100 million, fixed assets up to ₦250 million, no professional services).'} It must charge VAT and file monthly returns.{st.can_change ? '' : ' Ask the owner to turn VAT on.'}</Alert>}
      {st.advice === 'may_stop' && <Alert kind="blue" icon="info">As a small company the business need not charge VAT. Keeping it on means filing every month, but lets the business recover the input VAT on its purchases.</Alert>}
    </div>
  );
}

function Row({ label, value, strong, muted }: { label: ReactNode; value: unknown; strong?: boolean; muted?: boolean }) {
  return <div className="row" style={{ justifyContent: 'space-between', fontWeight: strong ? 700 : undefined, color: muted ? '#6B7280' : undefined }}><span>{label}</span><span className="num">{N2(Number(value || 0))}</span></div>;
}

function MonthModal({ m, canFile, onClose, onAct, onNrs }: { m: any; canFile: boolean; onClose: () => void; onAct: (k: 'file' | 'reopen') => void; onNrs: () => void }) {
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`VAT for ${monthName(m.period)}`} sub={`Due ${fmtDay(m.due_date)}${m.filed_at ? ` · filed ${fmtDay(String(m.filed_at).slice(0, 10))}` : ''}${m.journal_ref ? ` · ${m.journal_ref}` : ''}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 6, fontSize: 14 }}>
        <Row label={<>Standard-rated sales<VatInfo side="sale" treatment="standard" subject="These sales" day={`${m.period}-01`} /></>} value={m.standard_sales} muted />
        <Row label={<>Zero-rated sales<VatInfo side="sale" treatment="zero" subject="These sales" /></>} value={m.zero_rated_sales} muted />
        <Row label={<>Exempt sales<VatInfo side="sale" treatment="exempt" subject="These sales" /></>} value={m.exempt_sales} muted />
        <div style={{ height: 6 }} />
        <Row label="Output VAT" value={m.output} />
        <Row label="Less VAT withheld by customers" value={m.wvat_credit} />
        <Row label={<>{`Less input VAT${Number(m.reverse_charge) ? ` (with ${N2(m.reverse_charge)} self-charged on services from abroad)` : ''}`}<VatInfo side="purchase" treatment="standard" day={`${m.period}-01`} /></>} value={m.input} />
        {Number(m.import_vat) > 0 && <Row label="of which VAT paid at customs" value={m.import_vat} muted />}
        {Number(m.stock_writeoff_vat) > 0 && <Row label="after taking back VAT on stock written off" value={m.stock_writeoff_vat} muted />}
        <Row label="Net for the month" value={m.net} strong />
        <Row label="Credit brought forward" value={m.credit_bf} muted />
        {Number(m.credit_expired) > 0 && <Row label="Credit lapsed (over five years old)" value={m.credit_expired} muted />}
        <Row label="Credit used" value={m.credit_used} muted />
        {Number(m.refund_claimed) > 0 && <Row label="Refund claimed" value={m.refund_claimed} muted />}
        <Row label="Payable" value={m.payable} strong />
        <Row label="Credit carried forward" value={m.credit_cf} />
        {m.changed_since_filing && <Alert kind="amber" icon="alert" style={{ marginTop: 8 }}>Documents for this month changed after it was filed: output {N2(m.changed_since_filing.output)}, input {N2(m.changed_since_filing.input)} now. Reopen it to file again, or correct it in a later month.</Alert>}
      </div>
      <div className="modal-ft">
        {canFile && ['filed', 'paid'].includes(m.status) && !m.payment_ref && <button className="btn btn-ghost" onClick={() => onAct('reopen')}><Icon name="undo" size={13} />Reopen</button>}
        <button className="btn btn-secondary" onClick={onNrs}><Icon name="download" size={13} />NRS return</button>
        {canFile && m.ended && m.status === 'open' && <button className="btn btn-primary" onClick={() => onAct('file')}>File this month</button>}
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
      </div>
    </Modal>
  );
}

function FileModal({ m, refundable, onClose }: { m: any; refundable: number; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [refund, setRefund] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const canRefund = Number(m.credit_cf) > 0;
  return (
    <Modal onClose={onClose} width={500}>
      <ModalHead title={`File VAT for ${monthName(m.period)}`} sub={`Due ${fmtDay(m.due_date)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 8, fontSize: 14 }}>
        <Row label="Output VAT" value={m.output} /><Row label="Less withheld by customers" value={m.wvat_credit} /><Row label="Less input VAT" value={m.input} />
        <Row label="Credit used" value={m.credit_used} muted /><Row label="Payable" value={m.payable} strong /><Row label="Credit carried forward" value={m.credit_cf} />
        {canRefund && <Field label="Claim a refund instead of carrying it forward (optional)" hint={`Credit from the last 12 months qualifies: up to ${N2(Math.min(refundable, Number(m.credit_cf)))}.`}>
          <input className="input num" inputMode="decimal" value={refund} onChange={(e) => setRefund(e.target.value)} placeholder="0.00" /></Field>}
        <Field label="Note (optional)"><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        {Number(m.stock_writeoff_vat) > 0 && <Row label="VAT on stock written off, to the stock loss account" value={m.stock_writeoff_vat} muted />}
        <div className="faint" style={{ fontSize: 12 }}>Filing freezes the month and clears its output and input VAT into what is payable and the credit carried forward. Upload the NRS file for the month on the portal.</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy} onClick={async () => {
          setBusy(true);
          try { await rpc('file_vat_return', { p_org: orgId, p_period: m.period, p: { refund_claim: money(refund) || 0, notes } }); toast(`${monthName(m.period)} filed`); await refresh(); onClose(); }
          catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>File</button></div>
    </Modal>
  );
}

export function PayFrom({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const { orgId } = useSession();
  const [own, setOwn] = useState<any[]>([]);
  useEffect(() => { if (orgId) moneyAccounts(orgId).then((a) => setOwn((a || []).filter((x: any) => x.kind !== 'cash'))).catch(() => {}); }, [orgId]);
  return <Field label="Paid from"><select className="input" value={value} onChange={(e) => onChange(e.target.value)}><option value="">Choose</option>{own.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>;
}

function PayModal({ m, onClose }: { m: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [f, setF] = useState({ bank_account_id: '', paid_at: today(), reference: '' });
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`Pay VAT for ${monthName(m.period)}`} sub={`${N2(m.payable)} to the NRS`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <PayFrom value={f.bank_account_id} onChange={(v) => setF({ ...f, bank_account_id: v })} />
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Paid on"><input className="input" type="date" max={today()} value={f.paid_at} onChange={(e) => setF({ ...f, paid_at: e.target.value })} /></Field>
          <Field label="Reference (Remita RRR)"><input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
        </div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !f.bank_account_id} onClick={async () => {
          setBusy(true);
          try { await rpc('record_vat_payment', { p_org: orgId, p_period: m.period, p: { ...f, paid_at: f.paid_at + 'T12:00:00+01:00' } }); toast('VAT payment recorded'); await refresh(); onClose(); }
          catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>Record payment</button></div>
    </Modal>
  );
}

function ReopenModal({ m, onClose }: { m: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title={`Reopen ${monthName(m.period)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <div className="muted" style={{ fontSize: 13 }}>The filing entry is reversed and the month is worked out again from its documents. Later months must be reopened first.</div>
        <Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || reason.trim().length < 3} onClick={async () => {
          setBusy(true);
          try { await rpc('reopen_vat_return', { p_org: orgId, p_period: m.period, p_reason: reason }); toast('Reopened'); await refresh(); onClose(); }
          catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>Reopen</button></div>
    </Modal>
  );
}
