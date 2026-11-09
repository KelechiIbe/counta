// Payments, POS terminals: the business's Moniepoint account connected with an API key (the owner), its terminals and the branch
// each sits in, the ₦100 test that shows amounts arrive as Counta means them, and the POS payments waiting to be matched.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, usePos, usePosToMatch, type PosConnection, type PosOverview, type PosRequest, type PosTerminal } from '../../lib/api';
import { N2, when } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { PosToMatch } from './PosMatch';

const OUTCOME: Record<string, string> = { request: 'Till sale', collection: 'Confirmed a recorded payment', sale: 'Recorded as a till sale', unassigned: 'Waiting to be matched',
  assigned: 'Matched by a person', new: 'Waiting', ignored: 'Not a sale' };

export function PosTerminals() {
  const pos = usePos();
  const d = pos.data;
  const match = usePosToMatch(!!d?.can.assign);
  const [connect, setConnect] = useState<PosConnection | 'new' | null>(null);
  if (pos.isLoading || !d) return <SkeletonRows n={4} />;
  const conns = d.connections;
  return (
    <div className="stack" style={{ gap: 16 }}>
      {!conns.length ? (
        <div className="card card-pad stack" style={{ gap: 12, maxWidth: 760 }}>
          <div style={{ fontSize: 18, fontWeight: 600 }}>Take payments on your Moniepoint terminals</div>
          <div className="muted" style={{ fontSize: 14, lineHeight: 1.6 }}>
            Connect the Moniepoint account your terminals pay into. The till then sends each sale's amount to a terminal, so nobody keys it in by hand,
            and the sale completes the moment Moniepoint confirms the payment. Payments keyed on a terminal by hand reach Counta too, and are matched to their sales.
          </div>
          {d.sample ? <Alert kind="grey" icon="shield">The sample business cannot connect a POS provider. Switch to your own business.</Alert>
            : d.can.connect ? <div><button className="btn btn-primary" onClick={() => setConnect('new')}><Icon name="link" size={14} color="#fff" />Connect Moniepoint</button></div>
              : <Alert kind="grey" icon="shield">The owner connects the Moniepoint account, because it needs a key only the owner should create.</Alert>}
          <div className="faint" style={{ fontSize: 12 }}>OPay and PalmPay terminals are not supported yet.</div>
        </div>
      ) : conns.map((c) => <ConnectionCard key={c.id} c={c} d={d} onReplace={() => setConnect(c)} />)}
      {d.can.assign && (match.data || []).length > 0 && (
        <div className="stack" style={{ gap: 8 }}>
          <div style={{ fontWeight: 600 }}>Payments to match</div>
          <PosToMatch rows={match.data || []} />
        </div>
      )}
      {d.recent.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>Recent terminal payments</b></div>
          {d.recent.map((t) => (
            <div key={t.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', alignItems: 'start' }}>
              <span style={{ minWidth: 0 }}><b>{t.terminal_name || t.terminal_serial || 'Terminal'}</b>
                <span className="faint" style={{ display: 'block', fontSize: 12 }}>{t.kind === 'card' ? 'Card' : t.kind === 'transfer' ? 'Transfer' : 'POS'} · {when(t.occurred_at)} · {OUTCOME[t.outcome] || t.outcome}{t.sale_number ? ` · ${t.sale_number}` : ''}{t.cleared ? ' · in the account' : ''}</span></span>
              <span className="right num" style={{ whiteSpace: 'nowrap' }}>{N2(t.amount)}</span>
            </div>
          ))}
        </div>
      )}
      {connect && <ConnectModal d={d} existing={connect === 'new' ? null : connect} onClose={() => setConnect(null)} />}
    </div>
  );
}

function ConnectionCard({ c, d, onReplace }: { c: PosConnection; d: PosOverview; onReplace: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<string | null>(null);
  const [testing, setTesting] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const refresh = () => Promise.all(['pos_overview', 'pos_till'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
  async function testKey() {
    setBusy('key');
    const r = await edge<{ error?: string }>('pos', { action: 'test_key', connection_id: c.id });
    if (r.ok === false) toast(r.error || 'The key does not work.', 'err'); else toast('The key works');
    await refresh(); setBusy(null);
  }
  async function account(id: string) {
    try { await rpc('pos_connection_update', { p_connection: c.id, p: { bank_account_id: id } }); toast('Saved'); await refresh(); } catch (e) { toast((e as Error).message, 'err'); }
  }
  const live = c.status === 'live';
  const terms = c.terminals.filter((t) => t.active);
  return (
    <div className="card card-pad stack" style={{ gap: 12 }} data-testid="pos-connection">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 10 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 17, fontWeight: 600 }}>{c.provider_name}{c.business_name ? ` · ${c.business_name}` : ''}</div>
          <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>
            {c.key_hint ? `Key ending ${c.key_hint} · ` : ''}{c.last_event_at ? `last heard from ${when(c.last_event_at)}` : 'no payments yet'}{c.connected_by ? ` · connected by ${c.connected_by}` : ''}
          </div>
        </div>
        <span className={'chip ' + (live ? 't-green' : 't-red')}>{live ? 'Connected' : 'Stopped answering'}</span>
      </div>
      {!live && <Alert kind="red" icon="alert">{c.last_error || 'Moniepoint stopped answering Counta.'} {d.can.connect ? 'Test the key, or replace it.' : 'Tell the owner.'}</Alert>}
      {!c.unit_checked && live && (
        <Alert kind="amber" icon="info">
          <span className="row wrap" style={{ gap: 8, justifyContent: 'space-between', width: '100%' }}>
            <span>Send ₦100 to a terminal to check the amount arrives as Counta means it. The till sends sales to the terminals only after this test.</span>
            {d.can.manage && <button className="btn btn-primary btn-xs" disabled={!terms.length} onClick={() => setTesting(true)}>Run the test</button>}
          </span>
        </Alert>
      )}
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1fr)', gap: 12 }}>
        <Field label="The terminals pay into" hint="Payments wait in the books as being confirmed until this account's statement or feed shows them.">
          {d.can.connect ? (
            <select className="input" value={c.bank_account_id || ''} onChange={(e) => account(e.target.value)} aria-label="The terminals pay into">
              {d.accounts.map((a) => <option key={a.id} value={a.id}>{a.name}{a.account_number ? ` · ${a.account_number}` : ''}</option>)}
            </select>
          ) : <div style={{ paddingTop: 6 }}>{c.bank_account_name}</div>}
        </Field>
        <Field label="Waiting to show in the account">
          <div style={{ paddingTop: 6 }}><b className="num">{N2(c.in_clearing)}</b> <span className="faint">· {c.in_clearing_count} {c.in_clearing_count === 1 ? 'payment' : 'payments'}</span></div>
        </Field>
      </div>
      <Terminals c={c} d={d} />
      {d.can.connect && (
        <div className="row wrap" style={{ gap: 8 }}>
          <button className="btn btn-secondary btn-sm" disabled={!!busy} onClick={testKey}>{busy === 'key' ? <Spinner small /> : <Icon name="shield" size={14} />}Test the key</button>
          <button className="btn btn-secondary btn-sm" onClick={onReplace}><Icon name="refresh" size={14} />Replace the key</button>
          {c.unit_checked && <button className="btn btn-ghost btn-sm" disabled={!terms.length} onClick={() => setTesting(true)}>Send a ₦100 test</button>}
          <button className="btn btn-ghost btn-sm" style={{ color: '#B91C1C' }} onClick={() => setLeaving(true)}>Disconnect</button>
        </div>
      )}
      {testing && <TestModal c={c} onClose={() => { setTesting(false); void refresh(); }} />}
      {leaving && <DisconnectModal c={c} onClose={() => { setLeaving(false); void refresh(); }} />}
    </div>
  );
}

function Terminals({ c, d }: { c: PosConnection; d: PosOverview }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [add, setAdd] = useState({ serial: '', label: '', location_id: d.locations[0]?.id || '' });
  const [busy, setBusy] = useState(false);
  async function save(p: Record<string, unknown>, ok?: string) {
    setBusy(true);
    try {
      await rpc('pos_terminal_save', { p_connection: c.id, p });
      if (ok) toast(ok);
      await Promise.all(['pos_overview', 'pos_till'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      return true;
    } catch (e) { toast((e as Error).message, 'err'); return false; }
    finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div style={{ fontWeight: 600 }}>Terminals</div>
      {!c.terminals.length && <Empty>Add each terminal by its serial number (on the back of the terminal, or in the Moniepoint Business app). A terminal that takes a payment before you add it appears here on its own.</Empty>}
      {c.terminals.map((t) => <TerminalRow key={t.id} t={t} d={d} busy={busy} save={save} />)}
      {d.can.manage && (
        <div className="row wrap" style={{ gap: 8, alignItems: 'flex-end' }}>
          <input className="input input-sm" style={{ width: 160 }} value={add.serial} onChange={(e) => setAdd({ ...add, serial: e.target.value })} placeholder="Serial, e.g. P260…" aria-label="Terminal serial number" />
          <input className="input input-sm" style={{ width: 150 }} value={add.label} onChange={(e) => setAdd({ ...add, label: e.target.value })} placeholder="Name, e.g. Front desk" aria-label="Terminal name" />
          <select className="input input-sm" style={{ width: 'auto' }} value={add.location_id} onChange={(e) => setAdd({ ...add, location_id: e.target.value })} aria-label="Terminal branch">
            {d.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
          <button className="btn btn-secondary btn-sm" disabled={busy || !add.serial.trim()} onClick={async () => {
            if (await save({ serial: add.serial, label: add.label, location_id: add.location_id || null }, 'Terminal added')) setAdd({ ...add, serial: '', label: '' });
          }}><Icon name="plus" size={13} />Add the terminal</button>
        </div>
      )}
    </div>
  );
}

function TerminalRow({ t, d, busy, save }: { t: PosTerminal; d: PosOverview; busy: boolean; save: (p: Record<string, unknown>, ok?: string) => Promise<boolean> }) {
  const [label, setLabel] = useState(t.label || '');
  const can = d.can.manage;
  return (
    <div className="row wrap" style={{ gap: 8, padding: '8px 10px', background: t.active ? '#FAFAFA' : '#F3F4F6', borderRadius: 10, opacity: t.active ? 1 : 0.7 }}
      data-testid="pos-terminal" data-serial={t.serial}>
      <input className="input input-sm" style={{ width: 150 }} value={label} disabled={!can || busy} onChange={(e) => setLabel(e.target.value)}
        onBlur={() => { if (label !== (t.label || '')) void save({ id: t.id, label }, 'Saved'); }} placeholder={t.name} aria-label={`Name of terminal ${t.serial}`} />
      <span className="faint num" style={{ fontSize: 12, minWidth: 110 }}>{t.serial}</span>
      <select className="input input-sm" style={{ width: 'auto', borderColor: t.location_id ? undefined : '#F59E0B' }} value={t.location_id || ''} disabled={!can || busy}
        onChange={(e) => void save({ id: t.id, location_id: e.target.value || null }, 'Saved')} aria-label={`Branch of terminal ${t.serial}`}>
        <option value="">Which branch is it in?</option>
        {d.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
      </select>
      <span className="faint" style={{ fontSize: 12, flex: '1 1 120px' }}>{t.last_seen_at ? `last payment ${when(t.last_seen_at)}` : 'no payments yet'}</span>
      {can && <button className="btn btn-ghost btn-xs" disabled={busy} onClick={() => void save({ id: t.id, active: !t.active }, t.active ? 'The till stops sending to it' : 'Back in use')}>{t.active ? 'Stop using' : 'Use again'}</button>}
    </div>
  );
}

function ConnectModal({ d, existing, onClose }: { d: PosOverview; existing: PosConnection | null; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const { orgId } = useSession();
  const guess = d.accounts.find((a) => /moniepoint/i.test(`${a.name} ${a.bank_name || ''}`));
  const [key, setKey] = useState('');
  const [acct, setAcct] = useState(existing?.bank_account_id || guess?.id || '');
  const [acctNo, setAcctNo] = useState('');
  const [choose, setChoose] = useState<{ id: string; name: string }[] | null>(null);
  const [biz, setBiz] = useState(existing?.business_ref || '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setBusy(true); setErr(null);
    const r = await edge<{ choose?: { id: string; name: string }[]; connection?: PosConnection }>('pos', { action: 'connect', org_id: orgId,
      key: key.trim(), business_id: biz || undefined, bank_account_id: acct || undefined, account_number: !acct && acctNo ? acctNo : undefined });
    setBusy(false);
    if (r.ok === false) { setErr(r.error || 'Moniepoint did not answer. Try again.'); return; }
    if (r.choose) { setChoose(r.choose); setBiz(r.choose[0]?.id || ''); return; }
    toast(existing ? 'The new key is in use' : 'Moniepoint is connected. Add your terminals and run the ₦100 test.');
    await Promise.all(['pos_overview', 'pos_till'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    onClose();
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={existing ? 'Replace the Moniepoint key' : 'Connect Moniepoint'} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        <ol style={{ margin: 0, paddingLeft: 18, fontSize: 14, lineHeight: 1.7 }} className="muted">
          <li>In the Moniepoint Business app, open Settings, then POS Terminal Configuration, and switch on ERP Integration.</li>
          <li>Open POS App Developers and create a client (an API key) for the live environment.</li>
          <li>Tick transaction push, transaction read, webhook read and webhook write.</li>
          <li>Copy the key straight away: Moniepoint shows it once. Paste it below.</li>
        </ol>
        <Field label="API key" req>
          <input className="input" type="password" autoComplete="off" spellCheck={false} value={key} onChange={(e) => setKey(e.target.value)} aria-label="API key" placeholder="Paste the key" />
        </Field>
        {choose && (
          <Field label="This key covers several businesses. Which one is this?">
            <select className="input" value={biz} onChange={(e) => setBiz(e.target.value)} aria-label="Moniepoint business">
              {choose.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          </Field>
        )}
        {!existing && (
          <Field label="The terminals pay into" hint="Counta keeps POS money as being confirmed until this account's statement or feed shows it.">
            <select className="input" value={acct} onChange={(e) => setAcct(e.target.value)} aria-label="The terminals pay into">
              <option value="">A new account called Moniepoint</option>
              {d.accounts.map((a) => <option key={a.id} value={a.id}>{a.name}{a.account_number ? ` · ${a.account_number}` : ''}</option>)}
            </select>
          </Field>
        )}
        {!existing && !acct && (
          <Field label="Its account number (optional)">
            <input className="input num" inputMode="numeric" maxLength={10} value={acctNo} onChange={(e) => setAcctNo(e.target.value.replace(/\D/g, ''))} aria-label="Moniepoint account number" />
          </Field>
        )}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <div className="faint" style={{ fontSize: 12 }}>Counta keeps the key locked away and uses it only to send amounts to your terminals and read their payments. It cannot move money out of the account.</div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || key.trim().length < 16} onClick={go}>{busy ? 'Checking with Moniepoint…' : choose ? 'Connect this business' : existing ? 'Use the new key' : 'Connect'}</button>
      </div>
    </Modal>
  );
}

function TestModal({ c, onClose }: { c: PosConnection; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const terms = c.terminals.filter((t) => t.active);
  const [term, setTerm] = useState(terms.find((t) => t.location_id)?.id || terms[0]?.id || '');
  const [req, setReq] = useState<PosRequest | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  async function send() {
    setBusy(true); setResult(null);
    try {
      const r = await rpc<PosRequest>('pos_test_request', { p_connection: c.id, p_terminal: term });
      const x = await edge<{ request: PosRequest }>('pos', { action: 'push', request_id: r.id });
      if (x.ok === false || !x.request) toast(x.error || 'Moniepoint did not answer.', 'err');
      setReq(x.request || r);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  async function answer(a: 'right' | 'too_big' | 'too_small') {
    setBusy(true);
    try {
      await rpc('pos_test_answer', { p_connection: c.id, p_answer: a });
      await Promise.all(['pos_overview', 'pos_till'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      if (a === 'right') { toast('The terminals are ready for sales'); onClose(); return; }
      setResult('Counta has changed how it counts the amount. Cancel the payment on the terminal, then send the test again.');
      setReq(null);
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title="The ₦100 test" onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 12 }}>
        {!req ? (
          <>
            <div className="muted" style={{ fontSize: 14 }}>Counta sends ₦100 to a terminal. You look at the terminal and say what it shows, then cancel it there. Do not pay it.</div>
            {result && <Alert kind="amber" icon="info">{result}</Alert>}
            <Field label="Terminal">
              <select className="input" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="Terminal to test">
                {terms.map((t) => <option key={t.id} value={t.id}>{t.name} · {t.serial}</option>)}
              </select>
            </Field>
          </>
        ) : req.status === 'failed' ? (
          <Alert kind="red" icon="alert">{req.error || 'Moniepoint did not send it.'}</Alert>
        ) : (
          <>
            <div className="muted" style={{ fontSize: 14 }}>Look at {req.terminal_name}. What amount does it show?</div>
            <div className="stack" style={{ gap: 8 }}>
              <button className="btn btn-primary" disabled={busy} onClick={() => answer('right')}>₦100.00</button>
              <button className="btn btn-secondary" disabled={busy} onClick={() => answer('too_big')}>₦10,000.00</button>
              <button className="btn btn-secondary" disabled={busy} onClick={() => answer('too_small')}>₦1.00</button>
            </div>
            <div className="faint" style={{ fontSize: 12 }}>Nothing on the terminal? Check it is switched on and online, that ERP Integration is on in the Moniepoint Business app, and that its app is up to date. Then send the test again.</div>
          </>
        )}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        {(!req || req.status === 'failed') && <button className="btn btn-primary" disabled={busy || !term} onClick={send}>{busy ? 'Sending…' : 'Send ₦100'}</button>}
        {req && req.status !== 'failed' && <button className="btn btn-ghost" disabled={busy} onClick={() => setReq(null)}>Send it again</button>}
      </div>
    </Modal>
  );
}

function DisconnectModal({ c, onClose }: { c: PosConnection; onClose: () => void }) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true);
    const r = await edge<{ warning?: string | null }>('pos', { action: 'disconnect', connection_id: c.id });
    setBusy(false);
    if (r.ok === false) { toast(r.error || 'Could not disconnect.', 'err'); return; }
    toast(r.warning || 'Moniepoint is disconnected');
    onClose();
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title="Disconnect Moniepoint?" onClose={onClose} />
      <div className="modal-body">
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.6 }}>The till stops sending sales to the terminals, Moniepoint stops sending their payments to Counta, and the key is wiped. Payments already in the books stay.</div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Keep it</button>
        <button className="btn btn-primary" style={{ background: '#B91C1C', borderColor: '#B91C1C' }} disabled={busy} onClick={go}>{busy ? 'Disconnecting…' : 'Disconnect'}</button>
      </div>
    </Modal>
  );
}
