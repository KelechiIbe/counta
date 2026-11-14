// The Filing page of a filing-only business: for each year, its bank accounts and statements, the count of transactions
// and the one-time fee, paying it (by the business's card, or the accounting firm's), and after payment where the books
// and the return stand. Nothing is read by AI and nothing is shown before the year is paid for.
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { cleanError, rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import {
  bandWords, filingPay, filingVerify, LINES_PER_PAGE, RETURN_NAME, useFiling, yearStage, type FilingState, type FilingYear, type FilingScan,
} from '../../lib/filing';
import { Icon } from '../../components/Icon';
import { Alert, Pills, SkeletonRows, Spinner } from '../../components/ui';
import StatementUpload from '../accounting/BankStatement';
import { AddAccount } from '../accounting/Banking';
import { OpeningStep } from './Opening';

const n0 = (n: number | null | undefined) => Number(n || 0).toLocaleString('en-NG');

export default function Filing() {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useFiling(orgId);
  const s = q.data;
  const [params, setParams] = useSearchParams();
  const [checking, setChecking] = useState(false);
  const [year, setYear] = useState<number | null>(null);
  const refresh = () => Promise.all(['filing', 'org-features', 'inv'].map((k) => qc.invalidateQueries({ queryKey: [k] })));

  // Back from Flutterwave's page: Counta asks Flutterwave about the payment before saying anything.
  const ref = params.get('ref');
  useEffect(() => {
    if (!ref || !orgId) return;
    setChecking(true);
    (async () => {
      for (let i = 0; i < 6; i++) {
        const r = await filingVerify(orgId, ref);
        if (r.ok === false) { toast(r.error || 'Counta could not check the payment.', 'err'); break; }
        const st = r.result?.status;
        if (st === 'successful') { toast('Paid. Counta is reading the statements and building the books.'); break; }
        if (st === 'failed' || st === 'cancelled') { toast('The card payment did not go through. Nothing was charged.', 'err'); break; }
        await new Promise((res) => setTimeout(res, 3000));
      }
      setChecking(false); params.delete('ref'); setParams(params, { replace: true }); await refresh();
    })();
  }, [ref, orgId]); // eslint-disable-line react-hooks/exhaustive-deps

  // The year shown first: the oldest one under way (paid but not filed, or started), else the latest that can be filed.
  const shown = useMemo(() => {
    if (!s?.years.length) return null;
    const found = s.years.find((y) => y.year === year);
    if (found) return found;
    const busy = [...s.years].reverse().find((y) => y.order && yearStage(y).label !== 'Filed');
    return busy || s.years[0];
  }, [s, year]);

  if (q.isLoading) return <div className="container" style={{ maxWidth: 1000 }}><SkeletonRows n={6} /></div>;
  if (q.isError || !s) return <div className="container" style={{ maxWidth: 1000 }}><Alert kind="yellow" icon="alert">{cleanError(q.error) || 'The Filing page could not be loaded.'}</Alert></div>;
  if (!s.filing_only) return (
    <div className="container" style={{ maxWidth: 760 }}>
      <Alert kind="grey" icon="info">{inv?.org.name || 'This business'} is on a Counta plan, so its income tax return is under Tax returns with everything else.{' '}
        <Link to={s.kind === 'pit' ? '/tax/pit' : '/tax/cit'}>Open the income tax return</Link></Alert>
    </div>
  );
  const name = inv?.org.name || 'The business';
  return (
    <div className="container stack" style={{ maxWidth: 1000, gap: 16 }} data-testid="filing-page">
      {checking && <Alert kind="blue" icon="clock"><span className="row" style={{ gap: 8 }}><Spinner small />Checking the payment with Flutterwave…</span></Alert>}
      <div className="card card-pad stack" style={{ gap: 8 }}>
        <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
          <b style={{ fontSize: 18 }}>Annual filing</b>
          {s.hold && <span className="chip t-grey">Nothing read yet</span>}
        </div>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.55, maxWidth: 760 }}>
          {s.kind ? `Counta prepares ${name}'s ${RETURN_NAME[s.kind].toLowerCase()} from its bank statements.` : `${name} is exempt from income tax, so it has no return to file.`}{' '}
          Each year has its own one-time fee, worked out from the number of transactions on that year's statements. You pay before anything is read by AI,
          and the books and the return appear once the year is paid for.
        </div>
      </div>
      {s.is_sample && <Alert kind="grey" icon="info">This is the sample business. Set up your own business to file its return.</Alert>}
      {!s.years.length ? (
        <Alert kind="grey" icon="info">{s.kind ? 'No year has ended yet that Counta can file. Come back after the business\'s first accounting year ends.' : 'There is nothing to file.'}</Alert>
      ) : (
        <>
          {s.years.length > 1 && (
            <Pills value={String(shown!.year)} onChange={(v) => setYear(Number(v))}
              options={s.years.map((y) => ({ id: String(y.year), label: `${y.year} accounts`, count: y.order?.status === 'paid' && Number(y.order.extra_due) > 0 ? 1 : undefined }))} />
          )}
          <Year key={shown!.year} s={s} y={shown!} onChanged={refresh} />
        </>
      )}
      <div className="card card-pad row wrap" style={{ gap: 12, justifyContent: 'space-between' }}>
        <div style={{ minWidth: 0, flex: '1 1 320px' }}>
          <b>Need more than the yearly return?</b>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.5 }}>Monthly VAT and WHT returns, invoicing, bills and inventory come with a Counta plan. Choosing one ends filing-only; years already paid for stay paid.</div>
        </div>
        <Link className="btn btn-secondary btn-sm" to="/settings/subscription">See the plans</Link>
      </div>
    </div>
  );
}

function Year({ s, y, onChanged }: { s: FilingState; y: FilingYear; onChanged: () => Promise<unknown> }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [upload, setUpload] = useState<{ account: FilingState['accounts'][number]; scan?: FilingScan } | null>(null);
  const [adding, setAdding] = useState(false);
  const paid = y.order?.status === 'paid';
  const kind = y.kind;
  const stage = yearStage(y);
  const held = y.scans.filter((x) => x.status === 'held');
  const extra = paid ? Number(y.order!.extra_due) : 0;
  const due = paid ? extra : Number(y.price || 0);
  // Steps are numbered as shown: the start of the year appears only when something has to be said about it.
  const showOpening = !!y.opening && y.opening.source !== 'began' && y.opening.source !== 'moved';
  const dayBefore = (d: string) => { const x = new Date(d + 'T12:00:00Z'); x.setUTCDate(x.getUTCDate() - 1); return x.toISOString().slice(0, 10); };

  // The year's order is opened the first time someone works on it.
  async function ensureOpen() {
    if (y.order) return;
    await rpc('filing_open', { p_org: orgId, p_year: y.year });
  }
  async function openUpload(account: FilingState['accounts'][number], scan?: FilingScan) {
    try { if (!scan) await ensureOpen(); setUpload({ account, scan }); }
    catch (e) { toast(cleanError(e), 'err'); }
  }
  async function removeScan(id: string) {
    setBusy('remove-' + id);
    try { await rpc('filing_scan_remove', { p_org: orgId, p_scan: id }); await onChanged(); toast('The scan no longer counts'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function pay(payer: 'business' | 'practice') {
    setBusy('pay-' + payer);
    try {
      await ensureOpen();
      const r = await filingPay(orgId!, y.year, payer);
      if (r.ok === false) { toast(r.error || 'The payment did not start.', 'err'); setBusy(null); return; }
      if (r.action === 'checkout' && r.link) { window.location.href = r.link; return; }
      const st = r.result?.status;
      if (st === 'successful') toast(extra > 0 ? 'Paid. The balance is settled.' : 'Paid. Counta is reading the statements and building the books.');
      else if (st === 'failed') toast(r.result?.error || 'The card payment did not go through.', 'err');
      else toast('The payment is being confirmed. This page updates once Flutterwave confirms it.');
      await onChanged();
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function check(txRef: string) {
    setBusy('check');
    const r = await filingVerify(orgId!, txRef);
    const st = r.result?.status;
    toast(r.ok === false ? (r.error || 'Counta could not check the payment.') : st === 'successful' ? 'Paid.' : st === 'failed' || st === 'cancelled'
      ? 'That payment did not go through. Start it again.' : 'Flutterwave has not confirmed it yet.', r.ok === false || st === 'failed' ? 'err' : undefined);
    await onChanged(); setBusy(null);
  }

  const card = (k: FilingState['card']) => (k?.last4 ? ` with card •••• ${k.last4}` : ' by card');
  const payButtons = (
    <div className="row wrap" style={{ gap: 8 }}>
      {s.can_pay && (
        <button className="btn btn-primary" data-testid="filing-pay" disabled={busy !== null || due <= 0} onClick={() => pay('business')}>
          {busy === 'pay-business' ? <Spinner small /> : <Icon name="card" size={15} color="#fff" />}Pay {N2(due)}{card(s.card)}
        </button>
      )}
      {s.practice && (
        <button className={'btn ' + (s.can_pay ? 'btn-secondary' : 'btn-primary')} data-testid="filing-pay-firm" disabled={busy !== null || due <= 0} onClick={() => pay('practice')}>
          {busy === 'pay-practice' ? <Spinner small /> : <Icon name="building" size={15} color={s.can_pay ? undefined : '#fff'} />}Pay {N2(due)} with {s.practice.name}'s card{s.practice.card?.last4 ? ` •••• ${s.practice.card.last4}` : ''}
        </button>
      )}
      {!s.can_pay && !s.practice && (
        <span className="muted" style={{ fontSize: 13 }}>{s.managed ? 'The accounting firm that runs the business pays for each year.' : 'The owner or an admin of the business pays for each year.'}</span>
      )}
    </div>
  );

  return (
    <div className="card" style={{ overflow: 'hidden' }} data-testid={`filing-year-${y.year}`}>
      <div className="card-pad row wrap" style={{ gap: 10, justifyContent: 'space-between', borderBottom: '1px solid var(--row)' }}>
        <div style={{ minWidth: 0 }}>
          <div className="row wrap" style={{ gap: 8 }}><b style={{ fontSize: 17 }}>{y.year} accounts</b><span className={'chip ' + stage.tone}>{stage.label}</span></div>
          <div className="muted" style={{ fontSize: 13, marginTop: 3 }}>{kind ? RETURN_NAME[kind] : 'No return'} · {fmtDay(y.from)} to {fmtDay(y.to)} · due {fmtDay(y.due)}</div>
        </div>
        {paid && kind && <Link className="btn btn-secondary btn-sm" to={kind === 'pit' ? '/tax/pit' : '/tax/cit'}>Open the return</Link>}
      </div>

      {y.late && kind && stage.label !== 'Filed' && (
        <div className="card-pad" style={{ borderBottom: '1px solid var(--row)' }}>
          <Alert kind="amber" icon="clock">The {RETURN_NAME[kind].toLowerCase()} for {y.year} was due on {fmtDay(y.due)}. Filed now it is late, and the tax office may
            charge a penalty for late filing and interest on tax paid late. Counta's figures cover the tax only.</Alert>
        </div>
      )}

      {paid && (
        <div className="card-pad stack" style={{ gap: 10, borderBottom: '1px solid var(--row)' }}>
          <Alert kind="green" icon="check">Paid {N2(y.order!.amount)} {when(y.order!.paid_at)}{y.order!.payer === 'practice' && y.order!.practice ? ` by ${y.order!.practice}` : ''}
            {Number(y.order!.extra_paid) > 0 ? `, and a balance of ${N2(y.order!.extra_paid)}` : ''}.</Alert>
          {extra > 0 && (
            <Alert kind="amber" icon="alert">The scanned statements came to {n0(y.order!.true_count)} transactions, more than the {n0(y.order!.counted)} counted at payment,
              which puts {y.year} in a dearer band. Pay the difference of {N2(extra)} before the return is approved.</Alert>
          )}
          {extra > 0 && payButtons}
          <div className="muted" style={{ fontSize: 13, lineHeight: 1.55 }}>
            Atlas reads the year's statement lines and builds the books. Lines it cannot explain come to the books inbox as questions; the financial statements and the
            return follow. Statements added from now on are read at no extra charge.
          </div>
          <div className="row wrap" style={{ gap: 8 }}>
            <Link className="btn btn-secondary btn-sm" to="/accounting/inbox">Books inbox</Link>
            <Link className="btn btn-secondary btn-sm" to="/accounting/banking">Banking</Link>
            <Link className="btn btn-secondary btn-sm" to="/accounting/statements">Financial statements</Link>
          </div>
        </div>
      )}

      <Step n={1} title="Bank accounts" done={s.accounts.length > 0}
        right={s.can_upload && <button className="btn btn-ghost btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} />Add an account</button>}>
        {!s.accounts.length ? <div className="muted" style={{ fontSize: 13 }}>Add each bank account the business used in {y.year}, with its balance at the close of {fmtDay(dayBefore(y.from))}.</div>
          : s.accounts.map((a) => (
            <div key={a.id} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 14 }}>
              <span>{a.name}<span className="faint">{a.bank_name ? ` · ${a.bank_name}` : ''}{a.last4 ? ` •••• ${a.last4}` : ''}</span></span>
              {s.can_upload && <button className="btn btn-secondary btn-sm" data-testid="filing-upload" onClick={() => openUpload(a)}><Icon name="upload" size={14} />Upload a statement</button>}
            </div>
          ))}
      </Step>

      <Step n={2} title={`Statements for ${fmtDay(y.from)} to ${fmtDay(y.to)}`} done={y.lines > 0 || y.statements.length + y.scans.length > 0}>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>The whole year, for every account: Excel, CSV or PDF from internet banking. Statements Counta can read by
          their columns are counted at once. A scanned PDF needs the AI reader, so {paid ? 'it is read now' : `it waits until ${y.year} is paid for and counts ${LINES_PER_PAGE} lines a page meanwhile`}.</div>
        {y.statements.map((x, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 13 }}>
            <span><Icon name="file" size={14} color="#6B7280" /> {x.file_name || 'Statement'} <span className="faint">· {x.account}{x.from ? ` · ${fmtDay(x.from)} to ${fmtDay(x.to)}` : ''}</span></span>
            <span className="faint">{x.lines != null ? `${n0(x.lines)} line${x.lines === 1 ? '' : 's'} added` : ''}</span>
          </div>
        ))}
        {y.scans.map((x) => {
          const acct = s.accounts.find((a) => a.id === x.bank_account_id);
          return (
            <div key={x.id} className="row wrap" style={{ gap: 8, justifyContent: 'space-between', fontSize: 13 }} data-testid="filing-scan">
              <span><Icon name="image" size={14} color="#6B7280" /> {x.file_name || 'Scanned statement'} <span className="faint">· {x.account || 'account'} · {x.pages} page{x.pages === 1 ? '' : 's'}</span></span>
              {x.status === 'read' ? <span className="faint">Read: {n0(x.lines_found)} lines</span>
                : paid ? (s.can_upload && acct && <button className="btn btn-primary btn-sm" onClick={() => openUpload(acct, x)}><Icon name="sparkles" size={14} color="#fff" />Read it now</button>)
                : <span className="row" style={{ gap: 6 }}><span className="faint">About {n0(x.pages * LINES_PER_PAGE)} lines, read after payment</span>
                  {s.can_upload && <button className="btn btn-ghost btn-xs" disabled={busy !== null} onClick={() => removeScan(x.id)} aria-label={`Take ${x.file_name || 'the scan'} off`}>Take off</button>}</span>}
            </div>
          );
        })}
        {paid && held.length > 0 && <Alert kind="blue" icon="info">Read the scanned statement{held.length === 1 ? '' : 's'} so their lines reach the books. The real number of lines settles the fee.</Alert>}
      </Step>

      {showOpening && (
        <Step n={3} title={`Where ${y.year} starts`} done={!!y.opening?.done}>
          <OpeningStep s={s} y={y} onChanged={onChanged} />
        </Step>
      )}

      <Step n={showOpening ? 4 : 3} title="Other documents" done={false} optional>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Receipts for equipment or vehicles bought, loan letters, last year's accounts and tax receipts help Counta get the return right.
          Add them under <Link to="/documents">Documents</Link>.</div>
      </Step>

      {!paid && (
        <Step n={showOpening ? 5 : 4} title="The fee" done={false}>
          {!kind ? <div className="muted" style={{ fontSize: 13 }}>The business is exempt from income tax for {y.year}, so there is nothing to pay or file.</div> : (
            <>
              <div className="filing-count" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))', gap: 10 }}>
                <Fact label="Statement lines in the year" value={n0(y.lines)} />
                <Fact label="Scanned pages" value={y.scan_pages ? `${n0(y.scan_pages)} × ${LINES_PER_PAGE} = ${n0(y.estimate)}` : 'None'} />
                <Fact label="Transactions counted" value={n0(y.counted)} strong />
                <Fact label="Fee for the year" value={y.price != null ? N2(y.price) : 'Not set yet'} strong />
              </div>
              {y.price != null && <div className="muted" style={{ fontSize: 13 }}>{y.counted > 0 ? `The band for ${bandWords(s.prices, kind, y.band_up_to)}. ` : ''}One fee for {y.year}; statements added after payment cost nothing more.
                {y.scan_pages > 0 ? ' If the scans hold more lines than estimated and the year moves to a dearer band, the difference is paid before the return is approved.' : ''}</div>}
              <PriceBands s={s} kind={kind} />
              {y.price == null ? <Alert kind="grey" icon="info">TaxStreem has not set the prices for this return yet.</Alert>
                : y.counted === 0 ? <Alert kind="grey" icon="info">Upload the year's statements first: the fee depends on how many transactions they hold.</Alert>
                : payButtons}
              {y.pending && (
                <div className="row wrap" style={{ gap: 8, fontSize: 13 }}>
                  <span className="muted">A payment of {N2(y.pending.amount)} was started {when(y.pending.at)}{y.pending.payer === 'practice' ? ' with the firm\'s card' : ''}. If you finished it, Counta is waiting for Flutterwave.</span>
                  <button className="btn btn-ghost btn-xs" disabled={busy !== null} onClick={() => check(y.pending!.tx_ref)}>{busy === 'check' ? <Spinner small /> : null}Check it</button>
                </div>
              )}
            </>
          )}
        </Step>
      )}

      {upload && <StatementUpload account={{ id: upload.account.id, name: upload.account.name, account_number: upload.account.last4 }}
        hold={paid ? undefined : { year: y.year }} scan={upload.scan} onClose={() => { setUpload(null); void onChanged(); }} />}
      {adding && <AddAccount defaultDate={dayBefore(y.from)} onClose={() => setAdding(false)} />}
    </div>
  );
}

function Step({ n, title, done, optional, right, children }: { n: number; title: string; done: boolean; optional?: boolean; right?: ReactNode; children: ReactNode }) {
  return (
    <section className="card-pad stack" style={{ gap: 8, borderBottom: '1px solid var(--row)' }} aria-label={title}>
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
        <div className="row" style={{ gap: 8 }}>
          <span className={'filing-step' + (done ? ' done' : '')} aria-hidden="true">{done ? <Icon name="check" size={13} color="#fff" /> : n}</span>
          <b>{title}</b>{optional && <span className="faint" style={{ fontSize: 12 }}>optional</span>}
        </div>
        {right}
      </div>
      {children}
    </section>
  );
}

function Fact({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div style={{ background: 'var(--canvas)', borderRadius: 10, padding: '10px 12px' }}>
      <div className="faint" style={{ fontSize: 12 }}>{label}</div>
      <div className="num" style={{ fontSize: strong ? 18 : 15, fontWeight: strong ? 700 : 600, marginTop: 2 }}>{value}</div>
    </div>
  );
}

function PriceBands({ s, kind }: { s: FilingState; kind: 'cit' | 'pit' }) {
  const bands = s.prices.filter((p) => p.kind === kind);
  if (!bands.length) return null;
  return (
    <details style={{ fontSize: 13 }}>
      <summary className="muted" style={{ cursor: 'pointer' }}>How the fee is worked out</summary>
      <div className="stack" style={{ gap: 3, marginTop: 6, maxWidth: 420 }}>
        {bands.map((b, i) => (
          <div key={i} className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{bandWords(s.prices, kind, b.up_to).replace(/^./, (c) => c.toUpperCase())}</span><span className="num">{N2(b.price)}</span></div>
        ))}
      </div>
    </details>
  );
}
