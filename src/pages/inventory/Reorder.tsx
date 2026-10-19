import { useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { useSuggestions } from '../../shell/needsAction';
import { useAction, useFx, usePOs, useVendorStats } from '../../lib/queries';
import { must, rpc, supabase } from '../../lib/supabase';
import { N, fmtDay, num, plural } from '../../lib/format';
import {
  buildItems, channelSentence, fxBanner, fxItemNote, fxTrend, pluralUnit, poMessage, puAbbr, qtyLabel, scoreVendors, waLink,
  type ItemView, type Suggestion, type VendorScore,
} from '../../lib/domain';
import type { PurchaseOrder, Vendor } from '../../lib/types';
import { Icon } from '../../components/Icon';
import { Alert, Annot, Chip, Empty, Field, Label, Modal, ModalHead, SkeletonRows } from '../../components/ui';
import { RecentCalls, VendorCallModal } from '../../components/Calls';
import { vatPct } from '../../lib/vat';

const scoreColor = (s: number) => (s >= 85 ? '#15803D' : s >= 70 ? '#0072F5' : '#A16207');
const PO_STATUS: Record<string, string> = { draft: 'Draft', sent: 'Sent', received: 'Received', cancelled: 'Cancelled' };

export default function Reorder() {
  const { data: inv } = useInventory();
  const location = useLocation();
  const nav = useNavigate();
  const { suggestions, ready } = useSuggestions();
  const approver = can(inv, 'approve_pos');
  const seeAll = approver || can(inv, 'see_margins');
  const pos = usePOs(seeAll);
  const stats = useVendorStats(seeAll);
  const fx = useFx();
  const { run } = useAction();
  const { orgId } = useSession();
  const [draft, setDraft] = useState<{ itemId: string } | null>(null);
  const [poOpen, setPoOpen] = useState<string | null>(null);
  const [vendorEdit, setVendorEdit] = useState<Vendor | 'new' | null>(null);
  const st = (location.state || {}) as { draft?: string };
  useEffect(() => {
    if (st.draft) { if (approver) setDraft({ itemId: st.draft }); nav(location.pathname, { replace: true, state: null }); }
  }, [st.draft]); // eslint-disable-line react-hooks/exhaustive-deps

  const scores = useMemo(() => (inv ? scoreVendors(inv.vendors, stats.data, inv.items) : {}), [inv, stats.data]);
  const trend = useMemo(() => fxTrend(fx.data || []), [fx.data]);
  if (!inv) return null;
  const costs = inv.can_see_costs;
  const imports = inv.items.filter((i) => i.import_priced).map((i) => i.name.split(' ').slice(0, 2).join(' '));
  const banner = fxBanner(trend, imports);
  const vendorName = (id: string | null) => inv.vendors.find((v) => v.id === id)?.name || '—';
  const itemName = (id: string) => inv.items.find((i) => i.id === id)?.name || 'Item';
  const openPOs = (pos.data || []).filter((p) => p.status !== 'cancelled');
  const ranked = Object.values(scores).sort((a, b) => b.total - a.total);
  const poSel = poOpen ? openPOs.find((p) => p.id === poOpen) || null : null;

  return (
    <div className="container">
      {banner && (
        <div className="row" style={{ gap: 12, alignItems: 'flex-start', background: '#FEFCE8', border: '1px solid #FDE68A', borderRadius: 14, padding: '14px 18px' }}>
          <Icon name="dollar" size={18} color="#A16207" style={{ marginTop: 1 }} />
          <div className="grow"><div style={{ fontSize: 13, fontWeight: 600 }}>FX timing</div><div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>{banner}</div></div>
        </div>
      )}
      <div className="row m-wrap" style={{ justifyContent: 'space-between' }}>
        <Label>Suggested orders</Label>
        <span className="faint" style={{ fontSize: 12 }}>Reorder point = sales per day × (lead time + {inv.org.safety_days} safety days) × season</span>
      </div>
      <div className="stack" style={{ gap: 12 }}>
        {!ready && <div className="card"><SkeletonRows n={3} /></div>}
        {ready && suggestions.map((s) => (
          <SuggestionCard key={s.item.id} s={s} score={s.vendor ? scores[s.vendor.id] : undefined} alt={s.alt ? scores[s.alt.id] : undefined} costs={costs} approver={approver}
            onDraft={() => setDraft({ itemId: s.item.id })}
            onSnooze={() => run(() => rpc('snooze_reorder', { p_org: orgId, p_item: s.item.id, p_days: 7 }), { ok: `${s.item.name.split(' ').slice(0, 2).join(' ')} snoozed for a week`, invalidate: ['inv'] })} />
        ))}
        {ready && !suggestions.length && <Empty>Nothing to reorder right now. Suggestions reappear as stock approaches each floor.</Empty>}
      </div>

      {seeAll && (
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><Label>Purchase orders</Label><span className="faint" style={{ fontSize: 12 }}>The delivery invoice closes each order through Receive stock</span></div>
          <div className="tbl">
            <div className="tr head th rsp" style={{ gridTemplateColumns: '100px minmax(220px,1.6fr) minmax(170px,1fr) 110px 120px 110px', minWidth: 860 }}>
              <span>Ref</span><span>Items</span><span>Vendor</span><span>Date</span><span className="right">Total</span><span>Status</span>
            </div>
            {pos.isLoading && <SkeletonRows n={2} />}
            {openPOs.map((p) => (
              <div key={p.id} className="tr click rsp" onClick={() => setPoOpen(p.id)} style={{ gridTemplateColumns: '100px minmax(220px,1.6fr) minmax(170px,1fr) 110px 120px 110px', minWidth: 860 }}>
                <span style={{ fontWeight: 600, color: '#0072F5' }}>{p.ref}</span>
                <span className="ellipsis m-main m-first" style={{ fontWeight: 500 }}>{p.po_lines.map((l) => `${num(l.qty)} ${puAbbr(inv.items.find((i) => i.id === l.item_id)?.purchase_unit || '')} ${itemName(l.item_id)}`).join(', ')}</span>
                <span className="ink3 ellipsis">{vendorName(p.vendor_id)}{p.sent_via ? ` · ${p.sent_via === 'whatsapp' ? 'WhatsApp' : p.sent_via}` : ''}</span>
                <span className="muted">{fmtDay(p.sent_at || p.created_at)}</span>
                <span className={'right num' + (costs ? '' : ' hide-sm')} style={{ fontWeight: 600 }}>{costs ? N(p.total) : '—'}</span>
                <span className="m-end"><Chip label={PO_STATUS[p.status]} /></span>
              </div>
            ))}
            {pos.data && !openPOs.length && <div className="muted" style={{ padding: 20, fontSize: 14 }}>No purchase orders yet. Approved drafts show up here.</div>}
          </div>
        </div>
      )}

      {approver && <RecentCalls />}

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd">
          <Label>Vendor scores · from invoice history</Label>
          {(approver || can(inv, 'receive_stock')) && <button className="btn btn-secondary btn-sm" onClick={() => setVendorEdit('new')}><Icon name="plus" size={14} />Add vendor</button>}
        </div>
        <div className="tbl">
          <div className="tr head th rsp" style={{ gridTemplateColumns: 'minmax(200px,1.3fr) 140px 90px 80px 100px 100px minmax(260px,2fr)', minWidth: 1020 }}>
            <span>Vendor</span><span>Score</span><span>Lead time</span><span>Fill rate</span><span>Price stability</span><span>Credit</span><span>Why</span>
          </div>
          {ranked.map((v) => (
            <div key={v.vendor.id} onClick={() => (approver || can(inv, 'receive_stock')) && setVendorEdit(v.vendor)} className="tr click rsp" style={{ gridTemplateColumns: 'minmax(200px,1.3fr) 140px 90px 80px 100px 100px minmax(260px,2fr)', minWidth: 1020 }}>
              <div className="m-main"><div style={{ fontWeight: 600 }}>{v.vendor.name}</div><div className="faint" style={{ fontSize: 11 }}>{[v.vendor.location, channelSentence(v.vendor), v.vendor.vat_registered ? 'VAT-registered' : null].filter(Boolean).join(' · ')}</div></div>
              <div className="row m-main"><div className="bar grow"><div style={{ width: v.total + '%', background: scoreColor(v.total) }} /></div><span style={{ fontWeight: 600, color: scoreColor(v.total), width: 24 }}>{v.total}</span></div>
              <span className="ink3" data-label="Lead">{v.leadDays === 0 ? 'Same day' : plural(v.leadDays, 'day')}</span>
              <span className="ink3" data-label="Fill">{Math.round(v.fillPct)}%</span>
              <span className="ink3" data-label="Prices">{v.stabilityLabel}</span>
              <span className="ink3" data-label="Credit">{v.vendor.credit_days ? `${v.vendor.credit_days} days` : 'None'}</span>
              <span className="ink3 m-main" style={{ fontSize: 12, lineHeight: 1.45 }}>{v.why}</span>
            </div>
          ))}
          {!ranked.length && <div className="muted" style={{ padding: 20, fontSize: 14 }}>No vendors yet. They are added as you receive invoices, or add one here.</div>}
        </div>
      </div>
      {draft && <DraftPo itemId={draft.itemId} sug={suggestions.find((s) => s.item.id === draft.itemId)} scores={scores} onClose={() => setDraft(null)} />}
      {poSel && <PoModal po={poSel} onClose={() => setPoOpen(null)} />}
      {vendorEdit && <VendorModal vendor={vendorEdit === 'new' ? null : vendorEdit} onClose={() => setVendorEdit(null)} />}
    </div>
  );
}

function SuggestionCard({ s, score, alt, costs, approver, onDraft, onSnooze }: {
  s: Suggestion; score?: VendorScore; alt?: VendorScore; costs: boolean; approver: boolean; onDraft: () => void; onSnooze: () => void;
}) {
  const it = s.item;
  const cover = s.onHand <= s.floor ? 'Below floor' : `${Math.max(0, Math.round(s.cover))} day${Math.round(s.cover) === 1 ? '' : 's'} cover`;
  return (
    <div className="card m-stack sug-card" style={{ padding: '18px 20px', display: 'grid', gridTemplateColumns: 'minmax(220px,1.3fr) minmax(240px,1.6fr) minmax(200px,1fr) auto', gap: 20, alignItems: 'center' }}>
      <div style={{ minWidth: 0 }}>
        <div className="row"><span className={'chip t-' + s.tone}>{cover}</span>{s.seasonLabel && <span className="chip t-blue">{s.seasonLabel}</span>}</div>
        <div style={{ fontSize: 15, fontWeight: 600, marginTop: 8 }}>{it.name}</div>
        <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>On hand {qtyLabel(it, s.onHand)} · floor {num(s.floor)} {pluralUnit(it.selling_unit, s.floor)}</div>
      </div>
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, minWidth: 0 }}>
        <div>{s.reason}</div>
        {s.fx && <div className="row" style={{ marginTop: 6, color: '#A16207', alignItems: 'flex-start', gap: 6 }}><Icon name="dollar" size={14} color="#A16207" style={{ marginTop: 3 }} /><span>{s.fx}</span></div>}
      </div>
      <div style={{ minWidth: 0 }}>
        <div className="muted" style={{ fontSize: 12 }}>Order <b style={{ color: '#111827' }}>{s.qtyPU} {pluralUnit(it.purchase_unit.toLowerCase(), s.qtyPU)}</b> ({num(s.qtySU)} {pluralUnit(it.selling_unit, s.qtySU)})</div>
        <div style={{ fontSize: 18, fontWeight: 600, marginTop: 2 }}>{costs ? N(s.cost) : '—'}</div>
        {s.vendor ? (
          <>
            <div className="row ink3" style={{ fontSize: 12, marginTop: 4, gap: 6 }}><span style={{ width: 8, height: 8, borderRadius: 4, background: scoreColor(score?.total || 0) }} />{s.vendor.name}{score ? ` · score ${score.total}` : ''}</div>
            {s.alt && <div className="faint" style={{ fontSize: 11, marginTop: 2 }}>vs {s.alt.name}{alt ? ` · ${alt.total}` : ''}</div>}
          </>
        ) : <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>No preferred vendor yet</div>}
      </div>
      <div className="stack m-row" style={{ gap: 8 }}>
        {approver ? (
          <>
            <button className="btn btn-primary btn-sm" onClick={onDraft}>Draft PO</button>
            <button className="btn btn-secondary btn-sm" onClick={onSnooze}>Not now</button>
          </>
        ) : <Annot>Awaits owner approval</Annot>}
      </div>
    </div>
  );
}

function DraftPo({ itemId, sug, scores, onClose }: { itemId: string; sug?: Suggestion; scores: Record<string, VendorScore>; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const stats = useVendorStats(true);
  const fx = useFx();
  const item: ItemView | undefined = useMemo(() => (inv ? buildItems(inv, 'ALL').find((i) => i.id === itemId) : undefined), [inv, itemId]);
  const best = sug?.vendor || inv?.vendors.find((v) => v.id === item?.preferred_vendor_id) || null;
  const alt = sug?.alt || inv?.vendors.find((v) => v.id === item?.alt_vendor_id) || null;
  const choices = [best, alt].filter(Boolean) as Vendor[];
  const [vendorId, setVendorId] = useState<string>(best?.id || inv?.vendors[0]?.id || '');
  const [qty, setQty] = useState<string>(String(sug?.qtyPU || 1));
  const vendor = inv?.vendors.find((v) => v.id === vendorId) || null;
  const vendorCost = (vid: string) => {
    const x = stats.data?.[vid]?.items.find((s) => s.item_id === itemId);
    return x && item ? Number(x.avg_cost) * item.pack_size : null;
  };
  const defaultCost = vendorCost(vendorId) ?? sug?.unitCostPU ?? (item ? Number(item.last_cost ?? item.wac ?? 0) * item.pack_size : 0);
  const [cost, setCost] = useState<string>('');
  useEffect(() => { setCost(defaultCost ? String(Math.round(defaultCost * 100) / 100) : ''); }, [vendorId, stats.data]); // eslint-disable-line react-hooks/exhaustive-deps
  const [sent, setSent] = useState<null | { id: string; ref: string; channel: string; phone: string | null; email: string | null; total: number; status: string }>(null);
  if (!inv || !item) return null;
  const costs = inv.can_see_costs;
  const q = Number(qty);
  const qtyErr = !(q >= 1 && Number.isFinite(q)) ? 'Quantity must be at least 1.' : null;
  const unitCost = Number(cost) || 0;
  const total = q > 0 ? q * unitCost : 0;
  const cash = inv.org.cash_available != null ? Number(inv.org.cash_available) : null;
  const fxNote = item.import_priced ? fxItemNote(fxTrend(fx.data || [])) : null;
  const sc = vendor ? scores[vendor.id] : undefined;
  const msg = poMessage({
    org: inv.org.name, ref: sent?.ref || 'PO', vendor: vendor?.name || 'there', branch: inv.locations.find((l) => l.is_main)?.name,
    lines: [{ name: item.name, qty: q || 0, unit: item.purchase_unit, unitCost: costs ? unitCost : null }], total: costs ? total : null,
  });

  async function save(send: boolean) {
    if (qtyErr || !vendor) return;
    const r = await run(() => rpc<any>('save_po', {
      p_org: orgId, p_vendor: vendor.id, p_lines: [{ item_id: item!.id, qty: q, unit_cost: unitCost }], p_send: send, p_sent_via: vendor.channel, p_fx_note: fxNote,
    }), { ok: (r) => send ? `${r.ref} approved · send it to ${vendor.name}` : `${r.ref} saved as a draft`, invalidate: ['pos', 'inv'] });
    if (r) { if (send) setSent({ id: r.id, ref: r.ref, channel: r.channel, phone: r.phone, email: r.email, total: Number(r.total), status: r.status }); else onClose(); }
  }

  if (sent) return <SendPanel title={`${sent.ref} approved`} vendor={vendor!} message={msg.replace('Purchase order PO ', `Purchase order ${sent.ref} `)} onClose={onClose}
    po={{ id: sent.id, ref: sent.ref, lines: [`${num(q)} ${puAbbr(item.purchase_unit)} ${item.name}${costs && unitCost ? ` at ${N(unitCost)} each` : ''}`] }} />;

  return (
    <Modal onClose={onClose} width={580}>
      <ModalHead title="Draft purchase order" sub={`${item.name} · nothing is sent until you approve`} onClose={onClose} />
      <div className="modal-body" style={{ gap: 16 }}>
        <div>
          <label className="field-label">Vendor</label>
          {choices.length ? (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 10 }}>
              {choices.map((v) => (
                <button key={v.id} onClick={() => setVendorId(v.id)} style={{ border: '1.5px solid ' + (v.id === vendorId ? '#0072F5' : '#E6E6E6'), borderRadius: 12, padding: 12, cursor: 'pointer', background: '#fff', textAlign: 'left', font: 'inherit' }}>
                  <div className="row" style={{ justifyContent: 'space-between' }}><span style={{ fontSize: 13, fontWeight: 600 }}>{v.name}</span>{scores[v.id] && <span style={{ fontSize: 12, fontWeight: 700, color: scoreColor(scores[v.id].total) }}>{scores[v.id].total}</span>}</div>
                  {costs && vendorCost(v.id) != null && <div className="faint" style={{ fontSize: 11, marginTop: 4 }}>Usually {N(vendorCost(v.id))} per {item.purchase_unit.toLowerCase()}</div>}
                </button>
              ))}
            </div>
          ) : null}
          <select className="input" style={{ marginTop: choices.length ? 8 : 0 }} value={vendorId} onChange={(e) => setVendorId(e.target.value)} aria-label="Another vendor">
            {!choices.length && <option value="">Choose a vendor…</option>}
            {inv.vendors.map((v) => <option key={v.id} value={v.id}>{choices.some((c) => c.id === v.id) ? '' : 'Other: '}{v.name}</option>)}
          </select>
          {sc && <div className="ink3" style={{ fontSize: 12, marginTop: 8, lineHeight: 1.45 }}>{sc.why}</div>}
        </div>
        <div className="m-2" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
          <Field label={`Quantity (${pluralUnit(item.purchase_unit.toLowerCase(), 2)})`} error={qtyErr}>
            <input className={'input' + (qtyErr ? ' err' : '')} type="number" min={1} step={1} value={qty} onChange={(e) => setQty(e.target.value)} />
          </Field>
          <Field label={`Unit cost / ${puAbbr(item.purchase_unit)}`}>
            {costs ? <input className="input" type="number" min={0} value={cost} onChange={(e) => setCost(e.target.value)} placeholder="₦" /> : <div className="muted" style={{ padding: '10px 0' }}>Hidden for your role</div>}
          </Field>
          <Field label="Total"><div style={{ padding: '10px 0', fontSize: 16, fontWeight: 600 }}>{costs ? N(total) : '—'}</div></Field>
        </div>
        <div className="muted" style={{ fontSize: 12, marginTop: -8 }}>{q >= 1 ? `${num(q * item.pack_size)} ${pluralUnit(item.selling_unit, q * item.pack_size)} · on hand ${qtyLabel(item, item.qAll)}` : ''}</div>
        <div className="m-2" style={{ background: '#FAFAFA', borderRadius: 12, padding: '12px 14px', display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, fontSize: 13 }}>
          <div><div className="muted" style={{ fontSize: 11 }}>Sends via</div><div style={{ fontWeight: 600, marginTop: 2 }}>{channelSentence(vendor)}</div></div>
          <div><div className="muted" style={{ fontSize: 11 }}>Lead time</div><div style={{ fontWeight: 600, marginTop: 2 }}>{vendor ? (vendor.lead_time_days === 0 ? 'Same day' : plural(vendor.lead_time_days, 'day')) : '—'}</div></div>
          <div><div className="muted" style={{ fontSize: 11 }}>Credit terms</div><div style={{ fontWeight: 600, marginTop: 2 }}>{vendor ? (vendor.credit_days ? `${vendor.credit_days} days` : 'Cash') : '—'}</div></div>
        </div>
        {fxNote && <Alert kind="yellow" icon="dollar">{fxNote}</Alert>}
        <div className="hint">
          {cash == null ? 'Set the cash you keep for stock in Settings and suggestions will be capped by it.'
            : !costs ? 'Cash check is visible to the owner.'
            : total <= cash ? `Cash check: ${N(cash)} is set aside for stock. This order fits and leaves ${N(cash - total)}.`
            : `Cash check: this order is ${N(total - cash)} more than the ${N(cash)} set aside for stock.`}
        </div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={() => save(false)} disabled={busy || !!qtyErr || !vendor}>Keep as draft</button>
        <button className="btn btn-primary" onClick={() => save(true)} disabled={busy || !!qtyErr || !vendor}><Icon name="send" size={16} color="#fff" />Approve &amp; send</button>
      </div>
    </Modal>
  );
}

function SendPanel({ title, vendor, message, onClose, po }: { title: string; vendor: Vendor; message: string; onClose: () => void; po?: { id: string; ref: string; lines: string[] } }) {
  const toast = useToast();
  const [call, setCall] = useState(false);
  if (call && po) return <VendorCallModal po={po} vendor={vendor} lines={po.lines} onClose={onClose} />;
  const mail = `mailto:${vendor.email || ''}?subject=${encodeURIComponent(title.replace(' approved', '') + ' purchase order')}&body=${encodeURIComponent(message)}`;
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={title} sub={`Send it to ${vendor.name} on their ${channelSentence(vendor)} channel`} onClose={onClose} />
      <div className="modal-body">
        <pre style={{ whiteSpace: 'pre-wrap', fontFamily: 'inherit', fontSize: 13, background: '#FAFAFA', borderRadius: 12, padding: 14, margin: 0, lineHeight: 1.5 }}>{message}</pre>
        {vendor.channel === 'whatsapp' && !vendor.phone && <div className="hint">No WhatsApp number saved for {vendor.name}. WhatsApp will ask you to pick the contact.</div>}
      </div>
      <div className="modal-ft m-wrap">
        {po && vendor.phone && <button className="btn btn-secondary" onClick={() => setCall(true)}><Icon name="call" size={16} />Have Martina call</button>}
        <button className="btn btn-secondary" onClick={() => { navigator.clipboard?.writeText(message).then(() => toast('Message copied')).catch(() => toast('Copy failed', 'err')); }}><Icon name="copy" size={16} />Copy</button>
        {vendor.channel === 'email' ? <a className="btn btn-primary" href={mail} onClick={() => setTimeout(onClose, 300)}><Icon name="mail" size={16} color="#fff" />Open email</a>
          : <a className="btn btn-primary" href={waLink(vendor.phone, message)} target="_blank" rel="noreferrer" onClick={() => setTimeout(onClose, 300)}><Icon name="wa" size={16} color="#fff" />Open WhatsApp</a>}
      </div>
    </Modal>
  );
}

function PoModal({ po, onClose }: { po: PurchaseOrder; onClose: () => void }) {
  const { data: inv } = useInventory();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [send, setSend] = useState(false);
  const [call, setCall] = useState(false);
  if (!inv) return null;
  const vendor = inv.vendors.find((v) => v.id === po.vendor_id) || null;
  const costs = inv.can_see_costs;
  const approver = can(inv, 'approve_pos');
  const lines = po.po_lines.map((l) => ({ l, it: inv.items.find((i) => i.id === l.item_id) }));
  const message = poMessage({ org: inv.org.name, ref: po.ref, vendor: vendor?.name || 'there', branch: inv.locations.find((x) => x.id === po.location_id)?.name,
    lines: lines.map(({ l, it }) => ({ name: it?.name || 'Item', qty: Number(l.qty), unit: it?.purchase_unit || 'unit', unitCost: costs ? Number(l.unit_cost) : null })), total: costs ? Number(po.total) : null });
  const callLines = lines.map(({ l, it }) => `${num(l.qty)} ${puAbbr(it?.purchase_unit || '')} ${it?.name || 'item'}${costs && Number(l.unit_cost) ? ` at ${N(l.unit_cost)} each` : ''}`);
  if (send && vendor) return <SendPanel title={po.ref} vendor={vendor} message={message} onClose={onClose} po={{ id: po.id, ref: po.ref, lines: callLines }} />;
  if (call && vendor) return <VendorCallModal po={{ id: po.id, ref: po.ref }} vendor={vendor} lines={callLines} onClose={onClose} />;
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title={`${po.ref} · ${vendor?.name || 'Vendor'}`} sub={`${PO_STATUS[po.status]}${po.sent_at ? ' ' + fmtDay(po.sent_at) : ''}${po.received_at ? ` · received ${fmtDay(po.received_at)}` : ''}`} onClose={onClose} extra={<Chip label={PO_STATUS[po.status]} />} />
      <div className="modal-body">
        <div className="card" style={{ borderRadius: 12, overflow: 'hidden' }}>
          <div className="tr head shade th" style={{ gridTemplateColumns: '1fr 110px 110px' }}><span>Item</span><span className="right">Qty</span><span className="right">Total</span></div>
          {lines.map(({ l, it }) => (
            <div key={l.id} className="tr" style={{ gridTemplateColumns: '1fr 110px 110px' }}>
              <span>{it?.name}</span><span className="right">{num(l.qty)} {puAbbr(it?.purchase_unit || '')}</span><span className="right num">{costs ? N(l.total) : '—'}</span>
            </div>
          ))}
        </div>
        {po.fx_note && <Alert kind="yellow" icon="dollar">{po.fx_note}</Alert>}
        {po.status === 'sent' && <div className="hint">When the goods arrive, receive them against this order. The lines come pre-filled and the order closes on post.</div>}
      </div>
      {approver && (po.status === 'draft' || po.status === 'sent') && (
        <div className="modal-ft m-wrap">
          <button className="btn btn-danger" disabled={busy} onClick={async () => {
            if (!confirmCancel) { setConfirmCancel(true); return; }
            const r = await run(() => rpc('cancel_po', { p_po: po.id }), { ok: `${po.ref} cancelled`, invalidate: ['pos', 'inv'] });
            if (r !== undefined) onClose();
          }}>{confirmCancel ? 'Tap again to cancel' : 'Cancel order'}</button>
          {po.status === 'draft' && <button className="btn btn-primary" disabled={busy} onClick={async () => {
            const r = await run(() => rpc('send_po', { p_po: po.id }), { ok: `${po.ref} approved`, invalidate: ['pos'] });
            if (r) setSend(true);
          }}><Icon name="send" size={16} color="#fff" />Approve &amp; send</button>}
          {vendor?.phone && <button className="btn btn-secondary" onClick={() => setCall(true)}><Icon name="call" size={16} />Call vendor</button>}
          {po.status === 'sent' && <button className="btn btn-secondary" onClick={() => setSend(true)}>Message again</button>}
          {po.status === 'sent' && can(inv, 'receive_stock') && <button className="btn btn-primary" onClick={() => nav('/inventory/receive', { state: { po: po.id } })}>Receive delivery</button>}
        </div>
      )}
    </Modal>
  );
}

function VendorModal({ vendor, onClose }: { vendor: Vendor | null; onClose: () => void }) {
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const [f, setF] = useState({
    name: vendor?.name || '', location: vendor?.location || '', channel: vendor?.channel || 'whatsapp', phone: vendor?.phone || '', email: vendor?.email || '',
    vat_registered: vendor?.vat_registered ?? false, lead_time_days: String(vendor?.lead_time_days ?? 2), credit_days: String(vendor?.credit_days ?? 0), notes: vendor?.notes || '',
  });
  const [err, setErr] = useState<string | null>(null);
  const set = (k: keyof typeof f, v: any) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    if (!f.name.trim()) { setErr('Enter the vendor name.'); return; }
    if (f.channel === 'email' && !/^\S+@\S+\.\S+$/.test(f.email.trim())) { setErr('Add an email address for vendors you order from by email.'); return; }
    const row = {
      name: f.name.trim(), location: f.location.trim() || null, channel: f.channel, phone: f.phone.trim() || null, email: f.email.trim() || null,
      vat_registered: f.vat_registered, lead_time_days: Math.max(0, parseInt(f.lead_time_days) || 0), credit_days: Math.max(0, parseInt(f.credit_days) || 0), notes: f.notes.trim() || null,
    };
    const r = await run(() => vendor ? must(supabase.from('vendors').update(row).eq('id', vendor.id).select().single()) : must(supabase.from('vendors').insert({ ...row, org_id: orgId }).select().single()),
      { ok: vendor ? 'Vendor updated' : `${row.name} added`, invalidate: ['inv', 'vstats'] });
    if (r) onClose();
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={vendor ? vendor.name : 'Add vendor'} onClose={onClose} />
      <div className="modal-body">
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 12 }}>
          <Field label="Name" req><input className="input" value={f.name} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Where"><input className="input" value={f.location} onChange={(e) => set('location', e.target.value)} placeholder="e.g. Trade Fair, Lagos" /></Field>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
          <Field label="Orders go by"><select className="input" value={f.channel} onChange={(e) => set('channel', e.target.value)}><option value="whatsapp">WhatsApp</option><option value="email">Email</option><option value="phone">Phone</option></select></Field>
          <Field label="Phone"><input className="input" value={f.phone} onChange={(e) => set('phone', e.target.value)} placeholder="0803…" inputMode="tel" /></Field>
          <Field label="Email"><input className="input" value={f.email} onChange={(e) => set('email', e.target.value)} type="email" /></Field>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Lead time (days)"><input className="input" type="number" min={0} value={f.lead_time_days} onChange={(e) => set('lead_time_days', e.target.value)} /></Field>
          <Field label="Credit (days)"><input className="input" type="number" min={0} value={f.credit_days} onChange={(e) => set('credit_days', e.target.value)} /></Field>
        </div>
        <label className="check"><input type="checkbox" checked={f.vat_registered} onChange={(e) => set('vat_registered', e.target.checked)} />VAT-registered (charges {vatPct()} VAT on invoices)</label>
        <Field label="Notes"><textarea className="input" value={f.notes} onChange={(e) => set('notes', e.target.value)} /></Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <div className="hint">Fill rate, price stability and lead time are measured from your own invoices and orders once there is history.</div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={save} disabled={busy}>Save vendor</button>
      </div>
    </Modal>
  );
}
