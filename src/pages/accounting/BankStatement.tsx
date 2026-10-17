// Uploading a bank statement: Excel, CSV or PDF from any Nigerian bank. The file is read in the browser (a PDF with a
// password asks for it), checked against its own balances and shown for a look before anything reaches the books.
import { useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import {
  PdfPasswordError, fromAi, fromPdfText, fromSheet, lastFour, openPdf, pageImages, pageText, pdfText, readStatementSheets, rolesOf,
  type AiStatement, type PdfText, type Role, type Statement,
} from '../../lib/statement';
import type { SheetData } from '../../lib/sheet';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';

export const STAGE: Record<string, string> = {
  in_books: 'Already in the books', pending_payment: 'Payment waiting for confirmation', statutory: 'Tax or levy payment', customer: 'Customer payment',
  customer_wht: 'Customer paid less WHT', customer_part: 'Customer part payment', customer_advance: 'Customer advance', vendor_bill: 'Bill payment',
  vendor_no_bill: 'Vendor without a bill', transfer: 'Between our accounts', transfer_one_leg: 'Transfer, other side not seen', rule: 'Learned rule',
  registry: 'Known payee', ai: 'Atlas', user: 'Answered by a person', suspense: 'Suspense', invoice_ref: 'Invoice named in the narration',
  bill_ref: 'Bill named in the narration', invoice_amount: 'Invoice of the same amount, to confirm', bill_amount: 'Bill of the same amount, to confirm',
};
const ROLE_LABEL: Record<Role, string> = { date: 'Date', value_date: 'Value date', description: 'Narration', reference: 'Reference', debit: 'Money out', credit: 'Money in',
  amount: 'Amount', drcr: 'Dr / Cr', balance: 'Balance', ignore: 'Skip' };

type Step = { k: 'pick' } | { k: 'password'; file: File; wrong: boolean } | { k: 'reading'; label: string } | { k: 'columns'; file: File; sheets: SheetData[]; kind: 'excel' | 'csv'; sheet: number; header: number; roles: Role[] }
  | { k: 'review'; file: File; st: Statement; pdf?: { doc: any; text: PdfText } } | { k: 'done'; result: any };

export default function StatementUpload({ account, onClose }: { account: any; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [step, setStep] = useState<Step>({ k: 'pick' });
  const [password, setPassword] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function readPdf(file: File, pw?: string) {
    setStep({ k: 'reading', label: 'Opening the PDF…' });
    let doc: any;
    try { doc = await openPdf(file, pw); }
    catch (e) {
      if (e instanceof PdfPasswordError) { setStep({ k: 'password', file, wrong: e.wrong }); return; }
      throw e;
    }
    setStep({ k: 'reading', label: `Reading ${doc.numPages} page${doc.numPages === 1 ? '' : 's'}…` });
    const text = await pdfText(doc);
    const st = text.scanned ? null : fromPdfText(text, file.name);
    if (st && st.lines.length) { setStep({ k: 'review', file, st, pdf: { doc, text } }); return; }
    await readWithAi(file, doc, text, text.scanned ? 'This PDF is a scan with no text in it, so the AI reader is reading the pages.' : 'The columns of this PDF could not be read, so the AI reader is reading it.');
  }

  // Long statements go two pages at a time, three parts at once; a part that fails is tried once more. The parts come
  // back as lines and are joined in page order.
  async function readWithAi(file: File, doc: any, text: PdfText, why?: string) {
    if (why) toast(why);
    const per = 2;
    const ranges: [number, number][] = [];
    for (let from = 1; from <= doc.numPages; from += per) ranges.push([from, Math.min(doc.numPages, from + per - 1)]);
    const parts: AiStatement[] = new Array(ranges.length);
    let done = 0;
    const show = () => setStep({ k: 'reading', label: doc.numPages <= per ? 'The AI reader is reading the statement…'
      : `The AI reader is reading the ${doc.numPages} pages · ${Math.min(done * per, doc.numPages)} of ${doc.numPages} read…` });
    show();
    const readPart = async (i: number) => {
      const [from, to] = ranges[i];
      const body = text.scanned ? { action: 'read_statement', images: await pageImages(doc, from, to), first_page: from }
        : { action: 'read_statement', pages: text.pages.slice(from - 1, to).map(pageText), first_page: from };
      let r = await edge<AiStatement>('ai', body);
      if (r.ok === false && r.reason !== 'not_configured') r = await edge<AiStatement>('ai', body);
      if (r.ok === false) throw new Error(r.reason === 'not_configured' ? 'AI reading is not switched on, so this statement cannot be read. Ask the bank for an Excel or CSV copy.'
        : `Pages ${from}${to > from ? `–${to}` : ''} could not be read: ${r.error || 'the AI reader did not answer'}. Try again, or ask the bank for an Excel or CSV copy.`);
      parts[i] = r; done++; show();
    };
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(3, ranges.length) }, async () => { while (next < ranges.length) await readPart(next++); }));
    setStep({ k: 'review', file, st: fromAi(parts, file.name), pdf: { doc, text } });
  }

  async function pick(file: File) {
    setErr(null); setConfirmed(false); setPassword('');
    if (file.size > 25 * 1024 * 1024) { setErr('That file is over 25MB. Ask the bank for a shorter period.'); return; }
    try {
      if (/\.pdf$/i.test(file.name) || file.type === 'application/pdf') { await readPdf(file); return; }
      setStep({ k: 'reading', label: 'Reading the file…' });
      const { sheets, kind } = await readStatementSheets(file);
      if (!sheets.length) throw new Error('That file has no rows.');
      // The sheet whose columns read best.
      let best: Statement | null = null; let bi = 0;
      sheets.forEach((s, i) => { const st = fromSheet(s, kind, file.name); if (st && (!best || st.lines.length > best.lines.length)) { best = st; bi = i; } });
      if (best && (best as Statement).lines.length) { setStep({ k: 'review', file, st: best }); return; }
      const s = sheets[bi];
      const header = Math.max(0, s.rows.findIndex((r) => r.filter((c) => c != null && c !== '').length >= 3));
      setStep({ k: 'columns', file, sheets, kind, sheet: bi, header, roles: rolesOf((s.rows[header] || []).map((c) => String(c ?? ''))) });
    } catch (e) { setErr((e as Error).message || 'Could not read that file.'); setStep({ k: 'pick' }); }
  }

  async function send(st: Statement, file: File) {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<any>('import_bank_lines', {
        p_org: orgId, p_bank_account: account.id,
        p_lines: st.lines.map((l) => ({ date: l.date, amount: l.amount, description: l.description, reference: l.reference, balance: l.balance })),
        p_meta: { file_name: file.name, source: st.kind, read_by: st.read_by, bank_name: st.meta.bank_name, account_number: st.meta.account_number,
          period_from: st.meta.period_from, period_to: st.meta.period_to, opening_balance: st.meta.opening_balance, closing_balance: st.meta.closing_balance,
          account_confirmed: confirmed },
      });
      setStep({ k: 'done', result: r });
      await Promise.all(['banking', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }

  const reading = step.k === 'reading';
  return (
    <Modal onClose={onClose} width={step.k === 'review' || step.k === 'columns' ? 980 : 640}>
      <ModalHead title={`Statement for ${account.name}`} sub="Excel, CSV or PDF from internet banking or the bank's email. Lines already in Counta are never added twice." onClose={onClose} />
      <div className="modal-body">
        {step.k === 'pick' && (
          <div className="stack" style={{ gap: 12 }}>
            <button className="empty" style={{ cursor: 'pointer', width: '100%' }} onClick={() => input.current?.click()}>
              <Icon name="upload" size={22} color="#6B7280" /><div style={{ marginTop: 8 }}>Choose the statement file</div>
              <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>PDF, Excel (.xlsx, .xls) or CSV</div>
            </button>
            <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
              Counta reads the account number, period and opening and closing balances from the top of the statement, joins narrations that run onto a second
              line, and checks that every balance follows from the one before. Statements that print the newest line first are put in date order. A scanned
              PDF is read by the AI reader. {account.account_number ? `This account ends ${lastFour(account.account_number)}.` : ''}
            </div>
            {account.feed?.linked && <Alert kind="blue" icon="info">This account has a bank feed. A statement for the same days adds only what the feed has not brought in.</Alert>}
          </div>
        )}
        {step.k === 'password' && (
          <form className="stack" style={{ gap: 10 }} onSubmit={(e) => { e.preventDefault(); const f = step.file; readPdf(f, password).catch((x) => { setErr((x as Error).message); setStep({ k: 'pick' }); }); }}>
            <Alert kind={step.wrong ? 'red' : 'blue'} icon="shield">{step.wrong ? 'That password did not open it. Try again.'
              : 'The bank protected this statement with a password. Banks usually say what it is in the email that brought it (often part of the account number or date of birth).'}</Alert>
            <Field label="Statement password"><input className="input" type="password" autoFocus autoComplete="off" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
            <div className="faint" style={{ fontSize: 12 }}>The password opens the file here in your browser. It is not sent or kept.</div>
            <div className="row"><button className="btn btn-primary" disabled={!password}>Open</button><button type="button" className="btn btn-ghost" onClick={() => setStep({ k: 'pick' })}>Another file</button></div>
          </form>
        )}
        {reading && <div className="stack" style={{ alignItems: 'center', padding: '40px 0', gap: 12 }}><Spinner /><div className="muted">{step.label}</div></div>}
        {step.k === 'columns' && <Columns step={step} onChange={(s) => setStep(s)} onRead={(st) => setStep({ k: 'review', file: step.file, st })} />}
        {step.k === 'review' && <Review st={step.st} account={account} confirmed={confirmed} setConfirmed={setConfirmed}
          onAi={step.pdf && step.st.read_by === 'columns' ? () => readWithAi(step.file, step.pdf!.doc, step.pdf!.text).catch((e) => { setErr((e as Error).message); }) : undefined} />}
        {step.k === 'done' && <Done r={step.result} onClose={onClose} />}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <input ref={input} type="file" hidden accept=".pdf,.xlsx,.xls,.xlsm,.csv,.txt,application/pdf,text/csv" onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) pick(f); }} />
      </div>
      {step.k === 'review' && (() => {
        const mismatch = needsConfirm(step.st, account);
        return (
          <div className="modal-ft">
            <button className="btn btn-secondary" onClick={() => { setStep({ k: 'pick' }); input.current?.click(); }}>Another file</button>
            <button className="btn btn-primary" disabled={busy || !step.st.lines.length || (mismatch && !confirmed)} onClick={() => send(step.st, step.file)}>
              {busy ? <><Spinner small />Matching…</> : `Upload ${step.st.lines.length} line${step.st.lines.length === 1 ? '' : 's'}`}
            </button>
          </div>
        );
      })()}
    </Modal>
  );
}

const needsConfirm = (st: Statement, account: any) => {
  const a = lastFour(account.account_number); const b = lastFour(st.meta.account_number);
  return !!(a && b && a !== b);
};

function Review({ st, account, confirmed, setConfirmed, onAi }: { st: Statement; account: any; confirmed: boolean; setConfirmed: (v: boolean) => void; onAi?: () => void }) {
  const inSum = st.lines.filter((l) => l.amount > 0).reduce((a, l) => a + l.amount, 0);
  const outSum = -st.lines.filter((l) => l.amount < 0).reduce((a, l) => a + l.amount, 0);
  const flagged = st.lines.filter((l) => l.issues.length).length;
  const [only, setOnly] = useState(false);
  const shown = useMemo(() => (only ? st.lines.filter((l) => l.issues.length) : st.lines).slice(0, 400), [st, only]);
  const m = st.meta;
  const fact = (label: string, value: string | null | undefined) => <div><div className="faint" style={{ fontSize: 11 }}>{label}</div><div style={{ fontWeight: 600, fontSize: 13 }}>{value || '—'}</div></div>;
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="card" style={{ padding: 12, display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(140px,1fr))', gap: 10 }}>
        {fact('Bank', m.bank_name)}
        {fact('Account', m.account_number ? `${m.account_number}${m.account_name ? ` · ${m.account_name}` : ''}` : m.account_name)}
        {fact('Period', m.period_from ? `${fmtDay(m.period_from)} to ${fmtDay(m.period_to || m.period_from)}` : null)}
        {fact('Opening balance', m.opening_balance != null ? N2(m.opening_balance) : null)}
        {fact('Money in', N2(inSum))}
        {fact('Money out', N2(outSum))}
        {fact('Closing balance', m.closing_balance != null ? N2(m.closing_balance) : null)}
        {fact('Read by', st.read_by === 'ai' ? 'AI reader' : `Columns (${st.kind.toUpperCase()})`)}
      </div>
      {needsConfirm(st, account) && (
        <Alert kind="red" icon="alert">
          This statement is for account ending {lastFour(m.account_number)}, but {account.name} is account ending {lastFour(account.account_number)}.
          <label className="check" style={{ display: 'flex', marginTop: 8, fontSize: 13 }}><input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} />It is the right account (the bank changed the number, or the number on file is wrong)</label>
        </Alert>
      )}
      {st.balance_check === 'agrees' && <Alert kind="green" icon="check">Opening balance plus every line reaches the closing balance{st.newest_first ? '. The bank printed the newest line first; the lines are in date order here' : ''}.</Alert>}
      {st.balance_check === 'unknown' && <Alert kind="blue" icon="info">The statement shows no opening and closing balance, so the total could not be checked. Compare the money in and out with the statement before uploading.</Alert>}
      {st.problems.length > 0 && <Alert kind="yellow" icon="alert"><div className="stack" style={{ gap: 4 }}>{st.problems.map((p, i) => <div key={i}>{p}</div>)}</div>
        {onAi && <div style={{ marginTop: 8 }}><button className="btn btn-secondary btn-xs" onClick={onAi}><Icon name="sparkles" size={13} />Read it with the AI reader instead</button></div>}</Alert>}
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className="muted" style={{ fontSize: 13 }}>{st.lines.length} lines{flagged ? ` · ${flagged} to check` : ''}</span>
        {flagged > 0 && <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={only} onChange={(e) => setOnly(e.target.checked)} />Only lines to check</label>}
      </div>
      <div className="card" style={{ overflow: 'auto', maxHeight: 380 }}>
        <table className="mini-table" style={{ width: '100%', minWidth: 760 }}>
          <thead><tr><th>Date</th><th>Narration</th><th>Reference</th><th className="right">Money in</th><th className="right">Money out</th><th className="right">Balance</th></tr></thead>
          <tbody>{shown.map((l, i) => (
            <tr key={i} style={l.issues.length ? { background: '#FFFBEB' } : undefined} title={l.issues.join(' ')}>
              <td className="muted" style={{ whiteSpace: 'nowrap' }}>{fmtDay(l.date)}</td>
              <td>{l.description}{l.issues.length > 0 && <div style={{ fontSize: 11, color: '#B45309' }}>{l.issues.join(' ')}</div>}</td>
              <td className="faint">{l.reference || ''}</td>
              <td className="right num" style={{ color: '#15803D' }}>{l.amount > 0 ? N2(l.amount) : ''}</td>
              <td className="right num">{l.amount < 0 ? N2(-l.amount) : ''}</td>
              <td className="right num faint">{l.balance != null ? N2(l.balance) : ''}</td>
            </tr>
          ))}</tbody>
        </table>
      </div>
      {st.lines.length > 400 && <div className="faint" style={{ fontSize: 12 }}>Showing the first 400 lines; all {st.lines.length} are uploaded.</div>}
    </div>
  );
}

// When no heading could be found: the person says which column is which.
function Columns({ step, onChange, onRead }: { step: Extract<Step, { k: 'columns' }>; onChange: (s: Step) => void; onRead: (st: Statement) => void }) {
  const s = step.sheets[step.sheet];
  const width = Math.max(...s.rows.slice(step.header, step.header + 12).map((r) => r.length), 1);
  const roles = Array.from({ length: width }, (_, i) => step.roles[i] || 'ignore');
  const st = fromSheet(s, step.kind, step.file.name, { header: step.header, roles });
  const ok = roles.includes('date') && (roles.includes('amount') || roles.includes('debit') || roles.includes('credit'));
  return (
    <div className="stack" style={{ gap: 10 }}>
      <Alert kind="blue" icon="info">Counta could not find the column headings. Choose the row with them and say what each column holds.</Alert>
      <div className="row wrap">
        {step.sheets.length > 1 && <Field label="Sheet"><select className="input input-sm" value={step.sheet} onChange={(e) => onChange({ ...step, sheet: Number(e.target.value), header: 0, roles: [] })}>
          {step.sheets.map((x, i) => <option key={i} value={i}>{x.name}</option>)}</select></Field>}
        <Field label="Headings are on"><select className="input input-sm" value={step.header} onChange={(e) => { const h = Number(e.target.value); onChange({ ...step, header: h, roles: rolesOf((s.rows[h] || []).map((c) => String(c ?? ''))) }); }}>
          {s.rows.slice(0, 40).map((r, i) => <option key={i} value={i}>Row {s.rowNo?.[i] ?? i + 1}: {r.map((c) => String(c ?? '')).filter(Boolean).slice(0, 3).join(' · ').slice(0, 50)}</option>)}</select></Field>
      </div>
      <div className="card" style={{ overflow: 'auto', maxHeight: 320 }}>
        <div style={{ display: 'grid', gridTemplateColumns: `repeat(${width}, minmax(120px,1fr))`, gap: 6, padding: 8, minWidth: width * 126 }}>
          {roles.map((r, i) => <select key={i} className="input input-sm" value={r} aria-label={`Column ${i + 1}`} onChange={(e) => onChange({ ...step, roles: roles.map((x, j) => (j === i ? (e.target.value as Role) : x)) })}>
            {(Object.keys(ROLE_LABEL) as Role[]).map((o) => <option key={o} value={o}>{ROLE_LABEL[o]}</option>)}</select>)}
          {s.rows.slice(step.header, step.header + 8).flatMap((row, ri) => roles.map((_, i) => <div key={ri + '-' + i} className={'ellipsis' + (ri === 0 ? ' faint' : '')} style={{ fontSize: 12, fontWeight: ri === 0 ? 600 : 400 }}>{String(row[i] instanceof Date ? (row[i] as Date).toISOString().slice(0, 10) : row[i] ?? '')}</div>))}
        </div>
      </div>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className="muted" style={{ fontSize: 13 }}>{ok && st ? `${st.lines.length} lines read` : 'Choose the date column and the money in and out (or amount) columns.'}</span>
        <button className="btn btn-primary btn-sm" disabled={!ok || !st || !st.lines.length} onClick={() => st && onRead(st)}>Check the lines</button>
      </div>
    </div>
  );
}

function Done({ r, onClose }: { r: any; onClose: () => void }) {
  const placed = Object.entries(r.matched || {}).filter(([, n]) => Number(n) > 0);
  return (
    <div className="stack" style={{ gap: 10 }}>
      <Alert kind="green" icon="check">{r.added} new line{r.added === 1 ? '' : 's'} added.{Number(r.already_in) > 0 ? ` ${r.already_in} were already in from the bank feed or another statement.` : ''}{Number(r.duplicates) > 0 ? ` ${r.duplicates} had been uploaded before.` : ''}</Alert>
      {r.balance_check === 'differs' && <Alert kind="yellow" icon="alert">The statement's balances do not add up. The lines are in; check the statement for a missing page.</Alert>}
      <div className="stack" style={{ gap: 4, fontSize: 13 }}>
        {placed.map(([k, n]) => <div key={k} className="row" style={{ justifyContent: 'space-between' }}><span>{STAGE[k] || k}</span><b>{String(n)}</b></div>)}
        {Number(r.for_ai) > 0 && <div className="row" style={{ justifyContent: 'space-between' }}><span>Left for Atlas</span><b>{r.for_ai}</b></div>}
      </div>
      <div className="row"><Link className="btn btn-primary" to="/accounting/inbox" onClick={onClose}>Go to the books inbox</Link><button className="btn btn-secondary" onClick={onClose}>Close</button></div>
    </div>
  );
}
