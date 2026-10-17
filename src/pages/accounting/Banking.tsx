// Banking: every bank, cash and wallet account with its book balance; statement upload (Excel or CSV from any Nigerian bank);
// the matching pipeline (invoices, bills, transfers, statutory payees, learned rules, then the AI); and reconciliation.
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money, today, useBanking } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { cellText, detectHeader, parseDate, parseNum, readWorkbook, type Cell } from '../../lib/sheet';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows } from '../../components/ui';
import { StatusChip } from '../sell/common';

const STAGE: Record<string, string> = {
  in_books: 'Already in the books', pending_payment: 'Payment waiting for confirmation', statutory: 'Tax or levy payment', customer: 'Customer payment', customer_wht: 'Customer paid less WHT',
  customer_part: 'Customer part payment', customer_advance: 'Customer advance', vendor_bill: 'Bill payment', vendor_no_bill: 'Vendor without a bill', transfer: 'Between our accounts',
  transfer_one_leg: 'Transfer, other side not seen', rule: 'Learned rule', registry: 'Known payee', ai: 'Atlas', user: 'Answered by a person', suspense: 'Suspense',
};

export default function Banking() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const bank = useBanking();
  const [acct, setAcct] = useState<string>('all');
  const [status, setStatus] = useState<'all' | 'unmatched' | 'proposed' | 'done'>('all');
  const [upload, setUpload] = useState<any | null>(null);
  const [recon, setRecon] = useState<any | null>(null);
  const [adding, setAdding] = useState(false);
  const d = bank.data;
  const lines = useMemo(() => (d?.lines || []).filter((l: any) => (acct === 'all' || l.bank_account_id === acct)
    && (status === 'all' || (status === 'unmatched' && l.status === 'unmatched') || (status === 'proposed' && l.status === 'proposed') || (status === 'done' && ['matched', 'posted', 'ignored'].includes(l.status)))), [d, acct, status]);
  if (!inv) return null;
  if (bank.error) return <div className="container"><Alert kind="yellow" icon="shield">{(bank.error as Error).message}</Alert></div>;
  async function runMatching() {
    try { const r = await rpc<any>('run_bank_matching', { p_org: orgId, p_bank_account: acct === 'all' ? null : acct }); toast(`Matched ${Object.values(r.matched || {}).reduce((a: number, b: any) => a + Number(b), 0)} · ${r.for_ai} for Atlas`); await qc.invalidateQueries({ queryKey: ['banking'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  const accounts = d?.accounts || [];
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div className="muted" style={{ fontSize: 14, maxWidth: 680 }}>Upload a statement and Counta matches each line to invoices, bills, transfers between your accounts and tax payments. Atlas explains what is left, and asks you in the books inbox when it is not sure.</div>
        {can(inv, 'keep_books') && <div className="row wrap">
          <button className="btn btn-secondary btn-sm" onClick={runMatching}><Icon name="refresh" size={14} />Match again</button>
          <button className="btn btn-secondary btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} />Account</button>
        </div>}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(260px,1fr))', gap: 12 }}>
        {bank.isLoading ? <SkeletonRows n={3} /> : accounts.map((a: any) => (
          <div key={a.id} className="card card-pad stack" style={{ gap: 6, borderColor: acct === a.id ? '#0072F5' : undefined, cursor: 'pointer' }} onClick={() => setAcct(acct === a.id ? 'all' : a.id)}>
            <div className="row" style={{ justifyContent: 'space-between' }}><b className="ellipsis">{a.name}</b><span className="chip t-grey">{a.kind}</span></div>
            <div className="faint" style={{ fontSize: 12 }}>{a.ledger_code}{a.account_number ? ` · ${a.bank_name || ''} ${a.account_number}` : ''}</div>
            <div style={{ fontSize: 22, fontWeight: 700 }} className="num">{N2(a.book_balance)}</div>
            <div className="faint" style={{ fontSize: 12 }}>{a.anchor_balance != null ? `Bank said ${N2(a.anchor_balance)} on ${fmtDay(String(a.anchor_at).slice(0, 10))}` : 'No statement yet'}{a.last_line ? ` · last line ${fmtDay(a.last_line)}` : ''}</div>
            <div className="row wrap" style={{ gap: 6 }}>
              {Number(a.unmatched) > 0 && <span className="chip t-amber">{a.unmatched} unmatched</span>}
              {Number(a.questions) > 0 && <span className="chip t-blue">{a.questions} questions</span>}
              {a.last_reconciliation && <span className="chip t-green">Reconciled to {fmtDay(a.last_reconciliation.as_of)}</span>}
            </div>
            {can(inv, 'keep_books') && a.kind !== 'wallet' && <div className="row" style={{ gap: 6 }} onClick={(e) => e.stopPropagation()}>
              {a.kind !== 'cash' && <button className="btn btn-secondary btn-xs" onClick={() => setUpload(a)}><Icon name="upload" size={13} />Statement</button>}
              <button className="btn btn-secondary btn-xs" onClick={() => setRecon(a)}>Reconcile</button>
            </div>}
            {a.kind === 'wallet' && can(inv, 'keep_books') && <div onClick={(e) => e.stopPropagation()}><button className="btn btn-secondary btn-xs" onClick={() => setRecon(a)}>Reconcile</button></div>}
          </div>
        ))}
      </div>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={status} onChange={setStatus} options={[{ id: 'all', label: 'All lines' }, { id: 'unmatched', label: 'Unmatched' }, { id: 'proposed', label: 'Waiting for an answer' }, { id: 'done', label: 'Done' }]} />
        {Number(d?.suspense || 0) !== 0 && <Link className="pill" to="/accounting/inbox">Suspense {N2(d.suspense)} · answer the questions<Icon name="chevR" size={13} /></Link>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '100px minmax(200px,2fr) 130px 150px minmax(140px,1fr) 100px', minWidth: 900 }}><span>Date</span><span>Narration</span><span className="right">Amount</span><span>Status</span><span>How</span><span>Journal</span></div>
          {!lines.length ? <div style={{ padding: 20 }}><Empty>No lines here yet. Upload a statement.</Empty></div> : lines.slice(0, 500).map((l: any) => (
            <div key={l.id} className="tr" style={{ gridTemplateColumns: '100px minmax(200px,2fr) 130px 150px minmax(140px,1fr) 100px', minWidth: 900 }}>
              <span className="muted">{fmtDay(l.line_date)}</span>
              <span className="ellipsis" title={l.description}>{l.description}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{l.account_name}{l.counterparty ? ` · ${l.counterparty}` : ''}{l.reference ? ` · ${l.reference}` : ''}</span></span>
              <b className="right num" style={{ color: Number(l.amount) > 0 ? '#15803D' : undefined }}>{Number(l.amount) > 0 ? '+' : '−'}{N2(Math.abs(l.amount))}</b>
              <span><StatusChip s={l.status === 'proposed' ? 'pending' : l.status === 'unmatched' ? 'draft' : l.status === 'ignored' ? 'void' : 'confirmed'} />{l.confidence != null && l.stage === 'ai' && <span className="faint" style={{ fontSize: 11 }}> {Math.round(Number(l.confidence) * 100)}%</span>}</span>
              <span className="muted" style={{ fontSize: 12 }}>{STAGE[l.stage] || (l.status === 'unmatched' ? 'Waiting for Atlas' : '—')}</span>
              <span className="muted mono" style={{ fontSize: 12 }}>{l.journal_ref || ''}</span>
            </div>
          ))}
        </div>
      </div>
      {(d?.rules || []).length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>What Atlas has learned</b><span className="faint" style={{ fontSize: 12 }}>From your answers in the books inbox</span></div>
          {d.rules.map((r: any) => (
            <div key={r.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 80px minmax(0,1fr) 140px' }}>
              <b className="ellipsis">{r.party_key}</b><span className="muted">{r.direction === 'in' ? 'money in' : 'money out'}</span><span className="ellipsis">{r.account_code} {r.account_name || ''}</span><span className="faint" style={{ fontSize: 12 }}>{r.hits ? `used ${r.hits}×` : ''} {r.created_at ? when(r.created_at) : ''}</span>
            </div>
          ))}
        </div>
      )}
      {upload && <StatementUpload account={upload} onClose={() => setUpload(null)} />}
      {recon && <Reconcile account={recon} onClose={() => setRecon(null)} />}
      {adding && <AddAccount onClose={() => setAdding(false)} />}
    </div>
  );
}

type Col = 'ignore' | 'date' | 'description' | 'reference' | 'debit' | 'credit' | 'amount' | 'balance';
const GUESS: [Col, RegExp][] = [['date', /date|value|posted|trans.*date/i], ['description', /narr|desc|details|remark|particular/i], ['reference', /ref|cheque|chq/i],
  ['debit', /debit|withdraw|dr\b|money out|paid out/i], ['credit', /credit|deposit|lodg|cr\b|money in|paid in/i], ['balance', /bal/i], ['amount', /amount|amt/i]];

function StatementUpload({ account, onClose }: { account: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [rows, setRows] = useState<Cell[][] | null>(null);
  const [head, setHead] = useState(0);
  const [cols, setCols] = useState<Col[]>([]);
  const [file, setFile] = useState('');
  const [closing, setClosing] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<any>(null);
  async function pick(f: File) {
    try {
      const sheets = await readWorkbook(f);
      const s = sheets.find((x) => x.rows.length > 1) || sheets[0];
      const h = detectHeader(s.rows);
      setRows(s.rows); setHead(h); setFile(f.name);
      setCols((s.rows[h] || []).map((c) => { const t = cellText(c); return (GUESS.find(([, re]) => re.test(t))?.[0] || 'ignore') as Col; }));
    } catch (e) { toast('Could not read that file. Save it as Excel or CSV and try again.', 'err'); }
  }
  const body = rows ? rows.slice(head + 1) : [];
  const idx = (c: Col) => cols.indexOf(c);
  const parsed = body.map((r) => {
    const amt = idx('amount') >= 0 ? parseNum(r[idx('amount')]) : (parseNum(r[idx('credit')]) || 0) - Math.abs(parseNum(r[idx('debit')]) || 0);
    return { date: parseDate(r[idx('date')]), description: cellText(r[idx('description')]), reference: idx('reference') >= 0 ? cellText(r[idx('reference')]) : null,
      amount: amt, balance: idx('balance') >= 0 ? parseNum(r[idx('balance')]) : null };
  }).filter((x) => x.date && x.amount);
  async function go() {
    setBusy(true);
    try {
      const r = await rpc<any>('import_bank_lines', { p_org: orgId, p_bank_account: account.id, p_lines: parsed, p_meta: { file_name: file, closing_balance: money(closing) } });
      setResult(r); await Promise.all(['banking', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={760}>
      <ModalHead title={`Statement for ${account.name}`} sub="Excel or CSV straight from internet banking. Lines already uploaded are skipped." onClose={onClose} />
      <div className="modal-body">
        {result ? (
          <div className="stack" style={{ gap: 10 }}>
            <Alert kind="green" icon="check">{result.added} new line{result.added === 1 ? '' : 's'}{result.duplicates ? `, ${result.duplicates} already here` : ''}.</Alert>
            <div className="stack" style={{ gap: 4, fontSize: 13 }}>{Object.entries(result.matched || {}).map(([k, n]) => <div key={k} className="row" style={{ justifyContent: 'space-between' }}><span>{STAGE[k] || k}</span><b>{String(n)}</b></div>)}
              {Number(result.for_ai) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span>Left for Atlas</span><b>{result.for_ai}</b></div>}</div>
            <Link className="btn btn-primary" to="/accounting/inbox" onClick={onClose}>Go to the books inbox</Link>
          </div>
        ) : !rows ? (
          <label className="empty" style={{ cursor: 'pointer' }}>
            <input type="file" accept=".xlsx,.xls,.csv" style={{ display: 'none' }} onChange={(e) => e.target.files?.[0] && pick(e.target.files[0])} />
            <Icon name="upload" size={22} color="#6B7280" /><div style={{ marginTop: 8 }}>Choose the statement file</div>
          </label>
        ) : (
          <>
            <div className="faint" style={{ fontSize: 12 }}>Tell Counta what each column holds. Money in and money out can be two columns or one signed amount.</div>
            <div className="tbl card" style={{ maxHeight: 300, overflow: 'auto' }}>
              <div style={{ display: 'grid', gridTemplateColumns: `repeat(${cols.length}, minmax(120px,1fr))`, gap: 6, padding: 8, minWidth: cols.length * 126 }}>
                {cols.map((c, i) => <select key={i} className="input input-sm" value={c} onChange={(e) => setCols(cols.map((x, j) => (j === i ? (e.target.value as Col) : x)))} aria-label={`Column ${i + 1}`}>
                  {(['ignore', 'date', 'description', 'reference', 'debit', 'credit', 'amount', 'balance'] as Col[]).map((o) => <option key={o} value={o}>{o === 'ignore' ? 'Skip' : o[0].toUpperCase() + o.slice(1)}</option>)}</select>)}
                {cols.map((_, i) => <div key={'h' + i} className="faint" style={{ fontSize: 11, fontWeight: 600 }}>{cellText(rows[head]?.[i])}</div>)}
                {body.slice(0, 6).flatMap((r, ri) => cols.map((_, i) => <div key={ri + '-' + i} className="ellipsis" style={{ fontSize: 12 }}>{cellText(r[i])}</div>))}
              </div>
            </div>
            <div className="row wrap" style={{ justifyContent: 'space-between' }}>
              <span className="muted" style={{ fontSize: 13 }}>{parsed.length} lines read · in {N2(parsed.filter((x) => (x.amount || 0) > 0).reduce((a, x) => a + (x.amount || 0), 0))} · out {N2(-parsed.filter((x) => (x.amount || 0) < 0).reduce((a, x) => a + (x.amount || 0), 0))}</span>
              <Field label="Closing balance on the statement"><input className="input input-sm" inputMode="decimal" value={closing} onChange={(e) => setClosing(e.target.value)} placeholder="From the last line" style={{ width: 180 }} /></Field>
            </div>
            {idx('date') < 0 || (idx('amount') < 0 && idx('debit') < 0 && idx('credit') < 0) ? <Alert kind="yellow" icon="info">Pick the date column and the amount (or money in and money out) columns.</Alert> : null}
          </>
        )}
      </div>
      {rows && !result && <div className="modal-ft"><button className="btn btn-secondary" onClick={() => setRows(null)}>Another file</button><button className="btn btn-primary" disabled={busy || !parsed.length} onClick={go}>{busy ? 'Matching…' : `Upload ${parsed.length} lines`}</button></div>}
    </Modal>
  );
}

function Reconcile({ account, onClose }: { account: any; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [asOf, setAsOf] = useState(today());
  const [stmt, setStmt] = useState(account.anchor_balance != null ? String(account.anchor_balance) : '');
  const [r, setR] = useState<any>(null);
  async function check() {
    try { setR(await rpc('bank_reconciliation', { p_bank_account: account.id, p_as_of: asOf, p_statement_balance: money(stmt) })); } catch (e) { toast((e as Error).message, 'err'); }
  }
  async function save() {
    try { await rpc('save_bank_reconciliation', { p_bank_account: account.id, p_as_of: asOf, p_statement_balance: money(stmt) }); toast('Reconciliation saved'); await qc.invalidateQueries({ queryKey: ['banking'] }); onClose(); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={640}>
      <ModalHead title={`Reconcile ${account.name}`} sub="The bank's balance, less what the bank has not yet processed, must equal the books." onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap">
          <Field label="As at"><input className="input" type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></Field>
          <Field label={account.kind === 'cash' ? 'Cash counted' : 'Balance on the statement'}><input className="input" inputMode="decimal" value={stmt} onChange={(e) => setStmt(e.target.value)} /></Field>
          <button className="btn btn-secondary" style={{ alignSelf: 'flex-end' }} onClick={check}>Check</button>
        </div>
        {r && (
          <div className="stack" style={{ gap: 8 }}>
            <div className="row" style={{ justifyContent: 'space-between' }}><span>Balance in the books</span><b className="num">{N2(r.book_balance)}</b></div>
            <div className="row" style={{ justifyContent: 'space-between' }}><span>On the statement</span><b className="num">{N2(r.statement_balance)}</b></div>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">In the books, not yet on the statement</span><span className="num">{N2(r.not_on_statement)}</span></div>
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">On the statement, not yet in the books</span><span className="num">{N2(r.not_in_books)}</span></div>
            <Alert kind={Math.abs(Number(r.difference)) < 0.01 ? 'green' : 'red'} icon={Math.abs(Number(r.difference)) < 0.01 ? 'check' : 'alert'}>{Math.abs(Number(r.difference)) < 0.01 ? 'Reconciled: no unexplained difference.' : `Unexplained difference of ${N2(r.difference)}. Upload the latest statement and answer the inbox questions first.`}</Alert>
            {[...(r.items?.not_in_books || []).map((x: any) => ({ ...x, side: 'Not in books' })), ...(r.items?.not_on_statement || []).map((x: any) => ({ ...x, side: 'Not on statement' }))].slice(0, 30).map((x: any, i: number) => (
              <div key={i} className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}><span className="ellipsis">{x.side} · {fmtDay(x.date)} · {x.description || x.memo}</span><span className="num">{N2(x.amount)}</span></div>
            ))}
          </div>
        )}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Close</button><button className="btn btn-primary" disabled={!r || Math.abs(Number(r.difference)) >= 0.01} onClick={save}>Save as reconciled</button></div>
    </Modal>
  );
}

function AddAccount({ onClose }: { onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState({ kind: 'bank', name: '', bank_name: '', account_number: '', account_name: inv?.org.name || '', opening_balance: '', opening_date: today(), location_id: '' });
  async function go() {
    try {
      await rpc('open_bank_account', { p_org: orgId, p_kind: f.kind, p_name: f.name, p_meta: { bank_name: f.bank_name || null, account_number: f.account_number || null, account_name: f.account_name || null,
        opening_balance: money(f.opening_balance), opening_date: f.opening_date, location_id: f.location_id || null } });
      toast('Account added'); await qc.invalidateQueries({ queryKey: ['banking'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="Add an account" sub="Each bank account, cash drawer or card gets its own ledger account." onClose={onClose} />
      <div className="modal-body">
        <Field label="Kind"><select className="input" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="bank">Bank account</option><option value="cash">Cash (safe or drawer)</option><option value="card">Company card</option></select></Field>
        <Field label="Name"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder={f.kind === 'bank' ? 'GTBank current' : 'Office safe'} /></Field>
        {f.kind === 'bank' && <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Bank"><input className="input" value={f.bank_name} onChange={(e) => setF({ ...f, bank_name: e.target.value })} /></Field>
          <Field label="Account number"><input className="input" inputMode="numeric" maxLength={10} value={f.account_number} onChange={(e) => setF({ ...f, account_number: e.target.value.replace(/\D/g, '') })} /></Field>
        </div>}
        {f.kind === 'cash' && <Field label="Branch"><select className="input" value={f.location_id} onChange={(e) => setF({ ...f, location_id: e.target.value })}><option value="">Head office</option>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Balance on" hint="From the bank, posted against opening balances."><input className="input" type="date" value={f.opening_date} onChange={(e) => setF({ ...f, opening_date: e.target.value })} /></Field>
          <Field label="Opening balance"><input className="input" inputMode="decimal" value={f.opening_balance} onChange={(e) => setF({ ...f, opening_balance: e.target.value })} placeholder="0.00" /></Field>
        </div>
      </div>
      <div className="modal-ft"><button className="btn btn-primary" disabled={!f.name.trim()} onClick={go}>Add</button></div>
    </Modal>
  );
}
