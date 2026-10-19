// Switches that pause a feature for every business, the businesses with a switch of their own, and the daily limits that
// keep one business from running up the bill for everyone.
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { num, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { FEATURES, featureLabel, tidyError, useSettings } from '../api';
import { Card, grid, PageHead, Toggle } from '../ui';

const LIMITS: { key: string; label: string; what: string }[] = [
  { key: 'guide_day', label: 'Onboarding with Martina, per day', what: 'Conversations one person can start in a day.' },
  { key: 'guide_week', label: 'Onboarding with Martina, per week', what: 'The same over seven days.' },
  { key: 'assistant_day', label: 'The assistant, per day', what: 'Conversations with Martina as the assistant, per person.' },
  { key: 'assistant_week', label: 'The assistant, per week', what: 'The same over seven days.' },
  { key: 'voice_org_phrases', label: 'Spoken phrases per business, per day', what: 'Announcements and read-backs in the business\'s voice.' },
  { key: 'voice_org_chars', label: 'Spoken characters per business, per day', what: 'ElevenLabs bills by the character.' },
  { key: 'voice_user_phrases', label: 'Spoken phrases per person, per day', what: 'Voice previews and read-backs one person asks for.' },
  { key: 'voice_user_chars', label: 'Spoken characters per person, per day', what: '' },
];
const LOOKUPS: { key: string; label: string }[] = [
  { key: 'search', label: 'CAC name searches' }, { key: 'profile', label: 'CAC records' }, { key: 'document', label: 'CAC documents read' },
  { key: 'tin', label: 'Tax ID lookups' }, { key: 'status_report', label: 'CAC status reports' }, { key: 'web', label: 'Web lookups' },
  { key: 'nin', label: 'NIN checks' }, { key: 'nin_slip', label: 'NIN slips read' }, { key: 'product', label: 'Product photos read' },
];

function Switches() {
  const s = useSettings();
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  async function set(id: string, on: boolean) {
    if (!on && confirm !== id) { setConfirm(id); return; }
    setBusy(id); setConfirm(null);
    try { await rpc('admin_save_setting', { p_key: 'switches', p_value: { [id]: on } }); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); await qc.invalidateQueries({ queryKey: ['admin-overview'] });
      toast(`${featureLabel(id)} ${on ? 'is on again' : 'is paused'} for every business`); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(null);
  }
  if (s.isLoading) return <SkeletonRows n={6} />;
  if (!s.data) return <Alert kind="red" icon="alert">{tidyError(s.error)}</Alert>;
  const d = s.data;
  const by = d.updated.switches;
  return (
    <Card title="For every business" sub={`Pausing a feature takes effect within a minute, and the business sees a plain note that TaxStreem has paused it. ${by ? `Last changed ${when(by.at)}${by.by ? ` by ${by.by}` : ''}.` : ''}`} pad={false}>
      {FEATURES.map((f) => {
        const on = d.switches[f.id] !== false;
        return (
          <div key={f.id} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
            <div style={{ minWidth: 0 }}>
              <b>{f.label}</b> {!on && <span className="chip t-amber">Paused</span>}
              <div className="faint" style={{ fontSize: 12, lineHeight: 1.45 }}>{f.what}</div>
              {confirm === f.id && <div style={{ marginTop: 8 }}><Alert kind="amber" icon="alert">This pauses {f.label.toLowerCase()} for every business except those switched on below. <button className="btn btn-danger btn-sm" style={{ marginLeft: 8 }} onClick={() => set(f.id, false)}>Pause it</button> <button className="btn btn-ghost btn-sm" onClick={() => setConfirm(null)}>Keep it on</button></Alert></div>}
            </div>
            <span className="row" style={{ gap: 6 }}>{busy === f.id && <Spinner small />}<Toggle on={on} disabled={busy !== null} label={f.label} onChange={(v) => set(f.id, v)} /></span>
          </div>
        );
      })}
    </Card>
  );
}

function Overrides() {
  const s = useSettings();
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  async function reset(org: string, feature: string) {
    setBusy(org + feature);
    try { await rpc('admin_org_switch', { p_org: org, p_feature: feature, p_enabled: null }); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); toast('Back to what everyone has'); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(null);
  }
  const rows = s.data?.overrides || [];
  return (
    <Card title={`Businesses with their own switch (${rows.length})`} sub="Set from a business's page. These win over the switch for everyone, either way." pad={false}>
      {!rows.length ? <div className="card-pad muted" style={{ fontSize: 14 }}>None. Every business follows the switches above.</div> : rows.map((o) => (
        <div key={o.org_id + o.feature} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.2fr) minmax(0,1.2fr) auto' }}>
          <div style={{ minWidth: 0 }}><Link to={`/admin/businesses/${o.org_id}`}><b>{o.business}</b></Link><div className="faint" style={{ fontSize: 12 }}>{when(o.set_at)}</div></div>
          <div style={{ minWidth: 0 }}>{featureLabel(o.feature)} <span className={'chip ' + (o.enabled ? 't-green' : 't-amber')}>{o.enabled ? 'On' : 'Off'}</span>
            {o.note && <div className="faint" style={{ fontSize: 12 }}>{o.note}</div>}</div>
          <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => reset(o.org_id, o.feature)}>{busy === o.org_id + o.feature ? <Spinner small /> : null}As everyone</button>
        </div>
      ))}
    </Card>
  );
}

function Limits() {
  const s = useSettings();
  const qc = useQueryClient();
  const toast = useToast();
  const [form, setForm] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const d = s.data;
  function fill() {
    if (!d) return;
    const f: Record<string, string> = {};
    for (const l of LIMITS) f[l.key] = String(d.limits[l.key] ?? '');
    for (const l of LOOKUPS) f['lookups.' + l.key] = String(d.limits.lookups?.[l.key] ?? '');
    setForm(f);
  }
  useEffect(fill, [d]);
  if (!d) return null;
  const def = (k: string) => (k.startsWith('lookups.') ? d.defaults.limits.lookups?.[k.slice(8)] : d.defaults.limits[k]);
  const cur = (k: string) => (k.startsWith('lookups.') ? d.limits.lookups?.[k.slice(8)] : d.limits[k]);
  const changed = Object.keys(form).filter((k) => String(cur(k)) !== form[k]);
  async function save() {
    const patch: Record<string, any> = {};
    for (const k of changed) {
      const n = Number(form[k].replace(/,/g, ''));
      if (!Number.isInteger(n) || n < 0) { setErr('Limits are whole numbers of 0 or more.'); return; }
      if (k.startsWith('lookups.')) patch.lookups = { ...(patch.lookups || {}), [k.slice(8)]: n }; else patch[k] = n;
    }
    setBusy(true); setErr(null);
    try { await rpc('admin_save_setting', { p_key: 'limits', p_value: patch }); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); toast('Limits saved'); }
    catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  const input = (k: string, label: string, what?: string) => (
    <label key={k} className="stack" style={{ gap: 4, minWidth: 0 }}>
      <span style={{ fontSize: 13, fontWeight: 600 }}>{label}</span>
      <input className="input num" inputMode="numeric" value={form[k] ?? ''} onChange={(e) => setForm({ ...form, [k]: e.target.value })} aria-label={label} />
      <span className="faint" style={{ fontSize: 12, lineHeight: 1.4 }}>{what ? `${what} ` : ''}{String(def(k)) !== form[k] ? `Counta's default is ${num(def(k))}.` : ''}</span>
    </label>
  );
  const by = d.updated.limits;
  return (
    <Card title="Daily limits" sub={`A person or business that reaches one is told to try again tomorrow. 0 stops it altogether. ${by ? `Last changed ${when(by.at)}${by.by ? ` by ${by.by}` : ''}.` : ''}`}
      right={changed.length ? <div className="row" style={{ gap: 6 }}>
        <button className="btn btn-ghost btn-sm" disabled={busy} onClick={fill}>Undo</button>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save {changed.length} change{changed.length === 1 ? '' : 's'}</button>
      </div> : undefined}>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div style={grid(230)}>{LIMITS.map((l) => input(l.key, l.label, l.what))}</div>
      <div className="mini-label" style={{ marginTop: 6 }}>Lookups per business, per day</div>
      <div style={grid(190)}>{LOOKUPS.map((l) => input('lookups.' + l.key, l.label))}</div>
    </Card>
  );
}

export default function LimitsPage() {
  return (
    <>
      <PageHead title="Limits and switches" sub="Pause a feature for everyone when a provider is down or a bill is running away, and set how much any one business can use in a day." />
      <Switches />
      <Overrides />
      <Limits />
    </>
  );
}
