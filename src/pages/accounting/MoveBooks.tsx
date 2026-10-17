// Moving the books from QuickBooks, Zoho Books, Xero or Sage. Counta opens on the old system's position at the
// cut-over date: the trial balance (each account placed by rules and the AI, a person confirming anything under 80%),
// customers and suppliers, and every unpaid invoice and bill, reconciled to the trial balance before it posts.
import { useMemo, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, useChart } from '../../lib/api';
import { N2, addDays, fmtDay, num, when } from '../../lib/format';
import { BOOK_SYSTEMS, CUSTOMER_FIELDS, OPEN_FIELDS, TB_FIELDS, bookSystem, customerRows, openRows, tbRows, type BooksSource } from '../../lib/moveBooks';
import { SheetRows } from '../../components/SheetRows';
import { SimpleImport, newImportId } from '../../components/SimpleImport';
import { Icon } from '../../components/Icon';
import { Alert, Chip, Field, Modal, ModalHead, Pills, SkeletonRows } from '../../components/ui';

interface MAccount {
  id: string; line_no: number; source_code: string | null; source_name: string; source_type: string | null; debit: number; credit: number;
  mapped_code: string | null; mapped_name: string | null; new_bank: boolean; bank_name: string | null; confidence: number | null; reason: string | null;
  mapped_by: 'rule' | 'ai' | 'person' | null; confirmed: boolean;
}
const BANK_PARENTS: Record<string, string> = { '1011': 'Cash', '1012': 'Bank (naira)', '1013': 'Bank (foreign currency)', '1014': 'Payment wallet' };
const pct = (c: number | null) => (c == null ? '' : `${Math.round(Number(c) * 100)}%`);

export default function MoveBooks() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const state = useQuery({ queryKey: ['books-migration', orgId], enabled: !!orgId, queryFn: () => rpc<any>('get_books_migration', { p_org: orgId }) });
  const chart = useChart(!!orgId);
  const [source, setSource] = useState<BooksSource | null>(null);
  const [asOf, setAsOf] = useState(() => lastYearEnd(inv?.org.fiscal_year_start || 1));
  const [busy, setBusy] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'check' | 'done'>('check');
  const [accept, setAccept] = useState(false);
  const [undo, setUndo] = useState<any>(null);
  const [vendorsImport] = useState(() => newImportId());
  const options = useMemo(() => accountOptions(chart.data?.accounts || []), [chart.data]);
  if (!inv) return null;
  if (!can(inv, 'keep_books') && inv.me.role !== 'owner') return <div className="container"><Alert kind="yellow" icon="shield">Moving the books needs the Keep the books permission. Ask the owner.</Alert></div>;
  const g = state.data;
  const mig = g?.migration && g.migration.status === 'draft' ? g.migration : null;
  const posted = g?.migration && g.migration.status === 'posted' ? g.migration : null;
  const history: any[] = [...(posted ? [{ ...posted, summary: posted.summary }] : []), ...(g?.history || []).filter((h: any) => h.status === 'posted')];
  const accounts: MAccount[] = mig ? g.accounts || [] : [];
  const open: any[] = mig ? g.open_items || [] : [];
  const checks = mig ? g.checks : null;
  const sys = bookSystem(mig?.source || source);
  const refresh = (data?: any) => { if (data) qc.setQueryData(['books-migration', orgId], data); else qc.invalidateQueries({ queryKey: ['books-migration'] }); };
  async function act(key: string, fn: () => Promise<any>, ok?: string) {
    setBusy(key);
    try { const r = await fn(); if (r && typeof r === 'object' && 'checks' in r) refresh(r); else refresh(); if (ok) toast(ok); return r; }
    catch (e) { toast((e as Error).message, 'err'); }
    finally { setBusy(null); }
  }
  const shownAccounts = accounts.filter((a) => filter === 'all' || (filter === 'check' ? !a.mapped_code || !a.confirmed : a.mapped_code && a.confirmed));
  const toConfirm = accounts.filter((a) => a.mapped_code && !a.confirmed);
  const invoices = open.filter((i) => i.kind === 'invoice');
  const bills = open.filter((i) => i.kind === 'bill');

  return (
    <div className="container" style={{ maxWidth: 1080 }}>
      <div className="ink3" style={{ fontSize: 14, maxWidth: 780, lineHeight: 1.55 }}>
        Bring your books across from QuickBooks, Zoho Books, Xero or Sage. Counta takes the trial balance at your cut-over date, places each account in its own chart (the AI does most of it and asks you about anything it is less than 80% sure of), brings in customers, suppliers and every unpaid invoice and bill, checks they agree, and posts one opening journal. You can undo it until something is paid against it.
      </div>
      {state.isLoading ? <div className="card card-pad"><SkeletonRows n={4} /></div> : (
        <>
          {history.length > 0 && !mig && (
            <div className="card card-pad stack" style={{ gap: 8 }}>
              <div className="label">Already moved</div>
              {history.map((h) => (
                <div key={h.id} className="row wrap" style={{ justifyContent: 'space-between', fontSize: 13.5 }}>
                  <span>From {bookSystem(h.source).name} at {fmtDay(h.as_of)} · {h.journal_ref || h.summary?.journal_ref}{h.summary?.invoices != null ? ` · ${h.summary.invoices} invoices, ${h.summary.bills} bills` : ''}{h.posted_at ? ` · ${when(h.posted_at)}` : ''}</span>
                  {inv.me.role === 'owner' && <button className="btn btn-ghost btn-xs" onClick={() => setUndo(h)}><Icon name="undo" size={13} />Undo</button>}
                </div>
              ))}
            </div>
          )}

          <Step n={1} title="Where are you coming from, and when do you switch?" done={!!mig}>
            {!mig ? (
              <>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(180px,1fr))', gap: 8 }}>
                  {BOOK_SYSTEMS.map((s) => (
                    <button key={s.id} className="card" onClick={() => setSource(s.id)} aria-pressed={source === s.id}
                      style={{ padding: '12px 14px', textAlign: 'left', cursor: 'pointer', font: 'inherit', borderColor: source === s.id ? '#0072F5' : undefined, background: source === s.id ? '#F0F7FF' : undefined }}>
                      <div style={{ fontSize: 14, fontWeight: 600 }}>{s.name}</div>
                    </button>
                  ))}
                </div>
                <div className="row wrap" style={{ gap: 12, alignItems: 'flex-end' }}>
                  <Field label="Cut-over date" hint="The last day kept in the old system. Counta's books start the day after.">
                    <input className="input" type="date" value={asOf} max={addDays(new Date().toISOString().slice(0, 10), -1)} onChange={(e) => setAsOf(e.target.value)} style={{ maxWidth: 200 }} />
                  </Field>
                  <button className="btn btn-primary" disabled={!source || !asOf || !!busy} onClick={() => act('start', () => rpc('start_books_migration', { p_org: orgId, p_source: source, p_as_of: asOf }))}>Start</button>
                </div>
                <Alert kind="blue" icon="info">Pick the end of a financial year you have closed in the old system, such as {fmtDay(lastYearEnd(inv.org.fiscal_year_start || 1))}. The opening position is then final and audited figures, and your first year in Counta compares cleanly with the old statements. The end of a month works too.</Alert>
              </>
            ) : (
              <div className="row wrap" style={{ justifyContent: 'space-between' }}>
                <span>From <b>{sys.name}</b> at <b>{fmtDay(mig.as_of)}</b>. Counta's books start on {fmtDay(addDays(mig.as_of, 1))}.</span>
                <button className="btn btn-ghost btn-xs" onClick={() => setSource(mig.source)}><Icon name="pencil" size={13} />Change</button>
              </div>
            )}
            {mig && source && source !== mig.source && (
              <div className="row wrap" style={{ gap: 8 }}>
                <select className="input input-sm" value={source} onChange={(e) => setSource(e.target.value as BooksSource)} style={{ width: 200 }}>{BOOK_SYSTEMS.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
                <input className="input input-sm" type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} style={{ width: 170 }} />
                <button className="btn btn-secondary btn-sm" onClick={() => act('start', () => rpc('start_books_migration', { p_org: orgId, p_source: source, p_as_of: asOf }), 'Updated')}>Save</button>
              </div>
            )}
          </Step>

          {(mig || source) && (
            <Step n={2} title={`Export these from ${sys.name}`}>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(240px,1fr))', gap: 10 }}>
                <How icon="book" title="Trial balance at the cut-over date">{sys.tb}</How>
                <How icon="receipt" title="Unpaid customer invoices">{sys.ar}</How>
                <How icon="file" title="Unpaid supplier bills">{sys.ap}</How>
                <How icon="users" title="Customers">{sys.customers}</How>
                <How icon="truck" title="Suppliers">{sys.suppliers}</How>
                <How icon="package" title="Items and stock">{sys.items}</How>
              </div>
              {sys.tip && <Alert kind="blue" icon="info">{sys.tip}</Alert>}
              <div className="faint" style={{ fontSize: 12 }}>Excel or CSV both work. Counta finds the columns; you check them before anything is saved.</div>
            </Step>
          )}

          {mig && (
            <>
              <Step n={3} title="Upload the trial balance" done={accounts.length > 0 && !!checks?.balances}>
                {accounts.length > 0 && (
                  <div className="row wrap" style={{ gap: 10 }}>
                    <Fig label="Accounts" value={num(accounts.length)} sub={mig.tb_file || ''} />
                    <Fig label="Debits" value={N2(checks.debits)} />
                    <Fig label="Credits" value={N2(checks.credits)} sub={checks.balances ? 'Balances' : `Off by ${N2(Number(checks.debits) - Number(checks.credits))}`} tone={checks.balances ? 'green' : 'amber'} />
                  </div>
                )}
                <SheetRows fields={TB_FIELDS} need={[['debit', 'credit'], ['balance']]} note={accounts.length ? 'Uploading again replaces the trial balance and its mapping.' : undefined}
                  action={(n) => `Use ${num(n)} account${n === 1 ? '' : 's'}`}
                  onRows={async (rows, file) => {
                    const r = await rpc<any>('set_migration_trial_balance', { p_migration: mig.id, p_rows: tbRows(rows), p_file: file });
                    refresh(r); toast(`${r.accounts?.length || 0} accounts read. ${r.checks?.unconfirmed ? `${r.checks.unconfirmed} to check.` : ''}`);
                    if ((r.accounts || []).some((a: MAccount) => (a.confidence ?? 0) < 0.9 && a.mapped_by !== 'person')) {
                      const ai = await edge<any>('ai', { action: 'map_accounts', org_id: orgId });
                      if (ai.ok !== false && ai.accounts) { refresh(ai); if (ai.ai_updated) toast(`The AI placed ${ai.ai_updated} more account${ai.ai_updated === 1 ? '' : 's'}.`); }
                    }
                  }} />
              </Step>

              {accounts.length > 0 && (
                <Step n={4} title="Place each account in Counta's chart" done={checks.unmapped === 0 && checks.unconfirmed === 0}>
                  <div className="row wrap" style={{ justifyContent: 'space-between', gap: 8 }}>
                    <Pills value={filter} onChange={setFilter} options={[{ id: 'check', label: 'Needs you', count: Number(checks.unmapped) + Number(checks.unconfirmed) || undefined }, { id: 'done', label: 'Confirmed' }, { id: 'all', label: 'All' }]} />
                    <div className="row wrap">
                      <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={() => act('ai', async () => {
                        const r = await edge<any>('ai', { action: 'map_accounts', org_id: orgId });
                        if (r.ok === false) throw new Error(r.error || r.reason || 'The AI is not available right now. Place the accounts yourself.');
                        return r;
                      }, 'The AI has gone through the accounts')}><Icon name="sparkles" size={14} />{busy === 'ai' ? 'Thinking…' : 'Ask the AI'}</button>
                      {toConfirm.length > 0 && <button className="btn btn-primary btn-sm" disabled={!!busy} onClick={() => act('confirm', () => rpc('confirm_migration_accounts', { p_migration: mig.id, p_lines: toConfirm.map((a) => a.id) }), `${toConfirm.length} confirmed`)}>
                        <Icon name="check" size={14} color="#fff" />Confirm {toConfirm.length} as suggested</button>}
                    </div>
                  </div>
                  <div className="card" style={{ overflow: 'hidden' }}>
                    <div className="tbl">
                      <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(200px,1.3fr) 130px minmax(240px,1.5fr) 110px', minWidth: 760 }}>
                        <span>In {sys.name}</span><span className="right">Balance</span><span>In Counta</span><span>How sure</span>
                      </div>
                      {!shownAccounts.length && <div style={{ padding: 16 }} className="faint">{filter === 'check' ? 'Nothing waiting for you.' : 'No accounts here.'}</div>}
                      {shownAccounts.map((a) => {
                        const bal = Number(a.debit) - Number(a.credit);
                        return (
                          <div key={a.id} className="tr" style={{ gridTemplateColumns: 'minmax(200px,1.3fr) 130px minmax(240px,1.5fr) 110px', minWidth: 760, alignItems: 'start' }}>
                            <span style={{ minWidth: 0 }}><b>{a.source_code ? `${a.source_code} ` : ''}{a.source_name}</b>{a.source_type && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{a.source_type}</span>}</span>
                            <span className="right num">{bal < 0 ? `${N2(-bal)} Cr` : `${N2(bal)} Dr`}</span>
                            <span className="stack" style={{ gap: 4, minWidth: 0 }}>
                              <select className="input input-sm" value={a.new_bank ? `new:${a.mapped_code}` : a.mapped_code || ''} disabled={!!busy}
                                onChange={(e) => {
                                  const v = e.target.value; if (!v) return;
                                  const code = v.replace(/^new:/, '');
                                  act('map', () => rpc('map_migration_account', { p_line: a.id, p_code: code, p_bank_name: v.startsWith('new:') ? (a.bank_name || a.source_name) : null }));
                                }}>
                                <option value="">Choose an account</option>
                                <optgroup label="Open a new account for it">{Object.entries(BANK_PARENTS).map(([c, l]) => <option key={c} value={`new:${c}`}>New {l.toLowerCase()} account</option>)}</optgroup>
                                {options.map((grp) => <optgroup key={grp.label} label={grp.label}>{grp.items.map((o) => <option key={o.code} value={o.code}>{o.code} {o.name}</option>)}</optgroup>)}
                              </select>
                              {a.reason && <span className="faint" style={{ fontSize: 12 }}>{a.mapped_by === 'ai' ? 'AI: ' : a.mapped_by === 'rule' ? '' : 'You: '}{a.reason}</span>}
                            </span>
                            <span className="stack" style={{ gap: 4 }}>
                              {a.mapped_code ? <Chip label={a.mapped_by === 'person' ? 'You chose' : pct(a.confidence)} t={a.confirmed ? 't-green' : Number(a.confidence) >= 0.8 ? 't-blue' : 't-amber'} /> : <Chip label="Not placed" t="t-red" />}
                              {a.mapped_code && !a.confirmed && <button className="btn btn-ghost btn-xs" style={{ paddingLeft: 0 }} disabled={!!busy} onClick={() => act('confirm', () => rpc('confirm_migration_accounts', { p_migration: mig.id, p_lines: [a.id] }))}>Confirm</button>}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                  <div className="faint" style={{ fontSize: 12 }}>Suggestions 80% sure or more are confirmed for you; anything less waits for you. Bank, cash and wallet accounts open as new accounts in Banking with their opening balance. Old "opening balance equity" goes to 3999 and is reclassified when you close.</div>
                </Step>
              )}

              <Step n={5} title="Customers and suppliers" optional>
                <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                  <div className="stack" style={{ gap: 8 }}>
                    <b style={{ fontSize: 14 }}>Customers</b>
                    <SheetRows fields={CUSTOMER_FIELDS} action={(n) => `Add ${num(n)} customer${n === 1 ? '' : 's'}`}
                      onRows={async (rows) => {
                        const list = customerRows(rows);
                        let created = 0, updated = 0;
                        for (let i = 0; i < list.length; i += 1000) {
                          const r = await rpc<any>('import_customers', { p_org: orgId, p_rows: list.slice(i, i + 1000), p_options: { source: sys.name } });
                          created += r.created || 0; updated += r.updated || 0;
                        }
                        toast(`${created} customer${created === 1 ? '' : 's'} added${updated ? `, ${updated} updated` : ''}`);
                        qc.invalidateQueries({ queryKey: ['customers'] }); refresh();
                      }} />
                  </div>
                  <div className="stack" style={{ gap: 8 }}>
                    <b style={{ fontSize: 14 }}>Suppliers</b>
                    <SimpleImport kind="vendors" orgId={orgId!} source={mig.source} importId={vendorsImport} onDone={() => refresh()} />
                  </div>
                </div>
                <div className="faint" style={{ fontSize: 12 }}>Anyone named on an unpaid invoice or bill who is not in these lists is added when the opening position posts. Items and stock come in under <Link to="/inventory/migrate">Inventory, Move to Counta</Link>, dated the same cut-over day, and Counta nets that stock against the inventory in the trial balance.</div>
              </Step>

              <Step n={6} title="Unpaid invoices and bills" done={open.length > 0 && Math.abs(Number(checks?.receivables_tb) - Number(checks?.receivables_open)) < 0.01 && Math.abs(Number(checks?.payables_tb) - Number(checks?.payables_open)) < 0.01}>
                <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                  {(['invoice', 'bill'] as const).map((kind) => {
                    const list = kind === 'invoice' ? invoices : bills;
                    const tb = Number(kind === 'invoice' ? checks?.receivables_tb : checks?.payables_tb) || 0;
                    const sum = list.reduce((s, x) => s + Number(x.amount), 0);
                    const unknown = list.filter((x) => !x.known).length;
                    return (
                      <div key={kind} className="stack" style={{ gap: 8 }}>
                        <b style={{ fontSize: 14 }}>{kind === 'invoice' ? 'Unpaid customer invoices' : 'Unpaid supplier bills'}</b>
                        {list.length > 0 && (
                          <div className="row wrap" style={{ gap: 8 }}>
                            <Fig label={kind === 'invoice' ? 'Invoices' : 'Bills'} value={N2(sum)} sub={`${list.length} open${unknown ? `, ${unknown} new ${kind === 'invoice' ? 'customer' : 'supplier'}${unknown === 1 ? '' : 's'}` : ''}`} />
                            <Fig label="Trial balance" value={N2(tb)} sub={Math.abs(tb - sum) < 0.01 ? 'Agrees' : `Differs by ${N2(tb - sum)}`} tone={Math.abs(tb - sum) < 0.01 ? 'green' : 'amber'} />
                          </div>
                        )}
                        <SheetRows fields={OPEN_FIELDS(kind)} action={(n) => `Use ${num(n)} ${kind === 'invoice' ? 'invoice' : 'bill'}${n === 1 ? '' : 's'}`}
                          note={list.length ? 'Uploading again replaces this list.' : undefined}
                          onRows={async (rows, file) => { const r = await rpc<any>('set_migration_open_items', { p_migration: mig.id, p_kind: kind, p_rows: openRows(rows), p_file: file }); refresh(r); }} />
                      </div>
                    );
                  })}
                </div>
                <div className="faint" style={{ fontSize: 12 }}>Each unpaid invoice and bill comes in as an open document dated as it was, so reminders, statements and payments work on it from day one. Use the amount still unpaid, not the original total.</div>
              </Step>

              <Step n={7} title="Check and post" done={false}>
                <div className="stack" style={{ gap: 6 }}>
                  <Check ok={accounts.length > 0 && checks.balances} text={accounts.length ? `Trial balance balances: debits ${N2(checks.debits)}, credits ${N2(checks.credits)}` : 'Upload the trial balance'} />
                  <Check ok={accounts.length > 0 && checks.unmapped === 0 && checks.unconfirmed === 0} text={checks.unmapped || checks.unconfirmed ? `${checks.unmapped} account(s) not placed, ${checks.unconfirmed} waiting for you to confirm` : 'Every account is placed and confirmed'} />
                  <Check ok={Math.abs(Number(checks.receivables_tb) - Number(checks.receivables_open)) < 0.01} soft text={`Receivables: trial balance ${N2(checks.receivables_tb)}, unpaid invoices ${N2(checks.receivables_open)}`} />
                  <Check ok={Math.abs(Number(checks.payables_tb) - Number(checks.payables_open)) < 0.01} soft text={`Payables: trial balance ${N2(checks.payables_tb)}, unpaid bills ${N2(checks.payables_open)}`} />
                  <Check ok={Math.abs(Number(checks.inventory_tb) - Number(checks.inventory_items)) < 0.01} soft text={`Inventory: trial balance ${N2(checks.inventory_tb)}, stock brought in with items ${N2(checks.inventory_items)}`} />
                </div>
                {(checks.blockers || []).length > 0 && <Alert kind="red" icon="alert">{(checks.blockers as string[]).join(' ')}</Alert>}
                {(checks.warnings || []).length > 0 && (
                  <div className="stack" style={{ gap: 8 }}>
                    <Alert kind="amber" icon="info">
                      {(checks.warnings as string[]).join(' ')} Usually the ageing report was run on a different date from the trial balance, or credit notes and unapplied payments were left out. Export them again at {fmtDay(mig.as_of)}, or post now and clear the difference later.
                    </Alert>
                    <label className="check"><input type="checkbox" checked={accept} onChange={(e) => setAccept(e.target.checked)} />Post anyway: what the lists do not explain goes to the control account to clear later</label>
                  </div>
                )}
                <div className="row wrap">
                  <button className="btn btn-primary" disabled={!checks.ready || ((checks.warnings || []).length > 0 && !accept) || !!busy}
                    onClick={() => act('post', () => rpc('post_books_migration', { p_migration: mig.id, p_options: { accept_differences: accept } }), 'Opening position posted')}>
                    {busy === 'post' ? 'Posting…' : `Post the opening position at ${fmtDay(mig.as_of)}`}
                  </button>
                </div>
                <div className="faint" style={{ fontSize: 12 }}>Posts one opening journal dated {fmtDay(mig.as_of)}, opens the bank accounts, creates the open invoices and bills, and sets the books to start on {fmtDay(addDays(mig.as_of, 1))}. The cash flow statement treats these balances as opening, never as cash moving.</div>
              </Step>
            </>
          )}
          {posted && !mig && (
            <Alert kind="green" icon="check">
              Moved from {bookSystem(posted.source).name} at {fmtDay(posted.as_of)}: {posted.summary?.accounts} accounts, {posted.summary?.invoices} unpaid invoices and {posted.summary?.bills} bills in journal {posted.journal_ref || posted.summary?.journal_ref}.
              {' '}<Link to="/accounting/statements">See the statements</Link> or <Link to="/accounting/banking">match the bank</Link>.
            </Alert>
          )}
        </>
      )}
      {undo && <UndoModal m={undo} onClose={() => setUndo(null)} onDone={() => { setUndo(null); refresh(); }} />}
    </div>
  );
}

function UndoModal({ m, onClose, onDone }: { m: any; onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title="Undo the move" sub="Reverses the opening journal and cancels the opening invoices and bills. Refused once anything has been paid against them." onClose={onClose} />
      <div className="modal-body"><Field label="Why"><input className="input" autoFocus value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Wrong cut-over date" /></Field></div>
      <div className="modal-ft"><button className="btn btn-danger" disabled={busy || reason.trim().length < 3} onClick={async () => {
        setBusy(true);
        try { await rpc('reverse_books_migration', { p_migration: m.id, p_reason: reason }); toast('Undone'); onDone(); } catch (e) { toast((e as Error).message, 'err'); }
        setBusy(false);
      }}>Undo</button></div>
    </Modal>
  );
}

function lastYearEnd(fyStart: number): string {
  const now = new Date();
  const y = now.getUTCMonth() + 1 >= fyStart ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
  const start = new Date(Date.UTC(y, fyStart - 1, 1));
  return new Date(start.getTime() - 864e5).toISOString().slice(0, 10);
}
function accountOptions(accounts: any[]) {
  const parents = new Set(accounts.map((a) => a.parent_code).filter(Boolean));
  const postable = accounts.filter((a) => a.active !== false && !a.is_group && !(parents.has(a.code) && accounts.some((c) => c.parent_code === a.code && ['bank', 'cash', 'wallet'].includes(c.kind))) && !/^9/.test(a.code) || ['3999'].includes(a.code));
  const groups: Record<string, string> = { '1': 'Assets', '2': 'Liabilities', '3': 'Equity', '4': 'Income', '5': 'Cost of sales', '6': 'Expenses', '7': 'Other income and expenses', '8': 'Tax' };
  const out: { label: string; items: { code: string; name: string }[] }[] = [];
  for (const a of postable) {
    const label = groups[a.code[0]] || 'Other';
    let g = out.find((x) => x.label === label);
    if (!g) { g = { label, items: [] }; out.push(g); }
    g.items.push({ code: a.code, name: a.name });
  }
  return out;
}

function Step({ n, title, done, optional, children }: { n: number; title: string; done?: boolean; optional?: boolean; children: ReactNode }) {
  return (
    <div className="card card-pad stack" style={{ gap: 12 }}>
      <div className="row" style={{ gap: 10 }}>
        <span style={{ width: 26, height: 26, borderRadius: '50%', display: 'grid', placeItems: 'center', fontSize: 13, fontWeight: 700, flex: 'none',
          background: done ? '#15803D' : '#F0F7FF', color: done ? '#fff' : '#0072F5' }}>{done ? <Icon name="check" size={14} color="#fff" sw={3} /> : n}</span>
        <div style={{ fontSize: 16, fontWeight: 600 }}>{title}</div>
        {optional && <Chip label="Optional" t="t-grey" />}
      </div>
      {children}
    </div>
  );
}
function How({ icon, title, children }: { icon: string; title: string; children: ReactNode }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: 12 }}>
      <div className="row" style={{ gap: 8, marginBottom: 6 }}><Icon name={icon} size={16} color="#0072F5" /><b style={{ fontSize: 13.5 }}>{title}</b></div>
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5 }}>{children}</div>
    </div>
  );
}
function Fig({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'green' | 'amber' }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: '10px 12px', minWidth: 150 }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 16, fontWeight: 600, marginTop: 3 }} className="num">{value}</div>
      {sub && <div style={{ fontSize: 12, marginTop: 2, color: tone === 'green' ? '#15803D' : tone === 'amber' ? '#A16207' : '#6B7280' }}>{sub}</div>}
    </div>
  );
}
function Check({ ok, text, soft }: { ok: boolean; text: string; soft?: boolean }) {
  return (
    <div className="row" style={{ gap: 8, fontSize: 13.5 }}>
      <Icon name={ok ? 'check' : soft ? 'info' : 'x'} size={15} color={ok ? '#15803D' : soft ? '#B45309' : '#DC2626'} />
      <span>{text}</span>
    </div>
  );
}
