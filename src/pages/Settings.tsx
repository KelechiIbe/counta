import { useEffect, useState, type ReactNode } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../state/session';
import { useAction } from '../lib/queries';
import { must, rpc, supabase } from '../lib/supabase';
import { localPhone } from '../lib/format';
import { isOn, offNote, useFeatures } from '../lib/features';
import { Icon } from '../components/Icon';
import { Alert, Field, Label } from '../components/ui';
import { ChartDrawer, PostingRules } from '../components/ChartOfAccounts';
import { CallList } from '../components/Calls';
import { TOPICS, useVoiceCalls, useVoiceStatus, type VoiceCall } from '../lib/voice';
import { INDUSTRIES, industryOf } from '../lib/industries';
import { disablePush, enablePush, usePwaState } from '../lib/pwa';
import { BooksSection, MessagesSection, TaxStreemSection } from './SettingsBooks';
import { BrandingSection } from './SettingsBranding';
import { useVoiceSettings, VoicePicker } from '../guide/VoicePicker';
import { useGuideTalk } from '../guide/GuideProvider';
import { saveVoice } from '../lib/onboard';
import { PeopleCard, RolesCard } from './settings/Team';
import { IdentityPanel, useIdentity } from './onboarding/Identity';
import { MartinaAnywhere } from './settings/MartinaAnywhere';
import { AccountantSection } from './settings/Accountant';

function Section({ id, title, sub, children }: { id?: string; title: string; sub?: string; children: ReactNode }) {
  return (
    <div id={id} className="card card-pad sec" style={{ display: 'grid', gridTemplateColumns: 'minmax(200px,280px) 1fr', gap: 24, scrollMarginTop: 16 }}>
      <div><Label>{title}</Label>{sub && <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>{sub}</div>}</div>
      <div className="stack" style={{ gap: 14, minWidth: 0 }}>{children}</div>
    </div>
  );
}

// The Nigerian voice that says "payment received" and reads back voice sales, in English or Pidgin.
function VoiceSection() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const vs = useVoiceSettings(orgId);
  const [busy, setBusy] = useState(false);
  const s = vs.data;
  async function events(key: string, on: boolean) {
    if (!orgId) return;
    setBusy(true);
    try { await saveVoice(orgId, { events: { [key]: on } }); await qc.invalidateQueries({ queryKey: ['voice-settings'] }); toast(on ? 'Spoken' : 'Not spoken'); }
    catch (e) { toast((e as Error).message, 'err'); } finally { setBusy(false); }
  }
  return (
    <Section id="voice" title="Payment voice" sub="Real Nigerian voices announce payments and read back sales recorded by voice. Without a connection, the device's own voice speaks.">
      <VoicePicker compact />
      {s && (
        <div className="stack" style={{ gap: 8 }}>
          <label className="check"><input type="checkbox" checked={s.events?.payment_received !== false} disabled={!s.can_edit || busy} onChange={(e) => events('payment_received', e.target.checked)} />Say "payment received" when a transfer, link or QR payment lands</label>
          <label className="check"><input type="checkbox" checked={s.events?.sale_recorded !== false} disabled={!s.can_edit || busy} onChange={(e) => events('sale_recorded', e.target.checked)} />Read back sales recorded by voice on the phone app</label>
          {!s.can_edit && <div className="faint" style={{ fontSize: 12 }}>Only the owner or a manager changes the voice.</div>}
        </div>
      )}
    </Section>
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
        You hear about tax returns coming due, invoices due and overdue, bank lines and payments to confirm before the month&apos;s returns, counts waiting for approval, invoices Martina could not read with confidence, stock on its way to your branch, price checks after a cost change, and the outcome of every phone call Martina makes. Each goes only to people whose role covers it.
      </div>
    </Section>
  );
}

// What reaches the owner beyond the app: emails, WhatsApp messages and Martina's calls, and whether she calls customers.
// "Ada", "Ada and Tunde", "Ada, Tunde and Bisi", "Ada, Tunde, Bisi, Kemi, Femi and 3 others".
export function listNames(names: string[]) {
  const n = names.filter(Boolean);
  if (n.length > 6) return `${n.slice(0, 5).join(', ')} and ${n.length - 5} others`;
  return n.length <= 1 ? n[0] || '' : `${n.slice(0, -1).join(', ')} and ${n[n.length - 1]}`;
}

function AlertsSection() {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [data, setData] = useState<any>(null);
  useEffect(() => { if (orgId) rpc<any>('get_alert_prefs', { p_org: orgId }).then(setData).catch(() => setData(null)); }, [orgId]);
  async function set(k: string, v: boolean) {
    setBusy(true);
    try { const r = await rpc<any>('save_alert_prefs', { p_org: orgId, p: { [k]: v } }); setData({ ...data, ...r }); toast('Saved'); await qc.invalidateQueries({ queryKey: ['attention'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  if (!data) return null;
  const cfg = data.platform || {}, cc = cfg.customer_calls || {};
  const can_ = !!data.can_change;
  const row = (k: string, label: string, hint: string) => (
    <label className="check" style={{ alignItems: 'flex-start' }}>
      <input type="checkbox" style={{ flexShrink: 0, marginTop: 2 }} checked={!!data[k]} disabled={!can_ || busy} onChange={(e) => set(k, e.target.checked)} />
      <span>{label}<span className="faint" style={{ display: 'block', fontSize: 12 }}>{hint}</span></span>
    </label>
  );
  return (
    <Section id="alerts" title="Alerts" sub="Everything that needs doing shows as a red number in the menu and a push notification. The important things also reach the owner by email and, on WhatsApp, everyone who linked theirs to Martina.">
      {row('email', 'Email', `Tax returns due (${(cfg.tax_deadline?.message_days_before || [3, 1]).join(' and ')} days before), invoices overdue (weekly), and transactions to confirm before the returns.`)}
      {row('whatsapp', 'WhatsApp', 'The same on WhatsApp, plus anything waiting for you: bills and receipts to review, payouts to approve, a bank to sign in to again, new orders. Each person gets what their role covers, from TaxStreem\'s number, between 8:00 and 20:00, at most 10 a day.')}
      {row('owner_calls', 'A call from Martina the day before a tax return is due', 'She explains what is due and what to do. Calls go out between ' + (cfg.calls?.hours?.[0] ?? 9) + ':00 and ' + (cfg.calls?.hours?.[1] ?? 17) + ':00.')}
      {row('customer_calls', 'Martina follows up customers whose invoices are overdue', `Only after a reminder went unanswered, for invoices at least ${cc.min_days_overdue ?? 7} days overdue and ${cc.min_amount != null ? '₦' + Number(cc.min_amount).toLocaleString('en-NG') : '₦10,000'} or more, at most ${cc.per_org_per_day ?? 5} calls a day${cc.weekdays_only !== false ? ', on weekdays' : ''}. She is polite, never threatens, and writes what the customer said on the invoice.`)}
      {!can_ && <div className="faint" style={{ fontSize: 12 }}>Only the owner or someone who manages settings changes these.</div>}
      {!!data.owner && <div className="faint" style={{ fontSize: 12 }} data-testid="alerts-email-to">Emails go to {data.owner.name}{data.owner.email ? ` at ${data.owner.email}` : ''}.</div>}
      {Array.isArray(data.whatsapp_people) && (
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }} data-testid="alerts-whatsapp-to">
          {data.whatsapp_people.length
            ? `WhatsApp alerts go to ${listNames(data.whatsapp_people)}, on the number${data.whatsapp_people.length === 1 ? '' : 's'} linked to Martina.`
            : 'Nobody here has linked WhatsApp to Martina yet, so no WhatsApp alerts go out.'}
          {data.my_whatsapp ? ` Yours go to ${data.my_whatsapp}.` : ' Link your number under Martina on WhatsApp and Siri to get yours.'}
        </div>
      )}
      {!!(data.calls || []).length && (
        <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}>
          {(data.calls as any[]).slice(0, 8).map((c) => (
            <div key={c.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) 110px' }}>
              <span className="ellipsis">{c.kind === 'tax_deadline' ? 'Tax deadline call to the owner' : `${c.to || 'Customer'} · ${c.sale || 'invoice'}`}
                <span className="faint" style={{ display: 'block', fontSize: 12 }}>{new Date(c.created_at).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Africa/Lagos' })}{c.summary ? ` · ${c.summary}` : ''}</span></span>
              <span className="chip t-grey" style={{ justifySelf: 'end' }}>{String(c.status).replace('_', ' ')}</span>
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}

function CallsSection() {
  const { data: inv } = useInventory();
  const st = useVoiceStatus();
  const feats = useFeatures();
  const calls = useVoiceCalls({ limit: 6 });
  const name = (c: VoiceCall) => c.kind === 'vendor_order'
    ? `${inv?.vendors.find((v) => v.id === c.vendor_id)?.name || 'Vendor'}${c.variables?.po_ref ? ' · ' + c.variables.po_ref : ''}`
    : `${inv?.members.find((m) => m.id === c.member_id)?.display_name || 'Team member'} · ${TOPICS.find((t) => t.id === c.topic)?.label || 'reminder'}`;
  const paused = !isOn(feats.data, 'phone_calls');
  return (
    <Section id="calls" title="Phone calls" sub="Martina phones vendors to place orders and reminds staff about work waiting in Counta.">
      {st.isLoading || feats.isLoading ? <div className="skel" style={{ height: 40 }} /> : paused ? (
        <Alert kind="amber" icon="info">{offNote(feats.data, 'phone_calls')}</Alert>
      ) : st.data?.configured ? (
        <Alert kind="green" icon="check">Switched on · calls go out from {st.data.phone?.number || 'TaxStreem\'s number'}.</Alert>
      ) : (
        <Alert kind="blue" icon="info">Phone calls are not available yet. TaxStreem is setting them up; orders and reminders go out by WhatsApp or email meanwhile.</Alert>
      )}
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
        Start a vendor call from any open purchase order under Reorder. Reminder calls start from the phone icon beside a person under Locations &amp; staff. Martina always says she is an AI assistant, never discusses payment details, and writes the outcome back to the order.
      </div>
      {!!calls.data?.length && <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}><CallList calls={calls.data} names={name} /></div>}
    </Section>
  );
}

// Who is on the team, and what each role may do. Everyone sees the list; people who manage the team change it.
function TeamSection() {
  return (
    <Section id="team" title="Team and roles" sub="Invite people by email with a one-time link. Each role has its own permissions; a change reaches everyone in that role, and one person can still have their own exceptions.">
      <PeopleCard />
      <div style={{ borderTop: '1px solid var(--line)', paddingTop: 14 }}>
        <div className="mini-label" style={{ marginBottom: 10 }}>Roles and permissions</div>
        <RolesCard />
      </div>
    </Section>
  );
}

// The business's accountant, from Counta's accountant portal. The sample business has none.
function YourAccountantSection() {
  const { data: inv } = useInventory();
  if (!inv || inv.org.is_sample) return null;
  return (
    <Section id="accountant" title="Your accountant" sub="Invite your accountant by email. They keep your books and prepare your returns in Counta with an Accountant's place in the business, and never move money.">
      <AccountantSection />
    </Section>
  );
}

// The director's NIN check. Until it passes (or TaxStreem approves the slip), the wallet, payment links and payouts wait.
function IdentitySection() {
  const { orgId } = useSession();
  const id = useIdentity(orgId);
  const g = useGuideTalk();
  if (!orgId || !id.data || id.data.status === 'not_required') return null;
  return (
    <Section id="identity" title="Business identity" sub="A director confirms who they are with their NIN. Only the result and the last four digits are kept.">
      <IdentityPanel orgId={orgId} live={g.status === 'live'} askOpen={g.uploadAsk?.kind === 'nin_slip' ? g.uploadAsk.at : undefined} />
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
  const owner = inv?.me.role === 'owner';
  // Changing the business's settings is a permission of its own (owners and admins by default).
  const edit = can(inv, 'manage_settings');
  const [f, setF] = useState<Record<string, any>>({});
  const [pw, setPw] = useState('');
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [chart, setChart] = useState(false);
  useEffect(() => {
    if (!inv) return;
    const o = inv.org;
    setF({ name: o.name, industry: o.industry || 'retail', offering: o.offering || 'goods', email: o.email || '', phone: localPhone(o.phone), vat_registered: o.vat_registered, margin_threshold: String(o.margin_threshold), safety_days: String(o.safety_days),
      cover_days: String(o.cover_days), cash_available: o.cash_available == null ? '' : String(o.cash_available), voice_trust_threshold: String(o.voice_trust_threshold) });
  }, [inv?.org]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!inv || !hash) return;
    const t = setTimeout(() => document.getElementById(hash.slice(1))?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 150);
    return () => clearTimeout(t);
  }, [hash, !!inv]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));

  async function saveOrg() {
    if (!String(f.name || '').trim()) { toast('Enter the business name.', 'err'); return; }
    const mt = Number(f.margin_threshold); const sd = parseInt(f.safety_days); const cd = parseInt(f.cover_days); const vt = parseInt(f.voice_trust_threshold);
    if (!(mt >= 0 && mt < 100)) { toast('Margin threshold must be between 0 and 99%.', 'err'); return; }
    if (!(sd >= 0) || !(cd >= 1) || !(vt >= 0)) { toast('Days must be whole numbers; cover needs at least 1 day.', 'err'); return; }
    await run(() => must(supabase.from('orgs').update({
      name: f.name.trim(), industry: f.industry || 'retail', offering: f.offering || 'goods', email: f.email.trim() || null, phone: localPhone(f.phone) || null, vat_registered: !!f.vat_registered, margin_threshold: mt, safety_days: sd, cover_days: cd,
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
    nav(list.length ? '/home' : '/onboarding');
  }

  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      <Section id="business" title="Business" sub={edit ? 'Shown on purchase orders and labels.' : 'Only people who can change settings edit these.'}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
          <Field label="Business name"><input className="input" disabled={!edit} value={f.name || ''} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Email"><input className="input" disabled={!edit} value={f.email || ''} onChange={(e) => set('email', e.target.value)} /></Field>
          <Field label="Phone"><input className="input" disabled={!edit} value={f.phone || ''} onChange={(e) => set('phone', e.target.value)} placeholder="0803 123 4567" inputMode="tel" /></Field>
        </div>
        <Field label="Kind of business" hint={`Sets the item fields, units and import template. ${industryOf(f.industry).blurb}.`}>
          <select className="input" disabled={!edit} value={f.industry || 'retail'} onChange={(e) => set('industry', e.target.value)} style={{ maxWidth: 420 }}>
            {INDUSTRIES.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
          </select>
        </Field>
        <Field label="What the business sells" hint="Martina and the main screens use your words: revenue and clients for services, sales and customers for goods.">
          <select className="input" disabled={!edit} value={f.offering || 'goods'} onChange={(e) => set('offering', e.target.value)} style={{ maxWidth: 420 }}>
            <option value="goods">Goods: products we stock and sell</option>
            <option value="services">Services: work we do for clients</option>
            <option value="both">Both goods and services</option>
          </select>
        </Field>
        <label className="check"><input type="checkbox" disabled={!edit} checked={!!f.vat_registered} onChange={(e) => set('vat_registered', e.target.checked)} />VAT-registered business (claims input VAT on purchases)</label>
        {edit && <div><button className="btn btn-primary" onClick={saveOrg} disabled={busy}>Save business details</button></div>}
      </Section>
      <BrandingSection />
      <TeamSection />
      <YourAccountantSection />
      <IdentitySection />
      <Section title="Stock rules" sub="These drive reorder suggestions, price proposals and voice review.">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
          <Field label="Margin threshold (%)" hint="Prices under this margin get a proposal. Default 8%."><input className="input" type="number" min={0} max={99} disabled={!edit} value={f.margin_threshold || ''} onChange={(e) => set('margin_threshold', e.target.value)} /></Field>
          <Field label="Safety stock (days)" hint="Extra days added to each vendor's lead time."><input className="input" type="number" min={0} disabled={!edit} value={f.safety_days || ''} onChange={(e) => set('safety_days', e.target.value)} /></Field>
          <Field label="Order cover (days)" hint="How many days of sales a suggested order should cover."><input className="input" type="number" min={1} disabled={!edit} value={f.cover_days || ''} onChange={(e) => set('cover_days', e.target.value)} /></Field>
          <Field label="Cash set aside for stock (₦)" hint="Suggestions are capped by it. Leave blank for no cap."><input className="input" type="number" min={0} disabled={!edit} value={f.cash_available ?? ''} onChange={(e) => set('cash_available', e.target.value)} /></Field>
          <Field label="Voice entries before trust" hint="Each person's voice sales are reviewed until this many go through clean."><input className="input" type="number" min={0} disabled={!edit} value={f.voice_trust_threshold || ''} onChange={(e) => set('voice_trust_threshold', e.target.value)} /></Field>
        </div>
        {edit && <div><button className="btn btn-primary" onClick={saveOrg} disabled={busy}>Save settings</button></div>}
      </Section>
      <BooksSection />
      <MessagesSection />
      <Section title="Chart of accounts" sub={edit ? 'TaxStreem standard chart. Change where an entry lands; stock value moves with it.' : 'TaxStreem standard chart. Only people who can change settings change the rules.'}>
        <PostingRules owner={edit} onOpenChart={() => setChart(true)} />
      </Section>
      <TaxStreemSection />
      <NotificationsSection />
      <AlertsSection />
      <VoiceSection />
      <Section id="martina-anywhere" title="Martina on WhatsApp and Siri" sub="Talk to Martina from your own WhatsApp, or say Hey Siri on an iPhone. She acts as you, within what your role allows, for this business.">
        <MartinaAnywhere />
      </Section>
      <CallsSection />
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
