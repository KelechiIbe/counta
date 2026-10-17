// Bulk payments: download the template, upload a filled sheet, check every account with the bank, approve once,
// send from the wallet, and download the results.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, useChart, usePayments } from '../../lib/api';
import { N2, when } from '../../lib/format';
import { downloadBlob, safeName } from '../../lib/exporters';
import { BULK_FIELDS, COMMON_BANKS, STATUS_WORD, bulkResultsXlsx, bulkTemplateXlsx, namesAgree, paidFor, readBulkRows, transferFee, type Bank, type BulkRow } from '../../lib/bulkPay';
import { SheetRows } from '../../components/SheetRows';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { StatusChip } from '../sell/common';

// Codes Counta posts to through a bill or a supplier, never straight from a bulk payment.
const CONTROL = new Set(['1101', '1102', '2101', '2107']);
function useBulkAccounts() {
  const chart = useChart();
  return useMemo<{ code: string; name: string; kind: string }[]>(() => (chart.data?.accounts || [])
    .filter((a: any) => !a.is_group && a.active && (a.kind === 'expense' || a.kind === 'liability') && !CONTROL.has(a.code) && !/^1/.test(a.code))
    .map((a: any) => ({ code: a.code as string, name: a.name as string, kind: a.kind as string })), [chart.data]);
}
function useBanks() {
  const [banks, setBanks] = useState<Bank[]>([]);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    edge<{ banks: Bank[] }>('payments', { action: 'banks' }).then((r) => { if (r.ok === false) setErr(r.error || 'The bank list is not available.'); else setBanks(r.banks || []); });
  }, []);
  return { banks, err };
}

export function TemplateButton({ small }: { small?: boolean }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const accounts = useBulkAccounts();
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true);
    try {
      const r = await edge<{ banks: Bank[] }>('payments', { action: 'banks' });
      const banks = r.ok !== false && r.banks?.length ? r.banks : COMMON_BANKS;
      const blob = await bulkTemplateXlsx({ orgName: inv?.org.name || 'Counta', banks, suppliers: (inv?.vendors || []).map((v) => v.name).sort(), accounts });
      downloadBlob(blob, `${safeName(inv?.org.name || 'Counta')} bulk payment template.xlsx`);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return <button className={'btn btn-secondary' + (small ? ' btn-sm' : '')} disabled={busy} onClick={go}>{busy ? <Spinner small /> : <Icon name="download" size={14} />}Download the template</button>;
}

// Asks the bank for each account's name, five at a time.
async function resolveAll(rows: BulkRow[], onEach: (i: number, patch: Partial<BulkRow>) => void) {
  const todo = rows.map((r, i) => ({ r, i })).filter(({ r }) => /^\d{10}$/.test(r.account_number) && r.bank_code);
  let next = 0;
  async function worker() {
    while (next < todo.length) {
      const { r, i } = todo[next++];
      onEach(i, { resolving: true });
      const res = await edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: r.account_number, bank_code: r.bank_code });
      onEach(i, res.ok === false || !res.account_name ? { resolving: false, resolved: '', issues: [...r.issues.filter((x) => !x.startsWith('The bank')), `The bank could not find account ${r.account_number}`] }
        : { resolving: false, resolved: res.account_name, issues: r.issues.filter((x) => !x.startsWith('The bank')) });
    }
  }
  await Promise.all(Array.from({ length: Math.min(5, todo.length) }, worker));
}

export function BulkPayModal({ onClose, onCreated }: { onClose: () => void; onCreated: (batch: any) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const pay = usePayments();
  const accounts = useBulkAccounts();
  const { banks, err: banksErr } = useBanks();
  const [title, setTitle] = useState('');
  const [defaultAccount, setDefaultAccount] = useState('');
  const [rows, setRows] = useState<BulkRow[]>([]);
  const [file, setFile] = useState('');
  const [phase, setPhase] = useState<'upload' | 'checking' | 'review'>('upload');
  const [check, setCheck] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  const clientRef = useRef(crypto.randomUUID());
  const rowsRef = useRef<BulkRow[]>([]);
  rowsRef.current = rows;

  const patch = (i: number, p: Partial<BulkRow>) => setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...p } : r)));
  const payload = (rs: BulkRow[]) => ({ title, default_account: defaultAccount || null, file_name: file || null,
    rows: rs.map((r) => ({ row: r.row, name: r.name, bank_code: r.bank_code, bank_name: r.bank_name, account_number: r.account_number, account_name: r.resolved || '',
      amount: r.amount, narration: r.narration, bill: r.bill, supplier: r.supplier, account: r.account, reference: r.reference })) });

  async function runCheck(rs: BulkRow[]) {
    const ready = rs.filter((r) => !r.issues.length);
    if (!ready.length) { setCheck(null); return; }
    try {
      const c = await rpc<any>('check_payout_batch', { p_org: orgId, p: payload(ready) });
      setCheck(c);
      setRows((cur) => cur.map((r) => {
        const s = (c.rows || []).find((x: any) => Number(x.row) === r.row);
        const nameOk = r.resolved ? namesAgree(r.name, r.resolved) : false;
        // Ticked when the books accept the row and the bank's name matches the sheet. A name that differs waits for a
        // person to tick it; a choice someone already made stays.
        const ok = Boolean(s?.ok) && !r.issues.length;
        return { ...r, server: s, include: ok && (r.touched ? r.include : nameOk) };
      }));
    } catch (e) { toast((e as Error).message, 'err'); }
  }

  async function onRows(sheetRows: any[], fileName: string) {
    if (!banks.length) throw new Error(banksErr || 'The bank list has not loaded yet. Try again in a moment.');
    const parsed = readBulkRows(sheetRows, banks);
    if (!parsed.length) throw new Error('No payments found in that file.');
    if (parsed.length > 500) throw new Error(`That file has ${parsed.length} payments. Send at most 500 in one bulk payment; split the file.`);
    setFile(fileName); setRows(parsed); setPhase('checking');
    if (!title) setTitle(fileName.replace(/\.(xlsx|xls|xlsm|csv|ods)$/i, '').slice(0, 80));
    // The answers are gathered here as well as shown, so the check below sees every name the banks returned.
    const work = parsed.map((r) => ({ ...r }));
    await resolveAll(work, (i, p) => { Object.assign(work[i], p); patch(i, p); });
    await runCheck(work);
    setPhase('review');
  }

  async function pickBank(i: number, code: string) {
    const b = banks.find((x) => x.code === code);
    if (!b) return;
    const r = { ...rows[i], bank_code: b.code, bank_name: b.name, bankOptions: undefined, issues: rows[i].issues.filter((x) => !x.startsWith('Bank ')) };
    patch(i, r);
    const res = await edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: r.account_number, bank_code: b.code });
    const fixed: BulkRow = { ...r, resolved: res.ok === false ? '' : res.account_name, issues: res.ok === false || !res.account_name ? [...r.issues, `The bank could not find account ${r.account_number}`] : r.issues };
    const next = rowsRef.current.map((x, j) => (j === i ? fixed : x));
    setRows(next);
    await runCheck(next);
  }

  const included = rows.filter((r) => r.include && r.server?.ok && !r.issues.length);
  const total = included.reduce((a, r) => a + Number(r.server.amount), 0);
  const wht = included.reduce((a, r) => a + Number(r.server.wht || 0), 0);
  const fees = included.reduce((a, r) => a + transferFee(Number(r.server.amount)), 0);
  const available = Number(pay.data?.wallet?.available ?? check?.available ?? 0);
  const threshold = Number(pay.data?.settings?.payout_approval_threshold || 0);
  const needsApproval = threshold > 0 && total >= threshold && inv?.me.role !== 'owner';
  const short = Math.max(total + fees - available, 0);
  const dupes = useMemo(() => {
    const seen = new Map<string, number>(); const out = new Set<number>();
    rows.forEach((r) => { const k = `${r.account_number}|${r.amount}`; if (seen.has(k)) { out.add(r.row); out.add(seen.get(k)!); } else seen.set(k, r.row); });
    return out;
  }, [rows]);
  const recent = useMemo(() => new Set((pay.data?.payouts || []).filter((p: any) => ['processing', 'successful'].includes(p.status) && Date.now() - Date.parse(p.created_at) < 7 * 86400_000)
    .map((p: any) => `${p.account_number}|${Number(p.amount)}`)), [pay.data]);
  const resolving = rows.filter((r) => r.resolving).length;
  const resolvedCount = rows.filter((r) => r.resolved != null && !r.resolving).length;

  async function submit() {
    setBusy(true);
    try {
      const b = await rpc<any>('create_payout_batch', { p_org: orgId, p: { ...payload(included), client_uuid: clientRef.current } });
      await qc.invalidateQueries({ queryKey: ['payments'] });
      toast(b.status === 'pending_approval' ? `${b.number} is waiting for approval` : `${b.number} is ready to send`);
      onCreated(b);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }

  return (
    <Modal onClose={onClose} width={phase === 'upload' ? 620 : 1080}>
      <ModalHead title="Bulk payment" sub="Pay many people at once from the wallet: suppliers' bills, salaries, allowances and other costs." onClose={onClose} />
      <div className="modal-body">
        {phase === 'upload' && (
          <>
            <div className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
              <TemplateButton small />
              <span className="faint" style={{ fontSize: 12.5 }}>Fill it in Excel or Google Sheets, or upload your own payroll or bank sheet.</span>
            </div>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Name for this batch" hint="Shows on the batch and in the approval request."><input className="input" value={title} maxLength={80} onChange={(e) => setTitle(e.target.value)} placeholder="October salaries" /></Field>
              <Field label="Rows without a bill, supplier or account go to" hint="Optional. Such as Salaries & Wages for a payroll sheet.">
                <select className="input" value={defaultAccount} onChange={(e) => setDefaultAccount(e.target.value)}>
                  <option value="">Each row says</option>
                  <optgroup label="Expenses">{accounts.filter((a) => a.kind === 'expense').map((a) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</optgroup>
                  <optgroup label="Amounts owed">{accounts.filter((a) => a.kind === 'liability').map((a) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</optgroup>
                </select>
              </Field>
            </div>
            {banksErr && <Alert kind="amber" icon="alert">{banksErr}</Alert>}
            <SheetRows fields={BULK_FIELDS} need={[['amount'], ['bill']]} action={(n) => `Check ${n} payment${n === 1 ? '' : 's'} with the banks`} onRows={onRows}
              note="Excel or CSV. Up to 500 payments." />
          </>
        )}
        {phase !== 'upload' && (
          <>
            <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
              <span style={{ fontSize: 13 }}><Icon name="file" size={14} style={{ verticalAlign: -2, marginRight: 4 }} />{file} · {rows.length} row{rows.length === 1 ? '' : 's'}</span>
              {phase === 'checking' ? <span className="row" style={{ gap: 6, fontSize: 13 }}><Spinner small />Checking names with the banks · {resolvedCount} of {rows.filter((r) => /^\d{10}$/.test(r.account_number) && r.bank_code).length}{resolving ? '' : ' · checking the books'}</span>
                : <button className="btn btn-ghost btn-sm" onClick={() => { setRows([]); setCheck(null); setPhase('upload'); }}>Upload another file</button>}
            </div>
            <div className="card" style={{ overflow: 'auto', maxHeight: '48vh' }}>
              <table className="bulk-table">
                <thead><tr><th style={{ width: 34 }} aria-label="Pay" /><th>Row</th><th>Pay to</th><th>Bank and account</th><th>For</th><th className="num">Amount</th><th>Check</th></tr></thead>
                <tbody>
                  {rows.map((r, i) => {
                    const s = r.server;
                    const nameOk = r.resolved ? namesAgree(r.name, r.resolved) : null;
                    const problems = [...r.issues, ...((s && !s.ok) ? s.errors : [])];
                    const can = !problems.length && s?.ok && !r.resolving;
                    return (
                      <tr key={r.row} className={r.include && can ? '' : 'off'}>
                        <td><input type="checkbox" aria-label={`Pay row ${r.row}`} disabled={!can} checked={Boolean(r.include && can)} onChange={(e) => patch(i, { include: e.target.checked, touched: true })} /></td>
                        <td className="faint">{r.row}</td>
                        <td style={{ minWidth: 160 }}>
                          <div style={{ fontWeight: 600 }}>{r.name || '—'}</div>
                          {r.resolving ? <div className="faint" style={{ fontSize: 12 }}>Asking the bank…</div>
                            : r.resolved ? <div style={{ fontSize: 12, color: nameOk ? '#15803D' : '#B45309' }}>{nameOk ? <Icon name="check" size={12} color="#15803D" /> : <Icon name="alert" size={12} color="#B45309" />} Bank: {r.resolved}</div> : null}
                          {r.reference && <div className="faint" style={{ fontSize: 11 }}>Ref {r.reference}</div>}
                        </td>
                        <td style={{ minWidth: 170 }}>
                          {r.bankOptions?.length ? (
                            <select className="input input-sm" value="" onChange={(e) => pickBank(i, e.target.value)} aria-label={`Bank for row ${r.row}`}>
                              <option value="">Which "{r.bankText}"?</option>{r.bankOptions.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}
                            </select>
                          ) : !r.bank_code && r.bankText ? (
                            <select className="input input-sm" value="" onChange={(e) => pickBank(i, e.target.value)} aria-label={`Bank for row ${r.row}`}>
                              <option value="">Choose for "{r.bankText}"</option>{banks.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}
                            </select>
                          ) : <div>{r.bank_name || r.bankText}</div>}
                          <div className="mono faint" style={{ fontSize: 12 }}>{r.account_number}</div>
                        </td>
                        <td style={{ minWidth: 150 }}>
                          {s?.label ? <div>{s.label}</div> : <div className="faint">{r.bill || r.supplier || r.account || (defaultAccount ? `${defaultAccount}` : '—')}</div>}
                          {s?.kind === 'bill' && Number(s.wht) > 0 && <div className="faint" style={{ fontSize: 12 }}>Settles {N2(s.gross)}, WHT {N2(s.wht)}</div>}
                          {r.narration && <div className="faint" style={{ fontSize: 12 }}>{r.narration}</div>}
                        </td>
                        <td className="num">{s?.amount != null ? N2(s.amount) : r.amount != null ? N2(r.amount) : '—'}</td>
                        <td style={{ minWidth: 180, fontSize: 12 }}>
                          {problems.map((p: string, k: number) => <div key={k} style={{ color: '#B91C1C' }}>{p}</div>)}
                          {!problems.length && nameOk === false && <div style={{ color: '#B45309' }}>The bank's name differs from the sheet. Tick it only if this is who you mean to pay.</div>}
                          {dupes.has(r.row) && <div style={{ color: '#B45309' }}>Same account and amount as another row.</div>}
                          {recent.has(`${r.account_number}|${Number(s?.amount ?? r.amount)}`) && <div style={{ color: '#B45309' }}>Paid this amount in the last 7 days.</div>}
                          {r.notes.map((n, k) => <div key={'n' + k} className="faint">{n}</div>)}
                          {!problems.length && nameOk && !dupes.has(r.row) && s?.ok && <span className="faint">Ready</span>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {phase === 'review' && (
              <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(4,minmax(0,1fr))', gap: 10 }}>
                <Tile label={`${included.length} of ${rows.length} to pay`} value={N2(total)} />
                <Tile label="Transfer fees (estimate)" value={N2(fees)} />
                <Tile label="Withholding tax kept back" value={N2(wht)} />
                <Tile label="Wallet available" value={N2(available)} tone={short > 0 ? '#B91C1C' : undefined} />
              </div>
            )}
            {phase === 'review' && short > 0 && <Alert kind="red" icon="alert">The wallet is short by {N2(short)}. Fund it, or untick some rows.</Alert>}
            {phase === 'review' && needsApproval && <Alert kind="blue" icon="shield">Above {N2(threshold)}, so someone else who makes payments approves the batch before it goes. They get a notice.</Alert>}
            {phase === 'review' && rows.some((r) => r.server?.kind === 'vendor') && <div className="faint" style={{ fontSize: 12 }}>Payments to a supplier without a bill reduce what you owe them; no withholding tax is deducted on those.</div>}
          </>
        )}
      </div>
      {phase !== 'upload' && (
        <div className="modal-ft">
          <button className="btn btn-secondary" onClick={onClose}>Close</button>
          <button className="btn btn-primary" disabled={phase !== 'review' || busy || !included.length || short > 0} onClick={submit}>
            {busy ? 'Saving…' : `${needsApproval ? 'Ask for approval' : 'Save'}: ${included.length} payment${included.length === 1 ? '' : 's'}, ${N2(total)}`}
          </button>
        </div>
      )}
    </Modal>
  );
}

function Tile({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return <div className="card" style={{ padding: '10px 12px', borderRadius: 12 }}><div className="faint" style={{ fontSize: 12 }}>{label}</div><div className="num" style={{ fontWeight: 700, fontSize: 17, color: tone }}>{value}</div></div>;
}

function Progress({ b }: { b: any }) {
  const n = Math.max(Number(b.row_count) || 0, 1);
  const seg = [[b.paid_count, '#16A34A'], [b.failed_count, '#DC2626'], [b.processing_count, '#F59E0B'], [b.cancelled_count, '#9CA3AF']] as [number, string][];
  return <div className="bulk-progress" aria-hidden>{seg.map(([v, c], i) => Number(v) > 0 && <span key={i} style={{ width: `${(Number(v) / n) * 100}%`, background: c }} />)}</div>;
}

export function BatchList({ batches, onOpen }: { batches: any[]; onOpen: (id: string) => void }) {
  if (!batches.length) return <div style={{ padding: 20 }}><Empty>No bulk payments yet. Download the template, fill it and upload it to pay many people at once.</Empty></div>;
  return (
    <>
      {batches.map((b) => (
        <button key={b.id} className="tr click" onClick={() => onOpen(b.id)} style={{ gridTemplateColumns: 'minmax(0,1.5fr) minmax(120px,1fr) 140px 130px', width: '100%', textAlign: 'left', background: 'none', border: 0, borderBottom: '1px solid var(--line)' }}>
          <span className="ellipsis"><b>{b.title}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{b.number} · {b.row_count} payment{b.row_count === 1 ? '' : 's'} · asked by {b.requested_by_name || '—'} · {when(b.created_at)}</span></span>
          <span className="stack" style={{ gap: 4 }}><Progress b={b} /><span className="faint" style={{ fontSize: 11 }}>{b.paid_count} paid{Number(b.failed_count) ? ` · ${b.failed_count} failed` : ''}{Number(b.processing_count) ? ` · ${b.processing_count} at the bank` : ''}</span></span>
          <span><StatusChip s={b.status} /></span>
          <span className="right num">{N2(b.total)}</span>
        </button>
      ))}
    </>
  );
}

export function BatchModal({ id, onClose }: { id: string; onClose: () => void }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const [sending, setSending] = useState(false);
  const [note, setNote] = useState('');
  const [declining, setDeclining] = useState(false);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);
  const q = useQuery({ queryKey: ['payout-batch', id], queryFn: () => rpc<any>('get_payout_batch', { p_batch: id }),
    refetchInterval: (query) => ((query.state.data as any)?.status === 'sending' && !sending ? 6000 : false) });
  const b = q.data;
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['payout-batch', id] }), qc.invalidateQueries({ queryKey: ['payments'] }), qc.invalidateQueries({ queryKey: ['inbox'] })]);
  async function act(fn: () => Promise<any>, ok: string) {
    try { const r = await fn(); if (r?.id) qc.setQueryData(['payout-batch', id], { ...b, ...r }); toast(ok); await refresh(); } catch (e) { toast((e as Error).message, 'err'); }
  }
  async function send() {
    setSending(true);
    try {
      for (let i = 0; i < 40 && alive.current; i++) {
        const r = await edge<{ batch: any; sent: number; failed: number }>('payments', { action: 'send_batch', batch_id: id });
        if (r.ok === false) { toast(r.reason === 'not_configured' ? 'Payments are not switched on for TaxStreem yet. Add the Flutterwave keys first.' : r.error || 'Sending stopped.', 'err'); break; }
        if (r.batch) qc.setQueryData(['payout-batch', id], r.batch);
        if (!r.batch || Number(r.batch.approved_count) === 0) break;
      }
    } finally { setSending(false); await refresh(); }
  }
  async function download() {
    try { downloadBlob(await bulkResultsXlsx(b, inv?.org.name || 'Counta'), `${b.number} ${safeName(b.title)} results.xlsx`); } catch (e) { toast((e as Error).message, 'err'); }
  }
  const waiting = Number(b?.approved_count || 0);
  return (
    <Modal onClose={onClose} width={1000}>
      <ModalHead title={b ? `${b.number} · ${b.title}` : 'Bulk payment'} onClose={onClose}
        sub={b ? `${b.row_count} payment${b.row_count === 1 ? '' : 's'} · ${N2(b.total)} · asked by ${b.requested_by_name || '—'} ${when(b.created_at)}${b.approved_by_name ? ` · approved by ${b.approved_by_name}` : ''}${b.mode === 'bulk' ? ' · one Flutterwave bulk transfer' : ''}` : undefined}
        extra={b && <StatusChip s={b.status} />} />
      <div className="modal-body">
        {!b ? <SkeletonRows n={5} /> : (
          <>
            <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(5,minmax(0,1fr))', gap: 10 }}>
              <Tile label="Total" value={N2(b.total)} />
              <Tile label={`Paid (${b.paid_count})`} value={N2(b.paid_total)} tone="#15803D" />
              <Tile label={`Failed (${b.failed_count})`} value={N2(b.failed_total)} tone={Number(b.failed_count) ? '#B91C1C' : undefined} />
              <Tile label="Fees" value={N2(Number(b.fee_total) || Number(b.fee_estimate))} />
              <Tile label="WHT kept back" value={N2(b.wht_total)} />
            </div>
            <Progress b={b} />
            {b.status === 'pending_approval' && !b.can?.approve && <Alert kind="blue" icon="clock">Waiting for someone else who makes payments to approve it.</Alert>}
            {sending && <Alert kind="blue" icon="send"><span className="row" style={{ gap: 8 }}><Spinner small />Sending · {Number(b.row_count) - waiting} of {b.row_count} handed to the bank. You can close this; Counta carries on.</span></Alert>}
            {!sending && Number(b.processing_count) > 0 && <Alert kind="grey" icon="clock">{b.processing_count} payment{Number(b.processing_count) === 1 ? ' is' : 's are'} at the bank. Each one completes when the bank confirms it, and this page updates on its own.</Alert>}
            {b.status === 'sending' && !sending && waiting > 0 && <Alert kind="blue" icon="clock">{waiting} payment{waiting === 1 ? '' : 's'} still to go. Counta sends them within five minutes, or send them now.</Alert>}
            {['completed', 'partly_failed', 'failed'].includes(b.status) && Number(b.failed_count) > 0 && <Alert kind="amber" icon="alert">{b.failed_count} payment{Number(b.failed_count) === 1 ? '' : 's'} failed and nothing left the wallet for {Number(b.failed_count) === 1 ? 'it' : 'them'}. The results file lists the reason for each, so you can fix the details and pay them in a new batch.</Alert>}
            {declining && (
              <div className="row" style={{ gap: 8 }}>
                <input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Why it is declined (shown to the person who asked)" />
                <button className="btn btn-danger btn-sm" onClick={() => act(() => rpc('approve_payout_batch', { p_batch: id, p_approve: false, p_note: note || 'Not approved' }), 'Declined')}>Decline</button>
                <button className="btn btn-ghost btn-sm" onClick={() => setDeclining(false)}>Back</button>
              </div>
            )}
            <div className="card" style={{ overflow: 'auto', maxHeight: '46vh' }}>
              <table className="bulk-table">
                <thead><tr><th>Row</th><th>Paid to</th><th>Bank and account</th><th>For</th><th className="num">Amount</th><th className="num">Fee</th><th>Status</th></tr></thead>
                <tbody>
                  {(b.rows || []).map((r: any) => (
                    <tr key={r.id}>
                      <td className="faint">{r.row ?? '—'}</td>
                      <td style={{ minWidth: 160 }}><div style={{ fontWeight: 600 }}>{r.account_name}</div>{r.your_reference && <div className="faint" style={{ fontSize: 11 }}>Ref {r.your_reference}</div>}</td>
                      <td style={{ minWidth: 150 }}><div>{r.bank_name || r.bank_code}</div><div className="mono faint" style={{ fontSize: 12 }}>{r.account_number}</div></td>
                      <td style={{ minWidth: 150 }}>{paidFor(r)}{r.narration && <div className="faint" style={{ fontSize: 12 }}>{r.narration}</div>}</td>
                      <td className="num">{N2(r.amount)}{r.wht != null && Number(r.wht) > 0 && <div className="faint" style={{ fontSize: 11 }}>WHT {N2(r.wht)}</div>}</td>
                      <td className="num faint">{Number(r.fee) ? N2(r.fee) : ''}</td>
                      <td style={{ minWidth: 130 }}><span className={'chip ' + toneOf(r.status)}>{STATUS_WORD[r.status] || r.status}</span>
                        {r.error && r.status !== 'successful' && <div style={{ fontSize: 12, color: r.status === 'cancelled' ? '#6B7280' : '#B91C1C', marginTop: 2 }}>{r.error}</div>}
                        {r.journal_ref && <div className="faint" style={{ fontSize: 11 }}>{r.journal_ref}</div>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </div>
      {b && (
        <div className="modal-ft" style={{ justifyContent: 'space-between' }}>
          <button className="btn btn-secondary" onClick={download}><Icon name="download" size={14} />Download the results</button>
          <div className="row wrap" style={{ gap: 8 }}>
            {['pending_approval', 'approved', 'sending'].includes(b.status) && b.can?.pay_out && (Number(b.pending_count) > 0 || waiting > 0) && !sending && (
              <button className="btn btn-ghost" onClick={() => { if (window.confirm(`Cancel the ${Number(b.pending_count) + waiting} payment(s) of ${b.number} that have not gone to the bank?`)) act(() => rpc('cancel_payout_batch', { p_batch: id }), 'Cancelled what had not gone'); }}>Cancel the rest</button>
            )}
            {b.status === 'pending_approval' && b.can?.approve && !declining && <>
              <button className="btn btn-secondary" onClick={() => setDeclining(true)}>Decline</button>
              <button className="btn btn-primary" onClick={() => act(() => rpc('approve_payout_batch', { p_batch: id, p_approve: true }), 'Approved. Send it when ready.')}>Approve {N2(b.total)}</button>
            </>}
            {['approved', 'sending'].includes(b.status) && b.can?.pay_out && waiting > 0 && (
              <button className="btn btn-primary" disabled={sending} onClick={send}>{sending ? 'Sending…' : `Send ${waiting} payment${waiting === 1 ? '' : 's'} now`}</button>
            )}
          </div>
        </div>
      )}
    </Modal>
  );
}

const toneOf = (s: string) => ({ successful: 't-green', failed: 't-red', reversed: 't-red', processing: 't-amber', approved: 't-blue', pending_approval: 't-amber', cancelled: 't-grey' } as Record<string, string>)[s] || 't-grey';

