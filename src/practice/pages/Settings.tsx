// The practice's details (partners change them) and each person's own licence number, which TaxStreem checks.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { localPhone } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { usePracticeHome } from '../api';

export default function SettingsPage({ pid }: { pid: string }) {
  const h = usePracticeHome(pid).data!;
  const qc = useQueryClient();
  const toast = useToast();
  const p = h.practice;
  const [f, setF] = useState({ name: p.name, kind: p.kind, email: p.email || '', phone: localPhone(p.phone), address: p.address || '', state: p.state || '', firm_reg: p.firm_reg || '' });
  const [lic, setLic] = useState({ licence_body: h.me.licence_body || 'ICAN', licence_no: h.me.licence_no || '' });
  const [busy, setBusy] = useState<'p' | 'l' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const partner = h.me.role === 'partner';
  async function save() {
    setBusy('p'); setErr(null);
    try { await rpc('update_practice', { p_practice: pid, p: { ...f, phone: localPhone(f.phone) } }); await qc.invalidateQueries({ queryKey: ['practice-home', pid] }); await qc.invalidateQueries({ queryKey: ['practices-mine'] }); toast('Saved'); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function saveLicence() {
    setBusy('l'); setErr(null);
    try {
      await rpc('practice_set_licence', { p_practice: pid, p: lic.licence_no.trim() ? lic : { licence_body: null, licence_no: null } });
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      toast(lic.licence_no.trim() ? 'Saved. TaxStreem checks it shortly.' : 'Removed');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const up = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <>
      <PageHead title="Practice" sub="What clients see of your practice, and your own professional licence." />
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <Card title="Your licence" sub="Clients see it beside your name, and it goes into the statement you accept when you change a return.">
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label="Body"><select className="input" value={lic.licence_body} onChange={(e) => setLic({ ...lic, licence_body: e.target.value as any })}><option>ICAN</option><option>ANAN</option><option>CITN</option></select></Field>
          <Field label="Membership number"><input className="input" value={lic.licence_no} onChange={(e) => setLic({ ...lic, licence_no: e.target.value })} maxLength={30} /></Field>
          <button className="btn btn-secondary" disabled={busy !== null} onClick={saveLicence}>{busy === 'l' ? <Spinner small /> : null}Save</button>
        </div>
        <div className="faint" style={{ fontSize: 13 }}>Now: {h.me.licence_text}{h.me.licence_status === 'rejected' && h.me.licence_note ? `. TaxStreem: ${h.me.licence_note}` : ''}</div>
      </Card>
      <Card title="The practice" sub={partner ? undefined : 'A partner changes these.'}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Name"><input className="input" value={f.name} onChange={up('name')} disabled={!partner} maxLength={120} /></Field>
          <Field label="It is"><select className="input" value={f.kind} onChange={up('kind')} disabled={!partner}><option value="firm">A firm</option><option value="sole">A sole practitioner</option></select></Field>
          <Field label="Email"><input className="input" value={f.email} onChange={up('email')} disabled={!partner} /></Field>
          <Field label="Phone"><input className="input" value={f.phone} onChange={up('phone')} disabled={!partner} maxLength={30} placeholder="0803 123 4567" inputMode="tel" /></Field>
          <Field label="Address"><input className="input" value={f.address} onChange={up('address')} disabled={!partner} maxLength={300} /></Field>
          <Field label="State"><input className="input" value={f.state} onChange={up('state')} disabled={!partner} maxLength={40} /></Field>
          <Field label="Firm registration"><input className="input" value={f.firm_reg} onChange={up('firm_reg')} disabled={!partner} maxLength={40} /></Field>
        </div>
        {partner && <div><button className="btn btn-primary" disabled={busy !== null} onClick={save}>{busy === 'p' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Save</button></div>}
      </Card>
      <div><Link to="/practice/new" className="btn btn-ghost btn-sm"><Icon name="plus" size={14} />Set up another practice</Link></div>
    </>
  );
}
