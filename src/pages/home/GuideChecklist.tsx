// The first things to do in Counta, on Home for the owner until they are done: each step checked by the database from
// what really happened, with Martina a tap away and an optional call if they get stuck.
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { guideConsent, guideMark, openWallet, STEP_TEXT, useGuide, type GuideStep } from '../../lib/onboard';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';
import { Orb } from '../../guide/GuideDock';
import { useGuideTalk } from '../../guide/GuideProvider';
import '../../guide/guide.css';

const ICON: Record<string, string> = { find_business: 'search', questions: 'chat', submitted: 'check', cac_document: 'file', account_number: 'landmark', voice: 'volume',
  first_sale: 'receipt', bank_connect: 'link', bank_statement: 'upload', products: 'package', team: 'users' };

export function GuideChecklist() {
  const { data: inv } = useInventory();
  const { orgId, session } = useSession();
  const g = useGuideTalk();
  const nav = useNavigate();
  const qc = useQueryClient();
  const toast = useToast();
  const guide = useGuide(Boolean(orgId), orgId);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [phone, setPhone] = useState<string>(() => (session?.user?.user_metadata as any)?.phone || '');
  const [askCall, setAskCall] = useState(false);
  const [showDone, setShowDone] = useState(false);
  const gs = guide.data;
  if (!inv || inv.me.role !== 'owner' || inv.org.is_sample || !gs || gs.completed || gs.dismissed || gs.org?.id !== orgId) return null;
  const refresh = () => { void qc.invalidateQueries({ queryKey: ['guide'] }); void qc.invalidateQueries({ queryKey: ['compliance'] }); };
  const pct = Math.round((gs.done / Math.max(1, gs.total)) * 100);
  const steps = gs.steps;

  async function act(s: GuideStep) {
    setErr(null);
    const t = STEP_TEXT[s.id];
    if (s.phase === 'profile') { nav(`/onboarding?org=${orgId}${s.id === 'cac_document' ? '&screen=document' : ''}`); return; }
    if (s.id === 'voice') { g.setVoicePicker(true); return; }
    if (s.id === 'account_number') {
      setBusy(s.id);
      try {
        const w = await openWallet(orgId!);
        g.setWallet(w); refresh();
        if (w.status === 'active') { g.celebrate(); g.notify(`On screen, the business account number was created: ${w.account_number} at ${w.bank_name}.`); }
        else toast('The bank is still opening the account. It shows here as soon as it is ready.');
      } catch (e) { setErr((e as Error).message); } finally { setBusy(null); }
      return;
    }
    if (t?.to) nav(t.to);
  }
  async function skip(s: GuideStep) { setBusy('skip_' + s.id); try { await guideMark('skip_' + s.id); refresh(); } catch (e) { setErr((e as Error).message); } finally { setBusy(null); } }
  async function hide() { await guideMark('dismissed').catch(() => null); refresh(); toast('Checklist hidden. Ask Martina any time to bring it back.'); }
  async function consent(on: boolean) {
    setErr(null); setBusy('call');
    try { await guideConsent(on, phone); refresh(); setAskCall(false); toast(on ? 'Martina will call once if you get stuck' : 'No calls'); } catch (e) { setErr((e as Error).message); } finally { setBusy(null); }
  }
  const w = g.wallet;
  return (
    <div className="card" style={{ overflow: 'hidden', borderColor: 'var(--primary-line)' }}>
      <div className="row wrap" style={{ gap: 14, padding: '16px 18px', background: 'linear-gradient(120deg,#F0F7FF,#fff 70%)' }}>
        <Orb size={46} live={g.status === 'live'} />
        <div className="grow" style={{ minWidth: 200 }}>
          <b style={{ fontSize: 16 }}>{gs.done < 5 ? "Let's get you running" : gs.done < gs.total - 1 ? 'Nearly there' : 'One more and you\'re done'}</b>
          <div className="row" style={{ gap: 10, marginTop: 6 }}>
            <div className="ob-progress" style={{ maxWidth: 220 }}><div style={{ width: pct + '%' }} /></div>
            <span className="faint" style={{ fontSize: 12 }}>{gs.done} of {gs.total}</span>
          </div>
        </div>
        <div className="row" style={{ gap: 6 }}>
          {g.status === 'idle' && <button className="btn btn-primary btn-sm" onClick={() => g.start()}><Icon name="mic" size={14} color="#fff" />Talk to Martina</button>}
          <button className="btn btn-ghost btn-sm" onClick={hide} title="Hide the checklist">Hide</button>
        </div>
      </div>
      {w?.status === 'active' && (
        <div className="row wrap" style={{ gap: 14, padding: '14px 18px', borderTop: '1px solid var(--row)', background: '#F7FFFA' }}>
          <Icon name="landmark" size={22} color="#15803D" />
          <div className="grow">
            <div className="faint" style={{ fontSize: 12 }}>Your business account · {w.bank_name}</div>
            <div className="ob-acct">{w.account_number}</div>
            <div className="muted" style={{ fontSize: 13 }}>{w.account_name}</div>
          </div>
          <button className="btn btn-secondary btn-sm" onClick={() => { void navigator.clipboard?.writeText(w.account_number || ''); toast('Copied'); }}><Icon name="copy" size={14} />Copy</button>
        </div>
      )}
      {steps.filter((s) => showDone || !(s.done || s.skipped)).map((s) => {
        const t = STEP_TEXT[s.id];
        const isNext = gs.next === s.id;
        const finished = s.done || s.skipped;
        return (
          <div key={s.id} className={'ob-check' + (isNext ? ' next' : '')} style={{ opacity: finished ? 0.62 : 1 }}>
            <span className="ob-mark" style={{ width: 28, height: 28, borderRadius: 14, background: s.done ? '#22C55E' : finished ? 'var(--row)' : isNext ? 'var(--primary-soft)' : 'var(--row)' }}>
              <Icon name={s.done ? 'check' : ICON[s.id] || 'check'} size={14} color={s.done ? '#fff' : isNext ? '#0072F5' : '#6B7280'} sw={s.done ? 3 : undefined} />
            </span>
            <div style={{ minWidth: 0 }}>
              <b style={{ fontSize: 14, textDecoration: s.done ? 'line-through' : undefined }}>{t?.title || s.id}</b>{s.optional && !finished && <span className="faint" style={{ fontSize: 12 }}> · optional</span>}
              {!finished && <div className="faint" style={{ fontSize: 12.5, marginTop: 2 }}>{t?.body}</div>}
            </div>
            {finished ? <span className="faint" style={{ fontSize: 12 }}>{s.done ? 'Done' : 'Skipped'}</span> : (
              <span className="row" style={{ gap: 4 }}>
                {s.optional && <button className="btn btn-ghost btn-xs" onClick={() => skip(s)} disabled={!!busy}>Skip</button>}
                <button className={'btn btn-xs ' + (isNext ? 'btn-primary' : 'btn-secondary')} onClick={() => act(s)} disabled={!!busy}>{busy === s.id && <Spinner small />}{t?.cta || 'Open'}</button>
              </span>
            )}
          </div>
        );
      })}
      {steps.some((s) => s.done || s.skipped) && (
        <div style={{ padding: '6px 18px', borderTop: '1px solid var(--row)' }}>
          <button className="btn btn-ghost btn-xs" onClick={() => setShowDone(!showDone)}>
            <Icon name="check" size={12} />{showDone ? 'Hide finished steps' : `${steps.filter((s) => s.done || s.skipped).length} finished`}
          </button>
        </div>
      )}
      {err && <div style={{ padding: '0 18px 12px' }}><Alert kind="red" icon="alert">{err}</Alert></div>}
      <div className="row wrap" style={{ gap: 10, padding: '12px 18px', borderTop: '1px solid var(--row)', fontSize: 13, background: 'var(--canvas)' }}>
        <Icon name="phone" size={15} color="#6B7280" />
        {gs.call.consent ? (
          <><span className="grow">If you stop part-way, Martina calls <b>{gs.call.phone}</b> once, between 9am and 6:30pm, to help you finish.</span>
            <button className="btn btn-ghost btn-xs" onClick={() => consent(false)} disabled={busy === 'call'}>Don't call</button></>
        ) : askCall ? (
          <><input className="input input-sm" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="0803 123 4567" inputMode="tel" aria-label="Phone number for Martina's call" style={{ width: 160 }} />
            <button className="btn btn-primary btn-xs" onClick={() => consent(true)} disabled={busy === 'call' || !phone.trim()}>{busy === 'call' && <Spinner small />}Yes, call me</button>
            <button className="btn btn-ghost btn-xs" onClick={() => setAskCall(false)}>Cancel</button></>
        ) : (
          <><span className="grow">Stuck later? Martina can give you one quick call to help you finish.</span>
            <button className="btn btn-secondary btn-xs" onClick={() => setAskCall(true)}>Set it up</button></>
        )}
      </div>
    </div>
  );
}
