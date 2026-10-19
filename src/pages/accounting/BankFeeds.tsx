// Bank feeds through Mono Connect: the person signs in to their bank in Mono's window once, and the account's
// transactions come into Banking every few hours (or when they press Sync), through the same matching as a statement.
import { useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { edge } from '../../lib/api';
import { N2, when, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';

interface FeedConfig { ok: boolean; configured: boolean; public_key: string | null; customer: { name: string; email: string | null }; webhook_url: string; webhook_secret_set: boolean; error?: string }
export function useFeedConfig(enabled = true) {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['mono-config', orgId], enabled: enabled && !!orgId, staleTime: 300_000,
    queryFn: async () => { const r = await edge<FeedConfig>('mono', { action: 'config', org_id: orgId }); if (r.ok === false) throw new Error(r.error || 'Bank feeds are not available.'); return r; } });
}

// Opens Mono's window: to link a new account, or to sign in again on one already linked.
async function monoWindow(cfg: FeedConfig, opts: { reauth?: string; reference: string }): Promise<{ code: string } | null> {
  const Connect = (await import('@mono.co/connect.js')).default;
  // The widget leaves its frame in the page when it closes; it is taken away once its own opening timer (two seconds) is past.
  const tidy = () => setTimeout(() => document.getElementById('mono-connect--widget-div')?.remove(), 2500);
  return new Promise((resolve) => {
    let done = false;
    const c = new Connect({
      key: cfg.public_key!, scope: 'auth', reference: opts.reference,
      data: opts.reauth ? undefined : { customer: { name: cfg.customer.name, email: cfg.customer.email || undefined } },
      onSuccess: (d) => { done = true; tidy(); resolve(d); },
      onClose: () => { tidy(); if (!done) resolve(null); },
    });
    if (opts.reauth) c.reauthorise(opts.reauth); else c.setup();
    c.open();
  });
}

export function ConnectBank({ accounts, preselect, onClose }: { accounts: any[]; preselect?: string; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const cfg = useFeedConfig();
  const [target, setTarget] = useState(preselect || '');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const banks = accounts.filter((a) => a.kind === 'bank' && a.provider !== 'mono');
  async function go() {
    if (!cfg.data) return;
    setErr(null); setBusy('Waiting for your bank…');
    try {
      const got = await monoWindow(cfg.data, { reference: `${orgId}-${Date.now()}` });
      if (!got) { setBusy(null); return; }
      setBusy('Linking and fetching transactions…');
      const r = await edge<any>('mono', { action: 'link', org_id: orgId, code: got.code, bank_account_id: target || null });
      if (r.ok === false) throw new Error(r.error || 'The bank was not linked.');
      const n = r.sync?.added ?? 0;
      toast(`${r.account?.name || 'Account'} linked${r.sync ? ` · ${n} transaction${n === 1 ? '' : 's'} brought in` : ''}`);
      if (r.sync_error) toast(`The first fetch did not finish: ${r.sync_error}`, 'err');
      await Promise.all(['banking', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      onClose();
    } catch (e) { setErr((e as Error).message); }
    setBusy(null);
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title="Connect a bank account" sub="Transactions flow into Banking without uploading statements." onClose={onClose} />
      <div className="modal-body">
        {cfg.isLoading ? <Spinner /> : cfg.error ? <Alert kind="yellow" icon="shield">{(cfg.error as Error).message}</Alert> : !cfg.data?.configured ? (
          <Alert kind="blue" icon="info">Bank feeds are not available yet. TaxStreem is setting them up; statements can still be uploaded under Banking meanwhile.</Alert>
        ) : (
          <div className="stack" style={{ gap: 12 }}>
            <div className="stack" style={{ gap: 6, fontSize: 13, lineHeight: 1.5 }}>
              <Point>You sign in to your bank in Mono's window. Counta never sees your bank password.</Point>
              <Point>Counta can read the account's transactions and balance. It cannot move money.</Point>
              <Point>New transactions come in every four hours and when you press Sync, and are matched to invoices, bills and transfers like a statement.</Point>
              <Point>If your bank asks for a one-time code later, Banking shows a button to sign in again.</Point>
            </div>
            <Field label="Bring the transactions into" hint="Choose the account if it is already in Counta, so its statement lines and the feed are matched to each other.">
              <select className="input" value={target} onChange={(e) => setTarget(e.target.value)}>
                <option value="">The account with the same number, or a new one</option>
                {banks.map((a) => <option key={a.id} value={a.id}>{a.name}{a.account_number ? ` · ${a.account_number}` : ''}</option>)}
              </select>
            </Field>
          </div>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={!cfg.data?.configured || !!busy} onClick={go}>{busy ? <><Spinner small />{busy}</> : 'Continue to your bank'}</button>
      </div>
    </Modal>
  );
}

function Point({ children }: { children: ReactNode }) {
  return <div className="row" style={{ alignItems: 'flex-start', gap: 8 }}><Icon name="check" size={15} color="#15803D" sw={2.5} style={{ marginTop: 2, flex: 'none' }} /><span>{children}</span></div>;
}

// The feed's state on an account card, with Sync, Sign in again and Unlink.
export function FeedControls({ account, canAct }: { account: any; canAct: boolean }) {
  const toast = useToast();
  const qc = useQueryClient();
  const cfg = useFeedConfig(canAct && !!account.feed?.linked);
  const [busy, setBusy] = useState<string | null>(null);
  const [sure, setSure] = useState(false);
  const f = account.feed;
  if (!f?.linked) return null;
  const refresh = () => Promise.all(['banking', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function reauth() {
    if (!cfg.data?.configured) { toast('Bank feeds are not switched on.', 'err'); return; }
    setBusy('Waiting for your bank…');
    try {
      const got = await monoWindow(cfg.data, { reauth: account.provider_ref, reference: `${account.id}-${Date.now()}` });
      if (got) {
        const r = await edge<any>('mono', { action: 'reauthorised', bank_account_id: account.id });
        toast(r.sync ? `Signed in again · ${r.sync.added} new` : 'Signed in again'); await refresh();
      }
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  async function sync() {
    setBusy('Syncing…');
    const r = await edge<any>('mono', { action: 'sync', bank_account_id: account.id });
    if (r.ok === false && r.reason === 'reauth') { setBusy(null); toast(r.error, 'err'); await refresh(); return; }
    if (r.ok === false) toast(r.error || 'The sync did not finish.', 'err');
    else toast(`${r.sync.added} new transaction${r.sync.added === 1 ? '' : 's'}${r.sync.complete === false ? '; older months keep coming in the background' : r.sync.fresh_data === 'processing' ? '; the bank is still sending today\'s, they follow shortly' : ''}`);
    await refresh(); setBusy(null);
  }
  async function unlink() {
    if (!sure) { setSure(true); return; }
    setBusy('Unlinking…');
    const r = await edge<any>('mono', { action: 'unlink', bank_account_id: account.id });
    if (r.ok === false) toast(r.error || 'Could not unlink.', 'err'); else toast('Bank feed stopped. The transactions already in stay.');
    setSure(false); await refresh(); setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 6 }} onClick={(e) => e.stopPropagation()}>
      <div className="row wrap" style={{ gap: 6 }}>
        <span className={'chip ' + (f.reauth_required ? 't-amber' : 't-blue')}><Icon name="link" size={12} style={{ marginRight: 4, verticalAlign: -2 }} />{f.reauth_required ? 'Feed paused' : 'Bank feed'}{f.institution ? ` · ${f.institution}` : ''}</span>
        <span className="faint" style={{ fontSize: 12 }}>{f.last_synced_at ? `Synced ${when(f.last_synced_at)}` : 'Not synced yet'}{f.balance != null ? ` · bank ${N2(f.balance)}` : ''}</span>
      </div>
      {!f.history_done ? (
        <div className="faint" style={{ fontSize: 12 }}>Fetching the history back to {fmtDay(f.history_from || '2023-01-01')}{f.history_to ? `, now at ${fmtDay(f.history_to)}` : ''}. The rest follows on its own over the next few minutes.</div>
      ) : f.first_feed_line ? <div className="faint" style={{ fontSize: 12 }}>The bank gave transactions from {fmtDay(f.first_feed_line)}.</div> : null}
      {f.reauth_required && <div style={{ fontSize: 12, color: '#B45309' }}>The bank asks you to sign in again before it shares new transactions.</div>}
      {!f.reauth_required && f.last_error && <div className="faint" style={{ fontSize: 12 }} title={f.last_error}>Last fetch: {String(f.last_error).slice(0, 90)}</div>}
      {canAct && (
        <div className="row wrap" style={{ gap: 6 }}>
          {f.reauth_required
            ? <button className="btn btn-primary btn-xs" disabled={!!busy} onClick={reauth}>{busy || 'Sign in again'}</button>
            : <button className="btn btn-secondary btn-xs" disabled={!!busy} onClick={sync}><Icon name="refresh" size={13} />{busy || 'Sync'}</button>}
          <button className={'btn btn-xs ' + (sure ? 'btn-danger' : 'btn-ghost')} disabled={!!busy && !sure} onClick={unlink}>{sure ? 'Tap again to unlink' : 'Unlink'}</button>
        </div>
      )}
    </div>
  );
}
