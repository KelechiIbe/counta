// Fixed assets (IAS 16): the register is the source of the PPE balances. Assets come from bills (confirmed here) or are
// added by hand with their opening depreciation; depreciation runs month by month, pro rata to the day; disposals post
// the gain or loss.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { lastMonthEnd, money, today, useAssets, useBills, useChart, useCustomers, moneyAccounts } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Empty, Field, Modal, ModalHead, Pills, SkeletonRows } from '../../components/ui';
import { StatusChip } from '../sell/common';

export default function Assets() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const a = useAssets();
  const [tab, setTab] = useState<'active' | 'pending' | 'disposed'>('active');
  const [confirming, setConfirming] = useState<any>(null);
  const [adding, setAdding] = useState(false);
  const [disposing, setDisposing] = useState<any>(null);
  const [through, setThrough] = useState(lastMonthEnd());
  if (!inv) return null;
  if (a.error) return <div className="container"><Alert kind="yellow" icon="shield">{(a.error as Error).message}</Alert></div>;
  const d = a.data;
  const list = (d?.assets || []).filter((x: any) => (tab === 'pending' ? x.status === 'pending_confirmation' : tab === 'disposed' ? ['disposed', 'written_off'].includes(x.status) : x.status === 'active'));
  const pending = (d?.assets || []).filter((x: any) => x.status === 'pending_confirmation').length;
  const keep = can(inv, 'keep_books');
  async function depreciate() {
    try { const r = await rpc<any>('run_depreciation', { p_org: orgId, p_through: through }); toast(r?.total ? `Depreciation of ${N2(r.total)} posted` : 'Nothing to depreciate'); await qc.invalidateQueries({ queryKey: ['assets'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  const rec = (d?.reconciliation || []) as any[];
  const off = rec.filter((r) => Math.abs(Number(r.ledger_cost) - Number(r.register_cost)) > 0.01 || Math.abs(Number(r.ledger_accumulated) - Number(r.register_accumulated)) > 0.01);
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'active', label: 'In use' }, { id: 'pending', label: 'To confirm', count: pending || undefined }, { id: 'disposed', label: 'Disposed' }]} />
        {keep && <div className="row wrap">
          <span className="muted" style={{ fontSize: 13 }}>Depreciate to</span><input className="input input-sm" type="date" value={through} onChange={(e) => setThrough(e.target.value)} style={{ width: 150 }} />
          <button className="btn btn-secondary btn-sm" onClick={depreciate}>Run depreciation</button>
          <button className="btn btn-primary btn-sm" onClick={() => setAdding(true)}><Icon name="plus" size={14} color="#fff" />Asset</button>
        </div>}
      </div>
      {off.length > 0 ? <Alert kind="red" icon="alert">The register and the ledger differ for {off.map((r) => r.name).join(', ')}. Every PPE posting should come through the register.</Alert>
        : rec.length > 0 && <Alert kind="green" icon="check">The register agrees with the PPE accounts in the ledger.</Alert>}
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '90px minmax(180px,1.6fr) 140px 110px 120px 120px 120px 110px', minWidth: 1000 }}>
            <span>Asset</span><span>Description</span><span>Class</span><span>In use from</span><span className="right">Cost</span><span className="right">Depreciated</span><span className="right">Carrying</span><span />
          </div>
          {a.isLoading ? <SkeletonRows n={4} /> : !list.length ? <div style={{ padding: 20 }}><Empty>{tab === 'pending' ? 'Nothing to confirm. Bills with lines coded to an asset account land here.' : 'No assets here.'}</Empty></div> : list.map((x: any) => (
            <div key={x.id} className="tr" style={{ gridTemplateColumns: '90px minmax(180px,1.6fr) 140px 110px 120px 120px 120px 110px', minWidth: 1000 }}>
              <b>{x.number || '—'}</b>
              <span className="ellipsis">{x.name}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{x.vendor_name ? `${x.vendor_name} · ${x.bill_number}` : 'Added by hand'}{x.serial_no ? ` · ${x.serial_no}` : ''}{x.life_months ? ` · ${Math.round(x.life_months / 12 * 10) / 10} years` : ''}</span></span>
              <span className="muted">{x.class_name}</span>
              <span className="muted">{x.available_date ? fmtDay(x.available_date) : '—'}</span>
              <span className="right num">{N2(x.cost)}</span>
              <span className="right num">{N2(x.accumulated)}</span>
              <span className="right num"><b>{N2(Number(x.cost) - Number(x.accumulated))}</b></span>
              <span>{x.status === 'pending_confirmation' && keep ? <button className="btn btn-primary btn-xs" onClick={() => setConfirming(x)}>Confirm</button>
                : x.status === 'active' && keep ? <button className="btn btn-ghost btn-xs" onClick={() => setDisposing(x)}>Dispose</button> : <StatusChip s={x.status === 'disposed' ? 'closed' : x.status} />}</span>
            </div>
          ))}
        </div>
      </div>
      {(d?.runs || []).length > 0 && <div className="faint" style={{ fontSize: 12 }}>Depreciation runs: {(d.runs as any[]).slice(0, 6).map((r) => `${fmtDay(r.period_end)} ${N2(r.total)} (${r.journal_ref})`).join(' · ')}</div>}
      {confirming && <ConfirmAsset asset={confirming} classes={d?.classes || []} onClose={() => setConfirming(null)} />}
      {adding && <AddAsset classes={d?.classes || []} onClose={() => setAdding(false)} />}
      {disposing && <Dispose asset={disposing} onClose={() => setDisposing(null)} />}
    </div>
  );
}

function ConfirmAsset({ asset, classes, onClose }: { asset: any; classes: any[]; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const { data: inv } = useInventory();
  const [f, setF] = useState({ name: asset.name, class_account: asset.class_account || asset.cost_account || '', life_months: String(asset.life_months || ''), available_date: asset.available_date || today(), serial_no: asset.serial_no || '', location_id: asset.location_id || '', residual: '' });
  const [expense, setExpense] = useState(false);
  const [code, setCode] = useState('');
  const chart = useChart();
  const expenses = (chart.data?.accounts || []).filter((x: any) => !x.is_group && x.active && /^6/.test(x.code));
  async function go() {
    try {
      if (expense) await rpc('reject_asset', { p_asset: asset.id, p_expense_account: code });
      else await rpc('confirm_asset', { p_asset: asset.id, p: { ...f, life_months: Number(f.life_months) || null, residual: money(f.residual) || 0, location_id: f.location_id || null } });
      toast(expense ? 'Treated as an expense' : 'Asset confirmed'); await Promise.all(['assets', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title="Confirm the asset" sub={`${N2(asset.cost)} from ${asset.vendor_name || 'a bill'}. Depreciation starts from the day it is ready for use.`} onClose={onClose} />
      <div className="modal-body">
        <Field label="Description"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Class"><select className="input" value={f.class_account} onChange={(e) => { const c = classes.find((x) => x.cost_account === e.target.value); setF({ ...f, class_account: e.target.value, life_months: String(c?.default_life_months || f.life_months) }); }}>
            {classes.map((c) => <option key={c.cost_account} value={c.cost_account}>{c.name}</option>)}</select></Field>
          <Field label="Useful life (months)"><input className="input" inputMode="numeric" value={f.life_months} onChange={(e) => setF({ ...f, life_months: e.target.value })} /></Field>
          <Field label="Ready for use on"><input className="input" type="date" value={f.available_date} onChange={(e) => setF({ ...f, available_date: e.target.value })} /></Field>
          <Field label="Serial number"><input className="input" value={f.serial_no} onChange={(e) => setF({ ...f, serial_no: e.target.value })} /></Field>
          <Field label="Branch"><select className="input" value={f.location_id} onChange={(e) => setF({ ...f, location_id: e.target.value })}><option value="">Head office</option>{inv?.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
          <Field label="Value at the end of its life"><input className="input" inputMode="decimal" value={f.residual} onChange={(e) => setF({ ...f, residual: e.target.value })} placeholder="0.00" /></Field>
        </div>
        <label className="check"><input type="checkbox" checked={expense} onChange={(e) => setExpense(e.target.checked)} />It is not an asset (a small item or a repair): treat it as an expense</label>
        {expense && <Field label="Expense account"><select className="input" value={code} onChange={(e) => setCode(e.target.value)}><option value="">Choose</option>{expenses.map((x: any) => <option key={x.code} value={x.code}>{x.code} {x.name}</option>)}</select></Field>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={expense && !code} onClick={go}>{expense ? 'Treat as expense' : 'Confirm asset'}</button></div>
    </Modal>
  );
}

function AddAsset({ classes, onClose }: { classes: any[]; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const bills = useBills({}, true);
  const [f, setF] = useState({ name: '', class_account: classes[0]?.cost_account || '', cost: '', date: today(), available_date: today(), life_months: String(classes[0]?.default_life_months || ''), accumulated: '', funding: 'opening', bank_account_id: '', vendor_id: '', serial_no: '' });
  async function go() {
    try {
      await rpc('add_asset', { p_org: orgId, p: { ...f, cost: money(f.cost), accumulated: money(f.accumulated) || 0, life_months: Number(f.life_months) || null, bank_account_id: f.bank_account_id || null, vendor_id: f.vendor_id || null } });
      toast('Asset added'); await qc.invalidateQueries({ queryKey: ['assets'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={560}>
      <ModalHead title="Add an asset" sub="For assets already owned when you started on Counta, or bought without a bill." onClose={onClose} />
      <div className="modal-body">
        <Field label="Description"><input className="input" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="Toyota Hiace delivery van" /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Class"><select className="input" value={f.class_account} onChange={(e) => { const c = classes.find((x) => x.cost_account === e.target.value); setF({ ...f, class_account: e.target.value, life_months: String(c?.default_life_months || '') }); }}>{classes.map((c) => <option key={c.cost_account} value={c.cost_account}>{c.name}</option>)}</select></Field>
          <Field label="Cost"><input className="input" inputMode="decimal" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} /></Field>
          <Field label="Bought on"><input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field>
          <Field label="In use from"><input className="input" type="date" value={f.available_date} onChange={(e) => setF({ ...f, available_date: e.target.value })} /></Field>
          <Field label="Useful life (months)"><input className="input" inputMode="numeric" value={f.life_months} onChange={(e) => setF({ ...f, life_months: e.target.value })} /></Field>
          <Field label="Serial number"><input className="input" value={f.serial_no} onChange={(e) => setF({ ...f, serial_no: e.target.value })} /></Field>
        </div>
        <Field label="Paid for"><select className="input" value={f.funding} onChange={(e) => setF({ ...f, funding: e.target.value })}><option value="opening">Already owned when we started (opening balance)</option><option value="bank">From the bank</option><option value="vendor">On credit from a vendor</option></select></Field>
        {f.funding === 'opening' && <Field label="Depreciation already charged before we started"><input className="input" inputMode="decimal" value={f.accumulated} onChange={(e) => setF({ ...f, accumulated: e.target.value })} placeholder="0.00" /></Field>}
        {f.funding === 'vendor' && <Field label="Vendor"><select className="input" value={f.vendor_id} onChange={(e) => setF({ ...f, vendor_id: e.target.value })}><option value="">Choose</option>{(bills.data?.vendors || []).map((v: any) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>}
        {f.funding === 'bank' && <BankPicker value={f.bank_account_id} onChange={(v) => setF({ ...f, bank_account_id: v })} />}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={!f.name.trim() || !(money(f.cost)! > 0)} onClick={go}>Add asset</button></div>
    </Modal>
  );
}

function BankPicker({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const [list, setList] = useState<any[] | null>(null);
  if (list === null) moneyAccounts(orgId!).then((accounts) => setList((accounts || []).filter((a: any) => a.kind !== 'cash'))).catch(() => setList([]));
  return <Field label="From"><select className="input" value={value} onChange={(e) => onChange(e.target.value)}><option value="">Choose the account</option>{(list || []).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>;
}

function Dispose({ asset, onClose }: { asset: any; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const customers = useCustomers();
  const [f, setF] = useState({ date: today(), proceeds: '', bank_account_id: '', customer_id: '' });
  async function go() {
    try {
      const r = await rpc<any>('dispose_asset', { p_asset: asset.id, p: { ...f, proceeds: money(f.proceeds) || 0, bank_account_id: f.bank_account_id || null, customer_id: f.customer_id || null } });
      toast(r?.gain != null ? (Number(r.gain) >= 0 ? `Sold at a gain of ${N2(r.gain)}` : `Loss on disposal ${N2(-r.gain)}`) : 'Asset disposed'); await qc.invalidateQueries({ queryKey: ['assets'] }); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={480}>
      <ModalHead title={`Dispose of ${asset.name}`} sub={`Carrying amount ${N2(Number(asset.cost) - Number(asset.accumulated))}. Depreciation runs to the day of disposal first.`} onClose={onClose} />
      <div className="modal-body">
        <Field label="Date"><input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field>
        <Field label="Sold for" hint="0 if it was scrapped or written off."><input className="input" inputMode="decimal" value={f.proceeds} onChange={(e) => setF({ ...f, proceeds: e.target.value })} /></Field>
        {money(f.proceeds)! > 0 && <>
          <BankPicker value={f.bank_account_id} onChange={(v) => setF({ ...f, bank_account_id: v })} />
          <Field label="Or the buyer owes it"><select className="input" value={f.customer_id} onChange={(e) => setF({ ...f, customer_id: e.target.value })}><option value="">Paid already</option>{(customers.data?.customers || []).filter((c) => !c.is_walk_in).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        </>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-danger" onClick={go}>Dispose</button></div>
    </Modal>
  );
}

export { fmtDay };
