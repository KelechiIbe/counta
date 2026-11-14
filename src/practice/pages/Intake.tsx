// Adding a client: /practice/:pid/intake/new, then /practice/:pid/intake/:iid. Before a firm takes a business on it records
// who the client is (MLPPA 2022: registration details, directors and beneficial owners, politically exposed people, a risk
// rating, supporting documents) and checks the work against its own records for conflicts. Then either it invites the owner
// (involved), or, where TaxStreem lets the firm run full mandates, it gets a full-mandate engagement letter signed, a partner
// declares the client's written authority, and a verified partner sets the business up (full mandate). The database decides
// every rule; this page says what each one needs before it is met. Partners and managers only.
import { useEffect, useRef, useState, type MouseEvent, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../../lib/supabase';
import { fmtDay, uuid, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead, grid } from '../../admin/ui';
import { OpposingList } from '../Opposing';
import { type CacFields, CacFinder, NinCheck, titleName, useIntakeLookups } from '../IntakeLookups';
import {
  type ConflictHit, type Home, type IntakeDetail, type IntakeDoc, type IntakeMode, type IntakePerson, type LetterStatus,
  openDoc, SERVICES, sendInvite, useMandateGate, usePracticeClient, usePracticeHome, usePracticeIntake,
} from '../api';

const ENTITY: [string, string][] = [['company', 'Company (RC number)'], ['business_name', 'Business name (BN number)'],
  ['incorporated_trustees', 'Incorporated trustees (IT number)'], ['partnership', 'Partnership'], ['individual', 'Individual']];
const NUMBER_LABEL: Record<string, string> = { company: 'RC number', business_name: 'BN number', incorporated_trustees: 'IT number' };
const PERSON_KIND: [IntakePerson['kind'], string][] = [['director', 'Director'], ['beneficial_owner', 'Beneficial owner'], ['related', 'Related person']];
const ID_TYPES: [string, string][] = [['nin', 'NIN'], ['bvn', 'BVN'], ['passport', 'Passport'], ['drivers_licence', 'Driver\'s licence'], ['voters_card', 'Voter\'s card'],
  ['cac', 'CAC'], ['other', 'Other']];
const DOC_KIND: [IntakeDoc['kind'], string][] = [['cac', 'CAC documents'], ['id', 'Proof of identity'], ['address', 'Proof of address'], ['other', 'Other']];
const RISK_WORD: Record<string, string> = { low: 'Low', medium: 'Medium', high: 'High' };
// Where a possible conflict was found, and what matched.
const HIT_KIND: Record<ConflictHit['kind'], [string, string]> = {
  client: ['Client', 'one of your current or former clients'],
  prospect: ['Prospect', 'another business you recorded due diligence for'],
  related_party: ['Related person', 'someone recorded on another of your intakes'],
  opposing_party: ['Opposing party', 'the other side of a matter you recorded for a client'],
  books: ['Customer or supplier', 'in the books of a client you look after'],
};
const MATCHED: Record<ConflictHit['matched_on'], string> = { rc_number: 'Same RC, BN or IT number', tax_id: 'Same Tax ID', name: 'Similar name', person: 'Same person' };
const LETTER_WORD: Record<LetterStatus, [string, string]> = {
  draft: ['Draft', 't-grey'], partner_signed: ['Signed by the firm', 't-blue'], sent: ['Sent to the client', 't-amber'], completed: ['Signed by both sides', 't-green'],
  uploaded: ['Signed copy uploaded', 't-green'], void: ['Void', 't-red'],
};
const DUPLICATE = 'This business cannot be set up under full mandate. TaxStreem has been told and will be in touch.';
const MAX_FILE = 15 * 1024 * 1024;

type PersonForm = { key: string; kind: IntakePerson['kind']; name: string; role: string; ownership_pct: string; nationality: string; is_pep: boolean; id_type: string; id_last4: string };
type Form = {
  mode_requested: IntakeMode; legal_name: string; entity_type: string; rc_number: string; tax_id: string; address: string; industry: string;
  risk_rating: string; risk_reason: string; people: PersonForm[];
};

const blankPerson = (): PersonForm => ({ key: uuid(), kind: 'director', name: '', role: '', ownership_pct: '', nationality: '', is_pep: false, id_type: '', id_last4: '' });
// A name compared as the database compares people: no accents, any order, any case.
const nameKey = (s: string) => s.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().split(/[^a-z']+/).filter(Boolean).sort().join(' ');
// The CAC record's people added to those already on the form (a person already there by name is left as it is).
function withCacPeople(people: PersonForm[], cac: CacFields['people']): PersonForm[] {
  const have = new Set(people.map((p) => nameKey(p.name)));
  const added = cac.filter((c) => c.name && !have.has(nameKey(c.name))).map((c): PersonForm => ({ ...blankPerson(), kind: c.kind, name: c.name, role: c.role || '',
    ownership_pct: c.ownership_pct == null ? '' : String(Number(c.ownership_pct)), nationality: c.nationality || '' }));
  return [...people.filter((p) => p.name.trim()), ...added];
}
function toForm(d: IntakeDetail | null, mode: IntakeMode = 'involved'): Form {
  return {
    mode_requested: d?.mode_requested || mode, legal_name: d?.legal_name || '', entity_type: d?.entity_type || '', rc_number: d?.rc_number || '',
    tax_id: d?.tax_id || '', address: d?.address || '', industry: d?.industry || '', risk_rating: d?.risk_rating || '', risk_reason: d?.risk_reason || '',
    people: (d?.people || []).map((p) => ({ key: p.id || uuid(), kind: p.kind, name: p.name, role: p.role || '', ownership_pct: p.ownership_pct == null ? '' : String(Number(p.ownership_pct)),
      nationality: p.nationality || '', is_pep: p.is_pep, id_type: p.id_type || '', id_last4: p.id_last4 || '' })),
  };
}
// What the database is sent: trimmed text, blanks as nothing, and a politically exposed person making the risk high.
function payload(f: Form, id?: string) {
  const pep = f.people.some((p) => p.is_pep);
  return {
    ...(id ? { id } : {}), mode_requested: f.mode_requested, legal_name: f.legal_name.trim(), entity_type: f.entity_type || null, rc_number: f.rc_number.trim(),
    tax_id: f.tax_id.trim(), address: f.address.trim(), industry: f.industry.trim(), risk_rating: pep ? 'high' : f.risk_rating || null, risk_reason: f.risk_reason.trim(),
    people: f.people.map((p) => ({ kind: p.kind, name: p.name.trim(), role: p.role.trim() || null, ownership_pct: p.ownership_pct.trim() || null,
      nationality: p.nationality.trim() || null, is_pep: p.is_pep, id_type: p.id_type || null, id_last4: p.id_last4.trim() || null })),
  };
}
const same = (a: Form, b: Form) => JSON.stringify(payload(a)) === JSON.stringify(payload(b));
// The database's refusal of an ID number written anywhere but the last-4 field: ten or more digits in a row once spaces and
// dashes are taken out (an NIN or BVN), so "Director 2019-2024" passes.
const ID_REFUSAL = 'Record only the last 4 characters of an ID number.';
const hasIdNumber = (s: string) => /[0-9]{10,}/.test(s.replace(/[\s-]/g, ''));
// A refusal from the database about the people (step 3).
const PEOPLE_ERROR = /ID number|person|people|director, beneficial owner|Ownership is|kind of ID|role under|nationality under/i;
function personProblem(p: PersonForm): string | null {
  if (hasIdNumber(p.name) || hasIdNumber(p.role) || hasIdNumber(p.nationality)) return ID_REFUSAL;
  if (p.name.trim().length < 2) return 'Enter the person\'s full name.';
  if (p.id_last4 && !/^[A-Za-z0-9]{4}$/.test(p.id_last4)) return 'Enter exactly the last 4 characters of the ID number.';
  const pct = p.ownership_pct.trim();
  if (pct && !(/^\d{1,3}(\.\d+)?$/.test(pct) && Number(pct) <= 100)) return 'Ownership is a percentage from 0 to 100.';
  return null;
}
// The first thing to correct before saving, and the step it is on.
function formProblem(f: Form): [string, number] | null {
  const n = f.legal_name.trim().length;
  if (n < 2 || n > 160) return ['Enter the business\'s registered name (2 to 160 characters).', 2];
  const i = f.people.findIndex((p) => personProblem(p));
  if (i < 0) return null;
  const problem = personProblem(f.people[i])!;
  // (Never the name back when it may hold an ID number.)
  return [`${problem === ID_REFUSAL ? `Person ${i + 1}` : f.people[i].name.trim() || `Person ${i + 1}`}: ${problem}`, 3];
}
// An error or outcome, announced when it appears.
function ErrorNote({ children }: { children: ReactNode }) {
  return <div role="alert"><Alert kind="red" icon="alert">{children}</Alert></div>;
}
// The step to open an intake at: the first thing it still needs.
const nextStep = (d: IntakeDetail) => (!d.risk_rating ? 4 : !d.cleared ? 5 : 6);
// The intake's latest letter of that kind that is not void, and whether both sides have signed it.
function latestLetter(d: IntakeDetail, variant: IntakeMode) {
  const letter = d.letters.find((l) => l.variant === variant && l.status !== 'void') || null;
  return { letter, signed: !!letter && (letter.status === 'completed' || letter.status === 'uploaded') };
}
// The same words the database records when a partner declares the client's authority.
const statementText = (firm: string, client: string) => `I confirm that ${firm} holds the written authority of ${client} to set up and run its accounting records and tax `
  + `affairs on its behalf under full mandate, as set out in the engagement letter, and that I am a partner of ${firm}.`;
const fileName = (s: string) => s.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(-100) || 'file';
async function sha256(f: File) {
  const buf = await crypto.subtle.digest('SHA-256', await f.arrayBuffer());
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

export default function IntakePage({ pid }: { pid: string }) {
  const { iid = 'new' } = useParams();
  const isNew = iid === 'new';
  const h = usePracticeHome(pid).data!;
  const staff = h.me.role === 'staff';
  const q = usePracticeIntake(isNew || staff ? null : iid);
  const back = <BackLink pid={pid} />;
  if (staff) return <>{back}<Alert kind="amber" icon="lock">Only partners and managers add clients and keep their due-diligence records.</Alert></>;
  if (!isNew && q.isLoading) return <>{back}<SkeletonRows n={8} /></>;
  if (!isNew && (q.isError || !q.data)) return <>{back}<ErrorNote>{q.isError ? cleanError(q.error) : 'That intake was not found.'}</ErrorNote></>;
  return <Wizard pid={pid} h={h} d={isNew ? null : q.data!} />;
}

function BackLink({ pid, onClick }: { pid: string; onClick?: (e: MouseEvent) => void }) {
  return <div><Link to={`/practice/${pid}`} className="muted" style={{ fontSize: 13, display: 'inline-flex', alignItems: 'center', minHeight: 44 }} onClick={onClick}>← All clients</Link></div>;
}

function Wizard({ pid, h, d }: { pid: string; h: Home; d: IntakeDetail | null }) {
  const qc = useQueryClient();
  const nav = useNavigate();
  const [f, setF] = useState<Form>(() => toForm(d));
  const [step, setStep] = useState(() => (d ? nextStep(d) : 1));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [tried, setTried] = useState(false);
  // A CAC record found for this intake, attached to it on the next save.
  const [cacLookup, setCacLookup] = useState<string | null>(null);
  const [cacNote, setCacNote] = useState<string | null>(null);
  const lookups = useIntakeLookups(d?.id ?? null);
  const loaded = useRef<string | null>(d?.id ?? null);
  const heading = useRef<HTMLHeadingElement>(null);
  const first = useRef(true);

  // Another intake opened in place: start from it. (A new intake's first save keeps the wizard where it is.)
  useEffect(() => {
    const id = d?.id ?? null;
    if (id === loaded.current) return;
    loaded.current = id;
    setF(toForm(d)); setStep(d ? nextStep(d) : 1); setErr(null); setTried(false);
  }, [d]);
  // Keyboard and screen-reader users land on the new step's heading.
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    heading.current?.focus();
  }, [step]);

  const partner = h.me.role === 'partner';
  const declined = d?.status === 'declined';
  // Kept as it is once it has a retention date (the work ended, refused, or the business deleted). A current client's
  // intake stays up to date (ongoing due diligence), with its history.
  const kept = !!d && d.retain_until != null;
  const client = d?.status === 'engaged' && !kept;
  const invitation = d ? h.clients.find((c) => c.intake_id === d.id && c.status === 'invited') : undefined;
  const editable = !declined && !kept && !invitation;
  const dirty = !d || !same(f, toForm(d));
  const unsaved = editable && !same(f, toForm(d));
  const ended = d?.status === 'engaged' && d.retain_until != null;
  const pep = f.people.some((p) => p.is_pep);
  const steps = ['How you will work', 'The business', 'Directors and owners', 'Risk and documents', 'Conflicts check',
    f.mode_requested === 'full' ? 'Letter and set-up' : 'Invite the owner'];
  const done = [!!d, !!d, !!d && d.people.length > 0, !!d?.risk_rating, !!d?.cleared, !!d?.client_id];
  const up = <K extends keyof Form>(k: K, v: Form[K]) => setF((x) => ({ ...x, [k]: v }));
  // Unsaved changes: closing or reloading the tab asks first, and so do the links on this page (guard). (The portal's own
  // menu cannot be held back: the app's router has no navigation blocker.)
  useEffect(() => {
    if (!unsaved) return;
    const ask = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', ask);
    return () => window.removeEventListener('beforeunload', ask);
  }, [unsaved]);
  const guard = (e: MouseEvent) => {
    if (unsaved && !window.confirm('Leave this intake? Your changes are not saved yet.')) e.preventDefault();
  };

  async function save(): Promise<IntakeDetail | null> {
    setTried(true);
    const problem = formProblem(f);
    if (problem) { setErr(problem[0]); setStep(problem[1]); return null; }
    setBusy(true); setErr(null);
    try {
      let r = await rpc<IntakeDetail>('practice_intake_save', { p_practice: pid, p: payload(f, d?.id) });
      if (cacLookup) {
        try {
          r = await rpc<IntakeDetail>('practice_intake_attach_cac', { p_intake: r.id, p_lookup: cacLookup });
          setCacLookup(null);
          void qc.invalidateQueries({ queryKey: ['intake-lookups', r.id] });
        } catch (e) { setCacNote(`Saved, but the CAC record could not be kept with the intake: ${cleanError(e)}`); }
      }
      loaded.current = r.id;
      qc.setQueryData(['practice-intake', r.id], r);
      setF(toForm(r)); setTried(false);
      void qc.invalidateQueries({ queryKey: ['practice-intakes', pid] });
      void qc.invalidateQueries({ queryKey: ['mandate-gate', r.id] });
      void qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      if (!d) nav(`/practice/${pid}/intake/${r.id}`, { replace: true });
      return r;
    } catch (e) {
      const msg = cleanError(e);
      setErr(msg);
      if (PEOPLE_ERROR.test(msg)) setStep(3);
      return null;
    } finally { setBusy(false); }
  }
  // The first four steps are one form: moving between them keeps what was typed. "Save and continue" saves it, and so does
  // going on to the conflicts check or the last step, which work on the intake as saved. (A new intake is saved first
  // from step 2, once it has a name.)
  async function go(target: number, saving = false) {
    if (target === step || busy) return;
    if (!d && target > 2 && f.legal_name.trim().length < 2) { setStep(2); setTried(true); setErr('Enter the business\'s registered name first.'); return; }
    const mustSave = editable && dirty && (d ? saving || target >= 5 : target > 2);
    if (mustSave && !(await save())) return;
    setErr(null);
    setStep(target);
  }

  return (
    <div className="wiz stack" style={{ gap: 20 }}>
      <BackLink pid={pid} onClick={guard} />
      <PageHead title={d?.legal_name || 'Add a client'}
        sub="Due diligence and a conflicts check come first, whichever way you work. The records stay with your practice for at least five years after the work ends."
        right={d && <span className="row wrap" style={{ gap: 6 }}><StatusChip d={d} invited={!!invitation} /><span className="chip t-grey">{d.mode_requested === 'full' ? 'Full mandate' : 'Involved'}</span></span>} />
      {declined && <Alert kind="red" icon="alert">A partner refused this client after the conflicts check{d?.conflict_note ? `: “${d.conflict_note}”` : '.'} The record is kept{d?.retain_until ? ` until ${fmtDay(d.retain_until)}` : ''} and cannot be changed.</Alert>}
      {!declined && kept && (ended
        ? <Alert kind="grey" icon="history">The engagement with this business ended. Its due-diligence record is kept until {fmtDay(d!.retain_until)} and cannot be changed.</Alert>
        : <Alert kind="grey" icon="lock">This intake is the record of the engagement{d?.retain_until ? `, kept until ${fmtDay(d.retain_until)}` : ''}, so it cannot be changed. Start a new intake to record changes.</Alert>)}
      {!declined && !kept && d?.dd_incomplete && <Alert kind="amber" icon="alert">Due diligence incomplete: this business is already your client. Complete the details, rate the risk and run the conflicts check.</Alert>}
      {client && !d?.dd_incomplete && (
        <div data-testid="intake-ongoing">
          <Alert kind="blue" icon="info">This business is your client. Keep its due diligence up to date here: the intake as it was before each change stays in its history, and a new name, number or person means running the conflicts check again.</Alert>
        </div>
      )}
      {invitation && <InvitationNotice pid={pid} id={invitation.id} email={invitation.invite_email} sentAt={invitation.sent_at} />}

      <nav aria-label="Steps">
        <ol className="wiz-steps">
          {steps.map((label, i) => {
            const n = i + 1;
            return (
              <li key={n}>
                <button type="button" className={'wiz-step' + (done[i] && n !== step ? ' done' : '')} aria-current={n === step ? 'step' : undefined}
                  aria-label={`Step ${n}: ${label}${done[i] && n !== step ? ' (done)' : ''}`} disabled={busy || (!d && n > 2)} onClick={() => go(n)}>
                  <span className="wiz-num" aria-hidden="true">{done[i] && n !== step ? <Icon name="check" size={13} /> : n}</span>
                  <span className="wiz-label">{label}</span>
                </button>
              </li>
            );
          })}
        </ol>
      </nav>

      <section className="card" style={{ minWidth: 0 }} aria-labelledby="intake-step-title">
        <div className="card-hd" style={{ alignItems: 'flex-start' }}>
          <div style={{ minWidth: 0, flex: '1 1 260px' }}>
            <div className="mini-label">Step {step} of 6</div>
            <h2 id="intake-step-title" ref={heading} tabIndex={-1} style={{ fontSize: 17, fontWeight: 700, margin: '4px 0 0', outline: 'none' }}>{steps[step - 1]}</h2>
          </div>
        </div>
        <div className="card-pad stack" style={{ gap: 16, minWidth: 0 }}>
          {step === 1 && (
            <div data-testid="intake-step-1" className="stack" style={{ gap: 12 }}>
              <ModeChoice h={h} value={f.mode_requested} disabled={!editable || d?.status === 'engaged'} onChange={(m) => up('mode_requested', m)} />
              {d?.status === 'engaged' && !ended && <div className="muted" style={{ fontSize: 13 }}>This business is already your client, so the way you work for it is set.</div>}
              {editable && d?.authority_declared_at && f.mode_requested !== d.mode_requested && (
                <Alert kind="amber" icon="alert">Changing how you work withdraws the partner's declaration. A partner declares again for a full mandate.</Alert>
              )}
            </div>
          )}

          {step === 2 && (
            <div data-testid="intake-step-2" className="stack" style={{ gap: 14 }}>
              {editable && (
                <CacFinder pid={pid} initial={f.legal_name || f.rc_number} attached={lookups.data?.cac ?? null}
                  onFound={(c, taxNote) => {
                    setF((x) => ({ ...x, legal_name: titleName(c.legal_name).slice(0, 160), entity_type: c.entity_type || x.entity_type, rc_number: c.rc_number || x.rc_number,
                      tax_id: c.tax_id || x.tax_id, address: c.address || x.address, industry: c.industry || x.industry, people: withCacPeople(x.people, c.people || []) }));
                    setCacLookup(c.lookup_id);
                    setCacNote(`Filled from CAC${c.active === false ? ' (CAC shows the business as inactive)' : ''}${c.people?.length ? `, with ${c.people.length} director${c.people.length === 1 ? '' : 's'} and owner${c.people.length === 1 ? '' : 's'} in step 3` : ''}. Check the details, then save.${taxNote ? ` ${taxNote}` : ''}`);
                  }} />
              )}
              {cacNote && <div role="status"><Alert kind="blue" icon="info">{cacNote}</Alert></div>}
              <div style={grid(240)}>
                <Field label="Registered name" req error={tried && f.legal_name.trim().length < 2 ? 'Enter the name on the business\'s registration.' : null}>
                  <input className={'input' + (tried && f.legal_name.trim().length < 2 ? ' err' : '')} data-testid="intake-legal-name" value={f.legal_name} maxLength={160}
                    disabled={!editable} onChange={(e) => up('legal_name', e.target.value)} aria-invalid={tried && f.legal_name.trim().length < 2} />
                </Field>
                <Field label="Kind of business">
                  <select className="input" data-testid="intake-entity-type" value={f.entity_type} disabled={!editable} onChange={(e) => up('entity_type', e.target.value)}>
                    <option value="">Choose</option>
                    {ENTITY.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                  </select>
                </Field>
                <Field label={NUMBER_LABEL[f.entity_type] || 'RC, BN or IT number'} hint={f.mode_requested === 'full' ? 'Full mandate needs this number or the Tax ID.' : 'As on the CAC certificate.'}>
                  <input className="input" data-testid="intake-rc" value={f.rc_number} maxLength={40} disabled={!editable} onChange={(e) => up('rc_number', e.target.value)}
                    placeholder={f.entity_type === 'business_name' ? 'BN 1234567' : 'RC 123456'} />
                </Field>
                <Field label="Tax ID (TIN)">
                  <input className="input" data-testid="intake-tin" value={f.tax_id} maxLength={40} disabled={!editable} onChange={(e) => up('tax_id', e.target.value)} inputMode="numeric" />
                </Field>
                <Field label="Industry">
                  <input className="input" data-testid="intake-industry" value={f.industry} maxLength={80} disabled={!editable} onChange={(e) => up('industry', e.target.value)}
                    placeholder="For example, food manufacturing" />
                </Field>
              </div>
              <Field label="Registered address">
                <textarea className="input" data-testid="intake-address" rows={2} value={f.address} maxLength={300} disabled={!editable} onChange={(e) => up('address', e.target.value)} />
              </Field>
              {editable && d?.checked_at && <div className="muted" style={{ fontSize: 13 }}>A change to the name or numbers means running the conflicts check again{d.authority_declared_at && !client ? ', and a new name withdraws the partner\'s declaration' : ''}.</div>}
            </div>
          )}

          {step === 3 && (
            <div className="stack" style={{ gap: 14 }}>
              <People people={f.people} editable={editable} tried={tried} onChange={(p) => up('people', p)} rechecks={editable && !!d?.checked_at} />
              {editable && d && (
                <NinCheck pid={pid} iid={d.id} onChecked={(name, last4) => {
                  const key = nameKey(name);
                  setF((x) => ({ ...x, people: x.people.some((p) => nameKey(p.name) === key)
                    ? x.people.map((p) => (nameKey(p.name) === key ? { ...p, id_type: 'nin', id_last4: last4 } : p))
                    : [...x.people, { ...blankPerson(), name, id_type: 'nin', id_last4: last4 }] }));
                }} />
              )}
            </div>
          )}

          {step === 4 && d && (
            <div data-testid="intake-step-4" className="stack" style={{ gap: 16 }}>
              <div style={grid(240)}>
                <Field label="Risk" hint={pep ? 'A politically exposed person makes the risk high.' : 'Your assessment of the money-laundering risk.'}>
                  <select className="input" data-testid="intake-risk" value={pep ? 'high' : f.risk_rating} disabled={!editable || pep} onChange={(e) => up('risk_rating', e.target.value)}>
                    <option value="">Choose</option>
                    <option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option>
                  </select>
                </Field>
              </div>
              <Field label="Why this rating">
                <textarea className="input" data-testid="intake-risk-reason" rows={3} maxLength={1000} value={f.risk_reason} disabled={!editable}
                  onChange={(e) => up('risk_reason', e.target.value)} placeholder="For example: long-standing local business, cash sales, no politically exposed people." />
              </Field>
              <Docs pid={pid} d={d} disabled={declined} />
            </div>
          )}

          {step === 5 && d && <Conflicts pid={pid} h={h} d={d} partner={partner} guard={guard} />}

          {step === 6 && d && (
            <div data-testid="intake-step-6" className="stack" style={{ gap: 16 }}>
              {declined ? <Alert kind="red" icon="alert">A partner refused this client, so it cannot be taken on.</Alert>
                : d.client_id ? <Engaged pid={pid} h={h} d={d} />
                : d.mode_requested === 'full' ? <FullMandate pid={pid} h={h} d={d} />
                : <Invite pid={pid} d={d} invited={!!invitation} />}
            </div>
          )}

          {err && <ErrorNote>{err}</ErrorNote>}
        </div>
        <div className="modal-ft m-wrap" style={{ justifyContent: 'space-between' }}>
          {step > 1 ? <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => go(step - 1)}><Icon name="chevL" size={14} />Back</button> : <span />}
          {step <= 4 && editable && (d || step > 1)
            ? <span className="row wrap" style={{ gap: 10, justifyContent: 'flex-end' }}>
                {d && dirty && <span className="muted" style={{ fontSize: 13 }}>Changes not saved yet</span>}
                <button type="button" className="btn btn-primary" data-testid="intake-save" disabled={busy} onClick={() => go(step + 1, true)}>
                  {busy ? <Spinner small /> : null}{dirty ? 'Save and continue' : 'Continue'}<Icon name="chevR" size={14} color="#fff" />
                </button>
              </span>
            : step < 6 ? <button type="button" className="btn btn-primary" disabled={busy || (!d && step >= 2)} onClick={() => go(step + 1)}>Continue<Icon name="chevR" size={14} color="#fff" /></button>
            : <span />}
        </div>
      </section>
      {d && (d.history?.length || 0) > 0 && <History d={d} />}
    </div>
  );
}

function StatusChip({ d, invited }: { d: IntakeDetail; invited: boolean }) {
  if (d.status === 'declined') return <span className="chip t-red">Refused</span>;
  if (d.status === 'engaged' && d.retain_until) return <span className="chip t-grey">Engagement ended</span>;
  if (d.status === 'engaged') return d.dd_incomplete ? <span className="chip t-amber">Due diligence incomplete</span> : <span className="chip t-green">Client</span>;
  if (invited) return <span className="chip t-blue">Invitation waiting</span>;
  return d.cleared ? <span className="chip t-green">Cleared</span> : <span className="chip t-grey">Draft</span>;
}

function InvitationNotice({ pid, id, email, sentAt }: { pid: string; id: string; email: string | null; sentAt: string | null }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  async function withdraw() {
    setBusy(true);
    try {
      await rpc('practice_withdraw', { p_client: id });
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-home', pid] }), qc.invalidateQueries({ queryKey: ['practice-intakes', pid] })]);
      toast('Invitation withdrawn. You can change the intake now.');
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <Alert kind="blue" icon="send">
      <div className="row wrap" style={{ gap: 10, justifyContent: 'space-between' }}>
        <span>An invitation to {email || 'the owner'} carries this intake ({sentAt ? `sent ${when(sentAt)}` : 'not sent yet'}). Withdraw it to change the details.</span>
        <button type="button" className="btn btn-secondary btn-sm" disabled={busy} onClick={withdraw}>{busy ? <Spinner small /> : null}Withdraw the invitation</button>
      </div>
    </Alert>
  );
}

// Involved or full mandate. Full mandate is offered only to a firm TaxStreem lets run it.
function ModeChoice({ h, value, disabled, onChange }: { h: Home; value: IntakeMode; disabled: boolean; onChange: (m: IntakeMode) => void }) {
  const suspended = !!h.practice.mandate_suspended_at;
  const opt = (m: IntakeMode, title: string, body: ReactNode, off: boolean, testid: 'mode-involved' | 'mode-full', describedBy?: string) => (
    <label className={'acct-opt' + (value === m ? ' on' : '')} style={off || disabled ? { cursor: 'not-allowed', opacity: off ? 0.6 : 1 } : undefined}>
      {testid === 'mode-involved'
        ? <input type="radio" name="intake-mode" value={m} checked={value === m} disabled={disabled || off} onChange={() => onChange(m)} data-testid="mode-involved" />
        : <input type="radio" name="intake-mode" value={m} checked={value === m} disabled={disabled || off} onChange={() => onChange(m)} data-testid="mode-full" aria-describedby={describedBy} />}
      <span className="stack" style={{ gap: 4, minWidth: 0 }}>
        <b style={{ fontSize: 14 }}>{title}</b>
        <span className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>{body}</span>
      </span>
    </label>
  );
  return (
    <fieldset style={{ border: 0, margin: 0, padding: 0, minWidth: 0 }} className="stack">
      <legend className="muted" style={{ fontSize: 14, marginBottom: 12, padding: 0 }}>Both ways start with due diligence and a conflicts check.</legend>
      <div style={{ ...grid(280), alignItems: 'start' }}>
        {opt('involved', 'Involved: the owner runs the business on Counta',
          'You invite the business owner. Once they accept, your partners and managers get an accountant\'s place in their books: the books and tax returns, never moving money.',
          false, 'mode-involved')}
        <div className="stack" style={{ gap: 8 }}>
          {opt('full', 'Full mandate: your firm runs the business on Counta',
            'You set the business up and run it for the client. Counta never contacts the client. It needs a full-mandate engagement letter signed by both sides and a partner\'s declaration of the client\'s written authority. Wallets and payment links open only after a director confirms once.',
            !h.can_full, 'mode-full', h.can_full ? undefined : 'mode-full-locked')}
          {!h.can_full && (
            <div id="mode-full-locked" className="row" style={{ gap: 8, alignItems: 'flex-start', fontSize: 13, color: 'var(--ink-3)' }}>
              <Icon name="lock" size={14} style={{ marginTop: 2 }} />
              <span>
                {suspended
                  ? <span data-testid="mode-full-locked">TaxStreem has paused full mandates for your firm. Contact TaxStreem to find out more.</span>
                  : <span data-testid="mode-full-locked">Full mandate needs a partner whose licence TaxStreem has verified.</span>}
                {!suspended && h.me.role === 'partner' && h.me.licence_status !== 'verified' && <> <Link to={`/practice/${h.practice.id}/settings`}>Add or correct your licence number</Link>.</>}
                {' '}You can still take this client on as involved.
              </span>
            </div>
          )}
        </div>
      </div>
    </fieldset>
  );
}

function People({ people, editable, tried, rechecks, onChange }: { people: PersonForm[]; editable: boolean; tried: boolean; rechecks: boolean; onChange: (p: PersonForm[]) => void }) {
  const [kept4, setKept4] = useState<string | null>(null);
  const set = (key: string, patch: Partial<PersonForm>) => onChange(people.map((p) => (p.key === key ? { ...p, ...patch } : p)));
  return (
    <div data-testid="intake-step-3" className="stack" style={{ gap: 12 }}>
      <div className="muted" style={{ fontSize: 14, lineHeight: 1.5 }}>
        The directors, the people who ultimately own or control the business, and anyone else connected with it. For an ID, record only its last 4 characters, never the whole number.
      </div>
      {!people.length && <div className="empty" style={{ padding: 20 }}>No one recorded yet. Add the directors and beneficial owners.</div>}
      {people.map((p, i) => {
        const problem = tried ? personProblem(p) : null;
        return (
          <div key={p.key} data-testid="person-row" className="stack" style={{ gap: 12, paddingTop: i ? 16 : 0, borderTop: i ? '1px solid var(--row)' : 0 }}>
            <div className="row" style={{ gap: 8, justifyContent: 'space-between' }}>
              <b style={{ fontSize: 14 }}>{p.name.trim() || `Person ${i + 1}`}</b>
              {editable && (
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => onChange(people.filter((x) => x.key !== p.key))} aria-label={`Remove ${p.name.trim() || `person ${i + 1}`}`}>
                  <Icon name="trash" size={14} />Remove
                </button>
              )}
            </div>
            <div style={grid(180)}>
              <Field label="Full name" req>
                <input className={'input' + (tried && p.name.trim().length < 2 ? ' err' : '')} data-testid="person-name" value={p.name} maxLength={120} disabled={!editable}
                  onChange={(e) => set(p.key, { name: e.target.value })} autoComplete="off" />
              </Field>
              <Field label="They are">
                <select className="input" data-testid="person-kind" value={p.kind} disabled={!editable} onChange={(e) => set(p.key, { kind: e.target.value as PersonForm['kind'] })}>
                  {PERSON_KIND.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                </select>
              </Field>
              <Field label="Role">
                <input className="input" data-testid="person-role" value={p.role} maxLength={80} disabled={!editable} onChange={(e) => set(p.key, { role: e.target.value })}
                  placeholder="For example, managing director" />
              </Field>
              <Field label="Ownership (%)">
                <input className="input num" data-testid="person-pct" value={p.ownership_pct} inputMode="decimal" maxLength={6} disabled={!editable}
                  onChange={(e) => set(p.key, { ownership_pct: e.target.value.replace(/[^0-9.]/g, '') })} />
              </Field>
              <Field label="Nationality">
                <input className="input" data-testid="person-nationality" value={p.nationality} maxLength={60} disabled={!editable} onChange={(e) => set(p.key, { nationality: e.target.value })} />
              </Field>
              <Field label="ID type">
                <select className="input" data-testid="person-id-type" value={p.id_type} disabled={!editable} onChange={(e) => set(p.key, { id_type: e.target.value })}>
                  <option value="">None recorded</option>
                  {ID_TYPES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                </select>
              </Field>
              <Field label="ID number: last 4 only" hint={kept4 === p.key ? 'Only the last 4 characters were kept.' : 'Never the whole number.'}>
                <input className={'input mono' + (tried && p.id_last4 && p.id_last4.length !== 4 ? ' err' : '')} data-testid="person-id-last4" value={p.id_last4} maxLength={4}
                  disabled={!editable} autoComplete="off" spellCheck={false}
                  onChange={(e) => { setKept4(null); set(p.key, { id_last4: e.target.value.replace(/[^A-Za-z0-9]/g, '').slice(0, 4) }); }}
                  onPaste={(e) => {
                    // A whole ID number pasted here keeps only its last 4 characters: the rest never reaches the form.
                    const t = e.clipboardData.getData('text').replace(/[^A-Za-z0-9]/g, '');
                    if (t.length > 4) { e.preventDefault(); setKept4(p.key); set(p.key, { id_last4: t.slice(-4) }); }
                  }} />
              </Field>
            </div>
            <label className="check" style={{ alignSelf: 'flex-start' }}>
              <input type="checkbox" data-testid="person-pep" checked={p.is_pep} disabled={!editable} onChange={(e) => set(p.key, { is_pep: e.target.checked })} />
              <span>Politically exposed person <span className="muted">(makes the risk high)</span></span>
            </label>
            {problem && <div className="err-text" role="alert">{problem}</div>}
          </div>
        );
      })}
      {editable && (
        <div><button type="button" className="btn btn-secondary" data-testid="person-add" onClick={() => onChange([...people, blankPerson()])}><Icon name="plus" size={14} />Add a person</button></div>
      )}
      {rechecks && <div className="muted" style={{ fontSize: 13 }}>A change to the people means running the conflicts check again.</div>}
    </div>
  );
}

// Supporting documents: uploaded to the intake's own folder, fingerprinted (SHA-256) in the browser, then recorded.
function Docs({ pid, d, disabled }: { pid: string; d: IntakeDetail; disabled: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [kind, setKind] = useState<IntakeDoc['kind']>('cac');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);
  async function upload(f: File) {
    setErr(null);
    if (f.size > MAX_FILE) { setErr('That file is larger than 15 MB.'); return; }
    setBusy(true);
    try {
      const sha = await sha256(f);
      const path = `practice/${pid}/intake/${d.id}/${uuid()}-${fileName(f.name)}`;
      const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: f.type || 'application/octet-stream', upsert: false });
      if (error) throw new Error(cleanError(error));
      const r = await rpc<IntakeDetail>('practice_intake_doc_add', { p_intake: d.id, p: { path, name: f.name.slice(0, 200), sha256: sha, kind } });
      qc.setQueryData(['practice-intake', d.id], r);
      toast('Document added');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
    if (file.current) file.current.value = '';
  }
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div>
        <div className="field-label" style={{ marginBottom: 2 }}>Supporting documents</div>
        <div className="hint">CAC certificate and status report, IDs of the directors and owners, proof of address. Up to 15 MB each. Kept with the intake; nobody can delete them.</div>
      </div>
      {d.docs.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {d.docs.map((x, i) => (
            <div key={x.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', borderTop: i ? undefined : 0 }}>
              <span className="m-main" style={{ minWidth: 0 }}>
                <b className="ellipsis" style={{ display: 'block' }}>{x.name}</b>
                <span className="muted" style={{ fontSize: 12 }}>{DOC_KIND.find(([k]) => k === x.kind)?.[1]} · {x.added_by_name || 'Added'} {when(x.created_at)} · <span className="mono" title={x.sha256}>SHA-256 {x.sha256.slice(0, 12)}</span></span>
              </span>
              <button type="button" className="btn btn-secondary btn-sm" onClick={() => openDoc(x.path).catch((e) => toast(e.message, 'err'))} aria-label={`Open ${x.name}`}>
                <Icon name="eye" size={14} />Open
              </button>
            </div>
          ))}
        </div>
      )}
      {!disabled && (
        <div className="row wrap" style={{ gap: 8 }}>
          <select className="input" style={{ width: 'auto', flex: '0 1 220px' }} value={kind} onChange={(e) => setKind(e.target.value as IntakeDoc['kind'])} aria-label="Kind of document">
            {DOC_KIND.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
          <input ref={file} type="file" data-testid="intake-doc-upload" style={{ display: 'none' }} accept=".pdf,.png,.jpg,.jpeg,.webp,.heic,.doc,.docx"
            onChange={(e) => { const x = e.target.files?.[0]; if (x) void upload(x); }} />
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={() => file.current?.click()}>
            {busy ? <Spinner small /> : <Icon name="upload" size={14} />}Upload a document
          </button>
        </div>
      )}
      {err && <ErrorNote>{err}</ErrorNote>}
    </div>
  );
}

function Conflicts({ pid, h, d, partner, guard }: { pid: string; h: Home; d: IntakeDetail; partner: boolean; guard: (e: MouseEvent) => void }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [refusing, setRefusing] = useState(false);
  const closed = d.status === 'declined' || d.retain_until != null;
  async function act(kind: 'run' | 'cleared' | 'refused') {
    setBusy(kind); setErr(null);
    try {
      const r = kind === 'run' ? await rpc<IntakeDetail>('practice_conflict_run', { p_intake: d.id })
        : await rpc<IntakeDetail>('practice_conflict_decide', { p_intake: d.id, p: { outcome: kind, note: note.trim() } });
      qc.setQueryData(['practice-intake', d.id], r);
      void qc.invalidateQueries({ queryKey: ['practice-intakes', pid] });
      void qc.invalidateQueries({ queryKey: ['mandate-gate', d.id] });
      void qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      if (kind !== 'run') { setNote(''); setRefusing(false); }
      toast(kind === 'run' ? (r.conflict_status === 'hits' ? `${r.hits.length} possible ${r.hits.length === 1 ? 'conflict' : 'conflicts'} found` : 'Nothing found')
        : kind === 'cleared' ? 'Recorded: cleared' : 'Recorded: refused');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const n = d.hits.length;
  const stale = d.conflict_status === 'pending' && !!d.checked_at;
  const showHits = n > 0 && d.conflict_status !== 'pending';
  return (
    <div data-testid="intake-step-5" className="stack" style={{ gap: 16 }}>
      <div className="muted" style={{ fontSize: 14, lineHeight: 1.5 }}>
        Counta compares the business, its numbers and its people with your current and former clients, your other intakes and the people on them, and the opposing
        parties you recorded{h.practice.conflict_scan_books ? ', and with the customers and suppliers in your active clients\' books' : ''}. It never looks at another firm's records.
        {!h.practice.conflict_scan_books && <> Your clients' customers and suppliers can be included under <Link to={`/practice/${pid}/settings`}>Practice</Link>.</>}
      </div>

      <div role="status" className="stack" style={{ gap: 16 }}>
      {d.conflict_status === 'pending' && <Alert kind={stale ? 'amber' : 'grey'} icon="info">{stale ? `The intake changed after the last check (${when(d.checked_at)}). Run it again.` : 'Not checked yet.'}</Alert>}
      {d.conflict_status === 'none' && <Alert kind="green" icon="check">Nothing found. Checked {when(d.checked_at)}.</Alert>}
      {d.conflict_status === 'hits' && <Alert kind="amber" icon="alert">{n} possible {n === 1 ? 'conflict' : 'conflicts'} found {when(d.checked_at)}. {partner ? 'Look at each one, then clear or refuse the client with a note.' : 'A partner looks at each one and clears or refuses the client with a note.'}</Alert>}
      {d.conflict_status === 'cleared' && <Alert kind="green" icon="check">Cleared by {d.conflict_decided_by_name || 'a partner'} {when(d.conflict_decided_at)}: “{d.conflict_note}”</Alert>}
      {d.conflict_status === 'refused' && <Alert kind="red" icon="alert">Refused by {d.conflict_decided_by_name || 'a partner'} {when(d.conflict_decided_at)}: “{d.conflict_note}”</Alert>}
      </div>
      {!d.risk_rating && !closed && <div className="muted" style={{ fontSize: 13 }}>Rate the risk too (step 4): a client is cleared only once its risk is rated and the check is clear.</div>}

      {!closed && (
        <div>
          <button type="button" className={'btn ' + (d.conflict_status === 'pending' ? 'btn-primary' : 'btn-secondary')} data-testid="conflict-run" disabled={busy !== null} onClick={() => act('run')}>
            {busy === 'run' ? <Spinner small /> : <Icon name="search" size={14} color={d.conflict_status === 'pending' ? '#fff' : undefined} />}
            {d.checked_at ? 'Run the check again' : 'Run the conflicts check'}
          </button>
        </div>
      )}

      {showHits && (
        <div className="card" style={{ overflow: 'hidden' }}>
          {d.hits.map((x, i) => {
            const [kind, where] = HIT_KIND[x.kind];
            return (
              <div key={x.id} data-testid="conflict-hit" className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', borderTop: i ? undefined : 0, alignItems: 'start' }}>
                <span className="m-main stack" style={{ gap: 4, minWidth: 0 }}>
                  <span className="row wrap" style={{ gap: 6 }}>
                    <span className="chip t-amber">{kind}</span>
                    <span className="chip t-grey">{MATCHED[x.matched_on]}{x.matched_on === 'name' && x.score != null && Number(x.score) < 1 ? ` · ${Math.round(Number(x.score) * 100)}% alike` : ''}</span>
                  </span>
                  <span style={{ fontSize: 14 }}><b>{x.subject}</b> <span className="muted">matches</span> <b>{x.match_name || 'a record'}</b></span>
                  <span className="muted" style={{ fontSize: 12 }}>Found in {where}.</span>
                </span>
                {x.source_client_id ? <Link className="btn btn-ghost btn-sm" to={`/practice/${pid}/clients/${x.source_client_id}`} onClick={guard}>Open the client<Icon name="chevR" size={14} /></Link>
                  : x.source_intake_id ? <Link className="btn btn-ghost btn-sm" to={`/practice/${pid}/intake/${x.source_intake_id}`} onClick={guard}>Open the intake<Icon name="chevR" size={14} /></Link>
                  : <span />}
              </div>
            );
          })}
        </div>
      )}

      {d.conflict_status === 'hits' && !closed && (partner ? (
        <div className="stack" style={{ gap: 10 }}>
          <Field label="Your note" req hint={`At least 10 characters. Say why these are or are not conflicts. ${note.trim().length < 10 ? `${10 - note.trim().length} more to go.` : ''}`}>
            <textarea className="input" data-testid="conflict-note" rows={3} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
          </Field>
          {!refusing ? (
            <div className="row wrap" style={{ gap: 8 }}>
              <button type="button" className="btn btn-primary" data-testid="conflict-clear" disabled={busy !== null || note.trim().length < 10} onClick={() => act('cleared')}>
                {busy === 'cleared' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Clear: no conflict
              </button>
              {d.status === 'engaged'
                ? <span className="muted" style={{ fontSize: 13 }}>This business is already your client: to stop working for it, end the engagement from its page.</span>
                : <button type="button" className="btn btn-danger" data-testid="conflict-refuse" disabled={busy !== null || note.trim().length < 10} onClick={() => setRefusing(true)}>Refuse the client</button>}
            </div>
          ) : (
            <div className="card card-pad stack" style={{ gap: 10, borderColor: '#FECACA' }}>
              <div style={{ fontSize: 14 }}>Refusing declines this client{d.status === 'draft' ? ' and withdraws any invitation' : ''}. The intake is kept for five years and cannot be used again.</div>
              <div className="row wrap" style={{ gap: 8 }}>
                <button type="button" className="btn btn-danger" disabled={busy !== null} onClick={() => act('refused')}>{busy === 'refused' ? <Spinner small /> : null}Yes, refuse</button>
                <button type="button" className="btn btn-ghost" onClick={() => setRefusing(false)}>Keep it open</button>
              </div>
            </div>
          )}
        </div>
      ) : <div className="muted" style={{ fontSize: 13 }}>Only a partner records the outcome.</div>)}

      {err && <ErrorNote>{err}</ErrorNote>}
      {!closed && d.client_id && <OpposingParties pid={pid} clientId={d.client_id} />}
    </div>
  );
}

// The other side of the work (a dispute, a deal, a tax matter) for a business that is already a client: saved on that client,
// so later checks find them and the firm never acts for both sides. (A prospect's are recorded on its page once it is a client.)
function OpposingParties({ pid, clientId }: { pid: string; clientId: string }) {
  const c = usePracticeClient(clientId);
  return (
    <details className="card card-pad" style={{ background: 'var(--canvas)' }}>
      <summary style={{ cursor: 'pointer', fontSize: 14, fontWeight: 600, lineHeight: '20px', padding: '12px 0', margin: '-12px 0' }}>The other side of the work (optional)</summary>
      <div className="stack" style={{ gap: 10, marginTop: 10 }}>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>If you act for this client in a dispute, a deal or a tax matter with someone else, record them. Later checks will find them, so you never act for both sides.</div>
        <OpposingList pid={pid} clientId={clientId} list={c.data?.opposing_parties || []} />
      </div>
    </details>
  );
}

// A client's intake as it was before each change (ongoing due diligence), newest first: who changed it and when, and
// what it held then.
const CHECK_WORD: Record<string, string> = { pending: 'not checked since the last change', none: 'nothing found', hits: 'possible conflicts', cleared: 'cleared by a partner', refused: 'refused' };
function History({ d }: { d: IntakeDetail }) {
  const list = d.history || [];
  return (
    <section className="card" aria-labelledby="intake-history-title" data-testid="intake-history">
      <div className="card-hd"><h2 id="intake-history-title" style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>Earlier versions</h2></div>
      <div className="card-pad stack" style={{ gap: 0, paddingTop: 12 }}>
        <div className="muted" style={{ fontSize: 13, lineHeight: 1.5, marginBottom: 6 }}>The intake as it stood before each change. They are kept as long as the intake is.</div>
        {list.map((x, i) => {
          const v = x.snapshot;
          return (
            <details key={x.id} className="hist-row" data-testid="intake-history-row" style={{ borderTop: i ? '1px solid var(--row)' : undefined }}>
              <summary style={{ cursor: 'pointer', padding: '10px 0', fontSize: 14, minHeight: 44, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <b style={{ fontWeight: 600 }}>{when(x.created_at)}</b>
                <span className="muted">changed by {x.changed_by_name || 'someone no longer at the practice'}</span>
              </summary>
              <dl className="stack" style={{ gap: 4, margin: '0 0 12px', fontSize: 13, lineHeight: 1.5 }}>
                <div><dt className="faint" style={{ display: 'inline' }}>Name: </dt><dd style={{ display: 'inline', margin: 0 }}>{v.legal_name}</dd></div>
                {(v.rc_number || v.tax_id) && <div><dt className="faint" style={{ display: 'inline' }}>Numbers: </dt><dd style={{ display: 'inline', margin: 0 }}>{[v.rc_number, v.tax_id && `TIN ${v.tax_id}`].filter(Boolean).join(' · ')}</dd></div>}
                {v.address && <div><dt className="faint" style={{ display: 'inline' }}>Address: </dt><dd style={{ display: 'inline', margin: 0 }}>{v.address}</dd></div>}
                <div><dt className="faint" style={{ display: 'inline' }}>Risk: </dt><dd style={{ display: 'inline', margin: 0 }}>{v.risk_rating ? RISK_WORD[v.risk_rating] : 'not rated'}{v.risk_reason ? `, “${v.risk_reason}”` : ''}</dd></div>
                <div><dt className="faint" style={{ display: 'inline' }}>Conflicts check: </dt><dd style={{ display: 'inline', margin: 0 }}>{CHECK_WORD[v.conflict_status] || v.conflict_status}{v.checked_at ? ` (${when(v.checked_at)})` : ''}</dd></div>
                <div><dt className="faint" style={{ display: 'inline' }}>People: </dt><dd style={{ display: 'inline', margin: 0 }}>{v.people.length ? v.people.map((p) => `${p.name}${p.is_pep ? ' (politically exposed)' : ''}`).join(', ') : 'none recorded'}</dd></div>
              </dl>
            </details>
          );
        })}
      </div>
    </section>
  );
}

// The business this intake engaged: a client now, or an engagement that ended (the intake then has a retention date).
function Engaged({ pid, h, d }: { pid: string; h: Home; d: IntakeDetail }) {
  const c = h.clients.find((x) => x.id === d.client_id);
  if (d.retain_until) return (
    <Alert kind="grey" icon="history">
      The engagement with {c?.business_name || d.legal_name} ended. Its due-diligence record is kept until {fmtDay(d.retain_until)}.{' '}
      <Link to={`/practice/${pid}/clients/${d.client_id}`}>Open the client's page</Link>
    </Alert>
  );
  return (
    <Alert kind={d.dd_incomplete ? 'amber' : 'green'} icon={d.dd_incomplete ? 'alert' : 'check'}>
      {c?.business_name || d.legal_name} is your client{d.mode_requested === 'full' ? ' under full mandate' : ''}.
      {d.dd_incomplete ? ' Its due diligence is incomplete until the risk is rated and the conflicts check is clear.' : ''}{' '}
      <Link to={`/practice/${pid}/clients/${d.client_id}`}>Open the client</Link>
    </Alert>
  );
}

// What an involved client still needs before the owner is invited.
function readiness(d: IntakeDetail): string[] {
  const out: string[] = [];
  if (!d.risk_rating) out.push('Rate the risk (step 4).');
  if (d.conflict_status === 'pending') out.push('Run the conflicts check (step 5).');
  if (d.conflict_status === 'hits') out.push('A partner clears or refuses what the conflicts check found (step 5).');
  return out;
}

function Invite({ pid, d, invited }: { pid: string; d: IntakeDetail; invited: boolean }) {
  const qc = useQueryClient();
  const toast = useToast();
  const nav = useNavigate();
  const [f, setF] = useState({ email: '', name: '', billing: 'business', note: '' });
  const [services, setServices] = useState<string[]>(['bookkeeping', 'vat', 'wht', 'cit', 'statements']);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const missing = readiness(d);
  const ready = d.cleared && !missing.length;
  async function send() {
    setBusy(true); setErr(null);
    try {
      const id = await rpc<string>('practice_invite_client', { p_practice: pid, p: { ...f, services, intake_id: d.id, business_name: d.legal_name } });
      const r = await sendInvite('client', id);
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-home', pid] }), qc.invalidateQueries({ queryKey: ['practice-intakes', pid] })]);
      if (r.ok) toast(`Invitation sent to ${r.sent_to}`); else toast(`Saved, but the email did not go: ${r.error || 'try Send again from the list'}`, 'err');
      nav(`/practice/${pid}`);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  const sub = `The owner gets an email, signs in to Counta (or signs up) and connects ${d.legal_name}. Once they accept, your partners and managers get an `
    + 'accountant\'s place in its books: the books and tax returns, never moving money. Staff get one when you assign them.';
  return (
    <div className="stack" style={{ gap: 16 }}>
      {invited ? <Alert kind="blue" icon="send">The invitation is waiting for the owner. You can send it again from the client list.</Alert> : (
        <Card title="Invite the owner" sub={sub}>
          {!ready && (
            <Alert kind="amber" icon="info">
              <div>Before you invite the owner:</div>
              <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>{(missing.length ? missing : ['Run the conflicts check after your last change (step 5).']).map((m) => <li key={m}>{m}</li>)}</ul>
            </Alert>
          )}
          <div style={grid(240)}>
            <Field label="Owner's email" req>
              <input className="input" type="email" data-testid="invite-email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} disabled={!ready} autoComplete="off" />
            </Field>
            <Field label="Owner's name"><input className="input" value={f.name} maxLength={80} onChange={(e) => setF({ ...f, name: e.target.value })} disabled={!ready} /></Field>
            <Field label="Who pays for Counta">
              <select className="input" value={f.billing} onChange={(e) => setF({ ...f, billing: e.target.value })} disabled={!ready}>
                <option value="business">The business</option><option value="practice">Your practice</option>
              </select>
            </Field>
          </div>
          <fieldset style={{ border: 0, margin: 0, padding: 0, minWidth: 0 }}>
            <legend className="field-label" style={{ padding: 0 }}>What you will do for them</legend>
            <div style={{ ...grid(180), gap: 4 }}>
              {SERVICES.map(([k, l]) => (
                <label key={k} className="check">
                  <input type="checkbox" checked={services.includes(k)} disabled={!ready}
                    onChange={(e) => setServices((s) => (e.target.checked ? [...s, k] : s.filter((x) => x !== k)))} />{l}
                </label>
              ))}
            </div>
            {!services.length && <div className="err-text" role="alert">Choose at least one service.</div>}
          </fieldset>
          <Field label="A note to the owner"><textarea className="input" rows={2} maxLength={500} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} disabled={!ready} /></Field>
          {err && <ErrorNote>{err}</ErrorNote>}
          <div>
            <button type="button" className="btn btn-primary" data-testid="invite-owner" disabled={busy || !ready || !services.length || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())} onClick={send}>
              {busy ? <Spinner small /> : <Icon name="send" size={14} color="#fff" />}Send the invitation
            </button>
          </div>
        </Card>
      )}
      <LetterCard pid={pid} d={d} variant="involved" />
    </div>
  );
}

// The intake's engagement letter: where it stands, and drafting one (the letter itself is edited, signed and sent on the
// Letters page). counts: for a full mandate, whether the signed letter still counts (it was fixed after the intake's last change).
function LetterCard({ pid, d, variant, counts }: { pid: string; d: IntakeDetail; variant: IntakeMode; counts?: boolean }) {
  const qc = useQueryClient();
  const nav = useNavigate();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const { letter, signed } = latestLetter(d, variant);
  const stale = variant === 'full' && signed && counts === false;
  async function draft() {
    setBusy(true); setErr(null);
    try {
      const l = await rpc<{ id: string }>('practice_letter_draft', { p_intake: d.id, p: { variant } });
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-intake', d.id] }), qc.invalidateQueries({ queryKey: ['mandate-gate', d.id] })]);
      nav(`/practice/${pid}/letters/${l.id}`);
    } catch (e) { setErr(cleanError(e)); setBusy(false); }
  }
  return (
    <Card title={variant === 'full' ? 'Engagement letter' : 'Engagement letter (optional)'}
      sub={variant === 'full' ? 'Full mandate needs the full-mandate letter, signed by a partner for the firm and then by the client (or a copy signed outside Counta, uploaded).'
        : 'You can send the client your engagement letter to sign in Counta. A partner signs it for the firm once the conflicts check is clear.'}>
      <div className="row wrap" style={{ gap: 10, justifyContent: 'space-between' }}>
        <span className="row wrap" style={{ gap: 8, fontSize: 14, minWidth: 0 }}>
          {letter ? <span className={'chip ' + LETTER_WORD[letter.status][1]} data-testid="letter-status">{LETTER_WORD[letter.status][0]}</span>
            : <span className="chip t-grey" data-testid="letter-status">No letter yet</span>}
          <span className="muted">{!letter ? 'Draft it from your default template.'
            : letter.status === 'draft' ? 'A partner checks it and signs it for the firm, then sends it to the client.'
            : letter.status === 'partner_signed' ? 'Signed by the firm. Send it to the client to sign.'
            : letter.status === 'sent' ? 'Waiting for the client to sign.'
            : stale ? 'Signed before the intake last changed, so it no longer counts. Draft a new letter.' : 'Signed by both sides.'}</span>
        </span>
        <span className="row wrap" style={{ gap: 8 }}>
          {letter && <Link className="btn btn-secondary" data-testid="letter-open" to={`/practice/${pid}/letters/${letter.id}`}><Icon name="file" size={14} />Open the letter</Link>}
          {(!letter || stale) && (
            <button type="button" className="btn btn-primary" data-testid="letter-new" disabled={busy} onClick={draft}>
              {busy ? <Spinner small /> : <Icon name="plus" size={14} color="#fff" />}Draft the letter
            </button>
          )}
        </span>
      </div>
      {err && <ErrorNote>{err}</ErrorNote>}
    </Card>
  );
}

// "Full mandate needs: partner_verified, ..." from the database, in words.
function gateError(msg: string) {
  const m = /^Full mandate needs: (.+)$/.exec(msg);
  if (!m) return msg;
  const words: Record<string, string> = { partner_verified: 'a partner whose licence TaxStreem verified', practice_can_full: 'TaxStreem\'s permission to run full mandates',
    risk_rated: 'a risk rating', rc_or_tax_id: 'an RC, BN or IT number or a Tax ID', conflicts_cleared: 'a clear conflicts check', letter_completed: 'a signed full-mandate letter',
    authority_declared: 'a partner\'s declaration' };
  return `Full mandate still needs ${m[1].split(', ').map((k) => words[k] || k).join(', ')}.`;
}

function FullMandate({ pid, h, d }: { pid: string; h: Home; d: IntakeDetail }) {
  const g = useMandateGate(d.id);
  const qc = useQueryClient();
  const toast = useToast();
  const nav = useNavigate();
  const leads = h.members.filter((m) => m.status === 'active' && (m.role === 'partner' || m.role === 'manager'));
  const [f, setF] = useState({ email: '', phone: '', vat_registered: true, bank_details: '', alert_email: '', engagement_partner_id: leads.some((m) => m.id === h.me.id) ? h.me.id : leads[0]?.id || '',
    filing_only: false });
  const [docPath, setDocPath] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [dup, setDup] = useState(false);
  const partner = h.me.role === 'partner';
  const gate = g.data;
  const { signed } = latestLetter(d, 'full');

  async function refresh() {
    await Promise.all([qc.invalidateQueries({ queryKey: ['practice-intake', d.id] }), qc.invalidateQueries({ queryKey: ['mandate-gate', d.id] }),
      qc.invalidateQueries({ queryKey: ['practice-intakes', pid] })]);
  }
  async function declare() {
    setBusy('declare'); setErr(null);
    try {
      const r = await rpc<IntakeDetail>('practice_intake_declare', { p_intake: d.id, p: docPath ? { doc_path: docPath } : {} });
      qc.setQueryData(['practice-intake', d.id], r);
      await refresh();
      toast('Declaration recorded');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function create() {
    setBusy('create'); setErr(null); setDup(false);
    try {
      const r = await rpc<{ ok: boolean; reason?: string; org_id?: string; client_id?: string }>('practice_create_business', { p_intake: d.id, p: {
        email: f.email.trim(), phone: f.phone.trim() || null, vat_registered: f.vat_registered, bank_details: f.bank_details.trim() || null,
        alert_email: f.alert_email.trim() || null, engagement_partner_id: f.engagement_partner_id || null, filing_only: f.filing_only } });
      if (!r.ok || !r.client_id) { if (r.reason === 'duplicate') setDup(true); else setErr('The business was not set up. Try again.'); setBusy(null); return; }
      await Promise.all([qc.invalidateQueries({ queryKey: ['practice-home'] }), qc.invalidateQueries({ queryKey: ['practices-mine'] }), refresh()]);
      toast(`${d.legal_name} is set up under full mandate. Next: its identity check and a director's confirmation.`);
      nav(`/practice/${pid}/clients/${r.client_id}`);
    } catch (e) { setErr(gateError(cleanError(e))); setBusy(null); }
  }

  const licence = h.me.licence_status;
  const yourLicence = h.me.role !== 'partner' ? 'A partner whose licence TaxStreem has verified sets the business up. Ask one to finish this step.'
    : licence === 'pending' ? 'TaxStreem has not verified your licence yet. It checks licence numbers shortly after they are added.'
    : licence === 'rejected' ? 'TaxStreem could not confirm your licence number. Correct it under Practice.'
    : 'Add your licence number under Practice; TaxStreem verifies it.';
  const firmCan = h.practice.mandate_suspended_at ? 'TaxStreem has paused full mandates for your firm. Contact TaxStreem to find out more.'
    : 'Full mandate needs a partner whose licence TaxStreem has verified.';
  const item = (ok: boolean | undefined, met: ReactNode, unmet: ReactNode) => (
    <>
      <span className="wiz-mark" aria-hidden="true">{ok ? <Icon name="check" size={13} color="var(--green)" /> : <Icon name="minus" size={13} color="var(--muted)" />}</span>
      <span style={{ minWidth: 0 }}><span className="sr-only">{ok ? 'Done: ' : 'To do: '}</span>{ok ? met : unmet}</span>
    </>
  );
  const cls = (ok: boolean | undefined) => (ok ? 'met' : undefined);

  return (
    <div className="stack" style={{ gap: 16 }}>
      <Card title="What full mandate needs" sub="Each of these must hold when you set the business up. They are checked again at that moment.">
        {g.isLoading ? <SkeletonRows n={4} /> : g.isError || !gate ? <ErrorNote>{cleanError(g.error)}</ErrorNote> : (
          <ul className="wiz-gate" data-testid="mandate-gate">
            <li data-testid="gate-partner_verified" className={cls(gate.partner_verified)}>{item(gate.partner_verified, 'You are a partner, and TaxStreem has verified your licence.', yourLicence)}</li>
            <li data-testid="gate-practice_can_full" className={cls(gate.practice_can_full)}>{item(gate.practice_can_full, 'TaxStreem lets your firm run full mandates.', firmCan)}</li>
            <li data-testid="gate-risk_rated" className={cls(gate.risk_rated)}>{item(gate.risk_rated, `The risk is rated${d.risk_rating ? ` (${RISK_WORD[d.risk_rating].toLowerCase()})` : ''}.`, 'Rate the risk (step 4).')}</li>
            <li data-testid="gate-rc_or_tax_id" className={cls(gate.rc_or_tax_id)}>{item(gate.rc_or_tax_id, 'The business\'s RC, BN or IT number or its Tax ID is recorded.',
              'Add the business\'s RC, BN or IT number or its Tax ID (step 2), so Counta can tell it apart from businesses already on Counta.')}</li>
            <li data-testid="gate-conflicts_cleared" className={cls(gate.conflicts_cleared)}>{item(gate.conflicts_cleared, 'The conflicts check is clear, and was run after your last change.',
              d.risk_rating ? 'Run the conflicts check after your last change, and have a partner clear anything it finds (step 5).' : 'Rate the risk, then run the conflicts check (steps 4 and 5).')}</li>
            <li data-testid="gate-letter_completed" className={cls(gate.letter_completed)}>{item(gate.letter_completed, 'The full-mandate engagement letter is signed by the firm and the client.',
              signed ? 'The signed letter was fixed before the intake last changed, so it no longer counts. Draft a new letter for the intake as it stands.'
                : 'The full-mandate engagement letter must be signed by the firm and the client (or a signed copy uploaded), after the intake\'s last change.')}</li>
            <li data-testid="gate-authority_declared" className={cls(gate.authority_declared)}>{item(gate.authority_declared, 'A partner has declared that the firm holds the client\'s written authority.',
              'A partner declares that the firm holds the client\'s written authority (below).')}</li>
          </ul>
        )}
      </Card>

      <LetterCard pid={pid} d={d} variant="full" counts={gate?.letter_completed} />

      <Card title="Partner's declaration" sub="A partner confirms that the firm holds the client's written authority to run its books and tax affairs. It is recorded with their name and the time.">
        {d.authority_declared_at ? (
          <>
            <div className="wiz-quote" data-testid="declare-statement">{d.authority_statement}</div>
            <div className="muted" style={{ fontSize: 13 }}>Declared by {d.authority_declared_by_name || 'a partner'} {when(d.authority_declared_at)}{d.authority_doc_path ? ', with the signed authority attached' : ''}. A new name or way of working withdraws it.</div>
          </>
        ) : (
          <>
            <div className="wiz-quote" data-testid="declare-statement">{statementText(h.practice.name, d.legal_name)}</div>
            {partner ? (
              <>
                {d.docs.length > 0 && (
                  <Field label="The client's signed authority (optional)" hint="One of the documents on this intake.">
                    <select className="input" value={docPath} onChange={(e) => setDocPath(e.target.value)}>
                      <option value="">None attached</option>
                      {d.docs.map((x) => <option key={x.id} value={x.path}>{x.name}</option>)}
                    </select>
                  </Field>
                )}
                <div>
                  <button type="button" className="btn btn-primary" data-testid="declare-authority" disabled={busy !== null} onClick={declare}>
                    {busy === 'declare' ? <Spinner small /> : <Icon name="shield" size={14} color="#fff" />}I make this declaration
                  </button>
                </div>
              </>
            ) : <div className="muted" style={{ fontSize: 13 }}>Only a partner makes this declaration.</div>}
          </>
        )}
      </Card>

      <Card title="Set up the business" sub="The business is created with no owner. Your firm runs it, Counta sends the client nothing, and its documents carry no Counta branding.">
        <div style={grid(240)}>
          <Field label="The business's email address" req hint="Your firm chooses it. Counta's messages for the business go to the firm.">
            <input className="input" type="email" data-testid="create-email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} autoComplete="off" />
          </Field>
          <Field label="Phone"><input className="input" value={f.phone} maxLength={40} inputMode="tel" onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
          <Field label="Engagement partner" hint="Leads the work. Counta sends the business's alerts to them unless you give an alert address.">
            <select className="input" data-testid="create-partner" value={f.engagement_partner_id} onChange={(e) => setF({ ...f, engagement_partner_id: e.target.value })}>
              {leads.map((m) => <option key={m.id} value={m.id}>{m.display_name} ({m.role === 'partner' ? 'Partner' : 'Manager'})</option>)}
            </select>
          </Field>
          <Field label="Alert address (optional)" hint="One of your firm's addresses.">
            <input className="input" type="email" data-testid="create-alert-email" value={f.alert_email} onChange={(e) => setF({ ...f, alert_email: e.target.value })} autoComplete="off" />
          </Field>
        </div>
        <Field label="The client's bank details" hint="Shown on its invoices for customers to pay into, until a director confirms and the wallets open.">
          <textarea className="input" data-testid="create-bank-details" rows={2} maxLength={500} value={f.bank_details} onChange={(e) => setF({ ...f, bank_details: e.target.value })}
            placeholder="Bank, account name and account number" />
        </Field>
        <label className="check" style={{ alignSelf: 'flex-start' }}>
          <input type="checkbox" checked={f.vat_registered} onChange={(e) => setF({ ...f, vat_registered: e.target.checked })} />Registered for VAT
        </label>
        <label className="check" style={{ alignSelf: 'flex-start', alignItems: 'flex-start' }}>
          <input type="checkbox" data-testid="create-filing-only" checked={f.filing_only} onChange={(e) => setF({ ...f, filing_only: e.target.checked })} />
          <span>Filing only<span className="faint" style={{ display: 'block', fontSize: 12, lineHeight: 1.45 }}>The firm prepares only the yearly income tax return, for a one-time fee each year paid
            with the firm's card on the business's Filing page. Invoicing, stock, payments and the monthly returns stay off.</span></span>
        </label>
        {dup && <ErrorNote>{DUPLICATE}</ErrorNote>}
        {err && <ErrorNote>{err}</ErrorNote>}
        <div className="row wrap" style={{ gap: 10 }}>
          <button type="button" className="btn btn-primary" data-testid="create-business" disabled={busy !== null || !gate?.ok || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())} onClick={create}>
            {busy === 'create' ? <Spinner small /> : <Icon name="building" size={14} color="#fff" />}Set up the business
          </button>
          {gate && !gate.ok && <span className="muted" style={{ fontSize: 13 }}>Available once everything above is done.</span>}
        </div>
      </Card>
    </div>
  );
}
