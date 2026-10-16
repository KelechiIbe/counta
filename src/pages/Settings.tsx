import { useEffect, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../state/session';
import { useAction } from '../lib/queries';
import { must, rpc, supabase, SUPABASE_URL } from '../lib/supabase';
import { aiStatus } from '../lib/martina';
import { Icon } from '../components/Icon';
import { Alert, Field, Label } from '../components/ui';

function Section({ title, sub, children }: { title: string; sub?: string; children: ReactNode }) {
  return (
    <div className="card card-pad sec" style={{ display: 'grid', gridTemplateColumns: 'minmax(200px,280px) 1fr', gap: 24 }}>
      <div><Label>{title}</Label>{sub && <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>{sub}</div>}</div>
      <div className="stack" style={{ gap: 14, minWidth: 0 }}>{children}</div>
    </div>
  );
}

export default function Settings() {
  const { data: inv } = useInventory();
  const { session, signOut, refreshMemberships, setOrgId } = useSession();
  const { run, busy } = useAction();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const status = useQuery({ queryKey: ['aiStatus'], queryFn: aiStatus, staleTime: 60_000 });
  const owner = inv?.me.role === 'owner';
  const [f, setF] = useState<Record<string, any>>({});
  const [pw, setPw] = useState('');
  const [confirmRemove, setConfirmRemove] = useState(false);
  useEffect(() => {
    if (!inv) return;
    const o = inv.org;
    setF({ name: o.name, email: o.email || '', phone: o.phone || '', vat_registered: o.vat_registered, margin_threshold: String(o.margin_threshold), safety_days: String(o.safety_days),
      cover_days: String(o.cover_days), cash_available: o.cash_available == null ? '' : String(o.cash_available), voice_trust_threshold: String(o.voice_trust_threshold) });
  }, [inv?.org]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const project = SUPABASE_URL.replace('https://', '').split('.')[0];

  async function saveOrg() {
    if (!String(f.name || '').trim()) { toast('Enter the business name.', 'err'); return; }
    const mt = Number(f.margin_threshold); const sd = parseInt(f.safety_days); const cd = parseInt(f.cover_days); const vt = parseInt(f.voice_trust_threshold);
    if (!(mt >= 0 && mt < 100)) { toast('Margin threshold must be between 0 and 99%.', 'err'); return; }
    if (!(sd >= 0) || !(cd >= 1) || !(vt >= 0)) { toast('Days must be whole numbers; cover needs at least 1 day.', 'err'); return; }
    await run(() => must(supabase.from('orgs').update({
      name: f.name.trim(), email: f.email.trim() || null, phone: f.phone.trim() || null, vat_registered: !!f.vat_registered, margin_threshold: mt, safety_days: sd, cover_days: cd,
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
      <Section title="Phone app" sub="For the people who handle stock. Works offline and syncs in order when data returns.">
        <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>Open <b>{window.location.host}/m</b> on an Android phone in Chrome and tap <b>Add to Home screen</b>. Staff sign in with the email you invited; scanning, blind counts, invoice photos and voice entry are all there.</div>
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
    </div>
  );
}
