// Connect the tools the business already uses. Payments and orders from them become paid sales in the books; Slack hears
// Counta's alerts; the business's own WhatsApp number can send its messages. No accounting tools: the books live in Counta.
import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { N2, uuid, when } from '../../lib/format';
import { useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import bumpaLogo from '../../assets/integrations/bumpa.webp';
import flutterwaveLogo from '../../assets/integrations/flutterwave.webp';
import paystackLogo from '../../assets/integrations/paystack.webp';
import selarLogo from '../../assets/integrations/selar.webp';
import shopifyLogo from '../../assets/integrations/shopify.webp';
import slackLogo from '../../assets/integrations/slack.webp';
import whatsappLogo from '../../assets/integrations/whatsapp.webp';
import wooLogo from '../../assets/integrations/woocommerce.webp';
import zapierLogo from '../../assets/integrations/zapier.webp';
import { Alert, Drawer, Field, Spinner } from '../../components/ui';

type Provider = 'paystack' | 'flutterwave' | 'selar' | 'woocommerce' | 'shopify' | 'zapier' | 'bumpa' | 'slack';
type Conn = {
  id: string; provider: Provider; name: string; status: 'active' | 'paused' | 'error' | 'disconnected'; label: string | null; settings: Record<string, any>; secret_hint: string | null;
  has_hook: boolean; connected_at: string; connected_by: string | null; last_sync_at: string | null; last_event_at: string | null; last_error: string | null; recorded: number;
  today: number; account: { id: string; name: string; code: string } | null;
};
type Page = {
  can_manage: boolean; sample: boolean; connected: Conn[]; bank_feeds: number; locations: { id: string; name: string }[];
  whatsapp: { sender: 'counta' | 'own'; own: { status: string; phone: string | null; push_name: string | null; last_error: string | null } | null; counta: { status: string } | null; can_change: boolean };
};
// logo: the tool's own mark. bleed: the mark is its own tile (an app icon), so it fills the square; the others sit on a white
// tile, a wordmark (wide) with less room around it. The bank connection has no one brand, so it shows a bank.
type Tool = { id: Provider | 'whatsapp' | 'bank'; name: string; logo?: string; bleed?: boolean; wide?: boolean; what: string; group: string };

const TOOLS: Tool[] = [
  { id: 'paystack', name: 'Paystack', logo: paystackLogo, group: 'Get paid', what: 'Every successful payment to your Paystack account becomes a paid sale, with Paystack\'s fee booked.' },
  { id: 'flutterwave', name: 'Flutterwave', logo: flutterwaveLogo, group: 'Get paid', what: 'Payments to your own Flutterwave account become paid sales, checked with Flutterwave first.' },
  { id: 'selar', name: 'Selar', logo: selarLogo, wide: true, group: 'Sell online', what: 'Each Selar sale of your courses, e-books or products is recorded as it happens.' },
  { id: 'bumpa', name: 'Bumpa', logo: bumpaLogo, bleed: true, group: 'Sell online', what: 'Paid Bumpa orders come in through your API key every few minutes, or from the orders you export.' },
  { id: 'woocommerce', name: 'WooCommerce', logo: wooLogo, wide: true, group: 'Sell online', what: 'Paid orders from your WordPress store come in every few minutes.' },
  { id: 'shopify', name: 'Shopify', logo: shopifyLogo, group: 'Sell online', what: 'Paid Shopify orders come in every few minutes, products matched to yours.' },
  { id: 'zapier', name: 'Zapier or Make', logo: zapierLogo, bleed: true, group: 'Sell online', what: 'Anything else that can send a webhook: post its sales to Counta\'s address.' },
  { id: 'whatsapp', name: 'WhatsApp Business', logo: whatsappLogo, bleed: true, group: 'Talk to customers', what: 'Send invoices, receipts and reminders from your own WhatsApp number.' },
  { id: 'slack', name: 'Slack', logo: slackLogo, bleed: true, group: 'Your team', what: 'Payments in, tax deadlines and books alerts post to a channel your team reads.' },
  { id: 'bank', name: 'Bank accounts', group: 'Your bank', what: 'Bank lines come in through Mono, ready to match. Set them up in Banking.' },
];

function ToolMark({ t, size = 40 }: { t: Tool; size?: number }) {
  const box = { width: size, height: size, borderRadius: 10, flex: 'none', display: 'grid', placeItems: 'center', boxSizing: 'border-box' } as const;
  if (!t.logo) return <span aria-hidden="true" style={{ ...box, background: '#EEF4FF', border: '1px solid #D6E4FF' }} data-testid="logo-bank"><Icon name="landmark" size={Math.round(size / 2)} color="#0072F5" /></span>;
  if (t.bleed) return <img src={t.logo} alt="" aria-hidden="true" width={size} height={size} style={{ ...box, objectFit: 'contain' }} data-testid={`logo-${t.id}`} />;
  const pad = Math.round(size / (t.wide ? 13 : 8)), inner = size - 2 * pad - 2;
  return (
    <span aria-hidden="true" style={{ ...box, background: '#fff', border: '1px solid var(--line)', padding: pad }}>
      <img src={t.logo} alt="" width={inner} height={inner} style={{ width: inner, height: inner, objectFit: 'contain' }} data-testid={`logo-${t.id}`} />
    </span>
  );
}

const STATUS: Record<string, [string, string]> = { active: ['Connected', 't-green'], paused: ['Paused', 't-grey'], error: ['Needs attention', 't-red'] };

export function useIntegrations() {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['integrations', orgId], enabled: !!orgId, queryFn: () => rpc<Page>('org_integrations', { p_org: orgId }) });
}

export default function Integrations() {
  const q = useIntegrations();
  const [open, setOpen] = useState<Tool | null>(null);
  const d = q.data;
  const groups = [...new Set(TOOLS.map((t) => t.group))];
  const conn = (id: string) => d?.connected.find((c) => c.provider === id) || null;
  const state = (t: Tool): [string, string] | null => {
    if (t.id === 'whatsapp') return d?.whatsapp.sender === 'own' ? ['Your number', 't-green'] : d?.whatsapp.own?.status === 'ready' ? ['Linked', 't-blue'] : null;
    if (t.id === 'bank') return d && d.bank_feeds > 0 ? [`${d.bank_feeds} connected`, 't-green'] : null;
    const c = conn(t.id);
    return c ? STATUS[c.status] || null : null;
  };
  return (
    <div className="container stack" style={{ gap: 18 }} data-testid="integrations">
      <div>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.55, maxWidth: 760 }}>
          Connect the tools you already sell and talk through. What they sell becomes a paid sale in your books, in a balance account for each tool until
          the money reaches your bank. Accounting tools are not here: your books live in Counta.
        </div>
      </div>
      {d?.sample && <Alert kind="blue" icon="info">This is the sample business. Connect tools to your own business.</Alert>}
      {d && !d.can_manage && !d.sample && <Alert kind="grey" icon="lock">The owner, or someone who manages settings, connects tools. You can see what is connected.</Alert>}
      {q.isError && <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>}
      {groups.map((g) => (
        <section key={g} className="stack" style={{ gap: 10 }}>
          <div className="mini-label">{g}</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(min(300px, 100%), 1fr))', gap: 12 }}>
            {TOOLS.filter((t) => t.group === g).map((t) => {
              const st = state(t), c = conn(t.id);
              return (
                <button key={t.id} className="card card-pad stack entry-card" style={{ gap: 10, textAlign: 'left', cursor: 'pointer', background: '#fff' }} onClick={() => setOpen(t)}
                  data-testid={`tool-${t.id}`}>
                  <div className="row" style={{ gap: 10 }}>
                    <ToolMark t={t} />
                    <b className="grow" style={{ fontSize: 15 }}>{t.name}</b>
                    {st && <span className={'chip ' + st[1]}>{st[0]}</span>}
                  </div>
                  <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }}>{t.what}</div>
                  {c && c.status !== 'disconnected' && t.id !== 'slack' && (
                    <div className="faint" style={{ fontSize: 12 }}>{c.recorded} {c.recorded === 1 ? 'sale' : 'sales'} recorded{c.last_event_at ? `, the last ${when(c.last_event_at)}` : ''}</div>
                  )}
                </button>
              );
            })}
          </div>
        </section>
      ))}
      {open && d && <ToolDrawer t={open} page={d} onClose={() => setOpen(null)} />}
    </div>
  );
}

function ToolDrawer({ t, page, onClose }: { t: Tool; page: Page; onClose: () => void }) {
  const c = page.connected.find((x) => x.provider === t.id) || null;
  // What connecting answered (the webhook address, shown once) stays on screen after the page learns the tool is connected.
  const [fresh, setFresh] = useState<Done | null>(null);
  return (
    <Drawer onClose={onClose} width={600}>
      <div className="drawer-hd">
        <ToolMark t={t} />
        <div className="grow"><div className="drawer-title">{t.name}</div><div className="muted" style={{ fontSize: 13 }}>{t.what}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button>
      </div>
      <div className="drawer-body stack" style={{ gap: 14, padding: 20, overflowY: 'auto' }} data-testid="tool-drawer">
        {t.id === 'whatsapp' ? <WhatsAppOwn page={page} />
          : t.id === 'bank' ? <div className="stack" style={{ gap: 10 }}><div style={{ fontSize: 14, lineHeight: 1.6 }}>Bank feeds bring your bank lines in through Mono, a licensed open-banking provider, so Counta can match them to sales, bills and transfers. Settlements from Paystack, Flutterwave and your stores show up there; match each to the tool's balance account.</div><div><Link className="btn btn-primary btn-sm" to="/accounting/banking">Open Banking</Link></div></div>
          : t.id === 'bumpa' ? (
            <>
              {c?.settings?.api ? <>{fresh && <ConnectedNote t={t} done={fresh} />}<Connected t={t} c={c} page={page} /></> : <Connect t={t} page={page} onDone={setFresh} />}
              <div className="mini-label" style={{ marginTop: 6 }}>{c?.settings?.api ? 'Older orders, from a file' : 'Or upload the orders you export'}</div>
              <BumpaImport page={page} />
              {c && !c.settings?.api && <Connected t={t} c={c} page={page} />}
            </>
          )
          : c ? <>{fresh && <ConnectedNote t={t} done={fresh} />}<Connected t={t} c={c} page={page} /></>
          : <Connect t={t} page={page} onDone={setFresh} />}
      </div>
    </Drawer>
  );
}

const HOW: Partial<Record<Provider, string[]>> = {
  paystack: ['In Paystack, open Settings, then API Keys & Webhooks.', 'Copy the Secret Key (it starts sk_live_) and paste it here.',
    'After connecting, paste the webhook address Counta gives you into the Webhook URL box there, so payments arrive at once. Without it Counta still looks every few minutes.'],
  flutterwave: ['In Flutterwave, open Settings, then API keys. Copy the Secret Key (FLWSECK-…-X).', 'After connecting, open Settings, Webhooks: paste the address and the secret hash Counta gives you, and tick "Receive webhook response in JSON format".'],
  woocommerce: ['In WordPress, open WooCommerce, Settings, Advanced, REST API, and add a key with Read access.', 'Paste the consumer key and secret, and your shop\'s address.'],
  shopify: ['In Shopify, open Settings, Apps and sales channels, Develop apps, and create an app.', 'Give it the read_orders scope, install it, and copy the Admin API access token (shpat_…).'],
  selar: ['Connect, then copy the address Counta gives you.', 'In Selar, open Settings, Integrations or Webhooks, and paste it as the address for sale notifications. If your Selar plan has no webhooks, use it in Zapier with "Webhooks by Zapier".'],
  zapier: ['Connect, then copy the address Counta gives you.', 'In Zapier or Make, add a webhook action that POSTs JSON to it with the sale\'s id, amount, currency, product and customer.'],
  slack: ['In Slack, add the Incoming Webhooks app to the channel your team reads.', 'Copy the webhook URL (https://hooks.slack.com/services/…) and paste it here.'],
  bumpa: ['In your Bumpa dashboard (app.getbumpa.com), create a secret API key. Bumpa\'s API is in beta, so keep the key to yourself and paste it only here.',
    'Paid orders then come in every few minutes, with their products and delivery. An order already uploaded from a file is not recorded twice.'],
};
const HOW_CSV = ['In Bumpa, open Orders and export them as CSV.', 'Upload the file here. Paid orders become sales; the same order is never recorded twice.'];

type Done = { webhook_url?: string; secret_hash?: string; first?: { recorded?: number } | null; renewed?: boolean };

function Connect({ t, page, onDone }: { t: Tool; page: Page; onDone: (d: Done) => void }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [f, setF] = useState({ key: '', secret: '', site: '', shop: '', url: '', location_id: '', bumpa_location: '' });
  const [kinds, setKinds] = useState<string[]>(['payments', 'tax']);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const p = t.id as Provider;
  async function connect() {
    setBusy(true); setErr(null);
    const r = await edge<any>('integrations', { action: 'connect', org_id: orgId, provider: p, ...f, kinds });
    setBusy(false);
    if (r.ok === false) { setErr(r.error || 'Not connected.'); return; }
    onDone(r);
    await qc.invalidateQueries({ queryKey: ['integrations'] });
    toast(`${t.name} connected`);
  }
  const can = page.can_manage;
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="connect-form">
      <ol className="stack" style={{ gap: 6, margin: 0, paddingLeft: 18, fontSize: 14, lineHeight: 1.55 }}>{(HOW[p] || []).map((h) => <li key={h}>{h}</li>)}</ol>
      {(p === 'paystack' || p === 'flutterwave') && <Field label="Secret key"><input className="input" type="password" autoComplete="off" value={f.key} onChange={(e) => setF({ ...f, key: e.target.value })} disabled={!can} /></Field>}
      {p === 'bumpa' && (
        <>
          <Field label="Bumpa secret API key"><input className="input" type="password" autoComplete="off" value={f.key} onChange={(e) => setF({ ...f, key: e.target.value })} disabled={!can} /></Field>
          <Field label="Bumpa location ID" hint="Only if the store has more than one location in Bumpa. Empty means the store's main location.">
            <input className="input" autoComplete="off" value={f.bumpa_location} onChange={(e) => setF({ ...f, bumpa_location: e.target.value })} disabled={!can} />
          </Field>
        </>
      )}
      {p === 'woocommerce' && (
        <>
          <Field label="Shop address"><input className="input" placeholder="https://yourshop.com.ng" value={f.site} onChange={(e) => setF({ ...f, site: e.target.value })} disabled={!can} /></Field>
          <Field label="Consumer key"><input className="input" autoComplete="off" value={f.key} onChange={(e) => setF({ ...f, key: e.target.value })} disabled={!can} /></Field>
          <Field label="Consumer secret"><input className="input" type="password" autoComplete="off" value={f.secret} onChange={(e) => setF({ ...f, secret: e.target.value })} disabled={!can} /></Field>
        </>
      )}
      {p === 'shopify' && (
        <>
          <Field label="Shop address"><input className="input" placeholder="yourshop.myshopify.com" value={f.shop} onChange={(e) => setF({ ...f, shop: e.target.value })} disabled={!can} /></Field>
          <Field label="Admin API access token"><input className="input" type="password" autoComplete="off" value={f.key} onChange={(e) => setF({ ...f, key: e.target.value })} disabled={!can} /></Field>
        </>
      )}
      {p === 'slack' && (
        <>
          <Field label="Incoming webhook URL"><input className="input" type="password" autoComplete="off" value={f.url} onChange={(e) => setF({ ...f, url: e.target.value })} disabled={!can} /></Field>
          <Kinds value={kinds} onChange={setKinds} />
        </>
      )}
      {p !== 'slack' && page.locations.length > 1 && (
        <Field label="Branch the sales belong to">
          <select className="input" value={f.location_id} onChange={(e) => setF({ ...f, location_id: e.target.value })} disabled={!can}>
            <option value="">The main branch</option>{page.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
        </Field>
      )}
      <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Counta keeps keys in an encrypted vault and only uses them to read your payments and orders. It never moves money with them. Disconnecting deletes them.</div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      <div><button className="btn btn-primary" disabled={!can || busy || (p === 'bumpa' && !f.key.trim())} onClick={connect} data-testid="connect">{busy ? <Spinner small /> : <Icon name="link" size={14} color="#fff" />}Connect {t.name}</button></div>
    </div>
  );
}

function Kinds({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const all: [string, string][] = [['payments', 'Payments in'], ['tax', 'Tax deadlines and alerts'], ['books', 'Books: bank lines, bills, stock'], ['team', 'Everything else']];
  return (
    <div className="stack" style={{ gap: 6 }}>
      <span className="mini-label">What to post</span>
      {all.map(([k, l]) => (
        <label key={k} className="row" style={{ gap: 8, fontSize: 14 }}>
          <input type="checkbox" checked={value.includes(k)} onChange={(e) => onChange(e.target.checked ? [...value, k] : value.filter((x) => x !== k))} />{l}
        </label>
      ))}
    </div>
  );
}

function Copy({ label, value }: { label: string; value: string }) {
  const toast = useToast();
  return (
    <Field label={label}>
      <div className="row" style={{ gap: 6 }}>
        <input className="input mono" readOnly value={value} onFocus={(e) => e.target.select()} style={{ fontSize: 12 }} />
        <button className="btn btn-secondary btn-sm" onClick={() => navigator.clipboard?.writeText(value).then(() => toast('Copied'))} aria-label={`Copy the ${label.toLowerCase()}`}><Icon name="copy" size={14} /></button>
      </div>
    </Field>
  );
}

function ConnectedNote({ t, done }: { t: Tool; done: Done }) {
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="connected-note">
      {done.renewed
        ? <Alert kind="green" icon="check">A new webhook address is ready. The old one stops working now, so replace it in {t.name}.</Alert>
        : <Alert kind="green" icon="check">{t.name} is connected.{done.first?.recorded ? ` ${done.first.recorded} ${done.first.recorded === 1 ? 'sale' : 'sales'} from the last two days recorded.` : ''}</Alert>}
      {done.webhook_url && (
        <>
          <div style={{ fontSize: 14, lineHeight: 1.55 }}>Paste {done.secret_hash ? 'these into' : 'this into'} {t.name} so sales reach Counta at once. Counta shows {done.secret_hash ? 'them' : 'it'} only now; you can make a new address later.</div>
          <Copy label="Webhook address" value={done.webhook_url} />
          {done.secret_hash && <Copy label="Secret hash" value={done.secret_hash} />}
        </>
      )}
    </div>
  );
}

function Connected({ t, c, page }: { t: Tool; c: Conn; page: Page }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [addr, setAddr] = useState<Done | null>(null);
  const [sure, setSure] = useState(false);
  const ev = useQuery({ queryKey: ['integration-events', c.id], queryFn: () => rpc<any[]>('integration_events_list', { p_integration: c.id }), enabled: c.provider !== 'slack' });
  const refresh = () => Promise.all([qc.invalidateQueries({ queryKey: ['integrations'] }), qc.invalidateQueries({ queryKey: ['integration-events', c.id] })]);
  async function act(action: 'sync' | 'test' | 'new_address') {
    setBusy(action);
    const r = await edge<any>('integrations', { action, id: c.id });
    setBusy(null);
    await refresh();
    if (r.ok === false) { toast(r.error || 'That did not work.', 'err'); return; }
    if (action === 'new_address') setAddr({ ...r, renewed: true });
    else if (action === 'sync') toast(r.recorded ? `${r.recorded} new ${r.recorded === 1 ? 'sale' : 'sales'} recorded` : 'Nothing new');
    else toast(c.provider === 'slack' ? 'A test went to the channel' : 'The key works');
  }
  async function settings(p: Record<string, unknown>, ok: string) {
    setBusy('settings');
    try { await rpc('integration_settings', { p_integration: c.id, p }); await refresh(); toast(ok); } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  async function disconnect() {
    setBusy('off');
    try { await rpc('integration_disconnect', { p_integration: c.id }); await refresh(); toast(`${c.name} disconnected. Its key is deleted.`); } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  const can = page.can_manage;
  const [label, tone] = STATUS[c.status] || ['', ''];
  return (
    <div className="stack" style={{ gap: 14 }} data-testid="connected">
      <div className="row wrap" style={{ gap: 8 }}>
        <span className={'chip ' + tone}>{label}</span>
        <span className="faint" style={{ fontSize: 13 }}>{c.label ? `${c.label} · ` : ''}{c.secret_hint ? `key ending ${c.secret_hint} · ` : ''}by {c.connected_by || 'someone'} {when(c.connected_at)}</span>
      </div>
      {c.status === 'error' && c.last_error && <Alert kind="red" icon="alert">{c.last_error}</Alert>}
      {c.provider !== 'slack' && c.account && (
        <div style={{ fontSize: 14, lineHeight: 1.55 }}>
          Sales from {c.name} are paid into <b>{c.account.name}</b> ({c.account.code}). When {c.name} pays out to your bank, match the bank line in Banking as a transfer from it.
        </div>
      )}
      {c.provider === 'slack' && <Kinds value={c.settings.kinds || ['payments', 'tax']} onChange={(k) => settings({ kinds: k }, 'Saved')} />}
      {can && (
        <div className="row wrap" style={{ gap: 8 }}>
          {(['paystack', 'flutterwave', 'woocommerce', 'shopify'].includes(c.provider) || (c.provider === 'bumpa' && c.settings?.api)) && c.status !== 'paused' && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => act('sync')}>{busy === 'sync' ? <Spinner small /> : <Icon name="refresh" size={14} color="#fff" />}Look for new sales</button>}
          {(c.provider !== 'bumpa' || c.settings?.api) && c.provider !== 'selar' && c.provider !== 'zapier' && <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => act('test')}>{busy === 'test' ? <Spinner small /> : <Icon name="check" size={14} />}{c.provider === 'slack' ? 'Send a test' : 'Check the key'}</button>}
          {c.has_hook && <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => act('new_address')}>{busy === 'new_address' ? <Spinner small /> : <Icon name="link" size={14} />}New webhook address</button>}
          {(c.provider !== 'bumpa' || c.settings?.api) && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => settings({ paused: c.status !== 'paused' }, c.status === 'paused' ? 'On again' : 'Paused')}>{c.status === 'paused' ? 'Turn back on' : 'Pause'}</button>}
        </div>
      )}
      {addr && <ConnectedNote t={t} done={addr} />}
      {c.provider !== 'slack' && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>Latest</b><span className="faint" style={{ fontSize: 12 }}>{c.recorded} recorded</span></div>
          {ev.isLoading ? <div className="card-pad"><Spinner small /></div> : !(ev.data || []).length ? <div className="card-pad faint" style={{ fontSize: 13 }}>Nothing yet.</div> : (ev.data || []).slice(0, 20).map((e) => (
            <div key={e.id} className="tr rsp" style={{ gridTemplateColumns: 'minmax(0,1fr) 110px 90px' }}>
              <span className="m-main" style={{ minWidth: 0 }}>{e.sale ? <Link to={`/sell/sales?open=${e.sale.id}`}>{e.sale.number}</Link> : <span className="faint">{e.external_id.replace(/^[a-z]+:/, '')}</span>}
                {e.message && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{e.message}</span>}</span>
              <span className="right num">{e.amount != null ? N2(e.amount) : ''}</span>
              <span className="right"><span className={'chip ' + (e.status === 'recorded' ? 't-green' : e.status === 'skipped' ? 't-grey' : 't-red')}>{e.status}</span></span>
            </div>
          ))}
        </div>
      )}
      {can && (!sure
        ? <div><button className="btn btn-ghost btn-sm" onClick={() => setSure(true)}>Disconnect {c.name}</button></div>
        : <div className="row wrap" style={{ gap: 8 }}><span style={{ fontSize: 14 }}>The key is deleted. Sales already recorded stay.</span>
            <button className="btn btn-danger btn-sm" disabled={busy !== null} onClick={disconnect}>{busy === 'off' ? <Spinner small /> : null}Disconnect</button>
            <button className="btn btn-ghost btn-sm" onClick={() => setSure(false)}>Keep it</button></div>)}
    </div>
  );
}

function BumpaImport({ page }: { page: Page }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState<string | null>(null);
  async function upload(file: File) {
    setBusy(true); setErr(null); setRes(null);
    try {
      if (!/\.csv$/i.test(file.name)) throw new Error('Upload the CSV file Bumpa exports.');
      const path = `${orgId}/imports/bumpa/${uuid()}.csv`;
      const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: 'text/csv' });
      if (error) throw new Error(cleanError(error));
      const r = await edge<any>('integrations', { action: 'bumpa_import', org_id: orgId, path });
      if (r.ok === false) throw new Error(r.error || 'The file could not be imported.');
      setRes(r);
      await qc.invalidateQueries({ queryKey: ['integrations'] });
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
    if (input.current) input.current.value = '';
  }
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="bumpa-import">
      <ol className="stack" style={{ gap: 6, margin: 0, paddingLeft: 18, fontSize: 14, lineHeight: 1.55 }}>{HOW_CSV.map((h) => <li key={h}>{h}</li>)}</ol>
      <input ref={input} type="file" accept=".csv,text/csv" style={{ display: 'none' }} onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); }} data-testid="bumpa-file" />
      <div><button className="btn btn-primary btn-sm" disabled={!page.can_manage || busy} onClick={() => input.current?.click()}>{busy ? <Spinner small /> : <Icon name="upload" size={14} color="#fff" />}Upload Bumpa orders</button></div>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      {res && (
        <Alert kind="green" icon="check">
          {res.recorded} {res.recorded === 1 ? 'order' : 'orders'} recorded{res.duplicate ? `, ${res.duplicate} already in Counta` : ''}{res.skipped_rows?.length ? `, ${res.skipped_rows.length} left out (${res.skipped_rows[0].reason}${res.skipped_rows.length > 1 ? ' and more' : ''})` : ''}.
        </Alert>
      )}
    </div>
  );
}

// The business's own WhatsApp number on TaxStreem's WhatsApp server: scan a QR code once, then messages go from it.
function WhatsAppOwn({ page }: { page: Page }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [st, setSt] = useState<{ status: string; qr?: string | null; phone?: string | null; error?: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const w = page.whatsapp;
  useEffect(() => {
    if (st?.status !== 'qr_ready' && st?.status !== 'authenticating' && st?.status !== 'initializing') return;
    const t = setTimeout(async () => { const r = await edge<any>('messaging', { action: 'wa_status', org_id: orgId }); if (r.ok !== false) setSt(r); if (r.status === 'ready') qc.invalidateQueries({ queryKey: ['integrations'] }); }, 5000);
    return () => clearTimeout(t);
  }, [st, orgId, qc]);
  async function act(action: 'wa_link' | 'wa_status' | 'wa_unlink') {
    setBusy(action); setErr(null);
    const r = await edge<any>('messaging', { action, org_id: orgId });
    setBusy(null);
    if (r.ok === false) { setErr(r.error || 'That did not work.'); return; }
    setSt(r);
    await qc.invalidateQueries({ queryKey: ['integrations'] });
  }
  async function sender(s: 'counta' | 'own') {
    setBusy('sender');
    try { await rpc('set_whatsapp_sender', { p_org: orgId, p_sender: s }); await qc.invalidateQueries({ queryKey: ['integrations'] }); toast(s === 'own' ? 'Messages now go from your number' : 'Messages go from TaxStreem\'s number'); }
    catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  const ready = (st?.status || w.own?.status) === 'ready';
  return (
    <div className="stack" style={{ gap: 12 }} data-testid="wa-own">
      <div style={{ fontSize: 14, lineHeight: 1.6 }}>
        Counta sends invoices, receipts and reminders on WhatsApp from TaxStreem's number. Link your own business number and customers get them from you instead.
        Use a number on WhatsApp Business that you keep on a phone with data; WhatsApp may limit a number that sends too much too fast, so Counta sends only what you or your books ask for.
      </div>
      <div className="row wrap" style={{ gap: 8 }}>
        <span className={'chip ' + (w.sender === 'own' ? 't-green' : 't-grey')}>{w.sender === 'own' ? `Sending from ${w.own?.phone || 'your number'}` : 'Sending from TaxStreem\'s number'}</span>
        {w.own?.status && w.own.status !== 'ready' && <span className="chip t-amber">{w.own.status.replace(/_/g, ' ')}</span>}
      </div>
      {st?.qr && st.status === 'qr_ready' && (
        <div className="stack" style={{ gap: 6, alignItems: 'flex-start' }}>
          <img src={st.qr} alt="QR code to link your WhatsApp" style={{ width: 220, height: 220, border: '1px solid var(--line)', borderRadius: 12, padding: 8, background: '#fff' }} />
          <div className="faint" style={{ fontSize: 13 }}>On the phone: WhatsApp, Settings, Linked devices, Link a device. Scan this code.</div>
        </div>
      )}
      {err && <Alert kind="amber" icon="info">{err}</Alert>}
      {w.can_change && (
        <div className="row wrap" style={{ gap: 8 }}>
          {!ready && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => act('wa_link')}>{busy === 'wa_link' ? <Spinner small /> : <Icon name="wa" size={14} color="#fff" />}Link my number</button>}
          {ready && w.sender !== 'own' && <button className="btn btn-primary btn-sm" disabled={busy !== null} onClick={() => sender('own')}>Send from my number</button>}
          {w.sender === 'own' && <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => sender('counta')}>Send from TaxStreem's number</button>}
          {(ready || w.own) && <button className="btn btn-ghost btn-sm" disabled={busy !== null} onClick={() => act('wa_unlink')}>Unlink</button>}
        </div>
      )}
    </div>
  );
}
