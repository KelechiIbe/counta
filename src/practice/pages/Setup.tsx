// Setting up a practice: its name, and the founder's own licence number (TaxStreem checks it). A business that already
// invited this person shows here too, so they can set up and then take it on.
import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { localPhone } from '../../lib/format';
import { useSession } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { type Home, type Invitation, savePractice } from '../api';

export default function Setup({ invitations, again }: { invitations: Invitation[]; again?: boolean }) {
  const { session, memberships, signOut } = useSession();
  const nav = useNavigate();
  const qc = useQueryClient();
  const meta = (session?.user.user_metadata || {}) as Record<string, string>;
  const [f, setF] = useState({ name: '', kind: 'firm', email: session?.user.email || '', phone: '', firm_reg: '', my_name: meta.full_name || meta.name || '',
    licence_body: 'ICAN', licence_no: '' });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const up = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  async function create() {
    setBusy(true); setErr(null);
    try {
      const h = await rpc<Home>('create_practice', { p: { ...f, phone: localPhone(f.phone), licence_body: f.licence_no.trim() ? f.licence_body : null, licence_no: f.licence_no.trim() || null } });
      savePractice(h.practice.id);
      await qc.invalidateQueries({ queryKey: ['practices-mine'] });
      nav(`/practice/${h.practice.id}`, { replace: true });
    } catch (e) { setErr(cleanError(e)); setBusy(false); }
  }

  return (
    <div style={{ minHeight: '100vh', background: 'var(--canvas)', padding: '32px 16px' }}>
      <div className="card card-pad stack" style={{ gap: 16, maxWidth: 640, margin: '0 auto' }} data-testid="practice-setup">
        <div className="row" style={{ gap: 10 }}>
          <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 22 }} />
          <span className="chip t-blue">Accountant portal</span>
        </div>
        <div>
          <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 26, fontWeight: 600, margin: 0 }}>{again ? 'Set up another practice' : 'Set up your practice'}</h1>
          <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.55 }}>
            The portal keeps every business you look after in one place: what needs doing in each set of books, every tax deadline, your requests to clients and the
            returns you change. Businesses connect to you by invitation, from either side.
          </div>
        </div>
        {invitations.length > 0 && (
          <Alert kind="blue" icon="mail">
            {invitations.map((i) => i.business).join(', ')} {invitations.length === 1 ? 'has' : 'have'} invited you to be {invitations.length === 1 ? 'its' : 'their'} accountant.
            Set up your practice, then accept from the portal.
          </Alert>
        )}
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Name of the practice" req><input className="input" value={f.name} onChange={up('name')} maxLength={120} placeholder="Okafor & Co, Chartered Accountants" autoFocus /></Field>
          <Field label="It is">
            <select className="input" value={f.kind} onChange={up('kind')}><option value="firm">A firm</option><option value="sole">Me, practising on my own</option></select>
          </Field>
          <Field label="Practice email" hint="Clients' replies go here."><input className="input" type="email" value={f.email} onChange={up('email')} /></Field>
          <Field label="Phone"><input className="input" value={f.phone} onChange={up('phone')} maxLength={30} placeholder="0803 123 4567" inputMode="tel" /></Field>
          <Field label="Firm registration (optional)" hint="ICAN or CAC firm number"><input className="input" value={f.firm_reg} onChange={up('firm_reg')} maxLength={40} /></Field>
          <Field label="Your name as clients see it"><input className="input" value={f.my_name} onChange={up('my_name')} maxLength={80} /></Field>
          <Field label="Your professional body">
            <select className="input" value={f.licence_body} onChange={up('licence_body')}><option value="ICAN">ICAN</option><option value="ANAN">ANAN</option><option value="CITN">CITN</option></select>
          </Field>
          <Field label="Membership number" hint="TaxStreem checks it. Until then clients see it as unverified."><input className="input" value={f.licence_no} onChange={up('licence_no')} maxLength={30} /></Field>
        </div>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <div className="row wrap" style={{ gap: 8 }}>
          <button className="btn btn-primary" disabled={busy || f.name.trim().length < 2} onClick={create}>{busy ? <Spinner small /> : <Icon name="check" size={16} color="#fff" />}Set up the practice</button>
          {memberships.length > 0 ? <Link to="/" className="btn btn-ghost">Back to Counta</Link> : <button className="btn btn-ghost" onClick={signOut}>Sign out</button>}
        </div>
      </div>
    </div>
  );
}
