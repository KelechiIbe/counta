import { useState } from 'react';
import { Modal, ModalHead, Field, Alert } from './ui';
import { Icon } from './Icon';
import { rpc } from '../lib/supabase';
import { useInventory, useSession } from '../state/session';
import { useAction } from '../lib/queries';
import { qtyLabel } from '../lib/domain';

export default function TransferModal({ itemId, onClose }: { itemId?: string; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const { run, busy } = useAction();
  const locs = inv?.locations || [];
  const [item, setItem] = useState(itemId || inv?.items[0]?.id || '');
  const [from, setFrom] = useState(locs[0]?.id || '');
  const [to, setTo] = useState(locs[1]?.id || locs[0]?.id || '');
  const [qty, setQty] = useState('');
  const [err, setErr] = useState('');
  const it = inv?.items.find((i) => i.id === item);
  const avail = it ? Number(it.qty?.[from] || 0) : 0;
  const fromName = locs.find((l) => l.id === from)?.name;

  async function post() {
    const q = parseFloat(qty);
    if (from === to) { setErr('Choose two different locations.'); return; }
    if (!(q >= 1)) { setErr('Enter a quantity.'); return; }
    if (q > avail) { setErr(`Only ${avail.toLocaleString('en-NG')} ${it?.selling_unit} available at ${fromName}.`); return; }
    const toName = locs.find((l) => l.id === to)?.name;
    const r = await run(() => rpc<any>('create_transfer', { p_org: orgId, p_item: item, p_from: from, p_to: to, p_qty: q }), {
      ok: `Transfer posted · goods in transit until ${toName} confirms`, invalidate: ['inv', 'ledger', 'activity', 'transfers'],
    });
    if (r) onClose();
  }
  if (locs.length < 2) {
    return (
      <Modal onClose={onClose}>
        <ModalHead title="Transfer stock" onClose={onClose} />
        <div className="modal-body"><Alert kind="blue" icon="info">Transfers move stock between branches. Add a second branch on the Locations &amp; staff page first.</Alert></div>
      </Modal>
    );
  }
  return (
    <Modal onClose={onClose} z={60}>
      <ModalHead title="Transfer stock" onClose={onClose} />
      <div className="modal-body">
        <Field label="Item">
          <select className="input" value={item} onChange={(e) => { setItem(e.target.value); setErr(''); }}>
            {inv?.items.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
          </select>
        </Field>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="From"><select className="input" value={from} onChange={(e) => { setFrom(e.target.value); setErr(''); }}>{locs.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
          <Field label="To"><select className="input" value={to} onChange={(e) => { setTo(e.target.value); setErr(''); }}>{locs.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        </div>
        <Field label="Quantity (selling units)" hint={it ? `${qtyLabel(it, avail)} available at ${fromName}` : undefined}>
          <input className="input" type="number" inputMode="numeric" value={qty} onChange={(e) => { setQty(e.target.value); setErr(''); }} placeholder="0" />
        </Field>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <div className="hint">Posts Cr 1310 at origin / Dr 1315 Goods in transit. The receiving branch confirms on their phone, which moves it into their stock.</div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" onClick={post} disabled={busy}><Icon name="arrowLR" size={16} color="#fff" />Post transfer</button>
      </div>
    </Modal>
  );
}
