// Onboarding: find the business on CAC (or say it is not registered), see what Counta found on CAC and the web, a few
// curated questions, an editable summary, the compliance score, the CAC document, then the dashboard. Martina can run
// all of it by voice; every step also works by tapping.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import {
  cacSearch, cacSelect, cacStatusReport, classLabel, FILING, guideLanguage, guideMark, kycAnswer, kycManual, kycSubmit, longDate, naira, OFFERING, PAY, QUESTION_LABEL, readCacDocument,
  REASONS, RECEIVE, REVENUE, TAXES, titleCase, uploadCacDocument, useCategories, useGuide, useKyc, useScore, yearsSince, type Answers, type Candidate, type Kyc, type Score,
} from '../../lib/onboard';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { Orb } from '../../guide/GuideDock';
import { useGuideTalk, type OnboardScreen } from '../../guide/GuideProvider';
import { IdentityPanel, useIdentity } from './Identity';
import { usePracticesMine } from '../../practice/api';
import '../../guide/guide.css';

const ORDER: OnboardScreen[] = ['welcome', 'find', 'found', 'questions', 'summary', 'score', 'identity', 'document', 'done'];
const NG_STATES = ['Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa', 'Benue', 'Borno', 'Cross River', 'Delta', 'Ebonyi', 'Edo', 'Ekiti', 'Enugu', 'FCT', 'Gombe',
  'Imo', 'Jigawa', 'Kaduna', 'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara', 'Lagos', 'Nasarawa', 'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau', 'Rivers', 'Sokoto', 'Taraba', 'Yobe', 'Zamfara'];

function Say({ children, live }: { children: ReactNode; live?: boolean }) {
  return (
    <div className="ob-say">
      <Orb size={40} live={live} />
      <div className="bubble">{children}</div>
    </div>
  );
}

export default function Onboard() {
  const { session, signOut, memberships, setOrgId, refreshMemberships } = useSession();
  const nav = useNavigate();
  const toast = useToast();
  const g = useGuideTalk();
  const [params, setParams] = useSearchParams();
  const guide = useGuide();
  const fresh = params.get('new') === '1';
  // An accountant with a practice and no business of their own belongs in the portal.
  const practices = usePracticesMine(!memberships.length && !fresh);
  useEffect(() => { if (!memberships.length && !fresh && practices.data?.practices.length) nav('/practice', { replace: true }); }, [practices.data, memberships.length, fresh]); // eslint-disable-line react-hooks/exhaustive-deps
  // An existing business being completed (from the checklist), else the person's own profile: the open draft, or the one
  // they submitted last.
  const target = params.get('org') || null;
  const kyc = useKyc(target);
  const k = kyc.data;
  const first = (guide.data?.first_name || (session?.user?.user_metadata as any)?.full_name?.split(' ')[0] || '').trim();
  const lang = guide.data?.language || 'en';
  const [started, setStarted] = useState(false);
  const [skippedId, setSkippedId] = useState(false);
  const identity = useIdentity(k?.status === 'submitted' ? k.org_id : null);
  const idOpen = !skippedId && ['pending', 'rejected'].includes(identity.data?.status || '') && !!identity.data?.can_check;

  const natural: OnboardScreen = useMemo(() => {
    if (!k) return 'welcome';
    if (k.status === 'submitted') return fresh ? 'find' : idOpen ? 'identity' : k.doc?.path ? 'done' : 'score';
    if (!k.source) return started || k.search?.query ? 'find' : 'welcome';
    if (k.missing.length) return Object.keys(k.answers || {}).length ? 'questions' : k.source === 'cac' ? 'found' : 'questions';
    return 'summary';
  }, [k, started, fresh, idOpen]);
  const asked = params.get('screen') as OnboardScreen | null;
  const screen: OnboardScreen = g.screen || (asked && ORDER.includes(asked) ? asked : null) || natural;
  const go = (s: OnboardScreen) => { g.setScreen(s); if (asked) { params.delete('screen'); setParams(params, { replace: true }); } window.scrollTo({ top: 0, behavior: 'smooth' }); };
  useEffect(() => () => g.setScreen(null), []); // eslint-disable-line react-hooks/exhaustive-deps
  const step = Math.max(0, ORDER.indexOf(screen));
  const orgId = k?.status === 'submitted' ? k.org_id : target;

  const live = g.status === 'live';
  const talk = (text?: boolean) => { setStarted(true); void g.start({ text }); };
  async function setLang(l: 'en' | 'pcm') { try { await guideLanguage(l); await guide.refetch(); g.notify(`The person switched the language to ${l === 'pcm' ? 'Pidgin' : 'English'}.`); } catch (e) { toast((e as Error).message, 'err'); } }

  async function sample() {
    try {
      const id = await rpc<string>('create_sample_business');
      await refreshMemberships(); setOrgId(id);
      toast('Sample business ready · Kelandellen Company Limited');
      nav('/home', { replace: true });
    } catch (e) { toast((e as Error).message, 'err'); }
  }

  return (
    <div className="ob">
      <div className="ob-top">
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22 }} />
        {screen !== 'welcome' && <div className="ob-progress" aria-label={`Step ${step} of ${ORDER.length - 1}`}><div style={{ width: `${(step / (ORDER.length - 1)) * 100}%` }} /></div>}
        <div className="row" style={{ gap: 6 }}>
          <div className="seg" role="tablist" aria-label="Language">
            <button className={lang === 'en' ? 'on' : ''} onClick={() => setLang('en')}>English</button>
            <button className={lang === 'pcm' ? 'on' : ''} onClick={() => setLang('pcm')}>Pidgin</button>
          </div>
          {screen !== 'welcome' && g.status === 'idle' && (
            <button className="btn btn-secondary btn-sm" onClick={() => talk()} title="Talk to Martina" aria-label="Talk to Martina"><Icon name="mic" size={14} /><span className="ob-talk-label">Talk</span></button>
          )}
          <button className="btn btn-ghost btn-sm" onClick={signOut} title="Sign out"><Icon name="logout" size={16} /></button>
        </div>
      </div>
      <div className="ob-main">
        <div className="ob-col">
          {!k ? <div className="row" style={{ justifyContent: 'center', padding: 60 }}><Spinner /></div>
            : screen === 'welcome' ? <Welcome first={first} lang={lang} onTalk={() => talk()} onType={() => talk(true)} onSelf={() => { setStarted(true); go('find'); }} onSample={sample} hasOrgs={memberships.length > 0} />
            : screen === 'find' ? <Find k={k} live={live} onFound={() => go('found')} onManual={() => go('questions')} />
            : screen === 'found' ? <Found k={k} live={live} onNext={() => go('questions')} onBack={() => go('find')} />
            : screen === 'questions' ? <Questions k={k} live={live} onNext={() => go('summary')} />
            : screen === 'summary' ? <Summary k={k} live={live} onEdit={() => go('questions')} onDone={(org) => { setOrgId(org); go('score'); }} />
            : screen === 'score' ? <ScoreView orgId={orgId} first={first} live={live} next={idOpen ? 'Next: confirm a director' : 'Next: your CAC document'} onNext={() => go(idOpen ? 'identity' : 'document')} />
            : screen === 'identity' ? <IdentityStep orgId={orgId} first={first} live={live} lang={lang} onNext={() => { setSkippedId(true); go('document'); }} />
            : screen === 'document' ? <Document k={k} orgId={orgId} live={live} onDone={() => go('done')} />
            : <Done first={first} orgName={k.business?.name} onGo={() => nav('/home', { replace: true })} />}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the director's NIN
function IdentityStep({ orgId, first, live, lang, onNext }: { orgId: string | null | undefined; first: string; live: boolean; lang: string; onNext: () => void }) {
  const g = useGuideTalk();
  if (!orgId) return null;
  const pcm = lang === 'pcm';
  return (
    <>
      <Say live={live}>
        {pcm ? `${first ? first + ', ' : ''}one last check before money fit move: make a director confirm im NIN. Type am for here, or call am out for me.`
          : `${first ? first + ', o' : 'O'}ne last check before money moves through Counta: a director confirms their NIN. Type it below, or read it out to me.`}
      </Say>
      <div className="ob-card stack" style={{ gap: 14 }}>
        <h2 className="ob-h2">Confirm you are a director</h2>
        <IdentityPanel orgId={orgId} live={live} askOpen={g.uploadAsk?.kind === 'nin_slip' ? g.uploadAsk.at : undefined} onDone={onNext} onSkip={onNext} />
      </div>
    </>
  );
}

// ---------------------------------------------------------------- welcome
function Welcome({ first, lang, onTalk, onType, onSelf, onSample, hasOrgs }: { first: string; lang: string; onTalk: () => void; onType: () => void; onSelf: () => void; onSample: () => void; hasOrgs: boolean }) {
  const g = useGuideTalk();
  const nav = useNavigate();
  const pcm = lang === 'pcm';
  return (
    <>
      <div className="ob-card stack" style={{ gap: 18, textAlign: 'center', alignItems: 'center', padding: '34px 22px' }}>
        <div className="ob-hero-orb"><Orb size={120} live={g.status === 'live'} /></div>
        <div>
          <h1 className="ob-h1">{pcm ? `How far${first ? ', ' + first : ''}! Na me be Martina.` : `Hi${first ? ' ' + first : ''}, I'm Martina.`}</h1>
          <div className="ob-sub" style={{ marginTop: 10, maxWidth: 520 }}>
            {pcm ? 'I go set up your business for Counta in like five minutes. I go find am for CAC, check wetin people dey talk about you online, and tell you straight where you stand with tax.'
              : "I'll set up your business in about five minutes. I'll find you on the CAC register, see what the internet knows about you, and tell you honestly where you stand with tax. No long forms."}
          </div>
        </div>
        <div className="row wrap" style={{ gap: 10, justifyContent: 'center' }}>
          <button className="btn btn-primary" onClick={onTalk} disabled={g.status === 'connecting'} style={{ padding: '13px 22px', fontSize: 16, boxShadow: 'var(--shadow-cta)' }}>
            {g.status === 'connecting' ? <Spinner small /> : <Icon name="mic" size={18} color="#fff" />}{pcm ? 'Make we talk' : "Let's talk"}
          </button>
          <button className="btn btn-secondary" onClick={onType} disabled={g.status === 'connecting'} style={{ padding: '13px 18px', fontSize: 15 }}><Icon name="chat" size={16} />{pcm ? 'I go type' : "I'd rather type"}</button>
        </div>
        <button className="btn btn-ghost btn-sm" onClick={onSelf}>{pcm ? 'Make I do am myself' : 'I’ll fill it in myself'}</button>
        {g.error && <Alert kind="amber" icon="info">{g.error}</Alert>}
        <div className="faint" style={{ fontSize: 12 }}>You can speak, type or tap at any point. Martina is an AI assistant.</div>
      </div>
      <div className="ob-card row wrap" style={{ gap: 16, borderStyle: 'dashed', borderColor: 'var(--dashed)', boxShadow: 'none' }}>
        <span style={{ width: 44, height: 44, borderRadius: 12, background: 'var(--primary-soft)', display: 'grid', placeItems: 'center' }}><Icon name="martina" size={24} color="#0072F5" /></span>
        <div className="grow" style={{ minWidth: 220 }}>
          <div style={{ fontSize: 15, fontWeight: 600 }}>Just looking around?</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.45 }}>Open a sample shop with two Lagos branches and two months of history. It stays separate from your real business.</div>
        </div>
        <button className="btn btn-secondary" onClick={onSample}>Open sample</button>
      </div>
      <div className="ob-card row wrap" style={{ gap: 16, borderStyle: 'dashed', borderColor: 'var(--dashed)', boxShadow: 'none' }} data-testid="accountant-entry">
        <span style={{ width: 44, height: 44, borderRadius: 12, background: 'var(--primary-soft)', display: 'grid', placeItems: 'center' }}><Icon name="book" size={22} color="#0072F5" /></span>
        <div className="grow" style={{ minWidth: 220 }}>
          <div style={{ fontSize: 15, fontWeight: 600 }}>{pcm ? 'You be accountant?' : 'Are you an accountant?'}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.45 }}>Look after all your clients' books and tax returns from one portal. Clients connect to you by invitation.</div>
        </div>
        <button className="btn btn-secondary" onClick={() => nav('/practice')}>Accountant portal</button>
      </div>
      {hasOrgs && <button className="btn btn-ghost" onClick={() => nav('/home')} style={{ alignSelf: 'center' }}>Back to my businesses</button>}
    </>
  );
}

// ---------------------------------------------------------------- find
function Find({ k, live, onFound, onManual }: { k: Kyc; live: boolean; onFound: () => void; onManual: () => void }) {
  const g = useGuideTalk();
  const qc = useQueryClient();
  const [q, setQ] = useState(k.search?.query || '');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [manual, setManual] = useState(false);
  const cands = k.search?.candidates || [];
  const searched = Boolean(k.search?.query);
  const put = (x: Kyc) => qc.setQueriesData({ queryKey: ['kyc'] }, (old: any) => (old && old.id === x.id ? x : old));
  async function search(e?: React.FormEvent) {
    e?.preventDefault(); setErr(null);
    if (q.trim().length < 2) { setErr('Type the business name or its RC number.'); return; }
    setBusy('search');
    try { const x = await cacSearch(q.trim()); put(x); void qc.invalidateQueries({ queryKey: ['kyc'] }); g.notify(`On screen, the person searched CAC for "${q.trim()}" and sees ${x.search.candidates.length} matches.`); }
    catch (e) { setErr((e as Error).message); } finally { setBusy(null); }
  }
  async function pick(c: Candidate) {
    setErr(null); setBusy(String(c.id));
    try {
      const r = await cacSelect(c.id); put(r.kyc); void qc.invalidateQueries({ queryKey: ['kyc'] });
      void g.insights();
      g.notify(`On screen, the person picked ${c.name} (RC ${c.rc_number}) as their business. Call web_insights before you describe what the web says.`);
      onFound();
    } catch (e) { setErr((e as Error).message); } finally { setBusy(null); }
  }
  return (
    <>
      <Say live={live}>{searched && !cands.length ? <>Nothing on CAC under <b>{k.search.query}</b>. Try another spelling, the RC number, or tell me it isn't registered yet.</>
        : cands.length ? <>Found {cands.length === 1 ? 'one' : cands.length}. Which one is yours?</>
        : <>First, let's find you on the CAC register. The business name or the RC number works. I'll do the digging.</>}</Say>
      <form className="ob-card stack" style={{ gap: 12 }} onSubmit={search}>
        <div className="row" style={{ gap: 8 }}>
          <input className="input grow" value={q} onChange={(e) => setQ(e.target.value)} placeholder="e.g. Ada Provisions Limited, or RC 1234567" aria-label="Business name or RC number" autoFocus style={{ fontSize: 16, padding: '12px 14px' }} />
          <button className="btn btn-primary" disabled={busy === 'search'}>{busy === 'search' ? <Spinner small /> : <Icon name="search" size={16} color="#fff" />}Search</button>
        </div>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        {cands.length > 0 && (
          <div className="stack" style={{ gap: 8 }}>
            {cands.map((c) => (
              <button type="button" key={String(c.id)} className="ob-tile" onClick={() => pick(c)} disabled={!!busy} style={{ opacity: c.active === false ? 0.7 : 1 }}>
                <div className="row" style={{ justifyContent: 'space-between', gap: 8 }}>
                  <b style={{ fontSize: 15 }}>{c.name}</b>
                  {busy === String(c.id) ? <Spinner small /> : <span className={'chip ' + (c.active === false ? 't-grey' : 't-green')}>{c.active === false ? 'Inactive' : 'Active'}</span>}
                </div>
                <div className="faint" style={{ fontSize: 13 }}>{[c.rc_number && `RC ${c.rc_number}`, classLabel(c.classification), [titleCase(c.city), titleCase(c.state)].filter(Boolean).join(', '),
                  c.registered_on && `since ${new Date(c.registered_on).getFullYear()}`].filter(Boolean).join(' · ')}</div>
              </button>
            ))}
          </div>
        )}
        <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setManual(!manual)}>
          <Icon name="pencil" size={14} />Not on CAC, or registration still in progress?
        </button>
        {manual && <Manual onDone={onManual} />}
      </form>
    </>
  );
}

function Manual({ onDone }: { onDone: () => void }) {
  const g = useGuideTalk();
  const qc = useQueryClient();
  const [f, setF] = useState({ name: '', kind: 'unregistered', address: '', state: 'Lagos' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setErr(null); setBusy(true);
    try { await kycManual(f); await qc.invalidateQueries({ queryKey: ['kyc'] }); g.notify(`On screen, the person said ${f.name} is ${f.kind === 'pending' ? 'still registering' : 'not on CAC'}.`); onDone(); }
    catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 10, background: 'var(--canvas)', borderRadius: 14, padding: 14 }}>
      <Field label="Business name" req><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
      <div className="ob-chips">
        {[['unregistered', 'Not registered yet'], ['pending', 'Registration in progress'], ['other', 'Something else']].map(([id, l]) => (
          <button type="button" key={id} className={'ob-chip' + (f.kind === id ? ' on' : '')} onClick={() => setF({ ...f, kind: id })}>{l}</button>
        ))}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0,2fr) minmax(0,1fr)', gap: 8 }}>
        <Field label="Address"><input className="input" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
        <Field label="State"><select className="input" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value })}>{NG_STATES.map((s) => <option key={s}>{s}</option>)}</select></Field>
      </div>
      {f.kind === 'unregistered' && <div className="hint">Worth doing soon: banks, big customers and the NRS all ask for a CAC registration. A business name costs less than you think.</div>}
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div><button type="button" className="btn btn-primary btn-sm" onClick={save} disabled={busy || !f.name.trim()}>{busy && <Spinner small />}Continue</button></div>
    </div>
  );
}

// ---------------------------------------------------------------- found
function Fact({ k, children }: { k: string; children: ReactNode }) {
  if (children == null || children === '' || (Array.isArray(children) && !children.length)) return null;
  return <div className="ob-fact"><span className="k">{k}</span><span>{children}</span></div>;
}
function Found({ k, live, onNext, onBack }: { k: Kyc; live: boolean; onNext: () => void; onBack: () => void }) {
  const g = useGuideTalk();
  const [w, setW] = useState(k.web);
  const [loading, setLoading] = useState(!k.web);
  const [more, setMore] = useState(false);
  useEffect(() => {
    if (k.web) { setW(k.web); setLoading(false); return; }
    let on = true; setLoading(true);
    g.insights().then((x) => { if (on) { setW(x); setLoading(false); } });
    return () => { on = false; };
  }, [k.web?.at, k.business?.rc_number]); // eslint-disable-line react-hooks/exhaustive-deps
  const b = k.business;
  if (!b) return <Alert kind="amber" icon="info">Pick your business first. <button className="btn btn-ghost btn-xs" onClick={onBack}>Back</button></Alert>;
  const age = yearsSince(b.registered_on);
  const obj = b.objectives || '';
  return (
    <>
      <Say live={live}>{age ? <>{titleCase(b.name)}, {age} {age === 1 ? 'year' : 'years'} on the register. I've done some reading. Here's what I know so far.</>
        : <>Got you: {titleCase(b.name)}. Here's what CAC says, and I'm checking the web too.</>}</Say>
      <div className="ob-card stack" style={{ gap: 4 }}>
        <div className="row" style={{ justifyContent: 'space-between', marginBottom: 6 }}>
          <b className="ob-h2">From the CAC register</b>
          <span className={'chip ' + (b.active === false ? 't-amber' : 't-green')}>{b.active === false ? 'Inactive on CAC' : 'Active'}</span>
        </div>
        <Fact k="Name">{b.name}</Fact>
        <Fact k="RC number">{b.rc_number}</Fact>
        <Fact k="Type">{[classLabel(b.classification), b.company_type && titleCase(b.company_type)].filter(Boolean).join(' · ')}</Fact>
        <Fact k="Registered">{longDate(b.registered_on)}</Fact>
        <Fact k="Address">{b.address && titleCase(b.address)}</Fact>
        <Fact k="What it may do">{obj && <>{more || obj.length < 180 ? obj : obj.slice(0, 180) + '…'}{obj.length >= 180 && <button className="link" onClick={() => setMore(!more)} style={{ border: 0, background: 'none', marginLeft: 6, cursor: 'pointer' }}>{more ? 'less' : 'more'}</button>}</>}</Fact>
        <Fact k="Directors">{b.directors?.length ? b.directors.map((d) => d.name + (d.chairman ? ' (chair)' : '')).join(', ') : null}</Fact>
        <Fact k="Shareholders">{b.shareholders?.length ? b.shareholders.map((s) => s.name + (s.shares ? ` · ${Number(s.shares).toLocaleString('en-NG')} shares` : '')).join('; ') : null}</Fact>
        <Fact k="Share capital">{b.share_capital ? naira(b.share_capital) : null}</Fact>
        <Fact k="Secretary">{b.secretary && titleCase(b.secretary)}</Fact>
        <Fact k="Tax ID">{b.tax_id ? <>On record{b.tin?.tax_office ? ` · ${titleCase(b.tin.tax_office)}` : ''}</> : <span style={{ color: 'var(--amber)' }}>Not found. We'll sort it.</span>}</Fact>
      </div>
      <div className="ob-card stack" style={{ gap: 10 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <b className="ob-h2">What the web says</b>
          {loading && <span className="row faint" style={{ gap: 6, fontSize: 12 }}><Spinner small />Reading about you…</span>}
        </div>
        {loading ? <div className="stack" style={{ gap: 8 }}><div className="ob-shimmer" style={{ width: '90%' }} /><div className="ob-shimmer" style={{ width: '70%' }} /><div className="ob-shimmer" style={{ width: '50%' }} /></div>
          : !w || !w.summary ? <div className="muted" style={{ fontSize: 14 }}>Not much online yet. That's fine: plenty of great businesses live on WhatsApp.</div>
          : <>
            <div style={{ fontSize: 15, lineHeight: 1.55 }}>{w.summary}</div>
            {w.sells.length > 0 && <div className="ob-chips">{w.sells.map((s) => <span key={s} className="ob-tag">{s}</span>)}</div>}
            {w.observations.length > 0 && <div className="stack" style={{ gap: 6 }}>{w.observations.map((o) => (
              <div key={o} className="row" style={{ gap: 8, alignItems: 'flex-start', fontSize: 13.5 }}><Icon name="sparkles" size={14} color="#7C3AED" /><span>{o}</span></div>))}</div>}
            <div className="row wrap" style={{ gap: 8, fontSize: 12 }}>
              {w.website && <a href={w.website} target="_blank" rel="noopener noreferrer"><Icon name="external" size={12} /> {new URL(w.website).hostname}</a>}
              {w.socials.map((s) => <a key={s.url} href={s.url} target="_blank" rel="noopener noreferrer" style={{ textTransform: 'capitalize' }}>{s.platform}</a>)}
              {w.sources.length > 0 && <span className="faint">· from {w.sources.length} web {w.sources.length === 1 ? 'source' : 'sources'}</span>}
            </div>
          </>}
      </div>
      <div className="ob-sticky">
        <button className="btn btn-secondary" onClick={onBack}>Not us</button>
        <button className="btn btn-primary" onClick={() => { g.notify('On screen, the person confirmed the business and moved to the questions.'); onNext(); }} style={{ boxShadow: 'var(--shadow-cta)' }}>That's us<Icon name="arrow" size={16} color="#fff" /></button>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- questions
function Q({ id, title, hint, done, filled, children }: { id: string; title: string; hint?: ReactNode; done: boolean; filled?: number; children: ReactNode }) {
  const [flash, setFlash] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!filled || Date.now() - filled > 4000) return;
    setFlash(true); ref.current?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    const t = window.setTimeout(() => setFlash(false), 1400);
    return () => window.clearTimeout(t);
  }, [filled]);
  return (
    <div id={'q-' + id} ref={ref} className={'ob-q' + (done ? ' done' : '') + (flash ? ' filled' : '')}>
      <div className="ob-q-hd">
        <span className="ob-q-title">{done ? <span className="ob-tick"><Icon name="check" size={12} color="#fff" sw={3} /></span> : <span style={{ width: 20, height: 20, borderRadius: 10, border: '2px solid var(--line)' }} />}{title}</span>
      </div>
      {hint && <div className="faint" style={{ fontSize: 13, marginTop: -4 }}>{hint}</div>}
      {children}
    </div>
  );
}

// Candid tips, as the answers come in.
function adviceFor(a: Answers): string[] {
  const out: string[] = [];
  const rec = a.receive_methods || [];
  if (rec.length === 1 && rec[0] === 'cash') out.push('Cash only? Transfers leave a trail that banks and lenders like. Your own Counta account number fixes that in a minute.');
  if (a.revenue_band && a.revenue_band !== 'over_100m') out.push('Up to ₦100 million a year (and not a professional services firm) makes you a small company: no companies income tax and no VAT to charge. A company still files its return every year, so we\'ll keep that easy.');
  if (a.revenue_band === 'over_100m' && a.filing?.vat && a.filing.vat !== 'always') out.push('Above ₦100 million, VAT is not optional: a return every month by the 21st, even when it\'s nil. Counta builds it from your sales and bills.');
  if (a.filing?.wht === 'never' && (a.pay_methods || []).length) out.push('If you pay for services, rent or contracts, withholding tax is usually due. Counta works it out on each bill so you never guess.');
  if (a.filing?.cit === 'never' && a.revenue_band) out.push('Missed CIT returns attract penalties, even when no tax is due. Counta puts your return together from the books.');
  if ((a.reasons || []).includes('loans')) out.push('Lenders want 6 to 12 months of clean books and bank records. Starting today is the right move.');
  return out.slice(0, 2);
}

function Questions({ k, live, onNext }: { k: Kyc; live: boolean; onNext: () => void }) {
  const g = useGuideTalk();
  const qc = useQueryClient();
  const cats = useCategories();
  const [a, setA] = useState<Answers>(k.answers || {});
  const [err, setErr] = useState<string | null>(null);
  const [all, setAll] = useState(false);
  const [tag, setTag] = useState('');
  const [note, setNote] = useState(k.answers?.reason_note || '');
  useEffect(() => { setA(k.answers || {}); }, [k.updated_at]); // eslint-disable-line react-hooks/exhaustive-deps
  const w = k.web;
  async function save(p: Partial<Answers>, say?: string) {
    setErr(null);
    setA((x) => ({ ...x, ...p, ...(p.filing ? { filing: { ...(x.filing || {}), ...p.filing } } : {}) }));
    try {
      const x = await kycAnswer(p);
      qc.setQueriesData({ queryKey: ['kyc'] }, (old: any) => (old && old.id === x.id ? x : old));
      if (say) g.notify(`On screen, the person answered ${say}.`);
    } catch (e) { setErr((e as Error).message); }
  }
  const toggle = (key: 'receive_methods' | 'pay_methods' | 'reasons', id: string) => {
    const cur = a[key] || [];
    const next = cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id];
    void save({ [key]: next }, `${key.replace('_', ' ')}: ${next.join(', ') || 'none'}`);
  };
  const missing = k.missing;
  const list = cats.data || [];
  const fit = list.filter((c) => !a.offering || a.offering === 'both' || c.kind === a.offering || c.kind === 'both');
  const suggested = w?.category_guess || null;
  const shown = (all ? fit : fit.slice(0, 10)).sort((x, y) => Number(y.id === suggested) - Number(x.id === suggested));
  if (a.category && !shown.some((c) => c.id === a.category)) { const c = list.find((x) => x.id === a.category); if (c) shown.unshift(c); }
  const f = g.filled;
  const tips = adviceFor(a);
  const left = missing.length;
  return (
    <>
      <Say live={live}>{left === 0 ? <>That's everything. Let's check the summary.</>
        : left > 8 ? <>Quick ones now, so Counta fits how you actually work. Tap, type, or just tell me.</>
        : <>{left} to go. You're flying.</>}</Say>
      <div className="ob-card stack" style={{ gap: 12 }}>
        <Q id="offering" title="Do you sell goods, services or both?" done={!!a.offering} filled={f.offering}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0,1fr))', gap: 8 }}>
            {OFFERING.map((o) => (
              <button key={o.id} className={'ob-tile' + (a.offering === o.id ? ' on' : '')} onClick={() => save({ offering: o.id }, `offering: ${o.id}`)}>
                <b>{o.label}</b><span className="faint" style={{ fontSize: 12 }}>{o.hint}</span>
                {w?.offering_guess === o.id && !a.offering && <span className="chip t-purple" style={{ alignSelf: 'flex-start', marginTop: 4 }}>Martina's guess</span>}
              </button>
            ))}
          </div>
        </Q>
        <Q id="category" title="Which of these fits you best?" hint={suggested && list.find((c) => c.id === suggested) ? <>From what I read, I'd say <b>{list.find((c) => c.id === suggested)!.label}</b>.</> : undefined} done={!!a.category} filled={f.category}>
          <div className="ob-chips">
            {shown.map((c) => (
              <button key={c.id} className={'ob-chip' + (a.category === c.id ? ' on' : '')} onClick={() => save({ category: c.id }, `category: ${c.label}`)}>
                {c.label}{c.id === suggested && a.category !== c.id && <span className="sug">pick</span>}
              </button>
            ))}
            {fit.length > 10 && <button className="ob-chip" onClick={() => setAll(!all)} style={{ borderStyle: 'dashed' }}>{all ? 'Fewer' : `More (${fit.length - 10})`}</button>}
          </div>
        </Q>
        <Q id="revenue_band" title="Roughly how much do you sell in a year?" hint="A band is fine. It decides which taxes apply to you." done={!!a.revenue_band} filled={f.revenue_band}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 8 }}>
            {REVENUE.map((r) => (
              <button key={r.id} className={'ob-tile' + (a.revenue_band === r.id ? ' on' : '')} onClick={() => save({ revenue_band: r.id }, `yearly sales: ${r.label}`)}>
                <b>{r.label}</b><span className="faint" style={{ fontSize: 12 }}>{r.hint}</span>
              </button>
            ))}
          </div>
        </Q>
        <Q id="receive_methods" title="How do customers pay you today?" hint="Pick all that apply." done={!!a.receive_methods?.length} filled={f.receive_methods}>
          <div className="ob-chips">{RECEIVE.map((m) => <button key={m.id} className={'ob-chip' + (a.receive_methods?.includes(m.id) ? ' on' : '')} onClick={() => toggle('receive_methods', m.id)}>{m.label}</button>)}</div>
        </Q>
        <Q id="pay_methods" title="And how do you pay suppliers and bills?" done={!!a.pay_methods?.length} filled={f.pay_methods}>
          <div className="ob-chips">{PAY.map((m) => <button key={m.id} className={'ob-chip' + (a.pay_methods?.includes(m.id) ? ' on' : '')} onClick={() => toggle('pay_methods', m.id)}>{m.label}</button>)}</div>
        </Q>
        <Q id="reasons" title="What do you want Counta to do for you?" done={!!a.reasons?.length || !!a.reason_note} filled={f.reasons || f.reason_note}>
          <div className="ob-chips">{REASONS.map((m) => <button key={m.id} className={'ob-chip' + (a.reasons?.includes(m.id) ? ' on' : '')} onClick={() => toggle('reasons', m.id)}>{m.label}</button>)}</div>
          <input className="input input-sm" value={note} onChange={(e) => setNote(e.target.value)} onBlur={() => note !== (a.reason_note || '') && save({ reason_note: note }, `their reason: ${note}`)}
            placeholder="Anything else, in your own words (optional)" aria-label="Your reason in your own words" />
        </Q>
        <Q id="examples" title="Name a few things you sell" hint="Three or more helps Counta set up your items and VAT." done={!!a.examples?.length} filled={f.examples}>
          <div className="ob-tags" onClick={(e) => (e.currentTarget.querySelector('input') as HTMLInputElement)?.focus()}>
            {(a.examples || []).map((x) => (
              <span key={x} className="ob-tag">{x}<button aria-label={`Remove ${x}`} onClick={() => save({ examples: (a.examples || []).filter((y) => y !== x) })} style={{ border: 0, background: 'none', cursor: 'pointer', padding: 0 }}><Icon name="x" size={12} /></button></span>
            ))}
            <input value={tag} onChange={(e) => setTag(e.target.value)} placeholder={(a.examples || []).length ? 'Add another…' : 'e.g. Peak Milk, haircuts, logo design'}
              onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ',') && tag.trim()) { e.preventDefault(); void save({ examples: [...(a.examples || []), tag.trim()] }, `an example: ${tag.trim()}`); setTag(''); } }}
              onBlur={() => { if (tag.trim()) { void save({ examples: [...(a.examples || []), tag.trim()] }); setTag(''); } }} aria-label="Something you sell" />
          </div>
          {w?.sells?.filter((s) => !(a.examples || []).includes(s)).length ? (
            <div className="row wrap" style={{ gap: 6, fontSize: 12 }}><span className="faint">Seen online:</span>
              {w.sells.filter((s) => !(a.examples || []).includes(s)).map((s) => <button key={s} className="ob-chip" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => save({ examples: [...(a.examples || []), s] })}><Icon name="plus" size={11} />{s}</button>)}
            </div>) : null}
        </Q>
        {TAXES.map((t) => (
          <Q key={t.id} id={'filing_' + t.id} title={t.q} hint={t.hint} done={!!a.filing?.[t.id]} filled={f['filing_' + t.id]}>
            <div className="ob-chips">{FILING.map((o) => (
              <button key={o.id} className={'ob-chip' + (a.filing?.[t.id] === o.id ? ' on' : '')} onClick={() => save({ filing: { [t.id]: o.id } }, `${t.label}: ${o.label}`)}>{o.label}</button>
            ))}</div>
          </Q>
        ))}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      {tips.length > 0 && (
        <div className="ob-card stack" style={{ gap: 8, background: 'linear-gradient(135deg,#F5F3FF,#fff)' }}>
          <b className="row" style={{ gap: 8 }}><Icon name="martina" size={16} color="#0072F5" />Martina's two cents</b>
          {tips.map((t) => <div key={t} style={{ fontSize: 14, lineHeight: 1.5 }}>{t}</div>)}
        </div>
      )}
      <div className="ob-sticky">
        <button className="btn btn-primary" disabled={left > 0} onClick={() => { g.notify('On screen, the person finished the questions and opened the summary.'); onNext(); }} style={{ boxShadow: 'var(--shadow-cta)' }}>
          {left ? `${left} to go` : 'See the summary'}<Icon name="arrow" size={16} color="#fff" />
        </button>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- summary
function Summary({ k, live, onEdit, onDone }: { k: Kyc; live: boolean; onEdit: () => void; onDone: (org: string) => void }) {
  const { session, refreshMemberships } = useSession();
  const g = useGuideTalk();
  const qc = useQueryClient();
  const meta = (session?.user?.user_metadata || {}) as any;
  const b = k.business;
  const [f, setF] = useState({ trading_name: titleCase(b?.name), phone: meta.phone || '', email: b?.email?.toLowerCase() || session?.user?.email || '', address: titleCase(b?.address) });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const a = k.answers || {};
  const lbl = (list: readonly { id: string; label: string }[], ids?: string[] | string) => (Array.isArray(ids) ? ids : ids ? [ids] : []).map((i) => list.find((x) => x.id === i)?.label || i).join(', ');
  const rows: [string, string, string][] = [
    ['offering', QUESTION_LABEL.offering, lbl(OFFERING, a.offering)],
    ['category', QUESTION_LABEL.category, k.category?.label || ''],
    ['revenue_band', QUESTION_LABEL.revenue_band, lbl(REVENUE, a.revenue_band)],
    ['receive_methods', QUESTION_LABEL.receive_methods, lbl(RECEIVE, a.receive_methods)],
    ['pay_methods', QUESTION_LABEL.pay_methods, lbl(PAY, a.pay_methods)],
    ['reasons', QUESTION_LABEL.reasons, [lbl(REASONS, a.reasons), a.reason_note].filter(Boolean).join('. ')],
    ['examples', QUESTION_LABEL.examples, (a.examples || []).join(', ')],
    ...TAXES.map((t) => ['filing_' + t.id, t.label, lbl(FILING, a.filing?.[t.id])] as [string, string, string]),
  ];
  async function submit() {
    setErr(null); setBusy(true);
    try {
      const r = await kycSubmit({ trading_name: f.trading_name, phone: f.phone || undefined, email: f.email || undefined, address: f.address || undefined });
      await refreshMemberships();
      qc.setQueryData(['compliance', r.org_id], r.compliance);
      void qc.invalidateQueries({ queryKey: ['kyc'] }); void qc.invalidateQueries({ queryKey: ['guide'] });
      g.celebrate();
      g.notify(`On screen, the person submitted the profile. ${r.name} is set up with a compliance score of ${r.compliance.score} out of ${r.compliance.total}. Call get_score and talk them through it.`);
      void guideMark('score_seen').catch(() => null);
      onDone(r.org_id);
    } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  }
  const jump = (id: string) => { onEdit(); window.setTimeout(() => document.getElementById('q-' + id)?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 250); };
  return (
    <>
      <Say live={live}>Here's everything in one place. Fix anything that looks off, then I'll set up {titleCase(b?.name) || 'the business'}.</Say>
      <div className="ob-card stack" style={{ gap: 12 }}>
        <b className="ob-h2">The business</b>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 10 }}>
          <Field label="Name customers see" hint={b?.rc_number ? `Registered as ${b.name}` : undefined}><input className="input" value={f.trading_name} onChange={(e) => setF({ ...f, trading_name: e.target.value })} /></Field>
          <Field label="Business phone"><input className="input" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} placeholder="0803 123 4567" inputMode="tel" /></Field>
          <Field label="Business email"><input className="input" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} inputMode="email" /></Field>
          <Field label="Address"><input className="input" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
        </div>
      </div>
      <div className="ob-card" style={{ padding: '10px 22px' }}>
        {rows.map(([id, l, v]) => (
          <div key={id} className="ob-fact" style={{ gridTemplateColumns: '170px minmax(0,1fr) auto', alignItems: 'center' }}>
            <span className="k">{l}</span><span>{v || <span style={{ color: 'var(--red)' }}>Not answered</span>}</span>
            <button className="btn btn-ghost btn-xs" onClick={() => jump(id)}>Change</button>
          </div>
        ))}
      </div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div className="ob-sticky">
        <button className="btn btn-secondary" onClick={onEdit}>Back</button>
        <button className="btn btn-primary" onClick={submit} disabled={busy || k.missing.length > 0 || !f.trading_name.trim()} style={{ boxShadow: 'var(--shadow-cta)' }}>
          {busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}Set up my business
        </button>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- score
const ACTION_ROUTE: Record<string, string> = { settings: '/settings', vat: '/tax/vat', wht: '/tax/wht', cit: '/tax/cit', account_number: '/home', bank: '/accounting/banking', first_sale: '/sell/till' };
function Ring({ score, total }: { score: number; total: number }) {
  const [n, setN] = useState(0);
  useEffect(() => {
    let i = 0; const t = window.setInterval(() => { i += 1; setN(Math.min(score, i)); if (i >= score) window.clearInterval(t); }, 110);
    return () => window.clearInterval(t);
  }, [score]);
  const r = 70, c = 2 * Math.PI * r, pct = total ? n / total : 0;
  const col = score >= 8 ? '#16A34A' : score >= 5 ? '#0072F5' : '#F59E0B';
  return (
    <div className="ob-score">
      <svg viewBox="0 0 168 168" width="100%" height="100%"><circle cx="84" cy="84" r={r} fill="none" stroke="#EEF2F7" strokeWidth="14" />
        <circle cx="84" cy="84" r={r} fill="none" stroke={col} strokeWidth="14" strokeLinecap="round" strokeDasharray={c} strokeDashoffset={c * (1 - pct)} style={{ transition: 'stroke-dashoffset .12s linear' }} /></svg>
      <div className="n"><div><div style={{ fontSize: 44, fontWeight: 700, lineHeight: 1, color: col }}>{n}<span style={{ fontSize: 20, color: 'var(--placeholder)' }}>/{total}</span></div>
        <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>compliance</div></div></div>
    </div>
  );
}
function ScoreView({ orgId, first, live, next, onNext }: { orgId: string | null | undefined; first: string; live: boolean; next: string; onNext: () => void }) {
  const nav = useNavigate();
  const sc = useScore(orgId);
  const s: Score | undefined = sc.data;
  if (!s) return <div className="row" style={{ justifyContent: 'center', padding: 60 }}><Spinner /></div>;
  const mood = s.score >= 10 ? 'A perfect ten. Honestly, I\'m impressed.' : s.score >= 7 ? "You're ahead of most businesses I meet. A few tweaks and you're spotless."
    : s.score >= 4 ? 'A solid start. The gaps are the usual ones, and Counta closes most of them for you.' : "Plenty to fix, and that's exactly why you're here. None of it is hard with Counta doing the heavy lifting.";
  const todo = s.items.filter((i) => !i.ok), done = s.items.filter((i) => i.ok);
  return (
    <>
      <Say live={live}>{first ? `${first}, ` : ''}here's where you stand. No judgement, just a plan.</Say>
      <div className="ob-card row wrap" style={{ gap: 22, alignItems: 'center' }}>
        <Ring score={s.score} total={s.total} />
        <div className="grow" style={{ minWidth: 220 }}>
          <div className="ob-h2" style={{ fontSize: 20 }}>{s.score} out of {s.total}</div>
          <div className="ob-sub" style={{ marginTop: 6 }}>{mood}</div>
          {s.next && <div className="row" style={{ gap: 8, marginTop: 12, fontSize: 14 }}><Icon name="zap" size={16} color="#F59E0B" /><span><b>Do this first:</b> {s.next.label}</span></div>}
        </div>
      </div>
      {todo.length > 0 && (
        <div className="ob-card" style={{ padding: '6px 22px' }}>
          <div style={{ padding: '12px 0 4px' }}><b className="ob-h2">What to do next</b></div>
          {todo.map((i) => (
            <div key={i.id} className="ob-item">
              <span className="ob-mark" style={{ background: 'var(--amber-bg)' }}><Icon name="alert" size={13} color="#A16207" /></span>
              <div><b style={{ fontSize: 14 }}>{i.label}</b><div className="muted" style={{ fontSize: 13.5, lineHeight: 1.5, marginTop: 2 }}>{i.text}</div></div>
              {i.action === 'cac_document' ? <button className="btn btn-secondary btn-xs" onClick={onNext}>Add it</button>
                : i.action && ACTION_ROUTE[i.action] ? <button className="btn btn-ghost btn-xs" onClick={() => nav(ACTION_ROUTE[i.action!])}>Open</button> : <span />}
            </div>
          ))}
        </div>
      )}
      {done.length > 0 && (
        <div className="ob-card" style={{ padding: '6px 22px' }}>
          <div style={{ padding: '12px 0 4px' }}><b className="ob-h2">Already sorted</b></div>
          {done.map((i) => (
            <div key={i.id} className="ob-item">
              <span className="ob-mark" style={{ background: 'var(--green-bg)' }}><Icon name="check" size={13} color="#15803D" sw={3} /></span>
              <div><b style={{ fontSize: 14 }}>{i.label}</b><div className="muted" style={{ fontSize: 13.5, marginTop: 2 }}>{i.text}</div></div><span />
            </div>
          ))}
        </div>
      )}
      <div className="ob-sticky"><button className="btn btn-primary" onClick={onNext} style={{ boxShadow: 'var(--shadow-cta)' }}>{next}<Icon name="arrow" size={16} color="#fff" /></button></div>
    </>
  );
}

// ---------------------------------------------------------------- the CAC document
function Document({ k, orgId, live, onDone }: { k: Kyc; orgId: string | null | undefined; live: boolean; onDone: () => void }) {
  const g = useGuideTalk();
  const qc = useQueryClient();
  const [kind, setKind] = useState(g.uploadAsk?.kind || (k.business?.cac_id ? 'status_report' : 'application'));
  const [busy, setBusy] = useState<'fetch' | 'upload' | 'read' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [checks, setChecks] = useState(k.doc?.checks || null);
  const file = useRef<HTMLInputElement>(null);
  useEffect(() => { if (g.uploadAsk) { setKind(g.uploadAsk.kind); file.current?.focus(); } }, [g.uploadAsk?.at]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setChecks(k.doc?.checks || null); }, [k.doc?.at, k.doc?.read]); // eslint-disable-line react-hooks/exhaustive-deps
  async function read() {
    if (!orgId) return;
    setBusy('read');
    try { const r = await readCacDocument(orgId); setChecks(r.checks); g.notify(`On screen, Counta read the CAC document: ${r.checks.map((c) => c.note).join(' ')}`); }
    catch (e) { setErr((e as Error).message); }
    finally { setBusy(null); void qc.invalidateQueries({ queryKey: ['kyc'] }); void qc.invalidateQueries({ queryKey: ['compliance'] }); void qc.invalidateQueries({ queryKey: ['guide'] }); }
  }
  async function fetchIt() {
    if (!orgId) return;
    setErr(null); setBusy('fetch');
    try { await cacStatusReport(orgId); g.celebrate(); await read(); } catch (e) { setErr((e as Error).message); setBusy(null); }
  }
  async function upload(f: File) {
    if (!orgId) return;
    setErr(null); setBusy('upload');
    try { await uploadCacDocument(orgId, f, kind); await read(); } catch (e) { setErr((e as Error).message); setBusy(null); }
  }
  async function skip() { await guideMark('skip_cac_document').catch(() => null); void qc.invalidateQueries({ queryKey: ['guide'] }); onDone(); }
  const has = Boolean(k.doc?.path);
  return (
    <>
      <Say live={live}>{has ? <>Got it, {k.doc!.file_name}. {checks?.every((c) => c.ok) ? 'Everything matches. Lovely.' : checks ? 'A couple of things to look at below.' : 'Reading it now…'}</>
        : <>Last bit of paperwork: your latest CAC status report{k.business?.classification === 'COMPANY' ? ', or the application for registration if the company is new' : ''}. {k.business?.cac_id ? 'I can fetch it from CAC for you.' : 'Upload a PDF or a clear photo.'}</>}</Say>
      <div className="ob-card stack" style={{ gap: 14 }}>
        {k.business?.cac_id && (
          <button className="ob-tile" onClick={fetchIt} disabled={!!busy} style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
            <span style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--primary-soft)', display: 'grid', placeItems: 'center' }}>{busy === 'fetch' ? <Spinner small /> : <Icon name="download" size={18} color="#0072F5" />}</span>
            <span className="grow"><b>Fetch it from CAC for me</b><span className="faint" style={{ display: 'block', fontSize: 13 }}>The latest status report, straight from the register.</span></span>
          </button>
        )}
        <div className="stack" style={{ gap: 8 }}>
          <div className="ob-chips">
            {[['status_report', 'Status report'], ['application', 'Application for registration'], ['certificate', 'Certificate'], ['other', 'Another CAC document']].map(([id, l]) => (
              <button key={id} className={'ob-chip' + (kind === id ? ' on' : '')} onClick={() => setKind(id)}>{l}</button>
            ))}
          </div>
          <label className={'ob-tile' + (g.uploadAsk ? ' on' : '')} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, cursor: busy ? 'wait' : 'pointer' }}>
            <span style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--row)', display: 'grid', placeItems: 'center' }}>{busy === 'upload' ? <Spinner small /> : <Icon name="upload" size={18} />}</span>
            <span className="grow"><b>Choose file</b><span className="faint" style={{ display: 'block', fontSize: 13 }}>PDF, JPG or PNG, up to 15 MB. Only you (the owner) can see it.</span></span>
            <input ref={file} type="file" accept="application/pdf,image/jpeg,image/png,image/webp" style={{ position: 'absolute', opacity: 0, width: 1, height: 1 }}
              onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); e.target.value = ''; }} disabled={!!busy} aria-label="Choose the CAC document" />
          </label>
        </div>
        {busy === 'read' && <div className="row" style={{ gap: 8, fontSize: 14 }}><Spinner small />Reading the document…</div>}
        {checks && (
          <div className="stack" style={{ gap: 6 }}>
            {checks.map((c) => (
              <div key={c.id} className="row" style={{ gap: 8, alignItems: 'flex-start', fontSize: 14 }}>
                <span className="ob-mark" style={{ background: c.ok ? 'var(--green-bg)' : 'var(--amber-bg)', width: 20, height: 20 }}><Icon name={c.ok ? 'check' : 'alert'} size={11} color={c.ok ? '#15803D' : '#A16207'} /></span>{c.note}
              </div>
            ))}
            {k.doc?.extract?.share_capital ? <div className="faint" style={{ fontSize: 13 }}>Share capital on the document: {naira(k.doc.extract.share_capital)}</div> : null}
          </div>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="ob-sticky">
        {!has && <button className="btn btn-secondary" onClick={skip}>Later</button>}
        <button className="btn btn-primary" onClick={onDone} disabled={!has || !!busy} style={{ boxShadow: 'var(--shadow-cta)' }}>Into Counta<Icon name="arrow" size={16} color="#fff" /></button>
      </div>
    </>
  );
}

// ---------------------------------------------------------------- done
function Done({ first, orgName, onGo }: { first: string; orgName?: string; onGo: () => void }) {
  const g = useGuideTalk();
  useEffect(() => { g.celebrate(); g.notify('On screen, the profile part is done and the person is going into the dashboard. Guide the first steps there.'); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div className="ob-card stack" style={{ gap: 16, alignItems: 'center', textAlign: 'center', padding: '36px 22px' }}>
      <Orb size={96} live={g.status === 'live'} />
      <h1 className="ob-h1">You're in{first ? `, ${first}` : ''}.</h1>
      <div className="ob-sub" style={{ maxWidth: 480 }}>{titleCase(orgName) || 'Your business'} is set up. Next, I'll get you your own account number, pick the voice that announces your payments, and record your first sale. Ten minutes, tops.</div>
      <button className="btn btn-primary" onClick={onGo} style={{ padding: '13px 22px', fontSize: 16, boxShadow: 'var(--shadow-cta)' }}>Go to my dashboard<Icon name="arrow" size={16} color="#fff" /></button>
    </div>
  );
}
