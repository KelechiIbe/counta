import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../../state/session';
import { useAction, useActivity, useTransfers } from '../../lib/queries';
import { must, rpc, supabase } from '../../lib/supabase';
import { K, N, initials, when } from '../../lib/format';
import { buildItems, qtyLabel } from '../../lib/domain';
import { moveItem, moveQty, typeLabel, typeTone } from '../../lib/ledger';
import { type Location, type Member } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { Alert, Chip, Field, Label, Modal, ModalHead, SkeletonRows } from '../../components/ui';
import { StateLga } from '../../components/Places';
import { useEinvoice } from '../../lib/einvoice';
import TransferModal from '../../components/TransferModal';
import { ReminderCallModal } from '../../components/Calls';
import { PeopleCard } from '../settings/Team';

const ROLE: Record<string, string> = { owner: 'Owner', manager: 'Manager', staff: 'Staff', cashier: 'Cashier', accountant: 'Accountant' };

export default function Locations() {
  const { data: inv } = useInventory();
  const transfers = useTransfers();
  const activity = useActivity(40);
  const { run, busy } = useAction();
  const [transfer, setTransfer] = useState(false);
  const [branch, setBranch] = useState<Location | 'new' | null>(null);
  const nav = useNavigate();
  const [calling, setCalling] = useState<Member | null>(null);
  const items = useMemo(() => (inv ? buildItems(inv, 'ALL') : []), [inv]);
  const voice = useQuery({
    queryKey: ['voiceQueue', inv?.org.id], enabled: !!inv && can(inv, 'approve_adjustments') && inv.can_see_costs,
    queryFn: () => must<any[]>(supabase.from('movements').select('id, item_id, qty, unit_price, location_id, author_id, recorded_at, note').eq('org_id', inv!.org.id).eq('review_status', 'pending').order('recorded_at', { ascending: false }).limit(30)),
  });
  // Only a business on e-invoicing is told its main branch needs a postcode (NRS refuses invoices without one).
  const einv = useEinvoice(inv && can(inv, 'manage_settings') ? inv.org.id : null);
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
              <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{[l.address || l.code, [l.city, l.lga, l.state].filter(Boolean).join(', '), l.postcode].filter(Boolean).join(' · ')}{!l.state && <span style={{ color: '#B45309' }}> · add its state</span>}{l.is_main && l.state && !l.postcode && einv.data?.started && <span style={{ color: '#B45309' }} data-testid="branch-needs-postcode"> · add its postcode: NRS needs it on e-invoices</span>}</div>
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
              <div key={t.id} className="tr rsp" style={{ gridTemplateColumns: '90px minmax(200px,1.5fr) minmax(150px,1fr) 110px 24px 110px 140px 150px', minWidth: 980 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{t.ref}</span>
                <span style={{ fontWeight: 500 }} className="m-main m-first">{it?.name || 'Item'}</span>
                <span className="ink3">{it ? qtyLabel(it, Number(t.qty)) : t.qty}</span>
                <span className="ink3">{locName(t.from_location_id)}</span><span className="faint">→</span><span className="ink3">{locName(t.to_location_id)}</span>
                <span className="muted">{when(t.received_at || t.created_at)}</span>
                <span className="m-end">
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
              <div key={v.id} className="tr rsp" style={{ gridTemplateColumns: '140px minmax(200px,1.4fr) minmax(200px,1.4fr) 150px 130px', minWidth: 880 }}>
                <span className="muted">{when(v.recorded_at)}</span>
                <span className="m-main m-first"><b>{it ? qtyLabel(it, Math.abs(Number(v.qty))) : Math.abs(v.qty)}</b> {it?.name}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{locName(v.location_id)} · {N(Math.abs(Number(v.qty)) * Number(v.unit_price || 0))}</span></span>
                <span className="ink3" style={{ fontStyle: 'italic', fontSize: 12 }}>{v.note ? `"${v.note}"` : '—'}</span>
                <span className="ink3">{m?.display_name || '—'}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{m ? `${m.voice_confirmed} of ${inv.org.voice_trust_threshold} confirmed` : ''}</span></span>
                <span className="m-end"><button className="btn btn-secondary btn-xs" disabled={busy} onClick={() => run(() => rpc('mark_voice_reviewed', { p_movement: v.id }), { ok: 'Marked reviewed', invalidate: ['voiceQueue', 'voicePending', 'ledger'] })}>Looks right</button></span>
              </div>
            );
          })}
        </div>
      )}

      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="row wrap" style={{ justifyContent: 'space-between' }}>
          <Label>Team</Label>
          <a className="btn btn-ghost btn-xs" href="/settings#team" onClick={(e) => { e.preventDefault(); nav('/settings#team'); }}><Icon name="shield" size={14} />Roles and permissions</a>
        </div>
        <PeopleCard onCall={inv.me.role === 'owner' || inv.me.role === 'manager' || inv.me.role === 'admin' ? (m) => setCalling(m as unknown as Member) : undefined} />
      </div>

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><Label>Activity · who did what</Label><span className="faint" style={{ fontSize: 12 }}>Author, branch and capture channel for every movement</span></div>
        <div className="tbl">
          {activity.isLoading && <SkeletonRows n={5} />}
          {(activity.data || []).map((a) => (
            <div key={a.gid} className="tr rsp" style={{ gridTemplateColumns: '150px 110px minmax(200px,1.5fr) minmax(140px,.8fr) 140px 120px minmax(150px,1fr)', minWidth: 1000 }}>
              <span className="muted">{when(a.recorded_at)}</span>
              <span><span className={'chip ' + typeTone(a.type)}>{typeLabel(a.type)}</span></span>
              <span className="m-main m-first">{moveItem(a)}</span>
              <span className="ink3">{moveQty(a)}</span>
              <span style={{ fontWeight: 500 }}>{a.author_name || 'System'}{a.approver_name ? <span className="faint" style={{ display: 'block', fontSize: 11, fontWeight: 400 }}>approved by {a.approver_name.split(' ')[0]}</span> : null}</span>
              <span className="muted">{locName(a.location_id)}</span>
              <span className="muted hide-sm" style={{ fontSize: 12 }}>{[a.channel, a.offline ? 'queued offline' : null, a.device_id ? 'phone' : null].filter(Boolean).join(' · ')}</span>
            </div>
          ))}
        </div>
      </div>
      {transfer && <TransferModal onClose={() => setTransfer(false)} />}
      {branch && <BranchModal branch={branch === 'new' ? null : branch} onClose={() => setBranch(null)} />}
      {calling && <ReminderCallModal member={calling} onClose={() => setCalling(null)} />}
    </div>
  );
}

function BranchModal({ branch, onClose }: { branch: Location | null; onClose: () => void }) {
  const { orgId } = useSession();
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [name, setName] = useState(branch?.name || '');
  const [address, setAddress] = useState(branch?.address || '');
  const [city, setCity] = useState(branch?.city || '');
  const [postcode, setPostcode] = useState(branch?.postcode || '');
  const [place, setPlace] = useState({ state: branch?.state || '', lga: branch?.lga || '' });
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    if (!name.trim()) { setErr('Enter the branch name.'); return; }
    const pc = postcode.replace(/\s/g, '');
    if (pc && !/^\d{6}$/.test(pc)) { setErr('A Nigerian postcode has 6 digits.'); return; }
    const base = name.trim().replace(/[^A-Za-z]/g, '').slice(0, 3).toUpperCase() || 'BR';
    let code = base; let i = 2;
    while (!branch && inv?.locations.some((l) => l.code === code)) code = base + i++;
    const r = await run(() => branch
      ? must(supabase.from('locations').update({ name: name.trim(), address: address.trim() || null, city: city.trim() || null, postcode: pc || null, state: place.state || null, lga: place.lga || null })
        .eq('id', branch.id).select().single())
      : must(supabase.from('locations').insert({ org_id: orgId, name: name.trim(), code, address: address.trim() || null, city: city.trim() || null, postcode: pc || null, is_main: false,
        state: place.state || null, lga: place.lga || null }).select().single()),
    { ok: branch ? 'Branch updated' : `${name.trim()} added`, invalidate: ['inv'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={440}>
      <ModalHead title={branch ? 'Edit branch' : 'Add branch'} onClose={onClose} />
      <div className="modal-body">
        <Field label="Branch name" req><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Ikeja" /></Field>
        <Field label="Address"><input className="input" value={address} onChange={(e) => setAddress(e.target.value)} placeholder="Street, area" /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="City or town"><input className="input" value={city} onChange={(e) => setCity(e.target.value)} placeholder="e.g. Lagos" /></Field>
          <Field label="Postcode" hint={branch?.is_main ? 'NRS needs it on every e-invoice, with the address.' : undefined}>
            <input className="input" value={postcode} onChange={(e) => setPostcode(e.target.value)} inputMode="numeric" maxLength={7} placeholder="6 digits" /></Field>
        </div>
        <StateLga state={place.state} lga={place.lga} onChange={(state, lga) => setPlace({ state, lga })} />
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        {!branch && <div className="hint">Stock at the new branch starts at zero. Move stock in with a transfer or receive straight into it.</div>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" onClick={save} disabled={busy}>Save branch</button></div>
    </Modal>
  );
}

