// Audits: what the firm needs before companies find it for audits, its offer (form, Tax ID, VAT, a price for each turnover
// band TaxStreem sets), switching audits on, setting up Flutterwave to pay the firm's share straight to its bank account,
// and the requests and audits themselves. Partners change the offer; partners and managers answer requests.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { useToast } from '../../state/session';
import { ENTITY_WORD, pct, type AuditBand, type AuditEngagement } from '../../lib/audits';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';

type Step = { id: 'signer' | 'bank' | 'tax' | 'prices' | 'flutterwave'; done: boolean; text: string };
type PracticeAudit = {
  enabled: boolean; referral_rate: number; request_days: number; bands: AuditBand[]; state: string | null; kind: string;
  offer: { active: boolean; entity_type: string; tin: string | null; vat_registered: boolean; prices: Record<string, number>; note: string | null;
    flutterwave: { status: 'none' | 'ready' | 'failed'; error: string | null; at: string | null } };
  ready: { steps: Step[]; ready: boolean; active: boolean; listed: boolean; signers: { id: string; name: string; body: string; frc_no: string }[] };
  bank: { bank_name: string; last4: string; account_name: string; name_match: boolean } | null;
  me: { id: string; role: string; licence_body: string | null; licence_status: string; frc_no: string | null; frc_status: string; signs: boolean };
  requests: AuditEngagement[]; engagements: AuditEngagement[];
};

export default function Audits({ pid }: { pid: string }) {
  const q = useQuery({ queryKey: ['practice-audit', pid], queryFn: () => rpc<PracticeAudit>('practice_audit', { p_practice: pid }) });
  const d = q.data;
  if (q.isLoading) return <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div>;
  if (q.isError || !d) return <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>;
  const partner = d.me.role === 'partner';
  return (
    <>
      <PageHead title="Audits" sub={<>Companies above the small company limits find you in Counta, see your price for their size and pay you through Flutterwave.
        TaxStreem keeps {pct(d.referral_rate)} of each fee before VAT as its referral fee.</>}
        right={<span className={'chip ' + (d.ready.listed ? 't-green' : 't-grey')} data-testid="audit-listed">{d.ready.listed ? 'Taking audits' : 'Not taking audits'}</span>} />
      {!d.enabled && <Alert kind="grey" icon="info">TaxStreem has not opened audits in Counta yet. You can get ready now.</Alert>}
      {d.requests.length > 0 && <Requests pid={pid} d={d} />}
      <Ready pid={pid} d={d} partner={partner} />
      <Offer pid={pid} d={d} partner={partner} />
      {d.engagements.length > 0 && <Engagements d={d} />}
    </>
  );
}

const STEP_LINK: Partial<Record<Step['id'], [string, string]>> = {
  signer: ['settings', 'Add your FRC number under Practice'], bank: ['earnings', 'Add or change it under Earnings'],
};

function Ready({ pid, d, partner }: { pid: string; d: PracticeAudit; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<'flw' | 'switch' | null>(null);
  const bankOk = d.ready.steps.find((s) => s.id === 'bank')?.done;
  async function setUpFlutterwave() {
    setBusy('flw');
    const r = await edge<{ state?: PracticeAudit }>('audits', { action: 'subaccount', practice_id: pid });
    if (r.ok === false) toast(r.error || 'Flutterwave could not be set up.', 'err');
    else if (r.state?.offer.flutterwave.status === 'ready') toast('Flutterwave is set up');
    else toast(r.state?.offer.flutterwave.error || 'Flutterwave said no.', 'err');
    await qc.invalidateQueries({ queryKey: ['practice-audit', pid] });
    setBusy(null);
  }
  async function toggle(on: boolean) {
    setBusy('switch');
    try { await rpc('practice_audit_switch', { p_practice: pid, p_on: on }); await qc.invalidateQueries({ queryKey: ['practice-audit', pid] }); toast(on ? 'Companies can now ask you for audits' : 'Audits switched off'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  return (
    <Card title="Getting ready" sub="Every step done, then a partner switches audits on. Requests already made carry on if you switch off."
      right={partner && (d.ready.active
        ? <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => toggle(false)}>{busy === 'switch' ? <Spinner small /> : null}Switch off</button>
        : <button className="btn btn-primary btn-sm" data-testid="audit-switch-on" disabled={busy !== null || !d.ready.ready} onClick={() => toggle(true)}>
            {busy === 'switch' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Take audits</button>)}>
      <div className="audit-steps">
        {d.ready.steps.map((s) => (
          <div key={s.id} className="audit-step" data-testid={`audit-step-${s.id}`}>
            <span className={'filing-step' + (s.done ? ' done' : '')} aria-hidden="true">{s.done ? <Icon name="check" size={13} color="#fff" /> : null}</span>
            <span style={{ minWidth: 0 }}>
              {s.text}
              {s.id === 'signer' && d.ready.signers.length > 0 && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{d.ready.signers.map((x) => `${x.name} (${x.body}, ${x.frc_no})`).join('; ')}</span>}
              {s.id === 'signer' && !s.done && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{d.me.role === 'partner'
                ? `You: ${d.me.licence_body && ['ICAN', 'ANAN'].includes(d.me.licence_body) ? `${d.me.licence_body} ${d.me.licence_status === 'verified' ? 'verified' : 'waiting for TaxStreem'}` : 'no ICAN or ANAN number'}, FRC ${d.me.frc_no ? (d.me.frc_status === 'verified' ? 'verified' : d.me.frc_status === 'rejected' ? 'not confirmed' : 'waiting for TaxStreem') : 'not given'}.`
                : 'A partner of the firm signs audits.'}</span>}
              {s.id === 'bank' && d.bank && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{d.bank.bank_name} ••••{d.bank.last4}, {d.bank.account_name}</span>}
              {s.id === 'tax' && !s.done && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{!d.offer.tin ? 'Enter the Tax ID below.' : ''}{!d.state ? ' Add the state under Practice.' : ''}</span>}
              {!s.done && STEP_LINK[s.id] && <Link to={`/practice/${pid}/${STEP_LINK[s.id]![0]}`} style={{ display: 'block', fontSize: 12 }}>{STEP_LINK[s.id]![1]}</Link>}
              {s.id === 'flutterwave' && !s.done && partner && (
                <span style={{ display: 'block', marginTop: 6 }}>
                  <button className="btn btn-secondary btn-sm" data-testid="audit-flutterwave" disabled={busy !== null || !bankOk} onClick={setUpFlutterwave}>
                    {busy === 'flw' ? <Spinner small /> : <Icon name="card" size={14} />}{d.offer.flutterwave.status === 'none' ? 'Set up Flutterwave' : 'Set up Flutterwave again'}</button>
                </span>
              )}
            </span>
          </div>
        ))}
      </div>
      {!partner && <div className="faint" style={{ fontSize: 13 }}>A partner sets up audits and switches them on.</div>}
    </Card>
  );
}

function Offer({ pid, d, partner }: { pid: string; d: PracticeAudit; partner: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ entity_type: d.offer.entity_type, tin: d.offer.tin || '', vat_registered: d.offer.vat_registered, note: d.offer.note || '',
    prices: Object.fromEntries(d.bands.map((b) => [b.key, d.offer.prices[b.key] != null ? Number(d.offer.prices[b.key]).toLocaleString('en-NG') : ''])) as Record<string, string> });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    try {
      await rpc('practice_audit_save', { p_practice: pid, p: { ...f, prices: Object.fromEntries(Object.entries(f.prices).map(([k, v]) => [k, v.replace(/[,\s₦]/g, '')])) } });
      await qc.invalidateQueries({ queryKey: ['practice-audit', pid] }); toast('Saved');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <Card title="Your offer" sub={<>Businesses pay your fee, with VAT when you charge it, less the withholding tax they deduct. TaxStreem's {pct(d.referral_rate)} and
      Flutterwave's charge come out of what reaches your bank. Leave a band blank if you do not audit companies of that size.</>}>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Field label="The firm is">
          <select className="input" value={f.entity_type} disabled={!partner} onChange={(e) => setF({ ...f, entity_type: e.target.value })}>
            {Object.entries(ENTITY_WORD).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
        <Field label="Firm's Tax ID" hint="Clients deduct withholding tax against it."><input className="input" value={f.tin} disabled={!partner} inputMode="numeric"
          onChange={(e) => setF({ ...f, tin: e.target.value })} placeholder="12345678-0001" maxLength={15} /></Field>
      </div>
      <label className="check" style={{ minHeight: 44, alignItems: 'center' }}>
        <input type="checkbox" checked={f.vat_registered} disabled={!partner} onChange={(e) => setF({ ...f, vat_registered: e.target.checked })} />
        <span>The firm charges VAT on its fees</span>
      </label>
      <div className="stack" style={{ gap: 8 }}>
        <div className="label">Fee by the company's turnover, before VAT</div>
        <div className="audit-prices">
          {d.bands.map((b) => (
            <label key={b.key} className="row" style={{ gap: 10, justifyContent: 'space-between' }}>
              <span style={{ fontSize: 14 }}>{b.label}</span>
              <span className="row" style={{ gap: 4 }}><span className="faint">₦</span>
                <input className="input num" style={{ width: 150, textAlign: 'right' }} inputMode="decimal" disabled={!partner} value={f.prices[b.key] || ''} data-testid={`audit-price-${b.key}`}
                  onChange={(e) => setF({ ...f, prices: { ...f.prices, [b.key]: e.target.value } })} aria-label={`Fee for ${b.label}`} placeholder="Not offered" /></span>
            </label>
          ))}
        </div>
      </div>
      <Field label="A line for businesses (optional)" hint={`${f.note.length}/300`}>
        <textarea className="input" value={f.note} disabled={!partner} maxLength={300} onChange={(e) => setF({ ...f, note: e.target.value })} style={{ minHeight: 56 }}
          placeholder="Audits for manufacturers and distributors in the South West." />
      </Field>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      {partner ? <div><button className="btn btn-primary" data-testid="audit-offer-save" disabled={busy} onClick={save}>{busy ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Save the offer</button></div>
        : <div className="faint" style={{ fontSize: 13 }}>A partner changes the offer.</div>}
    </Card>
  );
}

function Money({ e }: { e: AuditEngagement }) {
  const vat = Number(e.vat || 0);
  return (
    <span className="faint" style={{ fontSize: 12, display: 'block' }}>
      Fee {N2(e.price)}{vat > 0 ? ` + VAT ${N2(vat)}` : ''}{Number(e.wht) > 0 ? ` · WHT ${N2(e.wht)}` : ''} · TaxStreem {N2(e.referral)}
      {e.charge?.paid_amount != null && e.status === 'paid' ? ` · paid ${N2(e.charge.paid_amount)}` : ''}
    </span>
  );
}

function Requests({ pid, d }: { pid: string; d: PracticeAudit }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [declining, setDeclining] = useState<AuditEngagement | null>(null);
  const [note, setNote] = useState('');
  async function answer(e: AuditEngagement, accept: boolean, why?: string) {
    setBusy(e.id);
    try {
      await rpc('practice_audit_answer', { p_engagement: e.id, p_accept: accept, p_note: why || null });
      await qc.invalidateQueries({ queryKey: ['practice-audit', pid] });
      toast(accept ? `${e.business.name} can now pay for the audit` : 'Declined'); setDeclining(null); setNote('');
    } catch (err) { toast(cleanError(err), 'err'); }
    setBusy(null);
  }
  return (
    <Card title={`${d.requests.length} ${d.requests.length === 1 ? 'company asks' : 'companies ask'} you to audit their accounts`}
      sub={`Answer within ${d.request_days} days. Once you accept, the business pays through Flutterwave and your share goes to your bank.`} pad={false}>
      {d.requests.map((e) => (
        <div key={e.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(220px,1fr) auto' }} data-testid="audit-request">
          <span className="m-main" style={{ minWidth: 0 }}>
            <b>{e.business.name}</b> <span className="faint">· {e.year} accounts · {e.band?.label || ''}</span>
            <span className="faint" style={{ fontSize: 12, display: 'block' }}>Turnover {N2(e.turnover)} · fixed assets {N2(e.fixed_assets)}{e.business.rc_number ? ` · ${e.business.rc_number}` : ''} · asked {fmtDay(e.requested_at.slice(0, 10))}{e.lapses_at ? `, lapses ${fmtDay(e.lapses_at.slice(0, 10))}` : ''}</span>
            <Money e={e} />
            {e.note && <span className="muted" style={{ fontSize: 13, display: 'block', marginTop: 4 }}>“{e.note}”</span>}
            {e.keeps_books && <span className="chip t-amber" style={{ marginTop: 6, whiteSpace: 'normal' }}>You keep its books: consider independence before you accept</span>}
          </span>
          <span className="row" style={{ gap: 6, justifyContent: 'flex-end' }}>
            <button className="btn btn-primary btn-sm" data-testid="audit-accept" disabled={busy !== null} onClick={() => answer(e, true)}>{busy === e.id ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Accept</button>
            <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => setDeclining(e)}>Decline</button>
          </span>
        </div>
      ))}
      {declining && (
        <Modal onClose={() => setDeclining(null)} width={460}>
          <ModalHead title={`Decline ${declining.business.name}`} sub="The business hears at once and can choose another firm." onClose={() => setDeclining(null)} />
          <div className="modal-body"><Field label="Why (optional, the business sees it)"><textarea className="input" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} style={{ minHeight: 70 }} /></Field></div>
          <div className="modal-ft">
            <button className="btn btn-secondary" onClick={() => setDeclining(null)}>Cancel</button>
            <button className="btn btn-danger" disabled={busy !== null} onClick={() => answer(declining, false, note)}>{busy ? <Spinner small /> : null}Decline</button>
          </div>
        </Modal>
      )}
    </Card>
  );
}

const STATUS: Record<string, [string, string]> = {
  accepted: ['Waiting for payment', 't-blue'], paid: ['Paid', 't-green'], declined: ['Declined', 't-grey'], lapsed: ['Lapsed', 't-grey'], cancelled: ['Withdrawn', 't-grey'],
};

function Engagements({ d }: { d: PracticeAudit }) {
  return (
    <Card title="Audits" sub="Accepted and paid audits, and requests that ended in the last 90 days." pad={false}>
      {d.engagements.map((e) => {
        const [t, c] = STATUS[e.status] || [e.status, 't-grey'];
        return (
          <div key={e.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(220px,1fr) auto' }} data-testid="audit-engagement">
            <span className="m-main" style={{ minWidth: 0 }}>
              <b>{e.business.name}</b> <span className="faint">· {e.year} accounts</span>
              <Money e={e} />
              {e.status === 'paid' && <span className="faint" style={{ fontSize: 12, display: 'block' }}>Paid on {fmtDay((e.paid_at || '').slice(0, 10))}. The business deducted withholding tax from the fee: ask it for the credit note once it remits the tax.</span>}
            </span>
            <span className={'chip ' + c}>{t}</span>
          </div>
        );
      })}
    </Card>
  );
}
