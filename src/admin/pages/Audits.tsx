// Audits: TaxStreem's referral fee on each audit paid through Counta, the turnover bands firms price by, how long firms have
// to answer, the firms that offer audits and where each stands, and every audit request with its payments (a payment marked
// for a refund among them).
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { N2, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { pct, type AuditBand, type AuditEngagement } from '../../lib/audits';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { Card, grid, PageHead, Tile } from '../ui';

type Settings = { enabled: boolean; referral_rate: number; request_days: number; bands: number[] };
type Firm = { id: string; name: string; state: string | null; entity_type: string; tin: string | null; vat_registered: boolean; prices: Record<string, number>;
  flutterwave: { status: string; ref: string | null; error: string | null; at: string | null };
  ready: { ready: boolean; listed: boolean; active: boolean; steps: { id: string; done: boolean; text: string }[] } };
type Charge = { tx_ref: string; status: string; amount: number; referral: number; paid_amount: number | null; fee: number | null; error: string | null; at: string; paid_at: string | null };
type AdminAudits = { settings: Settings; bands: AuditBand[]; firms: Firm[]; engagements: (AuditEngagement & { charges: Charge[] })[];
  totals: { paid: number; fees: number; referral: number; waiting: number; refunds: number } };

const plain = (v: string) => v.replace(/[,\s₦]/g, '');

export default function Audits() {
  const q = useQuery({ queryKey: ['admin-audits'], queryFn: () => rpc<AdminAudits>('admin_audits') });
  const d = q.data;
  return (
    <div className="stack" style={{ gap: 18 }}>
      <PageHead title="Audits" sub="Companies above the small company limits ask a partner firm to audit their accounts and pay it through Flutterwave. TaxStreem's referral fee is split off each payment; the rest settles to the firm's bank account." />
      {q.isLoading ? <SkeletonRows n={6} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
        <>
          <div style={grid(190)}>
            <Tile label="Audits paid" value={d.totals.paid.toLocaleString('en-NG')} />
            <Tile label="Fees paid to firms" value={N2(d.totals.fees)} />
            <Tile label="TaxStreem's referral fees" value={N2(d.totals.referral)} />
            <Tile label="Waiting to be answered or paid" value={d.totals.waiting.toLocaleString('en-NG')} />
          </div>
          {d.totals.refunds > 0 && <Alert kind="amber" icon="alert">{d.totals.refunds} payment{d.totals.refunds === 1 ? ' was' : 's were'} made twice or after a request was withdrawn. Refund {d.totals.refunds === 1 ? 'it' : 'them'} from Flutterwave; each is marked below.</Alert>}
          <SettingsCard s={d.settings} bands={d.bands} />
          <Card title="Firms" sub="Practices that started an audit offer, and the steps each has done." pad={false}>
            {!d.firms.length ? <div className="card-pad faint">None yet.</div> : d.firms.map((f) => (
              <div key={f.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(220px,1fr) auto' }} data-testid="admin-audit-firm">
                <span className="m-main" style={{ minWidth: 0 }}>
                  <b>{f.name}</b><span className="faint">{f.state ? ` · ${f.state}` : ''}{f.tin ? ` · TIN ${f.tin}` : ''}{f.vat_registered ? ' · charges VAT' : ''}</span>
                  <span className="faint" style={{ fontSize: 12, display: 'block' }}>
                    {d.bands.filter((b) => f.prices[b.key]).map((b) => `${b.label}: ${N2(f.prices[b.key])}`).join(' · ') || 'No prices yet'}
                  </span>
                  {f.ready.steps.filter((s) => !s.done).map((s) => <span key={s.id} className="faint" style={{ fontSize: 12, display: 'block', color: '#B45309' }}>To do: {s.text}</span>)}
                  {f.flutterwave.ref && <span className="faint mono" style={{ fontSize: 11, display: 'block' }}>{f.flutterwave.ref}</span>}
                </span>
                <span className={'chip ' + (f.ready.listed ? 't-green' : f.ready.ready ? 't-blue' : 't-grey')}>{f.ready.listed ? 'Taking audits' : f.ready.ready ? 'Ready, switched off' : 'Getting ready'}</span>
              </div>
            ))}
          </Card>
          <Card title="Requests and payments" sub="The newest 200." pad={false}>
            {!d.engagements.length ? <div className="card-pad faint">None yet.</div> : d.engagements.map((e) => (
              <div key={e.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(220px,1fr) auto' }} data-testid="admin-audit">
                <span className="m-main" style={{ minWidth: 0 }}>
                  <b>{e.business.name}</b><span className="faint"> · {e.year} · {e.firm?.name || 'firm'}</span>
                  <span className="faint" style={{ fontSize: 12, display: 'block' }}>Fee {N2(e.price)}{Number(e.vat) > 0 ? ` + VAT ${N2(e.vat)}` : ''} · referral {pct(e.referral_rate)} = {N2(e.referral)} · asked {when(e.requested_at)}</span>
                  {e.charges.map((c) => (
                    <span key={c.tx_ref} className="faint" style={{ fontSize: 12, display: 'block', color: c.error ? '#B45309' : undefined }}>
                      <span className="mono">{c.tx_ref}</span> · {c.status} · {N2(c.paid_amount ?? c.amount)}{c.fee != null ? ` · Flutterwave ${N2(c.fee)}` : ''}{c.error ? ` · ${c.error}` : ''}
                    </span>
                  ))}
                </span>
                <span className={'chip ' + (e.status === 'paid' ? 't-green' : e.status === 'accepted' || e.status === 'requested' ? 't-blue' : 't-grey')}>{e.status}</span>
              </div>
            ))}
          </Card>
        </>
      )}
    </div>
  );
}

function SettingsCard({ s, bands }: { s: Settings; bands: AuditBand[] }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ enabled: s.enabled, rate: String(Math.round(s.referral_rate * 10000) / 100), days: String(s.request_days),
    bands: s.bands.map((b) => String(b)).join(', ') });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    try {
      const list = f.bands.split(/[;\n]|,\s+/).map((x) => plain(x)).filter(Boolean).map(Number);
      await rpc('admin_audit_settings_save', { p: { enabled: f.enabled, referral_rate: Number(plain(f.rate)) / 100, request_days: Number(f.days), bands: list } });
      await qc.invalidateQueries({ queryKey: ['admin-audits'] }); toast('Saved');
    } catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  return (
    <Card title="Settings" sub="A new referral fee applies to requests made from now on. Changing the bands asks firms to price the new ones; a band a firm has not priced does not show it.">
      <label className="check" style={{ minHeight: 44, alignItems: 'center' }}>
        <input type="checkbox" checked={f.enabled} onChange={(e) => setF({ ...f, enabled: e.target.checked })} /><span>Businesses can find and pay audit firms in Counta</span>
      </label>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, maxWidth: 520 }}>
        <label className="stack" style={{ gap: 4 }}><span className="label">Referral fee (% of the fee before VAT)</span>
          <input className="input num" inputMode="decimal" value={f.rate} onChange={(e) => setF({ ...f, rate: e.target.value })} data-testid="admin-audit-rate" /></label>
        <label className="stack" style={{ gap: 4 }}><span className="label">Days a firm has to answer</span>
          <input className="input num" inputMode="numeric" value={f.days} onChange={(e) => setF({ ...f, days: e.target.value })} /></label>
      </div>
      <label className="stack" style={{ gap: 4 }}><span className="label">Turnover bands: the upper end of each, in naira</span>
        <input className="input num" value={f.bands} onChange={(e) => setF({ ...f, bands: e.target.value })} /></label>
      <div className="faint" style={{ fontSize: 13 }}>Now: {bands.map((b) => b.label).join(' · ')}</div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div><button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save</button></div>
    </Card>
  );
}
