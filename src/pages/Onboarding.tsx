import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { useSession, useToast } from '../state/session';
import { Alert, Field, Spinner } from '../components/ui';
import { Icon } from '../components/Icon';

export default function Onboarding() {
  const { session, memberships, refreshMemberships, setOrgId, signOut } = useSession();
  const nav = useNavigate();
  const toast = useToast();
  const meta = (session?.user?.user_metadata || {}) as any;
  const [name, setName] = useState('');
  const [you, setYou] = useState<string>(meta.full_name || '');
  const [phone, setPhone] = useState('');
  const [vat, setVat] = useState(true);
  const [branches, setBranches] = useState([{ name: 'Main store', address: '' }]);
  const [busy, setBusy] = useState<'create' | 'sample' | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function create() {
    setErr(null);
    if (!name.trim()) { setErr('Enter your business name.'); return; }
    if (!branches.some((b) => b.name.trim())) { setErr('Add at least one branch.'); return; }
    setBusy('create');
    try {
      const id = await rpc<string>('create_org', {
        p_name: name.trim(), p_email: session?.user?.email, p_phone: phone, p_display_name: you,
        p_locations: branches.filter((b) => b.name.trim()), p_vat_registered: vat,
      });
      await refreshMemberships(); setOrgId(id);
      toast(name.trim() + ' is set up');
      nav('/inventory', { replace: true });
    } catch (e: any) { setErr(e.message); } finally { setBusy(null); }
  }
  async function sample() {
    setErr(null); setBusy('sample');
    try {
      const id = await rpc<string>('create_sample_business');
      await refreshMemberships(); setOrgId(id);
      toast('Sample business ready · Kelandellen Company Limited');
      nav('/inventory', { replace: true });
    } catch (e: any) { setErr(e.message); } finally { setBusy(null); }
  }

  return (
    <div style={{ minHeight: '100vh', background: '#FAFAFA', display: 'flex', justifyContent: 'center', padding: '40px 16px' }}>
      <div style={{ width: 640, maxWidth: '100%', display: 'flex', flexDirection: 'column', gap: 20 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 24 }} />
          <button className="btn btn-ghost btn-sm" onClick={signOut}><Icon name="logout" size={16} />Sign out</button>
        </div>
        <div>
          <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 28, fontWeight: 600, margin: 0, letterSpacing: '-.01em' }}>Set up your business</h1>
          <div className="muted" style={{ fontSize: 15, marginTop: 6, lineHeight: 1.5 }}>Two minutes. You can add staff, vendors and products right after.</div>
        </div>
        <div className="card card-pad" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <Field label="Business name" req><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Kelandellen Company Limited" /></Field>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 12 }}>
            <Field label="Your name"><input className="input" value={you} onChange={(e) => setYou(e.target.value)} /></Field>
            <Field label="Business phone"><input className="input" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+234" /></Field>
          </div>
          <div>
            <label className="field-label">Branches</label>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {branches.map((b, i) => (
                <div key={i} style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr 36px', gap: 8 }}>
                  <input className="input" value={b.name} placeholder="Branch name" onChange={(e) => setBranches(branches.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} />
                  <input className="input" value={b.address} placeholder="Address (optional)" onChange={(e) => setBranches(branches.map((x, j) => (j === i ? { ...x, address: e.target.value } : x)))} />
                  <button className="x-btn" disabled={branches.length === 1} onClick={() => setBranches(branches.filter((_, j) => j !== i))} aria-label="Remove branch"><Icon name="x" size={16} color="#9CA3AF" /></button>
                </div>
              ))}
            </div>
            <button className="btn btn-secondary btn-sm" style={{ marginTop: 8 }} onClick={() => setBranches([...branches, { name: '', address: '' }])}><Icon name="plus" size={14} />Add branch</button>
            <div className="hint" style={{ marginTop: 6 }}>The first branch is your main store. Stock is tracked per branch and summed for the business.</div>
          </div>
          <label className="check"><input type="checkbox" checked={vat} onChange={(e) => setVat(e.target.checked)} />The business is registered for VAT</label>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          <div className="row" style={{ justifyContent: 'flex-end' }}>
            <button className="btn btn-primary" onClick={create} disabled={!!busy}>{busy === 'create' && <Spinner small />}Create business</button>
          </div>
        </div>
        <div className="card card-pad row wrap" style={{ gap: 16, borderStyle: 'dashed', borderColor: '#D1D5DB' }}>
          <span style={{ width: 44, height: 44, borderRadius: 12, background: '#F0F7FF', display: 'grid', placeItems: 'center' }}><Icon name="sparkles" size={22} color="#0072F5" /></span>
          <div className="grow" style={{ minWidth: 220 }}>
            <div style={{ fontSize: 15, fontWeight: 600 }}>Explore a sample shop first</div>
            <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.45 }}>Kelandellen Company Limited: two Lagos branches, 16 FMCG lines, six vendors and two months of history. It stays separate from your real business.</div>
          </div>
          <button className="btn btn-secondary" onClick={sample} disabled={!!busy}>{busy === 'sample' && <Spinner small />}Open sample</button>
        </div>
        {memberships.length > 0 && (
          <button className="btn btn-ghost" onClick={() => nav('/inventory')} style={{ alignSelf: 'center' }}>Back to my businesses</button>
        )}
      </div>
    </div>
  );
}
