// Withholding: WHT deducted from suppliers (to the NRS for companies and suppliers abroad, to the state service of the
// supplier's state for everyone else) and VAT withheld or self-charged (to the NRS), month by month. Each month's schedule
// downloads on the authority's own template; paying it over clears the deductions; each supplier gets a receipt.
import { useEffect, useState } from 'react';
import { useInventory, useSession, useToast } from '../../../state/session';
import { edge, today } from '../../../lib/api';
import { rpc } from '../../../lib/supabase';
import { N2, fmtDay } from '../../../lib/format';
import { addMonths, authorityLabel, monthName, monthShort, pct, useWhtReceipts, useWithholding } from '../../../lib/tax';
import { Icon } from '../../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows, Spinner, Stat } from '../../../components/ui';
import { ExportMenu, useMeta } from '../../../components/Books';
import { downloadUrl, useTaxRefresh } from './CitTab';
import { PayFrom } from './VatTab';

type View = 'months' | 'receipts' | 'rates';

export default function WhtTab() {
  const [view, setView] = useState<View>('months');
  const [to, setTo] = useState(today().slice(0, 7));
  const from = addMonths(to + '-01', -11);
  const end = addMonths(to + '-01', 1);
  const last = new Date(end + 'T12:00:00Z'); last.setUTCDate(0);
  const q = useWithholding(from, [last.toISOString().slice(0, 10), today()].sort()[0]);
  const d = q.data;
  const [sched, setSched] = useState<any>(null);
  const [pay, setPay] = useState<any>(null);
  const groups: any[] = d?.groups || [];
  const authorities: any[] = d?.authorities || [];
  const led = d?.ledger || {};
  const mismatch = d && (Math.abs(Number(led.wht_payable) - Number(led.wht_outstanding)) >= 1 || Math.abs(Number(led.wvat_payable) - Number(led.wvat_outstanding)) >= 1);
  return (
    <div className="stack" style={{ gap: 14 }}>
      {q.isLoading ? <SkeletonRows n={6} /> : q.error ? <Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert> : d && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(160px,1fr))', gap: 8 }}>
            <Stat label="WHT to pay over" value={N2(led.wht_outstanding)} color="#C2410C" sub={`ledger 2202: ${N2(led.wht_payable)}`} />
            <Stat label="Withholding VAT to pay over" value={N2(led.wvat_outstanding)} sub={`ledger 2211: ${N2(led.wvat_payable)}`} />
            <Stat label="Late" value={String(groups.filter((g) => g.overdue).length)} color={groups.some((g) => g.overdue) ? '#DC2626' : undefined} sub="schedules past their due date" />
            <Stat label="Paid over in these months" value={N2((d.remittances || []).reduce((a: number, r: any) => a + Number(r.amount || 0), 0))} />
          </div>
          {mismatch && <Alert kind="amber" icon="alert">The ledger and the deductions differ. Something was posted to 2202 or 2211 by hand, or a payment to a tax authority was not recorded here.</Alert>}
          <div className="row wrap" style={{ justifyContent: 'space-between' }}>
            <Pills value={view} onChange={setView} options={[{ id: 'months', label: 'By month' }, { id: 'receipts', label: 'Receipts for suppliers' }, { id: 'rates', label: 'Rates' }]} />
            {view === 'months' && <div className="row"><span className="muted" style={{ fontSize: 14 }}>Twelve months to</span><input className="input input-sm" type="month" value={to} max={today().slice(0, 7)} onChange={(e) => e.target.value && setTo(e.target.value)} style={{ width: 160 }} /></div>}
          </div>
          {view === 'months' && (
            <>
              <div className="card" style={{ overflow: 'auto' }}>
                <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '110px 90px minmax(150px,1.2fr) 70px repeat(3,110px) 120px', minWidth: 900 }}>
                  <span>Month</span><span>Kind</span><span>Paid to</span><span className="right">Lines</span><span className="right">Deducted</span><span className="right">Paid over</span><span className="right">To pay</span><span>Due</span>
                </div>
                {!groups.length ? <div style={{ padding: 20 }}><Empty>Nothing withheld in these months.</Empty></div> : groups.map((g) => (
                  <div key={`${g.period}${g.kind}${g.authority}`} className="tr click" onClick={() => setSched(g)} style={{ gridTemplateColumns: '110px 90px minmax(150px,1.2fr) 70px repeat(3,110px) 120px', minWidth: 900 }}>
                    <b>{monthShort(g.period)}</b>
                    <span className={'chip ' + (g.kind === 'wht' ? 't-blue' : 't-purple')} style={{ justifySelf: 'start' }}>{g.kind === 'wht' ? 'WHT' : 'VAT'}</span>
                    <span className="ellipsis" title={g.authority_name}>{g.authority ? authorityLabel(g.authority, authorities) : <span style={{ color: '#DC2626' }}>State not known · add the suppliers' states</span>}</span>
                    <span className="right num">{g.deductions}</span>
                    <span className="right num">{N2(g.deducted)}</span>
                    <span className="right num">{Number(g.remitted) ? N2(g.remitted) : '—'}</span>
                    <span className="right num" style={{ fontWeight: 600, color: Number(g.outstanding) ? '#C2410C' : undefined }}>{Number(g.outstanding) ? N2(g.outstanding) : '—'}</span>
                    <span style={{ fontSize: 12, color: g.overdue ? '#DC2626' : undefined }}>{Number(g.outstanding) ? fmtDay(g.due_date) : 'Paid'}{Number(g.pending) ? <span className="faint"> · {N2(g.pending)} waiting on payments</span> : null}</span>
                  </div>
                ))}
              </div>
              {(d.remittances || []).length > 0 && (
                <div className="card" style={{ overflow: 'hidden' }}>
                  <div className="card-hd"><b>Paid over</b></div>
                  {(d.remittances as any[]).map((r) => (
                    <div key={r.id} className="tr" style={{ gridTemplateColumns: '110px minmax(0,1fr) 130px', fontSize: 13 }}>
                      <span>{fmtDay(String(r.paid_at).slice(0, 10))}</span>
                      <span className="ellipsis">{r.kind === 'wht' ? 'WHT' : 'Withholding VAT'} for {monthName(r.period)} to {authorityLabel(r.authority, d.authorities)}{r.reference ? ` · ${r.reference}` : ''}{r.journal_ref ? ` · ${r.journal_ref}` : ''}</span>
                      <span className="right num">{N2(r.amount)}</span>
                    </div>
                  ))}
                </div>
              )}
              <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>WHT is due to the NRS by the 21st of the next month and to a state service by the 30th; withholding VAT and VAT on services from abroad by the 14th.
                A deduction counts once the supplier is paid.</div>
            </>
          )}
          {view === 'receipts' && <Receipts />}
          {view === 'rates' && <Rates rates={d.rates || []} />}
        </>
      )}
      {sched && <ScheduleModal g={sched} authorities={d?.authorities || []} onClose={() => setSched(null)} onPay={() => { setPay(sched); setSched(null); }} />}
      {pay && <RemitModal g={pay} authorities={d?.authorities || []} onClose={() => setPay(null)} />}
    </div>
  );
}

function ScheduleModal({ g, authorities, onClose, onPay }: { g: any; authorities: any[]; onClose: () => void; onPay: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const meta = useMeta();
  const [busy, setBusy] = useState(false);
  const [s, setS] = useState<any>(null);
  const [err, setErr] = useState<string | null>(null);
  const [files, setFiles] = useState<any[] | null>(null);
  useEffect(() => {
    rpc<any>('wht_schedule', { p_org: orgId, p_period: g.period, p_authority: g.authority, p_kind: g.kind }).then(setS).catch((e) => setErr((e as Error).message));
  }, [g.period, g.authority, g.kind]); // eslint-disable-line react-hooks/exhaustive-deps
  const rows: any[] = s?.rows || [];
  const blocks = (s?.checks || []).filter((c: any) => c.severity === 'block');
  async function download() {
    setBusy(true);
    try {
      const r = await edge<any>('tax-files', { action: 'wht_files', org_id: orgId, period: g.period.slice(0, 7), authority: g.authority });
      if (r.ok === false) throw new Error(r.error || 'Could not make the file.');
      setFiles(r.files);
      if (r.files?.length === 1) downloadUrl(r.files[0].url);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const title = `${g.kind === 'wht' ? 'WHT' : 'Withholding VAT'} for ${monthName(g.period)}`;
  return (
    <Modal onClose={onClose} width={860}>
      <ModalHead title={title} sub={g.authority ? `${authorityLabel(g.authority, authorities)} · due ${fmtDay(s?.due_date || g.due_date)}` : 'State not known: these suppliers need a state before the WHT has somewhere to go'} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        {err ? <Alert kind="yellow" icon="shield">{err}</Alert> : !s ? <Spinner /> : (
          <>
            {(s.checks || []).map((c: any, i: number) => <Alert key={i} kind={c.severity === 'block' ? 'red' : 'amber'} icon="alert">{c.text}</Alert>)}
            <div style={{ overflow: 'auto', border: '1px solid #EEF0F3', borderRadius: 10, maxHeight: 380 }}>
              <table className="mini-table" style={{ width: '100%', fontSize: 12 }}>
                <thead><tr><th>Supplier</th><th>ID</th><th>Date</th><th>For</th><th className="right">Amount</th><th className="right">Rate</th><th className="right">{g.kind === 'wht' ? 'WHT' : 'VAT'}</th><th>Receipt</th></tr></thead>
                <tbody>{rows.map((r) => (
                  <tr key={r.id}><td>{r.beneficiary_name}</td><td className="faint">{r.beneficiary_type ? `${r.beneficiary_type} ${r.beneficiary_number}` : <span style={{ color: '#DC2626' }}>none</span>}</td>
                    <td>{fmtDay(r.transaction_date)}</td><td className="faint">{r.description || r.invoice}</td><td className="right num">{N2(r.amount)}</td><td className="right">{pct(r.rate)}</td>
                    <td className="right num">{N2(r.wht)}</td><td className="faint">{r.receipt_no || ''}{r.status === 'remitted' ? ' · paid' : ''}</td></tr>
                ))}</tbody>
              </table>
            </div>
            <div className="row" style={{ justifyContent: 'space-between', fontWeight: 700 }}><span>{rows.length} line{rows.length === 1 ? '' : 's'}</span><span className="num">{N2(s.total)}</span></div>
            {files && files.length > 1 && (
              <div className="stack" style={{ gap: 4 }}>
                <div className="faint" style={{ fontSize: 12 }}>The NRS template takes 130 lines a file, so the schedule is in {files.length} files:</div>
                {files.map((f) => <button key={f.name} className="btn btn-ghost btn-xs" style={{ justifyContent: 'flex-start' }} onClick={() => downloadUrl(f.url)}><Icon name="download" size={13} />{f.name} · {f.rows} lines · {N2(f.total)}</button>)}
              </div>
            )}
            {(files || []).some((f) => (f.mismatches || []).length) && <Alert kind="amber" icon="alert">The template's own formula gives a different WHT on some lines. Check the supplier's Tax ID and type before uploading.</Alert>}
          </>
        )}
      </div>
      <div className="modal-ft">
        {s && g.kind === 'wht' && g.authority && <button className="btn btn-secondary" disabled={busy || !!blocks.length || !rows.length} onClick={download}>{busy ? <Spinner small /> : <Icon name="download" size={14} />}{g.authority === 'NRS' ? 'NRS template' : 'State template'}</button>}
        {s && g.kind !== 'wht' && <ExportMenu name={`Withholding VAT ${g.period.slice(0, 7)}`} disabled={!rows.length} sheets={() => [{ meta: meta(title, 'Paid to the NRS'),
          cols: [{ key: 'beneficiary_name', label: 'Supplier' }, { key: 'beneficiary_number', label: 'Tax ID' }, { key: 'address', label: 'Address' }, { key: 'invoice', label: 'Invoice' },
            { key: 'transaction_date', label: 'Date', type: 'date' }, { key: 'amount', label: 'Amount', type: 'money', total: true }, { key: 'wht', label: 'VAT', type: 'money', total: true }],
          rows: rows as any }]} />}
        {Number(g.outstanding) > 0 && g.authority && <button className="btn btn-primary" disabled={!s} onClick={onPay}>Record payment</button>}
        <button className="btn btn-ghost" onClick={onClose}>Close</button>
      </div>
    </Modal>
  );
}

function RemitModal({ g, authorities, onClose }: { g: any; authorities: any[]; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const refresh = useTaxRefresh();
  const [f, setF] = useState({ bank_account_id: '', paid_at: today(), reference: '' });
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title={`Pay over ${g.kind === 'wht' ? 'WHT' : 'withholding VAT'} for ${monthName(g.period)}`} sub={`${N2(g.outstanding)} to ${authorityLabel(g.authority, authorities)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        <PayFrom value={f.bank_account_id} onChange={(v) => setF({ ...f, bank_account_id: v })} />
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Paid on"><input className="input" type="date" max={today()} value={f.paid_at} onChange={(e) => setF({ ...f, paid_at: e.target.value })} /></Field>
          <Field label="Reference"><input className="input" value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} placeholder="Remita RRR or receipt" /></Field>
        </div>
        <div className="faint" style={{ fontSize: 12 }}>Records the payment (Dr {g.kind === 'wht' ? '2202' : '2211'}, Cr the bank) and marks the month's {g.deductions} deduction{g.deductions === 1 ? '' : 's'} as paid over.</div>
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || !f.bank_account_id} onClick={async () => {
          setBusy(true);
          try {
            await rpc('record_wht_remittance', { p_org: orgId, p: { kind: g.kind, authority: g.authority, period: g.period, amount: Number(g.outstanding), bank_account_id: f.bank_account_id,
              paid_at: f.paid_at + 'T12:00:00+01:00', reference: f.reference || null } });
            toast('Payment recorded'); await refresh(); onClose();
          } catch (e) { toast((e as Error).message, 'err'); }
          setBusy(false);
        }}>Record payment</button></div>
    </Modal>
  );
}

function Receipts() {
  const [q, setQ] = useState('');
  const r = useWhtReceipts({});
  const [open, setOpen] = useState<any>(null);
  const list = (r.data || []).filter((x: any) => !q.trim() || `${x.receipt_no} ${x.beneficiary?.name} ${x.bill?.number}`.toLowerCase().includes(q.trim().toLowerCase()));
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd"><div className="row" style={{ flex: 1 }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" style={{ border: 0, boxShadow: 'none' }} placeholder="Receipt, supplier or bill" value={q} onChange={(e) => setQ(e.target.value)} /></div></div>
      {r.isLoading ? <SkeletonRows n={5} /> : !list.length ? <div style={{ padding: 20 }}><Empty>No receipts yet. One is made for every deduction when the supplier is paid.</Empty></div> : list.map((x: any) => (
        <div key={x.id} className="tr click" onClick={() => setOpen(x)} style={{ gridTemplateColumns: '110px minmax(0,1fr) 120px 110px', fontSize: 13 }}>
          <b>{x.receipt_no}</b>
          <span className="ellipsis">{x.beneficiary?.name}<span className="faint"> · {x.nature} · {x.bill?.number}</span></span>
          <span className="muted">{monthShort(x.month)}</span>
          <span className="right num">{N2(x.deducted)}</span>
        </div>
      ))}
      {open && <ReceiptModal x={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
function receiptHtml(x: any) {
  const line = (k: string, v: unknown) => `<tr><td style="color:#6B7280;padding:6px 12px 6px 0;vertical-align:top">${esc(k)}</td><td style="padding:6px 0">${esc(v)}</td></tr>`;
  return `<!doctype html><html><head><meta charset="utf-8"><title>${esc(x.receipt_no)}</title><style>body{font:14px/1.5 system-ui,sans-serif;color:#111827;margin:40px;max-width:720px}h1{font-size:20px;margin:0 0 4px}table{border-collapse:collapse;width:100%}.box{border:1px solid #E5E7EB;border-radius:10px;padding:16px;margin-top:16px}</style></head><body>
<h1>${x.kind === 'wvat' ? 'VAT withheld' : 'Withholding tax'} receipt ${esc(x.receipt_no)}</h1><div style="color:#6B7280">Issued ${esc(fmtDay(x.issued_on))} for ${esc(monthName(x.month))}</div>
<div class="box"><b>Deducted by</b><table>${line('Name', x.payer?.name)}${line('Address', x.payer?.address || '')}${line('Tax ID', x.payer?.tin || '')}${line('RC number', x.payer?.rc_number || '')}</table></div>
<div class="box"><b>Deducted from</b><table>${line('Name', x.beneficiary?.name)}${line('Address', x.beneficiary?.address || '')}${line(x.beneficiary?.id_type || 'Tax ID', x.beneficiary?.id_number || x.beneficiary?.tin || '')}</table></div>
<div class="box"><table>${line('Nature of transaction', x.nature)}${line('Invoice', [x.bill?.vendor_ref, x.bill?.number].filter(Boolean).join(' · '))}${line('Transaction amount', N2(x.transaction_amount))}
${line('Rate', pct(x.rate) + (x.doubled ? ' (doubled: no Tax ID)' : ''))}${line('Amount deducted', N2(x.deducted))}${line('Paid to', x.authority?.name || '')}${line('Status', x.status === 'remitted' ? 'Paid over' : 'To be paid over by ' + fmtDay(x.due_date))}</table></div>
<p style="color:#6B7280;font-size:12px;margin-top:20px">Keep this receipt to claim the amount as a credit against your income tax.</p></body></html>`;
}

function ReceiptModal({ x, onClose }: { x: any; onClose: () => void }) {
  const { data: inv } = useInventory();
  function print() {
    const w = window.open('', '_blank');
    if (!w) return;
    w.document.write(receiptHtml(x)); w.document.close(); w.focus(); setTimeout(() => w.print(), 300);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`Receipt ${x.receipt_no}`} sub={`${x.beneficiary?.name} · ${monthName(x.month)}`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 6, fontSize: 14 }}>
        {[['Deducted by', `${x.payer?.name || inv?.org.name}${x.payer?.tin ? ` · Tax ID ${x.payer.tin}` : ''}`],
          ['Deducted from', `${x.beneficiary?.name}${x.beneficiary?.id_number ? ` · ${x.beneficiary.id_type} ${x.beneficiary.id_number}` : ''}`],
          ['For', `${x.nature}${x.bill?.vendor_ref ? ` · their invoice ${x.bill.vendor_ref}` : ''} · ${x.bill?.number}`],
          ['Transaction amount', N2(x.transaction_amount)], ['Rate', pct(x.rate) + (x.doubled ? ' (doubled: no Tax ID)' : '')], ['Deducted', N2(x.deducted)],
          ['Paid to', x.authority?.name || ''], ['Status', x.status === 'remitted' ? 'Paid over' : `To be paid over by ${fmtDay(x.due_date)}`]].map(([k, v]) => (
          <div key={k} className="row" style={{ justifyContent: 'space-between', gap: 12 }}><span className="muted">{k}</span><span style={{ textAlign: 'right' }}>{v}</span></div>
        ))}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Close</button><button className="btn btn-primary" onClick={print}><Icon name="printer" size={14} color="#fff" />Print</button></div>
    </Modal>
  );
}

function Rates({ rates }: { rates: any[] }) {
  return (
    <div className="card" style={{ overflow: 'auto' }}>
      <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(220px,2fr) repeat(4,110px)', minWidth: 700 }}>
        <span>Transaction</span><span className="right">Company</span><span className="right">Company abroad</span><span className="right">Not a company</span><span className="right">Abroad</span>
      </div>
      {rates.filter((r) => r.code !== 'none').map((r) => (
        <div key={r.code} className="tr" style={{ gridTemplateColumns: 'minmax(220px,2fr) repeat(4,110px)', minWidth: 700, fontSize: 13 }}>
          <span>{r.name}{r.note && <span className="faint" style={{ display: 'block', fontSize: 11 }}>{r.note}</span>}</span>
          {r.exemption ? <span className="faint" style={{ gridColumn: 'span 4', textAlign: 'right' }}>Exempt</span> : [r.corp_res, r.corp_nonres, r.ind_res, r.ind_nonres].map((v, i) => <span key={i} className="right">{v == null ? 'n/a' : pct(v)}</span>)}
        </div>
      ))}
      <div style={{ padding: 12 }} className="faint">Rates double when the supplier has no Tax ID. Compensation for loss of office: 5% of the amount above ₦50 million.</div>
    </div>
  );
}
