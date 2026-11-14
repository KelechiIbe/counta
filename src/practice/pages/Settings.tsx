// The practice's details (partners change them), each person's own licence number, which TaxStreem checks, and how the
// conflicts check looks for a prospect (partners choose). The letterhead card sets how engagement letters look.
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
import { LetterheadCard } from '../LetterheadCard';

export default function SettingsPage({ pid }: { pid: string }) {
  const h = usePracticeHome(pid).data!;
  const qc = useQueryClient();
  const toast = useToast();
  const p = h.practice;
  const [f, setF] = useState({ name: p.name, kind: p.kind, email: p.email || '', phone: localPhone(p.phone), address: p.address || '', state: p.state || '', firm_reg: p.firm_reg || '' });
  const [lic, setLic] = useState({ licence_body: h.me.licence_body || 'ICAN', licence_no: h.me.licence_no || '', frc_no: h.me.frc_no || '' });
  const [busy, setBusy] = useState<'p' | 'l' | 'scan' | null>(null);
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
      await rpc('practice_set_licence', { p_practice: pid, p: { ...(lic.licence_no.trim() ? { licence_body: lic.licence_body, licence_no: lic.licence_no } : { licence_body: null, licence_no: null }),
        frc_no: lic.frc_no.trim() || null } });
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      toast(lic.licence_no.trim() ? 'Saved. TaxStreem checks it shortly.' : 'Removed');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function setScan(on: boolean) {
    setBusy('scan'); setErr(null);
    try {
      await rpc('practice_set_conflict_scan', { p_practice: pid, p_on: on });
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      toast(on ? 'The conflicts check now also looks in your clients\' books.' : 'The conflicts check no longer looks in your clients\' books.');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const up = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <>
      <PageHead title="Practice" sub="What clients see of your practice, your letterhead, and your own professional licence." />
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <Card title="Your licence" sub="Clients see it beside your name, and it goes into the statement you accept when you change a return. To audit companies through Counta, a partner needs an ICAN or ANAN number and an FRC number, both verified by TaxStreem.">
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <Field label="Body"><select className="input" value={lic.licence_body} onChange={(e) => setLic({ ...lic, licence_body: e.target.value as any })}><option>ICAN</option><option>ANAN</option><option>CITN</option></select></Field>
          <Field label="Membership number"><input className="input" value={lic.licence_no} onChange={(e) => setLic({ ...lic, licence_no: e.target.value })} maxLength={30} /></Field>
          <Field label="FRC number"><input className="input" value={lic.frc_no} onChange={(e) => setLic({ ...lic, frc_no: e.target.value })} maxLength={40} placeholder="FRC/2014/ICAN/00000001234" data-testid="settings-frc" /></Field>
          <button className="btn btn-secondary" disabled={busy !== null} onClick={saveLicence}>{busy === 'l' ? <Spinner small /> : null}Save</button>
        </div>
        <div className="faint" style={{ fontSize: 13 }}>Now: {h.me.licence_text}{h.me.licence_status === 'rejected' && h.me.licence_note ? `. TaxStreem: ${h.me.licence_note}` : ''}
          {h.me.frc_no ? `. FRC ${h.me.frc_no} (${h.me.frc_status === 'verified' ? 'verified by TaxStreem' : h.me.frc_status === 'rejected' ? `not confirmed${h.me.frc_note ? `: ${h.me.frc_note}` : ''}` : 'unverified'})` : ''}
          {h.me.signs_audits ? '. You can sign audits through Counta.' : ''}</div>
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
      {(partner || h.me.role === 'manager') && <LetterheadCard pid={pid} h={h} />}
      <Card title="Conflicts check" sub={`Each client you add is checked against your current and former clients, your other intakes and the opposing parties you record. Never against another firm's records.${partner ? '' : ' A partner changes this.'}`}>
        <label className="check" style={{ alignItems: 'flex-start', minHeight: 44 }}>
          <input type="checkbox" data-testid="conflict-scan-books" checked={!!p.conflict_scan_books} disabled={!partner || busy !== null} onChange={(e) => setScan(e.target.checked)}
            aria-describedby="conflict-scan-books-hint" style={{ marginTop: 1 }} />
          <span>Also look for the prospect among your clients' customers and suppliers</span>
        </label>
        <div id="conflict-scan-books-hint" className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>Off unless a partner turns it on. The check then also compares each prospect with the customers and suppliers in the books of the clients you look after now.</div>
      </Card>
      <div><Link to="/practice/new" className="btn btn-ghost btn-sm"><Icon name="plus" size={14} />Set up another practice</Link></div>
    </>
  );
}
