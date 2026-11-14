// The year's audit, on the Filing page and the CIT tab. A company above the small company limits is told its accounts need
// an audit and chooses a TaxStreem partner firm (or names its own auditor); then it follows the request, pays the fee less
// withholding tax at Flutterwave's checkout, and sees the bill in its books. Nothing shows for a business name.
import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { cleanError, rpc } from '../../lib/supabase';
import { N2, fmtDay, when } from '../../lib/format';
import { auditPay, auditVerify, useAuditFirms, useAuditState, type AuditEngagement, type AuditFirm, type AuditState } from '../../lib/audits';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';

export function AuditPanel({ year }: { year: number }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useAuditState(orgId, year);
  const [params, setParams] = useSearchParams();
  const [checking, setChecking] = useState(false);
  const refresh = () => Promise.all(['audit', 'audit-firms'].map((k) => qc.invalidateQueries({ queryKey: [k] })));

  // Back from Flutterwave's page: Counta asks Flutterwave about the payment before saying anything.
  const ref = params.get('audit_ref');
  useEffect(() => {
    if (!ref || !orgId) return;
    setChecking(true);
    (async () => {
      for (let i = 0; i < 6; i++) {
        const r = await auditVerify(ref);
        if (r.ok === false) { toast(r.error || 'Counta could not check the payment.', 'err'); break; }
        if (r.status === 'successful') { toast('Paid. The bill for the audit is in your books.'); break; }
        if (r.status === 'failed' || r.status === 'cancelled') { toast('The payment did not go through. Nothing was charged.', 'err'); break; }
        await new Promise((res) => setTimeout(res, 3000));
      }
      setChecking(false); params.delete('audit_ref'); setParams(params, { replace: true }); await refresh();
    })();
  }, [ref, orgId]); // eslint-disable-line react-hooks/exhaustive-deps

  const s = q.data;
  if (!s || !s.need.company) return checking ? <Alert kind="blue" icon="clock"><span className="row" style={{ gap: 8 }}><Spinner small />Checking the payment with Flutterwave…</span></Alert> : null;
  return (
    <div className="card card-pad stack" style={{ gap: 12 }} data-testid="audit-panel">
      {checking && <Alert kind="blue" icon="clock"><span className="row" style={{ gap: 8 }}><Spinner small />Checking the payment with Flutterwave…</span></Alert>}
      <Body s={s} onChanged={refresh} />
    </div>
  );
}

const LIVE = ['requested', 'accepted', 'paid', 'recorded'];

function Body({ s, onChanged }: { s: AuditState; onChanged: () => Promise<unknown> }) {
  const n = s.need;
  const e = s.engagement && LIVE.includes(s.engagement.status) ? s.engagement : null;
  const ended = s.engagement && !LIVE.includes(s.engagement.status) ? s.engagement : null;
  const [choosing, setChoosing] = useState(false);
  const [own, setOwn] = useState(false);
  const why = n.over_turnover
    ? `Turnover of ${N2(n.turnover)} ${n.ended ? 'was' : 'is so far'} above the small company limit of ${N2(n.turnover_max)}`
    : `Fixed assets of ${N2(n.fixed_assets)} ${n.ended ? 'were' : 'are'} above the small company limit of ${N2(n.fixed_assets_max)}`;

  if (e) return <Engagement s={s} e={e} onChanged={onChanged} />;
  return (
    <>
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div style={{ minWidth: 0, flex: '1 1 320px' }}>
          <div className="row wrap" style={{ gap: 8 }}>
            <Icon name="shield" size={18} color={n.required ? '#B45309' : '#6B7280'} />
            <b style={{ fontSize: 16 }}>{n.required ? `The ${s.year} accounts need an audit` : `Audit for ${s.year}`}</b>
          </div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.55 }}>
            {n.required
              ? <>{why}. A company above the limits has its financial statements audited by a chartered accountant before they are filed.</>
              : <>Turnover of {N2(n.turnover)} and fixed assets of {N2(n.fixed_assets)} {n.ended ? 'were' : 'are so far'} within the small company limits
                ({N2(n.turnover_max)} and {N2(n.fixed_assets_max)}), so the accounts can be filed unaudited.</>}
          </div>
        </div>
      </div>
      {n.required && s.audit_exempt && (
        <Alert kind="amber" icon="info">Your company details say it is exempt from audit as a small company. That no longer holds for {s.year}; change it under Financial statements, Company details.</Alert>
      )}
      {ended && <EndedNote e={ended} />}
      {n.required && !s.enabled && <Alert kind="grey" icon="info">Choosing an auditor in Counta opens soon. Until then, engage your own auditor.</Alert>}
      {s.can_act ? (
        <div className="row wrap" style={{ gap: 8 }}>
          {s.enabled && (n.required
            ? <button className="btn btn-primary" data-testid="audit-choose" onClick={() => setChoosing(true)}><Icon name="search" size={15} color="#fff" />Choose an auditor</button>
            : <button className="btn btn-ghost btn-sm" data-testid="audit-choose" onClick={() => setChoosing(true)}>Have it audited anyway</button>)}
          {n.required && <button className="btn btn-secondary" data-testid="audit-own" onClick={() => setOwn(true)}>We have an auditor</button>}
        </div>
      ) : n.required && <div className="faint" style={{ fontSize: 13 }}>The owner or an admin of the business chooses the auditor.</div>}
      {choosing && <Choose s={s} onClose={() => setChoosing(false)} onChanged={onChanged} />}
      {own && <OwnAuditor s={s} onClose={() => setOwn(false)} onChanged={onChanged} />}
    </>
  );
}

function EndedNote({ e }: { e: AuditEngagement }) {
  const firm = e.firm?.name || e.own_name || 'The firm';
  const text = e.status === 'declined' ? `${firm} could not take on the audit${e.answer_note ? `: “${e.answer_note}”` : '.'}`
    : e.status === 'lapsed' ? `${firm} did not answer in time, so the request lapsed.`
    : `You withdrew the request to ${firm}.`;
  return <Alert kind="grey" icon="info">{text} Choose another firm below.</Alert>;
}

// Requested, accepted (to pay), paid, or an auditor of the business's own.
function Engagement({ s, e, onChanged }: { s: AuditState; e: AuditEngagement; onChanged: () => Promise<unknown> }) {
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const firm = e.firm?.name || e.own_name || 'The firm';
  async function cancel() {
    if (!window.confirm(e.status === 'recorded' ? `Remove ${firm} as the auditor for ${s.year}?` : `Withdraw the request to ${firm}?`)) return;
    setBusy('cancel');
    try { await rpc('audit_cancel', { p_engagement: e.id }); await onChanged(); toast(e.status === 'recorded' ? 'Removed' : 'Withdrawn'); }
    catch (err) { toast(cleanError(err), 'err'); }
    setBusy(null);
  }
  async function pay() {
    setBusy('pay');
    const r = await auditPay(e.id);
    if (r.ok === false || !r.link) { toast(r.error || 'The payment did not start.', 'err'); setBusy(null); await onChanged(); return; }
    window.location.href = r.link;
  }
  async function check(txRef: string) {
    setBusy('check');
    const r = await auditVerify(txRef);
    toast(r.ok === false ? (r.error || 'Counta could not check the payment.') : r.status === 'successful' ? 'Paid.'
      : r.status === 'failed' || r.status === 'cancelled' ? 'That payment did not go through. Start it again.' : 'Flutterwave has not confirmed it yet.',
      r.ok === false || r.status === 'failed' ? 'err' : undefined);
    await onChanged(); setBusy(null);
  }
  const vat = Number(e.vat || 0);
  const tone = e.status === 'paid' ? 't-green' : e.status === 'accepted' ? 't-blue' : 't-amber';
  const label = { requested: 'Waiting for the firm', accepted: 'Accepted · to pay', paid: 'Paid', recorded: 'Your own auditor' }[e.status as 'requested'] || e.status;
  return (
    <>
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div style={{ minWidth: 0, flex: '1 1 320px' }}>
          <div className="row wrap" style={{ gap: 8 }}>
            <Icon name="shield" size={18} color="#0072F5" /><b style={{ fontSize: 16 }}>Audit of the {s.year} accounts</b><span className={'chip ' + tone}>{label}</span>
          </div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4 }}>{firm}{e.firm?.state ? ` · ${e.firm.state}` : ''}{e.own_email ? ` · ${e.own_email}` : ''}</div>
        </div>
        {s.can_act && e.status !== 'paid' && (
          <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={cancel}>{busy === 'cancel' ? <Spinner small /> : <Icon name="undo" size={14} />}{e.status === 'recorded' ? 'Remove' : 'Withdraw'}</button>
        )}
      </div>
      {e.kind === 'partner' && e.firm?.signers?.length ? (
        <div className="faint" style={{ fontSize: 12 }}>Signing partner{e.firm.signers.length > 1 ? 's' : ''}: {e.firm.signers.map((x) => `${x.name} (${x.body}, ${x.frc_no})`).join('; ')}</div>
      ) : null}
      {e.keeps_books && e.status !== 'paid' && <IndependenceNote firm={firm} />}
      {e.status === 'recorded' && <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>When {firm} signs the audited financial statements, add them under <Link to="/documents">Documents</Link>.</div>}
      {e.status === 'requested' && (
        <Alert kind="blue" icon="clock">Asked on {fmtDay(e.requested_at.slice(0, 10))}. {firm} answers in the accountant portal{e.lapses_at ? ` by ${fmtDay(e.lapses_at.slice(0, 10))}` : ''};
          if it does not, the request lapses and you can choose another firm.</Alert>
      )}
      {(e.status === 'requested' || e.status === 'accepted') && e.price != null && (
        <div className="audit-sum" data-testid="audit-sum">
          <Row label={`Fee for ${e.band?.label.toLowerCase() || 'your size'} turnover`} value={N2(e.price)} />
          {vat > 0 && <Row label="VAT" value={N2(vat)} />}
          <Row label="Less the withholding tax you deduct" value={e.amount != null ? `−${N2(Number(e.wht) + Number(e.wvat))}` : 'worked out when you pay'} />
          {e.amount != null && <Row label="You pay at checkout" value={N2(e.amount)} strong />}
        </div>
      )}
      {e.status === 'accepted' && (
        <>
          {e.answer_note && <div className="muted" style={{ fontSize: 13 }}>{firm}: “{e.answer_note}”</div>}
          {s.can_act ? (
            <div className="row wrap" style={{ gap: 8 }}>
              <button className="btn btn-primary" data-testid="audit-pay" disabled={busy !== null} onClick={pay}>
                {busy === 'pay' ? <Spinner small /> : <Icon name="card" size={15} color="#fff" />}Pay {firm}</button>
              <span className="faint" style={{ fontSize: 12, maxWidth: 420 }}>Card, transfer or USSD at Flutterwave. Counta enters the bill from {firm} in your books, with the withholding tax you owe on it.</span>
            </div>
          ) : <div className="faint" style={{ fontSize: 13 }}>The owner or an admin of the business pays for the audit.</div>}
          {e.charge?.status === 'pending' && (
            <div className="row wrap" style={{ gap: 8, fontSize: 13 }}>
              <span className="muted">A payment of {N2(e.charge.amount)} was started {when(e.charge.at)}. If you finished it, Counta is waiting for Flutterwave.</span>
              <button className="btn btn-ghost btn-xs" disabled={busy !== null} onClick={() => check(e.charge!.tx_ref)}>{busy === 'check' ? <Spinner small /> : null}Check it</button>
            </div>
          )}
        </>
      )}
      {e.status === 'paid' && (
        <>
          <Alert kind="green" icon="check">Paid {N2(e.charge?.paid_amount ?? e.amount)} {when(e.paid_at)}. {firm} audits the {s.year} accounts and signs them with your directors.</Alert>
          {e.bill && !e.bill_error && <div className="muted" style={{ fontSize: 13 }}>Bill {e.bill.number} is in your books under <Link to="/purchases/bills">Bills</Link>, with {N2(Number(e.wht) + Number(e.wvat))} of withholding tax to remit.</div>}
          {e.bill_error && <Alert kind="amber" icon="alert">The bill for the audit is still a draft: {e.bill_error} Approve it under <Link to="/purchases/bills">Bills</Link>.</Alert>}
        </>
      )}
    </>
  );
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="row" style={{ justifyContent: 'space-between', gap: 12, fontSize: strong ? 15 : 14, fontWeight: strong ? 700 : 400 }}>
      <span className={strong ? undefined : 'muted'}>{label}</span><span className="num">{value}</span>
    </div>
  );
}

function IndependenceNote({ firm }: { firm: string }) {
  return (
    <Alert kind="amber" icon="alert">{firm} keeps your books. Professional ethics rules treat auditing books a firm keeps as a self-review threat, so it must
      have safeguards in place, and some companies may not use their bookkeeper as auditor at all.</Alert>
  );
}

// The partner firms that audit companies of this size, with their price; asking one.
function Choose({ s, onClose, onChanged }: { s: AuditState; onClose: () => void; onChanged: () => Promise<unknown> }) {
  const { orgId } = useSession();
  const toast = useToast();
  const q = useAuditFirms(orgId, s.year, true);
  const [pick, setPick] = useState<AuditFirm | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  async function ask() {
    if (!pick) return;
    setBusy(true);
    try {
      await rpc('audit_request', { p_org: orgId, p_year: s.year, p_practice: pick.id, p: { note } });
      await onChanged(); toast(`Asked ${pick.name}`); onClose();
    } catch (e) { toast(cleanError(e), 'err'); setBusy(false); }
  }
  return (
    <Modal onClose={onClose} width={640}>
      <ModalHead title={pick ? `Ask ${pick.name}` : 'Choose an auditor'} onClose={onClose}
        sub={pick ? undefined : <>TaxStreem partner firms with an ICAN or ANAN partner registered with the FRC. Prices are for {q.data?.band.label.toLowerCase() || 'your size of'} turnover{s.need.turnover != null ? ` (${N2(s.need.turnover)} in ${s.year})` : ''}.</>} />
      <div className="modal-body stack" style={{ gap: 10 }}>
        {pick ? (
          <>
            <FirmRow f={pick} />
            {pick.keeps_books && <IndependenceNote firm={pick.name} />}
            <Field label="A note for the firm (optional)" hint="Your year end, where the records are, anything they should know.">
              <textarea className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} style={{ minHeight: 70 }} />
            </Field>
            <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>{pick.name} answers in its portal. Once it accepts, you pay {N2(pick.price)}{pick.vat > 0 ? ` and ${N2(pick.vat)} VAT` : ''},
              less the withholding tax you deduct, at Flutterwave's checkout.</div>
          </>
        ) : q.isLoading ? <div className="row" style={{ justifyContent: 'center', padding: 24 }}><Spinner /></div>
          : q.isError ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>
          : !q.data?.firms.length ? <Alert kind="grey" icon="info">No partner firm audits companies of this size through Counta yet. Name your own auditor instead.</Alert>
          : q.data.firms.map((f) => (
            <button key={f.id} type="button" className="audit-firm" data-testid="audit-firm" onClick={() => setPick(f)}>
              <FirmRow f={f} />
            </button>
          ))}
      </div>
      <div className="modal-ft">
        {pick ? (
          <>
            <button className="btn btn-secondary" onClick={() => setPick(null)}>Back</button>
            <button className="btn btn-primary" data-testid="audit-ask" disabled={busy} onClick={ask}>{busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Ask {pick.name}</button>
          </>
        ) : <button className="btn btn-secondary" onClick={onClose}>Close</button>}
      </div>
    </Modal>
  );
}

function FirmRow({ f }: { f: AuditFirm }) {
  return (
    <div className="stack" style={{ gap: 4, textAlign: 'left', width: '100%' }}>
      <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
        <span style={{ minWidth: 0 }}><b>{f.name}</b>{f.state && <span className="faint"> · {f.state}</span>}</span>
        <span className="num" style={{ fontWeight: 700 }}>{N2(f.price)}{f.vat > 0 && <span className="faint" style={{ fontWeight: 400, fontSize: 12 }}> + {N2(f.vat)} VAT</span>}</span>
      </div>
      {f.note && <div className="muted" style={{ fontSize: 13 }}>{f.note}</div>}
      <div className="row wrap" style={{ gap: 6 }}>
        {f.signers.map((x) => <span key={x.id} className="chip t-grey" style={{ fontSize: 11 }}>{x.name} · {x.body} · {x.frc_no}</span>)}
        {f.keeps_books && <span className="chip t-amber" style={{ fontSize: 11 }}>Keeps your books</span>}
      </div>
    </div>
  );
}

function OwnAuditor({ s, onClose, onChanged }: { s: AuditState; onClose: () => void; onChanged: () => Promise<unknown> }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [f, setF] = useState({ name: '', email: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    try { await rpc('audit_own', { p_org: orgId, p_year: s.year, p: f }); await onChanged(); toast('Saved'); onClose(); }
    catch (e) { setErr(cleanError(e)); setBusy(false); }
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="Your auditor" sub={`The firm that audits the ${s.year} accounts, if it is not one Counta lists.`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <Field label="Audit firm" req><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} maxLength={160} autoFocus /></Field>
        <Field label="Its email (optional)"><input className="input" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || f.name.trim().length < 2} onClick={save}>{busy ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Save</button>
      </div>
    </Modal>
  );
}
