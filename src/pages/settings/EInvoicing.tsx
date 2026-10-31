// E-invoicing with the NRS (MBS), in Settings: what is still missing before the business can send invoices to NRS, its
// own NRS keys (wrapped in TaxStreem's HSM; only their last four characters come back), the service code and the items
// whose HS codes need a person. See docs/e-invoicing.md.
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc, supabase } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { when } from '../../lib/format';
import { useEinvoice, type EinvReady, type EinvSettings } from '../../lib/einvoice';
import { Icon } from '../../components/Icon';
import { Alert, Field, SkeletonRows } from '../../components/ui';
import { NrsCodePicker } from '../../components/NrsCodePicker';

type Check = { ok: boolean; note: string; saved: boolean } | null;
const INVALIDATE = ['einvoice'];

function Readiness({ list }: { list: EinvReady[] }) {
  const nav = useNavigate();
  return (
    <div className="stack" style={{ gap: 0 }} data-testid="einv-ready">
      {list.map((r) => {
        const tone = r.ok ? 'var(--green, #15803D)' : r.blocking ? '#B45309' : '#6B7280';
        const go = !r.ok && r.link && !r.link.startsWith('/settings#einvoicing');
        return (
          <div key={r.id} className="row" data-ready={r.id} data-ok={r.ok ? 'yes' : 'no'}
            style={{ gap: 10, alignItems: 'flex-start', padding: '9px 0', borderTop: '1px solid var(--line, #EEE)' }}>
            <span style={{ flex: 'none', marginTop: 1 }}><Icon name={r.ok ? 'check' : 'alert'} size={16} color={tone} /></span>
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{r.title}{!r.ok && !r.blocking && <span className="faint" style={{ fontWeight: 400, fontSize: 12 }}> · does not hold you back</span>}</div>
              <div className="muted" style={{ fontSize: 13, lineHeight: 1.5, wordBreak: 'break-word' }}>{r.detail}</div>
            </div>
            {go && <button className="btn btn-ghost btn-sm" style={{ flex: 'none' }} onClick={() => nav(r.link!)}>Open</button>}
          </div>
        );
      })}
    </div>
  );
}

function CheckResult({ s, fresh }: { s: EinvSettings; fresh: Check }) {
  const c = fresh ? { ok: fresh.ok, note: fresh.note, at: fresh.saved ? new Date().toISOString() : null, current: true } : s.check;
  if (!c) return null;
  return (
    <Alert kind={c.ok && c.current ? 'green' : c.current ? 'red' : 'grey'} icon={c.ok && c.current ? 'check' : 'info'}>
      <div data-testid="einv-check" style={{ wordBreak: 'break-word' }}>{c.note}</div>
      <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>
        {c.at ? `Tested ${when(c.at)}.` : 'Not saved as a test.'}{!c.current && ' The keys or IDs have changed since: test again.'}
      </div>
    </Alert>
  );
}

// The business's own keys. Each box is write-only: a saved key shows as its last four characters and is replaced by
// pasting a new one.
function KeysForm({ s, orgId }: { s: EinvSettings; orgId: string }) {
  const toast = useToast();
  const { run, busy } = useAction();
  const [ids, setIds] = useState({ business_id: s.business_id || '', service_id: s.service_id || '' });
  const [k, setK] = useState({ api_key: '', api_secret: '', crypto_keys: '' });
  const [fresh, setFresh] = useState<Check>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);
  useEffect(() => { setIds({ business_id: s.business_id || '', service_id: s.service_id || '' }); }, [s.business_id, s.service_id]);
  const hasAll = !!(s.keys.api_key && s.keys.api_secret && s.keys.crypto_keys);
  const idsChanged = ids.business_id.trim().toLowerCase() !== (s.business_id || '') || ids.service_id.replace(/\s/g, '').toUpperCase() !== (s.service_id || '');
  const typed = Object.entries(k).filter(([, v]) => v.trim());

  async function test() {
    const r = await run(async () => {
      const x = await edge<{ check: Check }>('einvoice', { action: 'settings_check', org_id: orgId });
      if (x.ok === false) throw new Error(x.error || 'The test could not run.');
      return x.check;
    }, { invalidate: INVALIDATE });
    if (r !== undefined) setFresh(r);
  }
  async function saveIds() {
    const r = await run(() => rpc('einvoice_settings_set', { p_org: orgId, p: { business_id: ids.business_id, service_id: ids.service_id } }), { ok: 'Saved', invalidate: INVALIDATE });
    if (r !== undefined && (hasAll || s.platform_keys)) await test();
  }
  async function saveKeys(body: Record<string, string>) {
    const r = await run(async () => {
      const x = await edge<{ keys: EinvSettings['keys']; check: Check }>('einvoice', { action: 'settings_keys', org_id: orgId, ...body });
      if (x.ok === false) throw new Error(x.error || 'The keys could not be saved.');
      return x;
    }, { ok: Object.values(body).some((v) => !v) ? 'Removed' : 'Keys saved', invalidate: INVALIDATE });
    if (r !== undefined) { setK({ api_key: '', api_secret: '', crypto_keys: '' }); setFresh(r.check); setRemoving(null); }
  }
  async function readFile(f: File | undefined) {
    if (!f) return;
    if (f.size > 20_000) { toast('crypto_keys.txt is a small file. Choose the one from the NRS dashboard.', 'err'); return; }
    const text = await f.text();
    setK((x) => ({ ...x, crypto_keys: text.trim() }));
  }
  const saved = (field: keyof EinvSettings['keys'], label: string) => s.keys[field] && (
    <div className="row" style={{ gap: 6, fontSize: 12, marginTop: 4 }}>
      <span className="faint">Saved: {s.keys[field]}</span>
      <button className="btn btn-ghost btn-xs" disabled={busy} onClick={() => (removing === field ? saveKeys({ [field]: '' }) : setRemoving(field))}>
        {removing === field ? `Tap again to remove the ${label}` : 'Remove'}</button>
    </div>
  );
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="einv-keys">
      <div className="mini-label">Your NRS keys</div>
      <div className="hint" style={{ marginTop: -6 }}>From your business's NRS e-invoicing dashboard. Counta wraps the key, the secret and crypto_keys.txt in TaxStreem's
        hardware security module before they are stored, and shows only their last four characters after that.</div>
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Field label="Business ID"><input className="input" value={ids.business_id} onChange={(e) => setIds({ ...ids, business_id: e.target.value })}
          placeholder="6dc03c76-1d83-…" autoComplete="off" spellCheck={false} /></Field>
        <Field label="Service ID"><input className="input" value={ids.service_id} onChange={(e) => setIds({ ...ids, service_id: e.target.value })}
          placeholder="8 letters and numbers" maxLength={12} autoComplete="off" spellCheck={false} /></Field>
      </div>
      {idsChanged && <div><button className="btn btn-secondary btn-sm" disabled={busy} onClick={saveIds}>Save the IDs</button></div>}
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        <Field label="API key">
          <input className="input" type="password" value={k.api_key} onChange={(e) => setK({ ...k, api_key: e.target.value })} autoComplete="new-password"
            placeholder={s.keys.api_key ? 'Paste a new key to replace it' : 'Paste the API key'} aria-label="API key" />
          {saved('api_key', 'API key')}
        </Field>
        <Field label="API secret">
          <input className="input" type="password" value={k.api_secret} onChange={(e) => setK({ ...k, api_secret: e.target.value })} autoComplete="new-password"
            placeholder={s.keys.api_secret ? 'Paste a new secret to replace it' : 'Paste the API secret'} aria-label="API secret" />
          {saved('api_secret', 'API secret')}
        </Field>
      </div>
      <Field label="crypto_keys.txt" hint="Under My Account, Manage Cryptographic Keys on the NRS dashboard. Choose the file or paste what is in it.">
        <textarea className="input" value={k.crypto_keys} onChange={(e) => setK({ ...k, crypto_keys: e.target.value })} spellCheck={false} aria-label="crypto_keys.txt"
          placeholder={s.keys.crypto_keys ? 'Paste a new crypto_keys.txt to replace it' : '{ "public_key": "…", "certificate": "…" }'}
          style={{ minHeight: 64, fontFamily: 'ui-monospace, monospace', fontSize: 12 }} />
        <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
          <input ref={file} type="file" accept=".txt,.json,text/plain,application/json" style={{ display: 'none' }} onChange={(e) => { readFile(e.target.files?.[0]); e.target.value = ''; }} />
          <button className="btn btn-ghost btn-xs" onClick={() => file.current?.click()}><Icon name="upload" size={13} />Choose the file</button>
        </div>
        {saved('crypto_keys', 'crypto_keys.txt')}
      </Field>
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="btn btn-primary" disabled={busy || !typed.length} onClick={() => saveKeys(Object.fromEntries(typed.map(([f, v]) => [f, v.trim()])))}>
          {s.platform_keys ? 'Save the keys' : 'Save and test with NRS'}</button>
        <button className="btn btn-secondary" disabled={busy || !(hasAll || s.platform_keys)} onClick={test}>Test with NRS</button>
      </div>
      <CheckResult s={s} fresh={fresh} />
    </div>
  );
}

function ServiceCode({ s, orgId }: { s: EinvSettings; orgId: string }) {
  const { run, busy } = useAction();
  const [pick, setPick] = useState(false);
  const set = (code: string) => run(() => rpc('einvoice_settings_set', { p_org: orgId, p: { service_code: code } }),
    { ok: code ? `Service code set to ${code}` : 'Gemini will choose it again', invalidate: INVALIDATE });
  const sv = s.service;
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="einv-service">
      <div className="mini-label">Service code</div>
      <div className="hint" style={{ marginTop: -2 }}>The NRS code (ISIC) for the services you sell, used on service and delivery lines.</div>
      {sv ? (
        <div style={{ fontSize: 14 }}><b style={{ fontVariantNumeric: 'tabular-nums' }}>{sv.code}</b> <span className="muted">{sv.label}</span>
          <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{sv.source === 'manual' ? 'Chosen by you.'
            : `Chosen by Gemini${sv.confidence != null ? `, ${Math.round(Number(sv.confidence) * 100)}% sure` : ''}${sv.reason ? `: ${sv.reason}` : '.'}`}</div>
        </div>
      ) : <div className="muted" style={{ fontSize: 14 }}>{s.service_waiting ? 'Gemini is choosing it.' : 'Not chosen yet.'}</div>}
      {s.can.edit && (pick ? <NrsCodePicker list="services-codes" busy={busy} onCancel={() => setPick(false)} onPick={async (c) => { if (await set(c) !== undefined) setPick(false); }} /> : (
        <div className="row wrap" style={{ gap: 6 }}>
          <button className="btn btn-secondary btn-sm" onClick={() => setPick(true)}>{sv ? 'Change' : 'Choose it'}</button>
          {sv?.source === 'manual' && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => set('')}>Let Gemini choose</button>}
        </div>
      ))}
    </div>
  );
}

// Items Gemini was unsure about or could not code: each opens on Items, where the code is confirmed or chosen.
function HsToConfirm({ orgId, r }: { orgId: string; r: EinvReady | undefined }) {
  const nav = useNavigate();
  const q = useQuery({ queryKey: ['einvoice', 'hs-review', orgId, r?.counts?.review, r?.counts?.coded], queryFn: async () => {
    const { data, error } = await supabase.from('items').select('id, name, hs_code, hs_review').eq('org_id', orgId).eq('archived', false)
      // Codes to confirm first, then items with none.
      .eq('hs_review', true).order('hs_code', { ascending: true, nullsFirst: false }).order('name').limit(12);
    if (error) throw error;
    return (data || []) as { id: string; name: string; hs_code: string | null; hs_review: boolean }[];
  } });
  const c = r?.counts;
  if (!c || !c.items) return null;
  const rows = q.data || [];
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="einv-hs">
      <div className="mini-label">HS codes on items</div>
      <div className="muted" style={{ fontSize: 13 }}>{r!.detail}</div>
      {rows.length > 0 && (
        <div className="stack" style={{ gap: 0 }}>
          {rows.map((x) => (
            <div key={x.id} className="row" style={{ gap: 8, padding: '6px 0', borderTop: '1px solid var(--line, #EEE)' }}>
              <span className="ellipsis" style={{ flex: 1, minWidth: 0, fontSize: 13 }}>{x.name}</span>
              <span className="faint" style={{ fontSize: 12, flex: 'none' }}>{x.hs_code || 'no code'}</span>
              <button className="btn btn-ghost btn-xs" style={{ flex: 'none' }} onClick={() => nav('/inventory/items', { state: { item: x.id, tab: 'details' } })}>{x.hs_code ? 'Confirm' : 'Choose'}</button>
            </div>
          ))}
          {c.review > rows.length && <div className="faint" style={{ fontSize: 12, paddingTop: 4 }}>and {c.review - rows.length} more on Items.</div>}
        </div>
      )}
    </div>
  );
}

export function EInvoicingPanel() {
  const { orgId } = useSession();
  const q = useEinvoice(orgId);
  const { run, busy } = useAction();
  const s = q.data;
  if (q.isError) return <div className="muted" style={{ fontSize: 13 }}>Only people who change settings, keep the books or file tax see e-invoicing.</div>;
  if (!s || !orgId) return <SkeletonRows n={3} />;
  if (!s.started) {
    return (
      <div className="stack" style={{ gap: 12 }} data-testid="einv-start">
        <div className="ink3" style={{ fontSize: 13, lineHeight: 1.6 }}>
          NRS's e-invoicing system, the Merchant Buyer Solution, checks and signs each invoice between businesses before the buyer gets it, and keeps a
          record of every sale. TaxStreem connects Counta to it. Getting ready takes your NRS keys and a few details NRS puts on every invoice, and Gemini
          chooses the HS code of each item from NRS's list while you add them.
        </div>
        {s.can.edit ? <div><button className="btn btn-primary" disabled={busy} onClick={() => run(() => rpc('einvoice_settings_set', { p_org: orgId, p: {} }),
          { ok: 'Started. Gemini is choosing your codes.', invalidate: INVALIDATE })}>Get ready for e-invoicing</button></div>
          : <div className="hint">Someone who changes the business's settings starts this.</div>}
      </div>
    );
  }
  const blocking = s.readiness.filter((r) => r.blocking && !r.ok).length;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="row wrap" style={{ gap: 8, alignItems: 'center' }} data-testid="einv-status">
        <span className={'chip ' + (s.ready ? 't-green' : 't-amber')}>{s.ready ? 'Ready for NRS' : 'Getting ready'}</span>
        <span className="muted" style={{ fontSize: 13 }}>{s.ready ? 'Everything NRS needs is in place.' : `${blocking} ${blocking === 1 ? 'thing' : 'things'} still to do.`}</span>
      </div>
      {s.platform_keys && <Alert kind="blue" icon="info">You are on TaxStreem's keys while NRS is in test mode. Add your own keys below before you go live.</Alert>}
      <Readiness list={s.readiness} />
      {s.can.edit ? <KeysForm s={s} orgId={orgId} /> : <CheckResult s={s} fresh={null} />}
      <ServiceCode s={s} orgId={orgId} />
      <HsToConfirm orgId={orgId} r={s.readiness.find((r) => r.id === 'items')} />
    </div>
  );
}
