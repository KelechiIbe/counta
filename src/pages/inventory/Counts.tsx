import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from '../../state/session';
import { useAction, useCounts } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { N, fmtDay, signed, when } from '../../lib/format';
import { qtyLabel } from '../../lib/domain';
import { REASONS, type CountSession } from '../../lib/types';
import { acct, usePostingMap } from '../../lib/accounts';
import { Icon } from '../../components/Icon';
import { Alert, Annot, Chip, Drawer, Field, Label, Modal, ModalHead, SkeletonRows, XButton } from '../../components/ui';

const STATUS: Record<CountSession['status'], string> = { open: 'In progress', awaiting_reasons: 'Awaiting reasons', awaiting_approval: 'Awaiting approval', approved: 'Approved' };
const COLS = '90px 110px minmax(200px,1.4fr) 160px 120px 70px 90px 150px';

export default function Counts() {
  const { data: inv } = useInventory();
  const counts = useCounts();
  const location = useLocation();
  const nav = useNavigate();
  const st = (location.state || {}) as { open?: string; newCount?: { location_id?: string; area?: string } };
  const [active, setActive] = useState<string | null>(st.open || null);
  const [newCount, setNewCount] = useState<null | { location_id?: string; area?: string }>(st.newCount || null);
  useEffect(() => { if (st.open || st.newCount) nav(location.pathname, { replace: true, state: null }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const approver = can(inv, 'approve_adjustments');
  const rows = (counts.data || []).filter((c) => approver || c.assignee_id === inv.me.id);
  const locName = (id: string) => inv.locations.find((l) => l.id === id)?.name || '—';
  const who = (id: string | null) => inv.members.find((m) => m.id === id)?.display_name || '—';
  const session = active ? (counts.data || []).find((c) => c.id === active) || null : null;
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="ink3" style={{ fontSize: 14, maxWidth: 640, lineHeight: 1.5 }}>Staff count blind on their phones; expected quantities stay hidden. Differences post as adjustment journals only after you approve them.</div>
        {approver ? <button className="btn btn-primary" onClick={() => setNewCount({})}><Icon name="plus" size={16} color="#fff" />New count session</button>
          : <Annot>Counts are scheduled by the owner</Annot>}
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Count sessions</Label></div>
        <div className="tbl">
          <div className="tr head th" style={{ gridTemplateColumns: COLS, minWidth: 940 }}>
            <span>Session</span><span>Location</span><span>Area</span><span>Assigned to</span><span>Date</span><span>Items</span><span>Variances</span><span>Status</span>
          </div>
          {counts.isLoading && <SkeletonRows n={3} />}
          {rows.map((c) => {
            const lines = c.count_lines || [];
            const vars = lines.filter((l) => l.counted != null && l.expected != null && Number(l.counted) !== Number(l.expected)).length;
            return (
              <div key={c.id} className="tr click" onClick={() => setActive(c.id)} style={{ gridTemplateColumns: COLS, minWidth: 940 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{c.ref}</span>
                <span className="ink3">{locName(c.location_id)}</span>
                <span style={{ fontWeight: 500 }} className="ellipsis">{c.area}</span>
                <span className="ink3 ellipsis">{who(c.assignee_id)}{c.assignee_id === inv.me.id ? ' (you)' : ''}</span>
                <span className="muted">{fmtDay(c.submitted_at || c.created_at)}</span>
                <span className="ink3">{lines.length || '—'}</span>
                <span style={{ fontWeight: 600 }}>{c.status === 'open' ? '—' : approver ? vars : '—'}</span>
                <span><Chip label={STATUS[c.status]} /></span>
              </div>
            );
          })}
          {counts.data && !rows.length && <div className="muted" style={{ padding: 24, fontSize: 14 }}>{approver ? 'No counts yet. Start one for a shelf, an aisle or the whole store.' : 'No counts are assigned to you.'}</div>}
        </div>
      </div>
      {session && <CountDrawer session={session} onClose={() => setActive(null)} />}
      {newCount && <NewCountModal preset={newCount} onClose={() => setNewCount(null)} onCreated={(id) => { setNewCount(null); setActive(id); }} />}
    </div>
  );
}

function NewCountModal({ preset, onClose, onCreated }: { preset: { location_id?: string; area?: string }; onClose: () => void; onCreated: (id: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const counters = (inv?.members || []).filter((m) => m.status !== 'disabled' && (m.role === 'owner' || m.perms.count_stock));
  const [loc, setLoc] = useState(preset.location_id || inv?.locations[0]?.id || '');
  const [area, setArea] = useState(preset.area || 'Whole store');
  const [cat, setCat] = useState('');
  const [assignee, setAssignee] = useState(counters.find((m) => m.location_id === (preset.location_id || inv?.locations[0]?.id) && m.role !== 'owner')?.id || counters[0]?.id || '');
  const cats = useMemo(() => [...new Set((inv?.items || []).map((i) => i.category))].sort(), [inv]);
  const person = counters.find((m) => m.id === assignee);
  async function create() {
    const r = await run(() => rpc<{ id: string; ref: string; items: number }>('create_count_session', { p_org: orgId, p_location: loc, p_area: area, p_assignee: assignee, p_category: cat || null }), {
      ok: (r) => `${r.ref} sent to ${person?.is_me ? 'your phone' : (person?.display_name.split(' ')[0] || 'their') + "'s phone"} · ${r.items} items`, invalidate: ['counts'],
    });
    if (r) onCreated(r.id);
  }
  return (
    <Modal onClose={onClose} width={460}>
      <ModalHead title="New count session" onClose={onClose} />
      <div className="modal-body">
        <Field label="Location"><select className="input" value={loc} onChange={(e) => setLoc(e.target.value)}>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        <Field label="Area or shelf"><input className="input" value={area} onChange={(e) => setArea(e.target.value)} placeholder="e.g. Aisle 3 · Drinks & dairy" /></Field>
        <Field label="Items to count" hint="Leave on every item in stock, or limit the sheet to one category.">
          <select className="input" value={cat} onChange={(e) => setCat(e.target.value)}><option value="">Everything in stock at this branch</option>{cats.map((c) => <option key={c} value={c}>{c}</option>)}</select>
        </Field>
        <Field label="Assign to" hint={'Only people with the "Count stock" permission are listed. They count blind; expected quantities stay hidden.'}>
          <select className="input" value={assignee} onChange={(e) => setAssignee(e.target.value)}>
            {counters.map((m) => <option key={m.id} value={m.id}>{m.display_name}{m.is_me ? ' (you)' : ''}{!m.has_login ? ' · no login yet' : ''}</option>)}
          </select>
        </Field>
        {person && !person.has_login && <Alert kind="yellow" icon="info">{person.display_name.split(' ')[0]} has not signed in yet, so the count will wait until they do. Invite them from Locations &amp; staff.</Alert>}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={create} disabled={busy || !assignee || !loc}><Icon name="send" size={16} color="#fff" />Send to their phone</button>
      </div>
    </Modal>
  );
}

function CountDrawer({ session: s, onClose }: { session: CountSession; onClose: () => void }) {
  const { data: inv } = useInventory();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const approver = can(inv, 'approve_adjustments');
  const [reasons, setReasons] = useState<Record<string, { reason: string; note: string }>>({});
  const [confirmReject, setConfirmReject] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const map = usePostingMap().data;
  if (!inv) return null;
  const items = new Map(inv.items.map((i) => [i.id, i]));
  const locName = inv.locations.find((l) => l.id === s.location_id)?.name || '';
  const counter = inv.members.find((m) => m.id === s.assignee_id);
  const lines = (s.count_lines || []).map((l) => {
    const it = items.get(l.item_id);
    const v = l.counted != null && l.expected != null ? Number(l.counted) - Number(l.expected) : null;
    const r = reasons[l.item_id];
    return { ...l, it, v, value: v != null && it?.wac != null ? v * Number(it.wac) : null, reason: r?.reason ?? l.reason, note: r?.note ?? l.note };
  }).sort((a, b) => Math.abs(b.v || 0) - Math.abs(a.v || 0) || (a.it?.name || '').localeCompare(b.it?.name || ''));
  const net = lines.reduce((a, l) => a + (l.value || 0), 0);
  const missing = lines.filter((l) => l.v && !l.reason).length;
  const submitted = s.status !== 'open';
  const changed = Object.keys(reasons).length > 0;

  async function saveReasons(): Promise<boolean> {
    const list = lines.filter((l) => l.v && l.reason).map((l) => ({ item_id: l.item_id, reason: l.reason, note: l.note || '' }));
    const bad = list.find((l) => l.reason === 'Other' && !l.note.trim());
    if (bad) { setErr('Add a note when the reason is Other.'); return false; }
    const r = await run(() => rpc('set_count_reasons', { p_session: s.id, p_reasons: list }), { invalidate: ['counts'] });
    if (r !== undefined) setReasons({});
    return r !== undefined;
  }
  async function approve() {
    setErr(null);
    if (missing) { setErr(`${missing} variance${missing === 1 ? '' : 's'} still need${missing === 1 ? 's' : ''} a reason.`); return; }
    if (changed && !(await saveReasons())) return;
    const r = await run(() => rpc<{ journals: string[]; net_value: number }>('approve_count', { p_session: s.id }), {
      ok: (r) => r.journals.length ? `Approved · ${r.journals.length} adjustment journal${r.journals.length === 1 ? '' : 's'} posted` : 'Approved · no differences to post',
      invalidate: ['counts', 'inv', 'ledger', 'activity'],
    });
    if (r) onClose();
  }
  async function reject() {
    if (!confirmReject) { setConfirmReject(true); return; }
    const r = await run(() => rpc('reject_count', { p_session: s.id }), { ok: `${s.ref} reopened on ${counter?.display_name.split(' ')[0] || 'their'}'s phone for a recount`, invalidate: ['counts'] });
    if (r !== undefined) onClose();
  }
  const sub = `${locName} · ${submitted ? `counted by ${counter?.display_name || 'staff'} ${when(s.submitted_at)}` : `assigned to ${counter?.display_name || 'staff'} · ${when(s.created_at)}`}${s.device_id ? ' · phone' : ''}${s.offline ? ', offline' : ''}${s.rejected_count ? ` · recount ${s.rejected_count}` : ''}`;
  return (
    <Drawer onClose={onClose} width={680}>
      <div className="drawer-hd">
        <div className="grow"><div className="drawer-title">{s.ref} · {s.area}</div><div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{sub}</div></div>
        <Chip label={STATUS[s.status]} />
        <XButton onClick={onClose} />
      </div>
      <div className="drawer-body">
        {!submitted ? (
          <div className="stack" style={{ gap: 14 }}>
            <Alert kind="blue" icon="phone">Waiting for {s.assignee_id === inv.me.id ? 'you' : counter?.display_name || 'the counter'} to count {lines.length || 'the'} items on the phone. Expected quantities stay hidden from the counter.</Alert>
            {s.assignee_id === inv.me.id && <button className="btn btn-primary" style={{ alignSelf: 'flex-start' }} onClick={() => nav('/m/count/' + s.id)}><Icon name="phone" size={16} color="#fff" />Count on this device</button>}
            {approver && lines.length > 0 && (
              <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}>
                <div className="tr head shade th" style={{ gridTemplateColumns: '1fr 160px' }}><span>On the count sheet</span><span className="right">On hand now</span></div>
                {lines.map((l) => <div key={l.item_id} className="tr" style={{ gridTemplateColumns: '1fr 160px' }}><span>{l.it?.name}</span><span className="right ink3">{l.it ? qtyLabel(l.it, Number(l.it.qty?.[s.location_id] || 0)) : '—'}</span></div>)}
              </div>
            )}
          </div>
        ) : !approver ? (
          <Alert kind="yellow" icon="clock">Submitted. The owner reviews differences and approves the adjustments.</Alert>
        ) : (
          <>
            <div className="th" style={{ display: 'grid', gridTemplateColumns: 'minmax(130px,1.5fr) 68px 68px 52px 84px 140px', gap: 10, padding: '0 4px 8px' }}>
              <span>Item</span><span className="right">Expected</span><span className="right">Counted</span><span className="right">Var</span><span className="right">Value</span><span>Reason</span>
            </div>
            {lines.map((l) => {
              const color = !l.v ? '#9CA3AF' : l.v < 0 ? '#DC2626' : '#15803D';
              const editable = !!l.v && s.status !== 'approved';
              return (
                <div key={l.item_id} style={{ borderTop: '1px solid #F3F4F6', padding: '10px 4px' }}>
                  <div style={{ display: 'grid', gridTemplateColumns: 'minmax(130px,1.5fr) 68px 68px 52px 84px 140px', gap: 10, fontSize: 13, alignItems: 'center' }}>
                    <span style={{ fontWeight: 600 }}>{l.it?.name || 'Item'}<span className="faint" style={{ display: 'block', fontSize: 11, fontWeight: 400 }}>{l.it?.selling_unit}</span></span>
                    <span className="right muted num">{l.expected != null ? Number(l.expected).toLocaleString('en-NG') : '—'}</span>
                    <span className="right num">{l.counted != null ? Number(l.counted).toLocaleString('en-NG') : '—'}</span>
                    <span className="right num" style={{ fontWeight: 700, color }}>{l.v ? signed(l.v) : '0'}</span>
                    <span className="right num" style={{ color }}>{l.value ? N(l.value) : '—'}</span>
                    <span>
                      {!l.v ? null : editable ? (
                        <select className="input input-sm" value={l.reason || ''} onChange={(e) => { setErr(null); setReasons((r) => ({ ...r, [l.item_id]: { reason: e.target.value, note: r[l.item_id]?.note ?? l.note ?? '' } })); }}>
                          <option value="">Choose reason…</option>{REASONS.map((x) => <option key={x}>{x}</option>)}
                        </select>
                      ) : <span className="chip t-grey">{l.reason}</span>}
                    </span>
                  </div>
                  {editable && l.reason === 'Other' && (
                    <input className="input input-sm" style={{ marginTop: 6 }} placeholder="What happened?" value={l.note || ''}
                      onChange={(e) => setReasons((r) => ({ ...r, [l.item_id]: { reason: 'Other', note: e.target.value } }))} />
                  )}
                  {!editable && l.note && <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>{l.note}</div>}
                </div>
              );
            })}
            <div style={{ marginTop: 16, background: '#FAFAFA', borderRadius: 12, padding: 14, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span className="ink3" style={{ fontSize: 13 }}>Net adjustment to inventory value</span>
              <span style={{ fontFamily: 'var(--font-brand)', fontSize: 22, fontWeight: 600, color: net < 0 ? '#DC2626' : net > 0 ? '#15803D' : '#111827' }}>{net ? (net < 0 ? '−' : '+') + N(Math.abs(net)).replace('−', '') : N(0)}</span>
            </div>
            <div className="ink3" style={{ marginTop: 12, fontSize: 13, lineHeight: 1.5 }}>
              {s.status === 'approved'
                ? `Approved ${when(s.approved_at)} by ${inv.members.find((m) => m.id === s.approved_by)?.display_name || 'the owner'}. Each variance posted as its own journal.`
                : `Approving posts one adjustment journal per variance, each carrying the counter, the reason and you as approver. Breakage, expiry, theft and other losses go to ${acct(map, 'stock_loss').code} ${acct(map, 'stock_loss').name}; miscounts, unrecorded sales and stock found go to ${acct(map, 'stock_variance').code} ${acct(map, 'stock_variance').name}, against ${acct(map, 'inventory').code} ${acct(map, 'inventory').name}. Rejecting reopens the session on ${counter?.display_name.split(' ')[0] || 'the counter'}'s phone for a recount.`}
            </div>
            {err && <Alert kind="red" icon="alert" style={{ marginTop: 12 }}>{err}</Alert>}
          </>
        )}
      </div>
      {approver && submitted && s.status !== 'approved' && (
        <div className="drawer-ft">
          {changed && <button className="btn btn-secondary" onClick={saveReasons} disabled={busy}>Save reasons</button>}
          <button className="btn btn-danger" onClick={reject} disabled={busy}>{confirmReject ? 'Tap again to reopen' : 'Reject · recount'}</button>
          <button className="btn btn-primary" onClick={approve} disabled={busy}>Approve adjustments</button>
        </div>
      )}
      {!approver && submitted && s.status !== 'approved' && <div className="drawer-ft"><Annot>Only the owner can approve adjustments</Annot></div>}
    </Drawer>
  );
}

