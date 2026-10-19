// Keys and services: every key Counta uses, by service. A key pasted here goes to Supabase Vault and is never shown again
// (only its last four characters); Counta reads it before any Edge Function secret of the same name.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { edge } from '../../lib/api';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { GROUPS, type KeyRow, type KeysStatus, useKeys } from '../api';
import { Card, PageHead } from '../ui';

function KeyLine({ k }: { k: KeyRow }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const json = k.name.endsWith('_JSON');
  async function save() {
    if (!value.trim()) { setErr('Paste the value first.'); return; }
    setBusy(true); setErr(null);
    const r = await edge<{ shown: string; alerted: boolean }>('admin', { action: 'set_key', name: k.name, value });
    setBusy(false);
    if (r.ok === false) { setErr(r.error || 'Not saved.'); return; }
    setValue(''); setEditing(false);
    toast(`Saved. Counta uses it within a minute.${r.alerted ? ' Every admin was emailed.' : ''}`);
    await qc.invalidateQueries({ queryKey: ['admin-keys'] });
  }
  async function remove() {
    if (!confirm) { setConfirm(true); return; }
    setBusy(true);
    const r = await edge('admin', { action: 'clear_key', name: k.name });
    setBusy(false); setConfirm(false);
    if (r.ok === false) { toast(r.error || 'Not removed.', 'err'); return; }
    toast(k.env ? 'Removed here. The Supabase secret applies again.' : 'Removed.');
    await qc.invalidateQueries({ queryKey: ['admin-keys'] });
  }
  return (
    <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.3fr) minmax(0,1.5fr) auto' }}>
      <div style={{ minWidth: 0 }}>
        <b>{k.label}</b>
        <div className="faint mono" style={{ fontSize: 11 }}>{k.name}</div>
        {k.hint && <div className="faint" style={{ fontSize: 12, lineHeight: 1.45, marginTop: 2 }}>{k.hint}</div>}
      </div>
      <div style={{ minWidth: 0, fontSize: 13, lineHeight: 1.5 }}>
        {k.set ? (
          <>
            <span className="chip t-green">Set here</span> <span className="mono" style={{ wordBreak: 'break-all' }}>{k.shown}</span>
            <div className="faint" style={{ fontSize: 12 }}>{k.set_by ? `${k.set_by}, ` : ''}{when(k.set_at)}{k.env ? ' · overrides the Supabase secret' : ''}</div>
          </>
        ) : k.env ? <><span className="chip t-blue">Supabase secret</span> <span className="faint" style={{ fontSize: 12 }}>Set outside the portal. Add it here to manage it here.</span></>
          : <span className="chip t-grey">Not set</span>}
        {editing && (
          <div className="stack" style={{ gap: 8, marginTop: 8 }}>
            {json ? <textarea className="input mono" rows={6} style={{ fontSize: 12 }} placeholder='{ "type": "service_account", ... }' value={value} onChange={(e) => setValue(e.target.value)} aria-label={k.label} />
              : <input className="input mono" type={k.secret ? 'password' : 'text'} autoComplete="off" spellCheck={false} placeholder={k.secret ? 'Paste the key' : 'Enter the value'}
                  value={value} onChange={(e) => setValue(e.target.value)} aria-label={k.label} onKeyDown={(e) => { if (e.key === 'Enter') void save(); }} />}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
            <div className="row wrap" style={{ gap: 6 }}>
              <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save</button>
              <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { setEditing(false); setValue(''); setErr(null); }}>Cancel</button>
            </div>
          </div>
        )}
      </div>
      {!editing && (
        <div className="row wrap" style={{ gap: 6, justifyContent: 'flex-end' }}>
          <button className="btn btn-secondary btn-sm" onClick={() => setEditing(true)}>{k.set || k.env ? 'Replace' : 'Add'}</button>
          {k.set && <button className={'btn btn-sm ' + (confirm ? 'btn-danger' : 'btn-ghost')} disabled={busy} onClick={remove} onBlur={() => setConfirm(false)}>{confirm ? 'Remove it' : 'Remove'}</button>}
        </div>
      )}
    </div>
  );
}

function Hook({ label, url, last }: { label: string; url: string; last?: string | null }) {
  const toast = useToast();
  return (
    <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.3fr) minmax(0,2fr)' }}>
      <div><b>{label}</b><div className="faint" style={{ fontSize: 12 }}>{last === undefined ? 'Enter this address in the provider\'s dashboard.' : last ? `Last heard ${when(last)}` : 'Nothing received yet'}</div></div>
      <div className="row" style={{ gap: 6, minWidth: 0 }}>
        <code className="ellipsis" style={{ fontSize: 12, minWidth: 0, flex: 1 }}>{url}</code>
        <button className="btn btn-secondary btn-sm" onClick={() => navigator.clipboard?.writeText(url).then(() => toast('Copied'))}><Icon name="copy" size={14} />Copy</button>
      </div>
    </div>
  );
}

function Group({ g, data }: { g: (typeof GROUPS)[number]; data: KeysStatus }) {
  const [test, setTest] = useState<{ ok: boolean; note: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const keys = data.keys.filter((k) => k.group === g.id);
  const needed = keys.filter((k) => k.secret && !/fallback|optional/i.test(k.label));
  const ready = needed.length ? needed.every((k) => k.set || k.env) : keys.some((k) => k.set || k.env);
  async function run() {
    setBusy(true);
    const r = await edge<{ ok: boolean; note: string }>('admin', { action: 'test', group: g.id });
    setBusy(false);
    setTest({ ok: Boolean(r.ok), note: r.note || r.error || 'No answer.' });
  }
  const wh = data.webhooks;
  return (
    <Card title={g.title} sub={g.what} pad={false}
      right={<div className="row" style={{ gap: 8 }}>
        <span className={'chip ' + (ready ? 't-green' : 't-amber')}>{ready ? 'Set up' : 'Missing a key'}</span>
        {g.test && <button className="btn btn-secondary btn-sm" disabled={busy} onClick={run}>{busy ? <Spinner small /> : <Icon name="zap" size={14} />}Test</button>}
      </div>}>
      {test && <div style={{ padding: '12px 16px 0' }}><Alert kind={test.ok ? 'green' : 'red'} icon={test.ok ? 'check' : 'alert'}>{test.note}</Alert></div>}
      {keys.map((k) => <KeyLine key={k.name} k={k} />)}
      {g.id === 'flutterwave' && <Hook label="Webhook address" url={wh.flutterwave.url} last={wh.flutterwave.last?.received_at ?? null} />}
      {g.id === 'mono' && <Hook label="Webhook address" url={wh.mono.url} />}
      {g.id === 'whatsapp' && <Hook label="Webhook address" url={wh.whatsapp.url} last={wh.whatsapp.last} />}
      {g.id === 'taxstreem' && <Hook label="Flux reports back to" url={wh.flux.url} />}
    </Card>
  );
}

export default function Keys() {
  const keys = useKeys();
  return (
    <>
      <PageHead title="Keys and services" sub="Keys for every business, kept in Supabase Vault. A key is shown only by its last four characters once saved, every change is recorded and emailed to all admins, and Counta picks it up within a minute." />
      {keys.isLoading ? <SkeletonRows n={8} /> : keys.data?.ok === false || !keys.data ? <Alert kind="red" icon="alert">{keys.data?.error || 'Could not load the keys.'}</Alert>
        : GROUPS.map((g) => <Group key={g.id} g={g} data={keys.data!} />)}
    </>
  );
}
