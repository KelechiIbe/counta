import { useEffect, useState, type ReactNode } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../state/session';
import { useAction } from '../lib/queries';
import { must, rpc, supabase, SUPABASE_URL } from '../lib/supabase';
import { aiStatus } from '../lib/martina';
import { Icon } from '../components/Icon';
import { Alert, Field, Label } from '../components/ui';
import { ChartDrawer, PostingRules } from '../components/ChartOfAccounts';
import { CallList } from '../components/Calls';
import { TOPICS, useVoiceCalls, useVoiceStatus, type VoiceCall } from '../lib/voice';
import { INDUSTRIES, industryOf } from '../lib/industries';
import { disablePush, enablePush, usePwaState } from '../lib/pwa';

function Section({ id, title, sub, children }: { id?: string; title: string; sub?: string; children: ReactNode }) {
  return (
    <div id={id} className="card card-pad sec" style={{ display: 'grid', gridTemplateColumns: 'minmax(200px,280px) 1fr', gap: 24, scrollMarginTop: 16 }}>
      <div><Label>{title}</Label>{sub && <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>{sub}</div>}</div>
      <div className="stack" style={{ gap: 14, minWidth: 0 }}>{children}</div>
    </div>
  );
}

function NotificationsSection() {
  const s = usePwaState();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const on = s.permission === 'granted' && !!s.subscribed;
  async function turnOn() {
    setBusy(true);
    const r = await enablePush();
    setBusy(false);
    toast(r.ok ? 'Notifications are on for this device' : r.error || 'Could not turn on notifications', r.ok ? undefined : 'err');
  }
  return (
    <Section id="notifications" title="Notifications" sub="Per device. Turn them on for each phone or computer you use.">
      {!s.pushSupported ? (
        s.pushNeedsInstall
          ? <Alert kind="blue" icon="phone">On iPhone, notifications work from the installed app. In Safari tap Share, then Add to Home Screen, open Counta from the new icon and come back here. This needs iOS 16.4 or later.</Alert>
          : <Alert kind="grey" icon="info">This browser cannot show notifications. Chrome, Edge, Firefox or Safari on a recent phone or computer can.</Alert>
      ) : s.permission === 'denied' ? (
        <Alert kind="yellow" icon="alert">Notifications are blocked for Counta on this device. Allow them in the browser's site settings (or the phone's notification settings for the installed app), then turn them on here.</Alert>
      ) : on ? (
        <>
          <Alert kind="green" icon="check">On for this device.</Alert>
          <div className="row wrap">
            <button className="btn btn-secondary btn-sm" disabled={busy} onClick={async () => { setBusy(true); try { await rpc('send_test_notification'); toast('Test sent. It should arrive in a few seconds.'); } catch (e) { toast((e as Error).message, 'err'); } setBusy(false); }}><Icon name="bell" size={14} />Send a test</button>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={async () => { setBusy(true); await disablePush(); setBusy(false); toast('Notifications are off for this device'); }}>Turn off</button>
          </div>
        </>
      ) : (
        <div><button className="btn btn-primary btn-sm" disabled={busy || s.subscribed === null} onClick={turnOn}><Icon name="bell" size={14} color="#fff" />Turn on for this device</button></div>
      )}
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
        You hear about counts waiting for approval and recounts sent back to you, invoices Martina could not read with confidence, stock on its way to your branch, price checks after a cost change, and the outcome of every phone call Martina makes. Each goes only to people whose role covers it.
      </div>
    </Section>
  );
}

function CallsSection({ owner }: { owner: boolean }) {
  const { data: inv } = useInventory();
  const st = useVoiceStatus();
  const calls = useVoiceCalls({ limit: 6 });
  const name = (c: VoiceCall) => c.kind === 'vendor_order'
    ? `${inv?.vendors.find((v) => v.id === c.vendor_id)?.name || 'Vendor'}${c.variables?.po_ref ? ' · ' + c.variables.po_ref : ''}`
    : `${inv?.members.find((m) => m.id === c.member_id)?.display_name || 'Team member'} · ${TOPICS.find((t) => t.id === c.topic)?.label || 'reminder'}`;
  return (
    <Section id="calls" title="Phone calls" sub="Martina phones vendors to place orders and reminds staff about work waiting in Counta. Runs on ElevenLabs voice agents.">
      {st.isLoading ? <div className="skel" style={{ height: 40 }} /> : st.data?.configured ? (
        <Alert kind="green" icon="check">Switched on · calls go out from {st.data.phone?.number || 'your connected number'}{st.data.phone?.provider ? ` (${st.data.phone.provider === 'sip_trunk' ? 'SIP trunk' : 'Twilio'})` : ''}.</Alert>
      ) : (
        <>
          <Alert kind="blue" icon="info">{st.data?.reason === 'no_number' ? 'The ElevenLabs key is in place. Connect a phone number in ElevenLabs and calls start working.' : st.data?.reason === 'error' ? `ElevenLabs did not answer: ${st.data.message || 'try again shortly'}.` : 'Not switched on yet. Orders still go out by WhatsApp or email.'}</Alert>
          {owner && (
            <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
              {st.data?.reason !== 'no_number' && <>Create an API key in ElevenLabs with access to Agents and phone numbers, then store it in Supabase Vault as <span className="mono" style={{ background: '#F3F4F6', padding: '1px 6px', borderRadius: 6 }}>ELEVENLABS_API_KEY</span>. </>}
              Calls need a number to ring from: import a Twilio number (or connect a SIP trunk) under Phone Numbers in ElevenLabs. Counta creates both voice agents itself on the first call.
            </div>
          )}
          <div className="row wrap">
            {owner && <a className="btn btn-secondary btn-sm" href="https://elevenlabs.io/app/agents/phone-numbers" target="_blank" rel="noreferrer"><Icon name="external" size={14} />ElevenLabs phone numbers</a>}
            <button className="btn btn-ghost btn-sm" onClick={() => st.refetch()}>Check again</button>
          </div>
        </>
      )}
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
        Start a vendor call from any open purchase order under Reorder. Reminder calls start from the phone icon beside a person under Locations &amp; staff. Martina always says she is an AI assistant, never discusses payment details, and writes the outcome back to the order.
      </div>
      {!!calls.data?.length && <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}><CallList calls={calls.data} names={name} /></div>}
    </Section>
  );
}

export default function Settings() {
  const { data: inv } = useInventory();
  const { session, signOut, refreshMemberships, setOrgId } = useSession();
  const { run, busy } = useAction();
  const toast = useToast();
  const nav = useNavigate();
  const { hash } = useLocation();
  const qc = useQueryClient();
  const status = useQuery({ queryKey: ['aiStatus'], queryFn: aiStatus, staleTime: 60_000 });
  const owner = inv?.me.role === 'owner';
  const [f, setF] = useState<Record<string, any>>({});
  const [pw, setPw] = useState('');
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [chart, setChart] = useState(false);
  useEffect(() => {
    if (!inv) return;
    const o = inv.org;
    setF({ name: o.name, industry: o.industry || 'retail', email: o.email || '', phone: o.phone || '', vat_registered: o.vat_registered, margin_threshold: String(o.margin_threshold), safety_days: String(o.safety_days),
      cover_days: String(o.cover_days), cash_available: o.cash_available == null ? '' : String(o.cash_available), voice_trust_threshold: String(o.voice_trust_threshold) });
  }, [inv?.org]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!inv || !hash) return;
    const t = setTimeout(() => document.getElementById(hash.slice(1))?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 150);
    return () => clearTimeout(t);
  }, [hash, !!inv]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const project = SUPABASE_URL.replace('https://', '').split('.')[0];

  async function saveOrg() {
    if (!String(f.name || '').trim()) { toast('Enter the business name.', 'err'); return; }
    const mt = Number(f.margin_threshold); const sd = parseInt(f.safety_days); const cd = parseInt(f.cover_days); const vt = parseInt(f.voice_trust_threshold);
    if (!(mt >= 0 && mt < 100)) { toast('Margin threshold must be between 0 and 99%.', 'err'); return; }
    if (!(sd >= 0) || !(cd >= 1) || !(vt >= 0)) { toast('Days must be whole numbers; cover needs at least 1 day.', 'err'); return; }
    await run(() => must(supabase.from('orgs').update({
      name: f.name.trim(), industry: f.industry || 'retail', email: f.email.trim() || null, phone: f.phone.trim() || null, vat_registered: !!f.vat_registered, margin_threshold: mt, safety_days: sd, cover_days: cd,
      cash_available: f.cash_available === '' ? null : Math.max(0, Number(f.cash_available)), voice_trust_threshold: vt,
    }).eq('id', inv!.org.id).select().single()), { ok: 'Settings saved', invalidate: ['inv'] });
    refreshMemberships().catch(() => {});
  }

  async function removeSample() {
    if (!confirmRemove) { setConfirmRemove(true); return; }
    const r = await run(() => rpc('remove_sample_business', { p_org: inv!.org.id }), { ok: 'Sample business removed', invalidate: [] });
    if (r === undefined) return;
    const list = await refreshMemberships();
    setOrgId(list[0]?.org_id ?? null); qc.clear();
    nav(list.length ? '/inventory' : '/onboarding');
  }

  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <Section title="Business" sub={owner ? 'Shown on purchase orders and labels.' : 'Only the owner can change these.'}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
          <Field label="Business name"><input className="input" disabled={!owner} value={f.name || ''} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Email"><input className="input" disabled={!owner} value={f.email || ''} onChange={(e) => set('email', e.target.value)} /></Field>
          <Field label="Phone"><input className="input" disabled={!owner} value={f.phone || ''} onChange={(e) => set('phone', e.target.value)} /></Field>
        </div>
        <Field label="Kind of business" hint={`Sets the item fields, units and import template. ${industryOf(f.industry).blurb}.`}>
          <select className="input" disabled={!owner} value={f.industry || 'retail'} onChange={(e) => set('industry', e.target.value)} style={{ maxWidth: 420 }}>
            {INDUSTRIES.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
          </select>
        </Field>
        <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.vat_registered} onChange={(e) => set('vat_registered', e.target.checked)} />VAT-registered business (claims input VAT on purchases)</label>
      </Section>
      <Section title="Stock rules" sub="These drive reorder suggestions, price proposals and voice review.">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
          <Field label="Margin threshold (%)" hint="Prices under this margin get a proposal. Default 8%."><input className="input" type="number" min={0} max={99} disabled={!owner} value={f.margin_threshold || ''} onChange={(e) => set('margin_threshold', e.target.value)} /></Field>
          <Field label="Safety stock (days)" hint="Extra days added to each vendor's lead time."><input className="input" type="number" min={0} disabled={!owner} value={f.safety_days || ''} onChange={(e) => set('safety_days', e.target.value)} /></Field>
          <Field label="Order cover (days)" hint="How many days of sales a suggested order should cover."><input className="input" type="number" min={1} disabled={!owner} value={f.cover_days || ''} onChange={(e) => set('cover_days', e.target.value)} /></Field>
          <Field label="Cash set aside for stock (₦)" hint="Suggestions are capped by it. Leave blank for no cap."><input className="input" type="number" min={0} disabled={!owner} value={f.cash_available ?? ''} onChange={(e) => set('cash_available', e.target.value)} /></Field>
          <Field label="Voice entries before trust" hint="Each person's voice sales are reviewed until this many go through clean."><input className="input" type="number" min={0} disabled={!owner} value={f.voice_trust_threshold || ''} onChange={(e) => set('voice_trust_threshold', e.target.value)} /></Field>
        </div>
        {owner && <div><button className="btn btn-primary" onClick={saveOrg} disabled={busy}>Save settings</button></div>}
      </Section>
      <Section title="Chart of accounts" sub={owner ? 'TaxStreem standard chart. Change where an entry lands; stock value moves with it.' : 'TaxStreem standard chart. Only the owner can change the rules.'}>
        <PostingRules owner={!!owner} onOpenChart={() => setChart(true)} />
      </Section>
      <Section title="AI reading" sub="Invoice OCR, voice entry and Martina's open answers run on Gemini with your own key.">
        {status.isLoading ? <div className="skel" style={{ height: 40 }} /> : status.data?.configured ? (
          <Alert kind="green" icon="check">Switched on · model {status.data.model}. Invoices, handwritten sheets and voice notes are read automatically.</Alert>
        ) : (
          <>
            <Alert kind="blue" icon="info">Not switched on yet. Everything else works: lines can be typed by hand and Martina answers from your records with rules.</Alert>
            <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
              To switch it on, create a key in Google AI Studio, then add it to the Supabase project as an Edge Function secret named <span className="mono" style={{ background: '#F3F4F6', padding: '1px 6px', borderRadius: 6 }}>GEMINI_API_KEY</span>. Reading starts on the next invoice; nothing needs redeploying.
            </div>
            <div className="row wrap">
              <a className="btn btn-secondary btn-sm" href="https://aistudio.google.com/app/apikey" target="_blank" rel="noreferrer"><Icon name="external" size={14} />Get a Gemini key</a>
              <a className="btn btn-secondary btn-sm" href={`https://supabase.com/dashboard/project/${project}/functions/secrets`} target="_blank" rel="noreferrer"><Icon name="external" size={14} />Open Supabase secrets</a>
              <button className="btn btn-ghost btn-sm" onClick={() => status.refetch()}>Check again</button>
            </div>
          </>
        )}
      </Section>
      <NotificationsSection />
      <CallsSection owner={!!owner} />
      <Section title="Phone app" sub="For the people who handle stock. Works offline and syncs in order when data returns.">
        <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>Open <b>{window.location.host}</b> on the phone. On Android, Chrome offers <b>Install</b>; on iPhone, tap Share in Safari and choose <b>Add to Home Screen</b>. Staff sign in with the email you invited and land on the phone screens for scanning, blind counts, invoice photos and voice entry. The full app, with approvals and reports, is one tap away and fits the phone too.</div>
        <div><button className="btn btn-secondary btn-sm" onClick={() => nav('/m')}><Icon name="phone" size={14} />Open the phone app here</button></div>
      </Section>
      {inv.org.is_sample && owner && (
        <Section title="Sample business" sub="Kelandellen Company Limited is demo data so you can look around.">
          <Alert kind="yellow" icon="info">Removing it hides the sample from your account. Your own businesses are untouched.</Alert>
          <div><button className="btn btn-danger" onClick={removeSample} disabled={busy}>{confirmRemove ? 'Tap again to remove the sample' : 'Remove sample business'}</button></div>
        </Section>
      )}
      <Section title="Your account" sub={session?.user.email || ''}>
        <Field label="New password" hint="At least 8 characters.">
          <div className="row"><input className="input" type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} style={{ maxWidth: 320 }} />
            <button className="btn btn-secondary" disabled={pw.length < 8 || busy} onClick={async () => { const r = await run(async () => { const { error } = await supabase.auth.updateUser({ password: pw }); if (error) throw error; return true; }, { ok: 'Password changed', invalidate: [] }); if (r) setPw(''); }}>Change password</button></div>
        </Field>
        <div><button className="btn btn-secondary" onClick={signOut}><Icon name="logout" size={16} />Sign out</button></div>
      </Section>
      {chart && <ChartDrawer onClose={() => setChart(false)} />}
    </div>
  );
}
