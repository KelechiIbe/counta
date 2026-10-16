import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../../state/session';
import { useAction, useActivity, useTransfers } from '../../lib/queries';
import { must, rpc, supabase } from '../../lib/supabase';
import { K, N, initials, when } from '../../lib/format';
import { buildItems, qtyLabel } from '../../lib/domain';
import { moveItem, moveQty, typeLabel, typeTone } from '../../lib/ledger';
import { PERMS, type Location, type Member, type Perm } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { Alert, Chip, Field, Label, Modal, ModalHead, SkeletonRows } from '../../components/ui';
import TransferModal from '../../components/TransferModal';

const ROLE: Record<string, string> = { owner: 'Owner', manager: 'Manager', staff: 'Staff', cashier: 'Cashier' };

export default function Locations() {
  const { data: inv } = useInventory();
  const transfers = useTransfers();
  const activity = useActivity(40);
  const { run, busy } = useAction();
  const [transfer, setTransfer] = useState(false);
  const [branch, setBranch] = useState<Location | 'new' | null>(null);
  const [person, setPerson] = useState<Member | 'new' | null>(null);
  const items = useMemo(() => (inv ? buildItems(inv, 'ALL') : []), [inv]);
  const voice = useQuery({
    queryKey: ['voiceQueue', inv?.org.id], enabled: !!inv && can(inv, 'approve_adjustments') && inv.can_see_costs,
    queryFn: () => must<any[]>(supabase.from('movements').select('id, item_id, qty, unit_price, location_id, author_id, recorded_at, note').eq('org_id', inv!.org.id).eq('review_status', 'pending').order('recorded_at', { ascending: false }).limit(30)),
  });
  if (!inv) return null;
  const owner = inv.me.role === 'owner';
  const costs = inv.can_see_costs;
  const locName = (id: string | null) => inv.locations.find((l) => l.id === id)?.name || '—';
  const itemOf = (id: string) => inv.items.find((i) => i.id === id);
  const memberName = (id: string | null) => inv.members.find((m) => m.id === id)?.display_name || '—';
  const canTransfer = can(inv, 'transfer_stock');
  const canConfirm = can(inv, 'transfer_stock') || can(inv, 'receive_stock');
  return (
    <div className="container">
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(280px,1fr))', gap: 14 }}>
        {inv.locations.map((l) => {
          const value = items.reduce((a, i) => a + Number(i.qty?.[l.id] || 0) * (i.wac || 0), 0);
          const n = items.filter((i) => Number(i.qty?.[l.id] || 0) > 0).length;
          const staff = inv.members.filter((m) => m.location_id === l.id);
          return (
            <div key={l.id} className="card card-pad">
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <div className="row"><Icon name="pin" size={18} color="#0072F5" /><div style={{ fontSize: 16, fontWeight: 600 }}>{l.name}</div>{l.is_main && <span className="chip t-blue">Main</span>}</div>
                {owner && <button className="x-btn" onClick={() => setBranch(l)} aria-label={'Edit ' + l.name}><Icon name="pencil" size={15} color="#9CA3AF" /></button>}
              </div>
              <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{l.address || l.code}</div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 12, marginTop: 16 }}>
                <div><div className="mini-label">Stock value</div><div style={{ fontSize: 20, fontWeight: 600, marginTop: 4, letterSpacing: '-.01em' }}>{costs ? K(value) : '—'}</div></div>
                <div><div className="mini-label">Items</div><div style={{ fontSize: 20, fontWeight: 600, marginTop: 4 }}>{n}</div></div>
                <div><div className="mini-label">Staff</div><div className="ink3" style={{ fontSize: 13, marginTop: 6 }}>{staff.map((s) => s.display_name.split(' ')[0]).join(', ') || '—'}</div></div>
              </div>
            </div>
          );
        })}
        <div style={{ border: '1px dashed #D1D5DB', borderRadius: 16, padding: 20, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 10 }}>
          <div style={{ fontSize: 14, fontWeight: 600 }}>Move stock between branches</div>
          <div className="muted" style={{ fontSize: 13, lineHeight: 1.45 }}>Posts as goods-in-transit until the receiving branch confirms on their phone.</div>
          <div className="row wrap">
            {canTransfer && <button className="btn btn-primary btn-sm" onClick={() => setTransfer(true)}><Icon name="arrowLR" size={16} color="#fff" />New transfer</button>}
            {owner && <button className="btn btn-secondary btn-sm" onClick={() => setBranch('new')}><Icon name="plus" size={14} />Add branch</button>}
          </div>
        </div>
      </div>

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Transfers</Label></div>
        <div className="tbl">
          {transfers.isLoading && <SkeletonRows n={2} />}
          {(transfers.data || []).map((t) => {
            const it = itemOf(t.item_id);
            return (
              <div key={t.id} className="tr" style={{ gridTemplateColumns: '90px minmax(200px,1.5fr) minmax(150px,1fr) 110px 24px 110px 140px 150px', minWidth: 980 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{t.ref}</span>
                <span style={{ fontWeight: 500 }}>{it?.name || 'Item'}</span>
                <span className="ink3">{it ? qtyLabel(it, Number(t.qty)) : t.qty}</span>
                <span className="ink3">{locName(t.from_location_id)}</span><span className="faint">→</span><span className="ink3">{locName(t.to_location_id)}</span>
                <span className="muted">{when(t.received_at || t.created_at)}</span>
                <span>
                  {t.status === 'in_transit' && canConfirm ? (
                    <button className="btn btn-secondary btn-xs" disabled={busy} onClick={() => run(() => rpc<string>('receive_transfer', { p_transfer: t.id }), { ok: (ref) => `${t.ref} received at ${locName(t.to_location_id)} · ${ref}`, invalidate: ['inv', 'transfers', 'ledger', 'activity'] })}>Confirm received</button>
                  ) : <Chip label={t.status === 'in_transit' ? 'In transit' : 'Received'} />}
                </span>
              </div>
            );
          })}
          {transfers.data && !transfers.data.length && <div className="muted" style={{ padding: 20, fontSize: 14 }}>No transfers yet.</div>}
        </div>
      </div>

      {voice.data && voice.data.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><Label>Voice entries to review · {voice.data.length}</Label><span className="faint" style={{ fontSize: 12 }}>Each person's voice sales are checked until {inv.org.voice_trust_threshold} go through without a correction</span></div>
          {voice.data.map((v) => {
            const it = itemOf(v.item_id);
            const m = inv.members.find((x) => x.id === v.author_id);
            return (
              <div key={v.id} className="tr" style={{ gridTemplateColumns: '140px minmax(200px,1.4fr) minmax(200px,1.4fr) 150px 130px', minWidth: 880 }}>
                <span className="muted">{when(v.recorded_at)}</span>
                <span><b>{it ? qtyLabel(it, Math.abs(Number(v.qty))) : Math.abs(v.qty)}</b> {it?.name}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{locName(v.location_id)} · {N(Math.abs(Number(v.qty)) * Number(v.unit_price || 0))}</span></span>
                <span className="ink3" style={{ fontStyle: 'italic', fontSize: 12 }}>{v.note ? `"${v.note}"` : '—'}</span>
                <span className="ink3">{m?.display_name || '—'}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{m ? `${m.voice_confirmed} of ${inv.org.voice_trust_threshold} confirmed` : ''}</span></span>
                <span><button className="btn btn-secondary btn-xs" disabled={busy} onClick={() => run(() => rpc('mark_voice_reviewed', { p_movement: v.id }), { ok: 'Marked reviewed', invalidate: ['voiceQueue', 'voicePending', 'ledger'] })}>Looks right</button></span>
              </div>
            );
          })}
        </div>
      )}

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd">
          <Label>Staff &amp; permissions</Label>
          <div className="row wrap">
            <span className="faint row" style={{ fontSize: 12, gap: 6 }}><Icon name="shield" size={14} color="#9CA3AF" />Whoever records sales can never edit quantities, costs or prices</span>
            {owner && <button className="btn btn-primary btn-sm" onClick={() => setPerson('new')}><Icon name="plus" size={14} color="#fff" />Invite person</button>}
          </div>
        </div>
        <div className="tbl">
          <div className="th" style={{ display: 'grid', gridTemplateColumns: 'minmax(220px,1.4fr) repeat(8,minmax(88px,1fr))', gap: 8, padding: '10px 20px', minWidth: 1040, alignItems: 'end', fontSize: 10 }}>
            <span>Person</span>{PERMS.map((p) => <span key={p.key} style={{ textAlign: 'center', lineHeight: 1.3 }}>{p.label}</span>)}
          </div>
          {inv.members.map((m) => (
            <div key={m.id} style={{ display: 'grid', gridTemplateColumns: 'minmax(220px,1.4fr) repeat(8,minmax(88px,1fr))', gap: 8, padding: '10px 20px', borderTop: '1px solid #F3F4F6', fontSize: 13, alignItems: 'center', minWidth: 1040 }}>
              <button className="row" style={{ gap: 10, border: 0, background: 'transparent', padding: 0, cursor: owner && m.role !== 'owner' ? 'pointer' : 'default', textAlign: 'left', font: 'inherit' }} onClick={() => owner && m.role !== 'owner' && setPerson(m)}>
                <span style={{ width: 32, height: 32, borderRadius: 8, background: '#F3F4F6', display: 'grid', placeItems: 'center', fontSize: 11, fontWeight: 700, color: '#4B5563', flex: 'none' }}>{initials(m.display_name)}</span>
                <span style={{ minWidth: 0 }}>
                  <span style={{ display: 'block', fontWeight: 600 }}>{m.display_name}{m.is_me ? ' (you)' : ''}</span>
                  <span className="faint" style={{ display: 'block', fontSize: 11 }}>{m.title || ROLE[m.role]} · {locName(m.location_id) === '—' ? 'All branches' : locName(m.location_id)}{m.status === 'invited' ? ' · invited' : !m.has_login ? ' · no login' : ''}</span>
                </span>
              </button>
              {PERMS.map((p) => <PermCell key={p.key} m={m} p={p.key} editable={owner && m.role !== 'owner'} />)}
            </div>
          ))}
        </div>
      </div>

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Activity · who did what</Label><span className="faint" style={{ fontSize: 12 }}>Author, branch and capture channel for every movement</span></div>
        <div className="tbl">
          {activity.isLoading && <SkeletonRows n={5} />}
          {(activity.data || []).map((a) => (
            <div key={a.gid} className="tr" style={{ gridTemplateColumns: '150px 110px minmax(200px,1.5fr) minmax(140px,.8fr) 140px 120px minmax(150px,1fr)', minWidth: 1000 }}>
              <span className="muted">{when(a.recorded_at)}</span>
              <span><span className={'chip ' + typeTone(a.type)}>{typeLabel(a.type)}</span></span>
              <span>{moveItem(a)}</span>
              <span className="ink3">{moveQty(a)}</span>
              <span style={{ fontWeight: 500 }}>{a.author_name || 'System'}{a.approver_name ? <span className="faint" style={{ display: 'block', fontSize: 11, fontWeight: 400 }}>approved by {a.approver_name.split(' ')[0]}</span> : null}</span>
              <span className="muted">{locName(a.location_id)}</span>
              <span className="muted" style={{ fontSize: 12 }}>{[a.channel, a.offline ? 'queued offline' : null, a.device_id ? 'phone' : null].filter(Boolean).join(' · ')}</span>
            </div>
          ))}
        </div>
      </div>
      {transfer && <TransferModal onClose={() => setTransfer(false)} />}
      {branch && <BranchModal branch={branch === 'new' ? null : branch} onClose={() => setBranch(null)} />}
      {person && <PersonModal member={person === 'new' ? null : person} onClose={() => setPerson(null)} />}
    </div>
  );
}

function PermCell({ m, p, editable }: { m: Member; p: Perm; editable: boolean }) {
  const { run, busy } = useAction();
  const on = m.role === 'owner' || m.perms[p];
  const conflict = !on && ((p === 'record_sales' && (m.perms.edit_prices || m.perms.approve_adjustments)) || ((p === 'edit_prices' || p === 'approve_adjustments') && m.perms.record_sales));
  const title = m.role === 'owner' ? 'The owner keeps every permission' : conflict ? 'Someone who records sales cannot also edit prices or approve adjustments' : editable ? (on ? 'Click to remove' : 'Click to allow') : '';
  return (
    <div style={{ display: 'flex', justifyContent: 'center' }}>
      <button disabled={!editable || busy || conflict} title={title} aria-pressed={on} aria-label={`${PERMS.find((x) => x.key === p)?.label} for ${m.display_name}`}
        onClick={() => run(() => rpc('update_member', { p_member: m.id, p_patch: { perms: { [p]: !on } } }), { invalidate: ['inv'] })}
        style={{ width: 22, height: 22, borderRadius: 6, border: 0, display: 'grid', placeItems: 'center', background: on ? '#F0F7FF' : '#FAFAFA', color: '#D1D5DB', fontSize: 12, cursor: editable && !conflict ? 'pointer' : 'default', opacity: conflict ? 0.4 : 1 }}>
        {on ? <Icon name="check" size={14} color="#0072F5" sw={2.5} /> : '—'}
      </button>
    </div>
  );
}

function BranchModal({ branch, onClose }: { branch: Location | null; onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [name, setName] = useState(branch?.name || '');
  const [address, setAddress] = useState(branch?.address || '');
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    if (!name.trim()) { setErr('Enter the branch name.'); return; }
    const base = name.trim().replace(/[^A-Za-z]/g, '').slice(0, 3).toUpperCase() || 'BR';
    let code = base; let i = 2;
    while (!branch && inv?.locations.some((l) => l.code === code)) code = base + i++;
    const r = await run(() => branch
      ? must(supabase.from('locations').update({ name: name.trim(), address: address.trim() || null }).eq('id', branch.id).select().single())
      : must(supabase.from('locations').insert({ org_id: orgId, name: name.trim(), code, address: address.trim() || null, is_main: false }).select().single()),
    { ok: branch ? 'Branch updated' : `${name.trim()} added`, invalidate: ['inv'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title={branch ? 'Edit branch' : 'Add branch'} onClose={onClose} />
      <div className="modal-body">
        <Field label="Branch name" req><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Ikeja" /></Field>
        <Field label="Address"><input className="input" value={address} onChange={(e) => setAddress(e.target.value)} placeholder="Street, area" /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        {!branch && <div className="hint">Stock at the new branch starts at zero. Move stock in with a transfer or receive straight into it.</div>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" onClick={save} disabled={busy}>Save branch</button></div>
    </Modal>
  );
}

function PersonModal({ member, onClose }: { member: Member | null; onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [f, setF] = useState({ name: member?.display_name || '', email: member?.email || '', phone: member?.phone || '', role: member?.role || 'staff', title: member?.title || '', location_id: member?.location_id || inv?.locations[0]?.id || '' });
  const [err, setErr] = useState<string | null>(null);
  const [confirmOff, setConfirmOff] = useState(false);
  const set = (k: keyof typeof f, v: string) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    if (!f.name.trim()) { setErr('Enter the person\'s name.'); return; }
    if (f.email && !/^\S+@\S+\.\S+$/.test(f.email.trim())) { setErr('That email address does not look right.'); return; }
    const r = await run(() => member
      ? rpc('update_member', { p_member: member.id, p_patch: { display_name: f.name, role: f.role, title: f.title, phone: f.phone, location_id: f.location_id || '' } })
      : rpc('invite_member', { p_org: orgId, p_name: f.name, p_email: f.email || null, p_role: f.role, p_title: f.title || null, p_location: f.location_id || null, p_phone: f.phone || null }),
    { ok: member ? 'Saved' : f.email ? `${f.name.split(' ')[0]} invited · they join when they sign up with ${f.email.trim()}` : `${f.name.split(' ')[0]} added without a login`, invalidate: ['inv'] });
    if (r !== undefined) onClose();
  }
  async function disable() {
    if (!member) return;
    if (!confirmOff) { setConfirmOff(true); return; }
    const r = await run(() => rpc('update_member', { p_member: member.id, p_patch: { status: 'disabled' } }), { ok: `${member.display_name.split(' ')[0]} no longer has access`, invalidate: ['inv'] });
    if (r !== undefined) onClose();
  }
  const roleNote: Record<string, string> = {
    manager: 'Receives, counts, transfers and approves orders and adjustments. Sees margins.',
    staff: 'Records sales, receives stock and counts. Costs and margins stay hidden.',
    cashier: 'Records sales only. Cannot change quantities, costs or prices.',
  };
  return (
    <Modal onClose={onClose} width={500}>
      <ModalHead title={member ? member.display_name : 'Invite person'} sub={member ? undefined : 'They sign up with this email and land straight in your business.'} onClose={onClose} />
      <div className="modal-body">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Full name" req><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Job title"><input className="input" value={f.title} onChange={(e) => set('title', e.target.value)} placeholder="e.g. Store assistant" /></Field>
        </div>
        {!member && <Field label="Email" hint="Leave blank for someone who will not sign in (their name still appears on counts and voice entries)."><input className="input" type="email" value={f.email} onChange={(e) => set('email', e.target.value)} /></Field>}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Phone (WhatsApp)"><input className="input" inputMode="tel" value={f.phone} onChange={(e) => set('phone', e.target.value)} placeholder="0803…" /></Field>
          <Field label="Branch"><select className="input" value={f.location_id} onChange={(e) => set('location_id', e.target.value)}><option value="">All branches</option>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        </div>
        <Field label="Role" hint={roleNote[f.role]}>
          <select className="input" value={f.role} onChange={(e) => set('role', e.target.value)}><option value="manager">Manager</option><option value="staff">Staff</option><option value="cashier">Cashier</option></select>
        </Field>
        {member && <div className="hint">Changing the role resets permissions to that role's template. Fine-tune them in the matrix.</div>}
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>
      <div className="modal-ft">
        {member && <button className="btn btn-danger" onClick={disable} disabled={busy} style={{ marginRight: 'auto' }}>{confirmOff ? 'Tap again to remove' : 'Remove access'}</button>}
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy}>{member ? 'Save' : 'Send invite'}</button>
      </div>
    </Modal>
  );
}

