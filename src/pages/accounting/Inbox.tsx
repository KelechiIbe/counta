// The books inbox: what Atlas could not post on its own (below the confidence threshold, never under 80%) waits here as one
// plain question, with its best guess. What it did post is listed for a second look. Each answer can teach it a rule.
import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, useChart, useCustomers, useInbox, useBills, type AiProposal } from '../../lib/api';
import { N2, fmtDay, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Pills, SkeletonRows } from '../../components/ui';
import { vatPct } from '../../lib/vat';

const pct = (c: number) => `${Math.round(Number(c) * 100)}%`;

export default function Inbox() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const inbox = useInbox();
  const [tab, setTab] = useState<'questions' | 'review'>('questions');
  const [running, setRunning] = useState(false);
  const d = inbox.data;
  if (!inv) return null;
  async function runNow() {
    setRunning(true);
    const r = await edge<{ result: any }>('atlas', { action: 'run', org_id: orgId });
    if (r.ok === false) toast(r.error || 'The bookkeeper could not run.', 'err');
    else toast(r.result?.items ? `Atlas looked at ${r.result.items} line${r.result.items === 1 ? '' : 's'}: ${r.result.posted} posted, ${r.result.asked} asked` : 'Nothing waiting for the bookkeeper');
    await qc.invalidateQueries({ queryKey: ['inbox'] }); setRunning(false);
  }
  const counters: [number, string, string, string][] = d ? [
    [Number(d.payments_to_confirm), 'payment', 'to confirm against the bank', '/sell/sales?tab=confirm'],
    [Number(d.bills_to_approve), 'bill', 'to approve', '/purchases/bills'],
    [Number(d.assets_to_confirm), 'fixed asset', 'to confirm', '/accounting/assets'],
    [Number(d.payouts_to_approve), 'payout', 'to approve', '/payments'],
  ].filter(([n]) => Number(n) > 0) as [number, string, string, string][] : [];
  return (
    <div className="container" style={{ maxWidth: 1100 }}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'questions', label: 'Questions', count: d?.questions?.length || undefined }, { id: 'review', label: 'Posted by Atlas' }]} />
        <div className="row wrap">
          {d && <span className="muted" style={{ fontSize: 13 }}>Suspense {N2(d.suspense)}</span>}
          {can(inv, 'keep_books') && <button className="btn btn-secondary btn-sm" disabled={running} onClick={runNow}><Icon name="sparkles" size={14} />{running ? 'Working…' : 'Run the bookkeeper'}</button>}
        </div>
      </div>
      {counters.length > 0 && (
        <div className="row wrap" style={{ gap: 8 }}>
          {counters.map(([n, l, rest, to]) => <Link key={l} className="pill" to={to}>{n} {l}{n === 1 ? '' : 's'} {rest}<Icon name="chevR" size={13} /></Link>)}
        </div>
      )}
      {inbox.isLoading ? <SkeletonRows n={6} /> : inbox.error ? <Alert kind="yellow" icon="shield">{(inbox.error as Error).message}</Alert>
        : tab === 'questions' ? (
          !(d?.questions || []).length ? <Empty>Nothing to answer. Atlas posts what it is sure of (at least {pct(Math.max(Number(inv.org.auto_post_threshold || 0.8), 0.8))} confident) and asks here about the rest.</Empty>
            : <div className="stack" style={{ gap: 10 }}>{d.questions.map((p: AiProposal) => <Question key={p.id} p={p} />)}</div>
        ) : (
          !(d?.review || []).length ? <Empty>Atlas has not posted anything on its own in the last 45 days.</Empty>
            : <div className="card" style={{ overflow: 'hidden' }}>{d.review.map((p: any) => <Reviewed key={p.id} p={p} />)}</div>
        )}
    </div>
  );
}

function useAccountsFor(direction: 'in' | 'out' | null) {
  const chart = useChart();
  return useMemo(() => (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && !/^(2201|1402|2202|1401|9)/.test(a.code)
    && (direction !== 'in' || !/^[56]/.test(a.code) || true)), [chart.data, direction]);
}

function Question({ p }: { p: AiProposal }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const accounts = useAccountsFor(p.line ? (Number(p.line.amount) > 0 ? 'in' : 'out') : null);
  const customers = useCustomers();
  const bills = useBills({}, p.kind !== 'item_vat');
  const [code, setCode] = useState<string>(p.proposal?.account_code || '');
  const [party, setParty] = useState('');
  const [remember, setRemember] = useState(true);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [other, setOther] = useState(false);
  const canAnswer = can(inv, 'keep_books');
  async function act(fn: () => Promise<any>, ok: string) {
    setBusy(true);
    try { await fn(); toast(ok); await Promise.all(['inbox', 'banking', 'inv', 'report', 'overview'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  const needsParty = /^(1101|1102)/.test(code) ? 'customer' : /^(2101|2102)/.test(code) ? 'vendor' : null;
  const partyList = needsParty === 'customer' ? (customers.data?.customers || []).filter((c) => !c.is_walk_in) : needsParty === 'vendor' ? (bills.data?.vendors || []) : [];
  const answer = (action: 'approve' | 'change' | 'ignore' | 'dismiss') => act(() => rpc('resolve_proposal', { p_proposal: p.id, p: {
    action, account_code: code || null, party_type: needsParty, party_id: party || null, remember, note: note || null } }), action === 'ignore' ? 'Taken out of the books' : 'Posted');

  if (p.kind === 'item_vat') {
    const t = p.proposal?.treatment;
    const item = inv?.items.find((i) => i.id === p.source_id);
    return (
      <div className="card card-pad stack" style={{ gap: 8 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}><b>{p.question || p.title}</b><span className="chip t-blue">VAT · {pct(p.confidence)} sure</span></div>
        <div className="muted" style={{ fontSize: 13 }}>{p.rationale}{p.proposal?.law ? ` (${p.proposal.law})` : ''}. Now: {item?.vat_treatment === 'standard' ? `charged ${vatPct()}` : item?.vat_treatment}.</div>
        {can(inv, 'edit_prices') || can(inv, 'keep_books') ? (
          <div className="row wrap">
            {(['standard', 'zero', 'exempt'] as const).map((x) => (
              <button key={x} className={'btn btn-sm ' + (x === t ? 'btn-primary' : 'btn-secondary')} disabled={busy}
                onClick={() => act(() => rpc('set_item_vat', { p_item: p.source_id, p_treatment: x, p_reason: x === t ? 'Confirmed the suggestion' : 'Changed the suggestion' }), 'VAT set')}>
                {x === 'standard' ? `Charge ${vatPct()}` : x === 'zero' ? 'Zero-rated' : 'Exempt'}{x === t ? ' (suggested)' : ''}
              </button>
            ))}
          </div>
        ) : <div className="faint" style={{ fontSize: 12 }}>Someone who edits prices or keeps the books decides this.</div>}
      </div>
    );
  }
  if (p.source_type !== 'bank_line') {
    return (
      <div className="card card-pad stack" style={{ gap: 8 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}><b>{p.title}</b>{p.amount != null && <b className="num">{N2(p.amount)}</b>}</div>
        <div className="muted" style={{ fontSize: 13 }}>{p.question}</div>
        {p.kind === 'wallet_difference' && <div className="faint" style={{ fontSize: 12 }}>Wallet {N2(p.proposal?.provider)} · books {N2(p.proposal?.books)} · in transit {N2(p.proposal?.in_transit)}. Check the wallet's statement under Payments, then record what is missing.</div>}
        {canAnswer && <div className="row"><input className="input input-sm" placeholder="What you found" value={note} onChange={(e) => setNote(e.target.value)} />
          <button className="btn btn-secondary btn-sm" disabled={busy || note.trim().length < 3} onClick={() => answer('dismiss')}>Resolved</button></div>}
      </div>
    );
  }
  const l = p.line || {};
  const amt = Number(l.amount || 0);
  const match = p.proposal?.kind === 'invoice_match' || p.proposal?.kind === 'bill_match' ? p.proposal : null;
  if (match && !other) {
    // The documents this payment could settle, best first, each with why: the name or number in the narration, and the
    // amount as it stands, less WHT (a customer deducts it before paying), or less a bank charge.
    const cands: any[] = Array.isArray(match.candidates) && match.candidates.length ? match.candidates
      : [{ kind: match.kind === 'invoice_match' ? 'sale' : 'bill', id: match.sale_id || match.bill_id, number: match.number, party_name: match.customer_name || match.vendor_name, reasons: [] }];
    const isIn = match.kind === 'invoice_match';
    const how = (c: any) => c.basis === 'less_wht' ? `${N2(c.due)} owed${Number(c.wht) ? `, less ${N2(c.wht)} WHT` : ''}${Number(c.wvat) ? `${Number(c.wht) ? ' and' : ', less'} ${N2(c.wvat)} VAT withheld` : ''}`
      : c.basis === 'bank_charge' ? `${N2(c.due)} owed, ${N2(c.fee)} ${isIn ? 'less' : 'more'} for bank charges`
      : c.basis === 'less_wht_charge' ? `${N2(c.due)} owed, less ${N2(c.wht)} WHT and ${N2(c.fee)} charges`
      : c.basis === 'part' ? `Part of ${N2(c.due)} owed` : c.basis === 'over' ? `More than the ${N2(c.due)} owed; the extra is held as credit`
      : c.basis === 'several' ? `${N2(c.due)} owed on these invoices together` : `${N2(c.due)} owed`;
    return (
      <div className="card card-pad stack" style={{ gap: 10 }}>
        <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontWeight: 600 }}>{p.title}</div>
            <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{fmtDay(l.date)} · {l.account} · “{l.narration}”{l.counterparty ? ` · ${l.counterparty}` : ''}</div>
          </div>
          <b className="num" style={{ color: amt > 0 ? '#15803D' : '#111827', whiteSpace: 'nowrap' }}>{amt > 0 ? '+' : '−'}{N2(Math.abs(amt))}</b>
        </div>
        <div className="muted" style={{ fontSize: 13 }}>Counta found {cands.length === 1 ? 'a document' : `${cands.length} documents`} this {isIn ? 'payment' : 'payment out'} could settle. Nothing is recorded until you confirm.</div>
        <div className="stack" style={{ gap: 6 }}>
          {cands.map((c, i) => (
            <div key={(c.id || c.number) + i} className="row wrap" style={{ justifyContent: 'space-between', gap: 10, border: '1px solid var(--line)', borderRadius: 10, padding: '8px 10px', background: i === 0 ? '#F8FAFC' : undefined }}>
              <div style={{ minWidth: 0, flex: '1 1 260px' }}>
                <b>{c.number}</b> <span className="muted">· {c.party_name}</span>
                <div className="faint" style={{ fontSize: 12 }}>{how(c)}{(c.reasons || []).length ? ` · ${(c.reasons as string[]).filter((r) => !/owed|charge|More than|Part of/.test(r)).join(' · ')}` : ''}</div>
              </div>
              {canAnswer && <button className={'btn btn-sm ' + (i === 0 ? 'btn-primary' : 'btn-secondary')} disabled={busy}
                onClick={() => act(() => rpc('resolve_proposal', { p_proposal: p.id, p: { action: 'approve', candidate: i } }), `${c.number} settled`)}>
                Yes, it {isIn ? 'pays' : 'paid'} {c.kind === 'sales' ? 'these' : c.number}
              </button>}
            </div>
          ))}
        </div>
        {canAnswer ? (
          <div className="row wrap">
            <button className="btn btn-secondary btn-sm" disabled={busy} onClick={() => { setOther(true); setCode(''); }}>No, it was something else</button>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => answer('ignore')} title="A duplicate on the statement, or a transfer that was reversed">Not a real transaction</button>
          </div>
        ) : <div className="faint" style={{ fontSize: 12 }}>Someone who keeps the books answers these.</div>}
      </div>
    );
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10 }}>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600 }}>{p.question || p.title}</div>
          <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{fmtDay(l.date)} · {l.account} · “{l.narration}”{l.counterparty ? ` · ${l.counterparty}` : ''}</div>
        </div>
        <b className="num" style={{ color: amt > 0 ? '#15803D' : '#111827', whiteSpace: 'nowrap' }}>{amt > 0 ? '+' : '−'}{N2(Math.abs(amt))}</b>
      </div>
      {p.proposal?.account_code && <div className="muted" style={{ fontSize: 13 }}>Atlas thinks <b>{p.proposal.account_code} {p.account_name || ''}</b> ({pct(p.confidence)} sure){p.rationale ? `: ${p.rationale}` : ''}</div>}
      {!p.proposal?.account_code && p.rationale && <div className="muted" style={{ fontSize: 13 }}>{p.rationale}</div>}
      {canAnswer ? (
        <>
          <div className="row wrap" style={{ gap: 8 }}>
            <select className="input input-sm" style={{ flex: '1 1 260px' }} value={code} onChange={(e) => { setCode(e.target.value); setParty(''); }} aria-label="Account">
              <option value="">Where does it belong?</option>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}
            </select>
            {needsParty && <select className="input input-sm" style={{ flex: '1 1 200px' }} value={party} onChange={(e) => setParty(e.target.value)} aria-label={needsParty}>
              <option value="">Which {needsParty}?</option>{partyList.map((x: any) => <option key={x.id} value={x.id}>{x.name}</option>)}</select>}
          </div>
          <div className="row wrap" style={{ gap: 10 }}>
            <label className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />Do the same next time for this payee</label>
            <input className="input input-sm" style={{ flex: '1 1 200px' }} placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div className="row wrap">
            <button className="btn btn-primary btn-sm" disabled={busy || !code || (!!needsParty && !party)} onClick={() => answer(code === p.proposal?.account_code ? 'approve' : 'change')}>Post it</button>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => answer('ignore')} title="A duplicate on the statement, or a transfer that was reversed">Not a real transaction</button>
          </div>
        </>
      ) : <div className="faint" style={{ fontSize: 12 }}>Someone who keeps the books answers these.</div>}
    </div>
  );
}

function Reviewed({ p }: { p: any }) {
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const accounts = useAccountsFor(null);
  const [edit, setEdit] = useState(false);
  const [code, setCode] = useState(p.proposal?.account_code || '');
  async function change() {
    try { await rpc('resolve_proposal', { p_proposal: p.id, p: { action: 'change', account_code: code, remember: true } }); toast('Moved'); setEdit(false); await qc.invalidateQueries({ queryKey: ['inbox'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  async function confirm() {
    try { await rpc('resolve_proposal', { p_proposal: p.id, p: { action: 'approve' } }); toast('Confirmed'); await qc.invalidateQueries({ queryKey: ['inbox'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <div className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1.4fr) 120px 110px auto', gap: 12 }} data-testid="atlas-posted">
      <span className="m-main" style={{ minWidth: 0 }}><b>{p.title}</b><span className="faint" style={{ display: 'block', fontSize: 12 }}>{[[p.proposal?.account_code, p.account_name].filter(Boolean).join(' '), p.journal_ref, when(p.created_at), p.rationale].filter(Boolean).join(' · ')}</span>
        {edit && <span className="row" style={{ marginTop: 6 }}><select className="input input-sm" value={code} onChange={(e) => setCode(e.target.value)}>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select>
          <button className="btn btn-primary btn-xs" onClick={change}>Move</button></span>}</span>
      <span className="chip t-green" style={{ justifySelf: 'start' }}>{pct(p.confidence)} sure</span>
      <b className="num right m-end">{N2(p.amount)}</b>
      {can(inv, 'keep_books') && p.status === 'auto_posted' ? <span className="row m-line" style={{ gap: 4 }}><button className="btn btn-ghost btn-xs" onClick={confirm}>Right</button><button className="btn btn-ghost btn-xs" onClick={() => setEdit(!edit)}>Wrong account</button></span> : <span />}
    </div>
  );
}
