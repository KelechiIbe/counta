// E-invoicing with the NRS (MBS), in Settings: what is still missing before the business can send invoices to NRS, its
// own NRS keys (wrapped in TaxStreem's HSM; only their last four characters come back), the service code and the items
// whose HS codes need a person. See docs/e-invoicing.md.
import { useEffect, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc, supabase } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, N2, num, when } from '../../lib/format';
import { useEinvoice, useEinvOnly, useEinvOnlyList, type EinvOnlyFilter, type EinvOnlyRow, type EinvQueue, type EinvReady, type EinvSettings } from '../../lib/einvoice';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Pills, SkeletonRows, Spinner } from '../../components/ui';
import { NrsCodePicker } from '../../components/NrsCodePicker';
import { BuyerDelivery, EinvoiceCopies, EinvoiceStamp, nrsChip } from '../../components/Einvoice';

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
          {sv.review && <div style={{ marginTop: 4 }}><span className="chip t-yellow" data-testid="einv-service-review">Needs your answer</span>
            <span className="faint" style={{ fontSize: 12, marginLeft: 6 }}>Gemini was not sure. Confirm it, or choose another.</span></div>}
        </div>
      ) : <div className="muted" style={{ fontSize: 14 }}>{s.service_waiting ? 'Gemini is choosing it.' : 'Not chosen yet.'}</div>}
      {s.can.edit && (pick ? <NrsCodePicker list="services-codes" busy={busy} onCancel={() => setPick(false)} onPick={async (c) => { if (await set(c) !== undefined) setPick(false); }} /> : (
        <div className="row wrap" style={{ gap: 6 }}>
          {sv?.review && <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => run(() => rpc('einvoice_settings_set', { p_org: orgId, p: { service_confirm: true } }),
            { ok: `Service code ${sv.code} confirmed`, invalidate: INVALIDATE })}>Confirm {sv.code}</button>}
          <button className="btn btn-secondary btn-sm" onClick={() => setPick(true)}>{sv ? 'Change' : 'Choose it'}</button>
          {sv?.source === 'manual' && <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => set('')}>Let Gemini choose</button>}
        </div>
      ))}
    </div>
  );
}

// The switch: once everything NRS needs is in place, sales start going to NRS. Sales issued before stay as they are.
function SendSwitch({ s, orgId }: { s: EinvSettings; orgId: string }) {
  const { run, busy } = useAction();
  const [sure, setSure] = useState(false);
  const set = (on: boolean) => run(() => rpc('einvoice_settings_set', { p_org: orgId, p: { enabled: on } }),
    { ok: on ? 'Sales now go to NRS' : 'Sales no longer go to NRS', invalidate: INVALIDATE });
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="einv-switch" data-on={s.enabled ? 'yes' : 'no'}>
      <div className="mini-label">Sending to NRS</div>
      {s.enabled ? (
        <>
          <div style={{ fontSize: 14 }}><span className="chip t-green">On</span> <span className="muted">since {when(s.enabled_at)}. Invoices, receipts and credit notes go to NRS as they are issued.</span></div>
          {s.can.edit && (sure
            ? <div className="row wrap" style={{ gap: 6 }}><button className="btn btn-danger btn-sm" disabled={busy} onClick={async () => { await set(false); setSure(false); }}>Stop sending to NRS</button>
                <button className="btn btn-ghost btn-sm" onClick={() => setSure(false)}>Keep it on</button>
                <span className="faint" style={{ fontSize: 12 }}>Sales already waiting still go.</span></div>
            : <div><button className="btn btn-ghost btn-sm" onClick={() => setSure(true)}>Stop sending</button></div>)}
        </>
      ) : (
        <>
          <div className="muted" style={{ fontSize: 13 }}>{s.ready
            ? 'Everything NRS needs is in place. Once it is on, each sale goes to NRS as it is issued: to a business or government, NRS signs it before it reaches them; to anyone else, it is reported within the day. Sales issued before stay as they are.'
            : 'Switch it on once everything above is in place.'}</div>
          {s.can.edit && <div><button className="btn btn-primary btn-sm" disabled={busy || !s.ready} onClick={() => set(true)}>Start sending to NRS</button></div>}
        </>
      )}
    </div>
  );
}

// How the sending is going, and the sales that need a person: refused by NRS, or waiting longer than they should. One
// kept outside the books opens here, under E-invoicing.
function SendQueue({ q, openOnly }: { q: EinvQueue; openOnly: (id: string) => void }) {
  const nav = useNavigate();
  return (
    <div className="stack" style={{ gap: 6 }} data-testid="einv-queue">
      <div className="mini-label">Sales and NRS</div>
      <div className="row wrap" style={{ gap: 6, fontSize: 13 }}>
        <span className="chip t-green">{q.signed} signed{q.signed_today ? `, ${q.signed_today} today` : ''}</span>
        <span className={'chip ' + (q.waiting ? 't-amber' : 't-grey')}>{q.waiting} waiting{q.oldest_at && q.waiting ? `, oldest ${when(q.oldest_at)}` : ''}</span>
        <span className={'chip ' + (q.refused ? 't-red' : 't-grey')}>{q.refused} refused</span>
      </div>
      {q.to_buyers && q.to_buyers.sending + q.to_buyers.delivered + q.to_buyers.failed > 0 && (
        <div className="row wrap" style={{ gap: 6, fontSize: 13 }} data-testid="einv-to-buyers">
          <span className="faint" style={{ fontSize: 12 }}>To buyers through NRS:</span>
          <span className="chip t-green">{q.to_buyers.delivered} delivered{q.to_buyers.acknowledged ? `, ${q.to_buyers.acknowledged} received` : ''}</span>
          {q.to_buyers.sending > 0 && <span className="chip t-amber">{q.to_buyers.sending} on the way</span>}
          {q.to_buyers.failed > 0 && <span className="chip t-red">{q.to_buyers.failed} not delivered</span>}
        </div>
      )}
      {q.received && q.received.total + q.received.failed > 0 && (
        <div className="row wrap" style={{ gap: 6, fontSize: 13 }} data-testid="einv-received">
          <span className="faint" style={{ fontSize: 12 }}>From suppliers through NRS:</span>
          <span className="chip t-blue">{q.received.total} received</span>
          {q.received.to_review > 0 && <button className="btn btn-ghost btn-xs" onClick={() => nav('/purchases/bills?tab=invoices')}>{q.received.to_review} to review</button>}
        </div>
      )}
      {q.attention.length > 0 && (
        <div className="stack" style={{ gap: 0 }}>
          {q.attention.map((a) => (
            <div key={a.sale_id} className="row" style={{ gap: 8, padding: '7px 0', borderTop: '1px solid var(--line, #EEE)', alignItems: 'flex-start' }} data-testid="einv-attention">
              <div style={{ flex: 1, minWidth: 0, fontSize: 13 }}>
                <div><b>{a.number}</b> <span className="muted">{a.customer_name || ''}</span>{' '}
                  <span className={'chip ' + (a.state === 'refused' ? 't-red' : 't-amber')} style={{ fontSize: 11 }}>{a.state === 'refused' ? 'Refused' : a.state === 'not_delivered' ? 'Not delivered to the buyer' : 'Waiting'}</span></div>
                {a.note && <div className="faint" style={{ fontSize: 12, wordBreak: 'break-word' }}>{a.note}</div>}
              </div>
              <button className="btn btn-ghost btn-xs" style={{ flex: 'none' }} onClick={() => (a.source === 'only' ? openOnly(a.sale_id) : nav(`/sell/sales?open=${a.sale_id}`))}>Open</button>
            </div>
          ))}
        </div>
      )}
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

// ------------------------------------------------------------------ e-invoices kept outside the books (Prism's partners)
const BUYER_CHIP: Record<string, [string, string]> = { due: ['t-amber', 'To the buyer'], sending: ['t-amber', 'To the buyer'], transmitting: ['t-amber', 'On its way'],
  transmitted: ['t-green', 'Delivered'], acknowledged: ['t-green', 'Received'], failed: ['t-red', 'Not delivered'] };
const DOC_WORDS: Record<string, string> = { invoice: 'Invoice', receipt: 'Receipt', credit_note: 'Credit note' };

function OutsideBooks({ orgId, count, open }: { orgId: string; count: number; open: (id: string) => void }) {
  const [state, setState] = useState<'all' | NonNullable<EinvOnlyFilter['state']>>('all');
  const [q, setQ] = useState('');
  const [term, setTerm] = useState('');
  useEffect(() => { const t = window.setTimeout(() => setTerm(q.trim()), 250); return () => window.clearTimeout(t); }, [q]);
  const list = useEinvOnlyList(orgId, { ...(state === 'all' ? {} : { state }), ...(term ? { q: term } : {}), limit: 50 });
  const rows = list.data?.rows || [];
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="einv-only">
      <div className="mini-label">From partners, outside the books</div>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>
        Invoices your partners' systems sent through TaxStreem Prism for e-invoicing only. NRS signs them for the business; they are not in your books, reports or tax returns.
      </div>
      <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
        <Pills value={state} onChange={setState} options={[{ id: 'all', label: 'All', count }, { id: 'attention', label: 'Needs a person' }, { id: 'waiting', label: 'Waiting' }, { id: 'signed', label: 'Signed' }]} />
        <input className="input" style={{ flex: '1 1 160px', minWidth: 0, maxWidth: 260 }} placeholder="Number, customer or ref" value={q} onChange={(e) => setQ(e.target.value)}
          aria-label="Search e-invoices from partners" data-testid="einv-only-search" />
      </div>
      {list.isLoading ? <SkeletonRows n={3} /> : !rows.length ? <Empty>{term || state !== 'all' ? 'None match.' : 'None yet.'}</Empty> : (
        <div className="stack" style={{ gap: 0 }}>
          {rows.map((r) => <OnlyRow key={r.id} r={r} onOpen={() => open(r.id)} />)}
          {(list.data?.total || 0) > rows.length && <div className="faint" style={{ fontSize: 12, paddingTop: 6 }}>Showing {rows.length} of {num(list.data?.total)}. Search to find others.</div>}
        </div>
      )}
    </div>
  );
}

function OnlyRow({ r, onOpen }: { r: EinvOnlyRow; onOpen: () => void }) {
  const bc = r.buyer_state ? BUYER_CHIP[r.buyer_state] : null;
  return (
    <button className="row click" onClick={onOpen} data-testid="einv-only-row" data-state={r.state}
      style={{ gap: 8, padding: '8px 0', alignItems: 'flex-start', width: '100%', textAlign: 'left', background: 'none', border: 'none',
        borderTop: '1px solid var(--line, #EEE)', cursor: 'pointer', font: 'inherit', color: 'inherit' }}>
      <div style={{ flex: 1, minWidth: 0, fontSize: 13 }}>
        <div className="row wrap" style={{ gap: 6, alignItems: 'center' }}>
          <b>{r.number}</b>{r.doc !== 'invoice' && <span className="faint" style={{ fontSize: 12 }}>{DOC_WORDS[r.doc]}</span>}
          <span className="muted ellipsis" style={{ minWidth: 0 }}>{r.customer_name || 'Walk-in customer'}</span>
        </div>
        <div className="faint" style={{ fontSize: 12, wordBreak: 'break-word' }}>{fmtDay(r.issue_date)}{r.partner_name ? ` · ${r.partner_name}` : ''}{r.ref ? ` · ${r.ref}` : ''}</div>
        {r.state === 'refused' && r.note && <div style={{ fontSize: 12, color: 'var(--red, #B42318)', wordBreak: 'break-word' }}>{r.note}</div>}
      </div>
      <div className="stack" style={{ gap: 4, alignItems: 'flex-end', flex: 'none' }}>
        <span className="num" style={{ fontSize: 13 }}>{N2(r.total)}</span>
        <div className="row" style={{ gap: 4 }}>{nrsChip(r.state)}{bc && <span className={'chip ' + bc[0]} style={{ marginLeft: 4 }}>{bc[1]}</span>}</div>
      </div>
    </button>
  );
}

// One of them: the invoice as the partner sent it, its stamp, and where it stands with NRS and the buyer.
function OnlyDrawer({ id, onClose }: { id: string; onClose: () => void }) {
  const d = useEinvOnly(id);
  const x = d.data;
  const e = x?.einvoice;
  return (
    <Drawer onClose={onClose} width={640}>
      <div className="drawer-hd"><div className="grow" style={{ minWidth: 0 }}>
        <div className="row wrap" style={{ gap: 8 }}><div className="drawer-title">{x ? `${DOC_WORDS[x.doc]} ${x.number}` : 'Loading…'}</div>{e && nrsChip(e.state)}</div>
        {x && <div className="muted" style={{ fontSize: 13, wordBreak: 'break-word' }} data-testid="einv-only-source">
          From {x.partner_name || 'a partner'} through TaxStreem Prism{x.ref ? ` · ref ${x.ref}` : ''} · {when(x.created_at)}</div>}
      </div><button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }} data-testid="einv-only-drawer">
        {d.isError ? <Alert kind="red" icon="alert">{(d.error as Error)?.message || 'This e-invoice could not be opened.'}</Alert> : !x ? <Spinner /> : (
          <>
            <Alert kind="grey" icon="info">E-invoicing only: NRS signs it for the business, and it stays out of your books, reports and tax returns.</Alert>
            {e && (e.state === 'waiting' || e.state === 'sending') && <Alert kind="yellow" icon="clock">Waiting for NRS{e.kind === 'report' ? ', with the next batch' : ' to sign it'}.
              {e.tries > 0 && e.note ? <div style={{ marginTop: 4, fontSize: 13 }}>{e.note}{e.next_try_at ? ` Next try ${when(e.next_try_at)}.` : ''}</div> : null}</Alert>}
            {e?.state === 'signed' && <Alert kind="green" icon="check">Signed by NRS{e.signed_at ? ` ${when(e.signed_at)}` : ''}.{e.pay_status === 'PAID' ? ' NRS knows it is paid.' : ''}</Alert>}
            {e?.state === 'refused' && <Alert kind="red" icon="alert"><div style={{ wordBreak: 'break-word' }}>{e.note || 'NRS refused it.'}</div>
              <div style={{ marginTop: 4, fontSize: 13 }}>{x.partner_name || 'The partner'} sends it again, corrected, through Prism.</div></Alert>}
            {e?.state === 'signed' && e.buyer && <BuyerDelivery id={x.id} number={x.number} b={e.buyer} canAct={x.can.send_to_buyer} refresh={['einvoice', 'only-doc', x.id]} />}
            {e?.irn && (e.state === 'signed' || e.kind === 'report') && <EinvoiceStamp irn={e.irn} qr={e.qr} signed={e.state === 'signed'} />}
            {e && <EinvoiceCopies docId={x.id} kind={e.kind} signed={e.state === 'signed'} />}
            <div className="row wrap" style={{ gap: 16, fontSize: 13 }}>
              <div className="stack" style={{ gap: 2, minWidth: 180, flex: '1 1 200px' }}>
                <div className="mini-label">Customer</div>
                {x.customer && !x.customer.walk_in ? <>
                  <b>{x.customer.name}</b>
                  {x.customer.tin && <span className="muted">Tax ID {x.customer.tin}</span>}
                  {(x.customer.street || x.customer.city) && <span className="muted" style={{ wordBreak: 'break-word' }}>{[x.customer.street, x.customer.city, x.customer.lga, x.customer.state].filter(Boolean).join(', ')}{x.customer.postcode ? ` ${x.customer.postcode}` : ''}</span>}
                  {(x.customer.email || x.customer.phone) && <span className="muted" style={{ wordBreak: 'break-word' }}>{[x.customer.email, x.customer.phone].filter(Boolean).join(' · ')}</span>}
                </> : <span className="muted">Walk-in customer</span>}
              </div>
              <div className="stack" style={{ gap: 2, minWidth: 140 }}>
                <div className="mini-label">Dates</div>
                <span>Issued {fmtDay(x.issue_date)}</span>
                {x.due_date && <span className="muted">Due {fmtDay(x.due_date)}</span>}
                <span className="muted">{x.paid ? `Paid${x.paid_at ? ` ${when(x.paid_at)}` : ''}${x.pay_reference ? ` · ${x.pay_reference}` : ''}` : 'Not paid yet'}</span>
              </div>
            </div>
            {x.original && <div className="muted" style={{ fontSize: 13 }}>Corrects invoice {x.original.number}.</div>}
            {x.credit_notes.length > 0 && <div className="muted" style={{ fontSize: 13 }}>Credit notes: {x.credit_notes.map((c) => `${c.number} (${N2(c.total)})`).join(', ')}.</div>}
            {/* On a phone each line is two rows: what it is, then the quantity, price and VAT beside the amount. */}
            <div className="card show-sm" data-testid="einv-only-lines-sm">
              <div style={{ display: 'block' }}>
                {x.lines.map((l) => (
                  <div key={l.line_no} style={{ padding: '8px 12px', borderBottom: '1px solid var(--line, #EEE)', fontSize: 13 }}>
                    <div style={{ wordBreak: 'break-word' }}>{l.description}</div>
                    <div className="row" style={{ gap: 8, alignItems: 'flex-start' }}>
                      <span className="faint" style={{ fontSize: 12, flex: 1, minWidth: 0, wordBreak: 'break-word' }}>
                        {num(l.qty, 3)}{l.unit_label && l.unit_label !== 'unit' ? ` ${l.unit_label}` : ''} × {N2(l.unit_price)} · VAT {N2(l.vat)}
                        {' · '}{l.kind === 'goods' ? `HS ${l.hs_code || '—'}` : 'Service'}</span>
                      <span className="num" style={{ flex: 'none' }}>{N2(l.gross)}</span>
                    </div>
                  </div>
                ))}
                <div style={{ padding: '8px 12px', fontSize: 13 }} className="stack">
                  <div className="row"><span className="muted" style={{ flex: 1 }}>Before VAT</span><span className="num">{N2(x.subtotal)}</span></div>
                  <div className="row"><span className="muted" style={{ flex: 1 }}>VAT</span><span className="num">{N2(x.vat_total)}</span></div>
                  <div className="row"><b style={{ flex: 1 }}>Total</b><b className="num">{N2(x.total)}</b></div>
                </div>
              </div>
            </div>
            <div className="card hide-sm" style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13, minWidth: 420 }} data-testid="einv-only-lines">
                <thead><tr className="faint" style={{ fontSize: 12, textAlign: 'left' }}>
                  <th style={{ padding: '8px 10px' }}>Item</th><th style={{ padding: '8px 6px', textAlign: 'right' }}>Qty</th>
                  <th style={{ padding: '8px 6px', textAlign: 'right' }}>Price</th><th style={{ padding: '8px 6px', textAlign: 'right' }}>VAT</th>
                  <th style={{ padding: '8px 10px', textAlign: 'right' }}>Amount</th></tr></thead>
                <tbody>
                  {x.lines.map((l) => (
                    <tr key={l.line_no} style={{ borderTop: '1px solid var(--line, #EEE)' }}>
                      <td style={{ padding: '8px 10px', wordBreak: 'break-word' }}>{l.description}
                        <div className="faint" style={{ fontSize: 11 }}>{l.kind === 'goods' ? `HS ${l.hs_code || '—'}${l.hs_label ? ` · ${l.hs_label}` : ''}` : 'Service'}{l.vat_treatment !== 'standard' ? ` · ${l.vat_treatment === 'zero' ? 'zero-rated' : 'VAT exempt'}` : ''}</div></td>
                      <td className="num" style={{ padding: '8px 6px', textAlign: 'right', whiteSpace: 'nowrap' }}>{num(l.qty, 3)}{l.unit_label && l.unit_label !== 'unit' ? ` ${l.unit_label}` : ''}</td>
                      <td className="num" style={{ padding: '8px 6px', textAlign: 'right' }}>{N2(l.unit_price)}</td>
                      <td className="num" style={{ padding: '8px 6px', textAlign: 'right' }}>{N2(l.vat)}</td>
                      <td className="num" style={{ padding: '8px 10px', textAlign: 'right' }}>{N2(l.gross)}</td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr style={{ borderTop: '1px solid var(--line, #EEE)' }}><td colSpan={4} style={{ padding: '6px 10px' }} className="muted">Before VAT</td><td className="num" style={{ padding: '6px 10px', textAlign: 'right' }}>{N2(x.subtotal)}</td></tr>
                  <tr><td colSpan={4} style={{ padding: '6px 10px' }} className="muted">VAT</td><td className="num" style={{ padding: '6px 10px', textAlign: 'right' }}>{N2(x.vat_total)}</td></tr>
                  <tr><td colSpan={4} style={{ padding: '6px 10px' }}><b>Total</b></td><td className="num" style={{ padding: '6px 10px', textAlign: 'right' }}><b data-testid="einv-only-total">{N2(x.total)}</b></td></tr>
                </tfoot>
              </table>
            </div>
            {x.notes && <div className="muted" style={{ fontSize: 13, wordBreak: 'break-word' }}>{x.notes}</div>}
          </>
        )}
      </div>
    </Drawer>
  );
}

export function EInvoicingPanel() {
  const { orgId } = useSession();
  const q = useEinvoice(orgId);
  const { run, busy } = useAction();
  const [params, setParams] = useSearchParams();
  const onlyId = params.get('einvoice');
  // An e-invoice outside the books opens from the list, from what needs a person, or from a link (/settings?einvoice=…).
  const openOnly = (id: string) => { const n = new URLSearchParams(params); n.set('einvoice', id); setParams(n, { replace: true }); };
  const closeOnly = () => { const n = new URLSearchParams(params); n.delete('einvoice'); setParams(n, { replace: true }); };
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
        <span className={'chip ' + (s.enabled ? 't-green' : s.ready ? 't-blue' : 't-amber')}>{s.enabled ? 'Sending to NRS' : s.ready ? 'Ready for NRS' : 'Getting ready'}</span>
        <span className="muted" style={{ fontSize: 13 }}>{s.enabled && !s.ready ? `On, but ${blocking} ${blocking === 1 ? 'thing needs' : 'things need'} putting right.`
          : s.ready ? 'Everything NRS needs is in place.' : `${blocking} ${blocking === 1 ? 'thing' : 'things'} still to do.`}</span>
      </div>
      {s.platform_keys && <Alert kind="blue" icon="info">You are on TaxStreem's keys while NRS is in test mode. Add your own keys below before you go live.</Alert>}
      <Readiness list={s.readiness} />
      <SendSwitch s={s} orgId={orgId} />
      {s.queue && (s.enabled || s.queue.signed + s.queue.waiting + s.queue.refused > 0) && <SendQueue q={s.queue} openOnly={openOnly} />}
      {(s.queue?.outside_books || 0) > 0 && <OutsideBooks orgId={orgId} count={s.queue!.outside_books!} open={openOnly} />}
      {onlyId && <OnlyDrawer id={onlyId} onClose={closeOnly} />}
      {s.can.edit ? <KeysForm s={s} orgId={orgId} /> : <CheckResult s={s} fresh={null} />}
      <ServiceCode s={s} orgId={orgId} />
      <HsToConfirm orgId={orgId} r={s.readiness.find((r) => r.id === 'items')} />
    </div>
  );
}
