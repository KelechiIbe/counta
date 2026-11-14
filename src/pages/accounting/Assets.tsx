// Fixed assets (IAS 16): the register is the source of the PPE balances. Assets come from bills and bank payments posted to an
// asset account (confirmed here), or are added by hand with their opening depreciation; depreciation runs month by month,
// pro rata to the day; disposals post the gain or loss. Money in for an asset sold waits here to be matched to the asset.
import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
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
  const [params] = useSearchParams();
  const [tab, setTab] = useState<'active' | 'pending' | 'disposed'>(params.get('tab') === 'pending' ? 'pending' : 'active');
  const [matching, setMatching] = useState<any>(null);
  const [confirming, setConfirming] = useState<any>(null);
  const [adding, setAdding] = useState(false);
  const [disposing, setDisposing] = useState<any>(null);
  const [through, setThrough] = useState(lastMonthEnd());
  if (!inv) return null;
  if (a.error) return <div className="container"><Alert kind="yellow" icon="shield">{(a.error as Error).message}</Alert></div>;
  const d = a.data;
  const list = (d?.assets || []).filter((x: any) => (tab === 'pending' ? x.status === 'pending_confirmation' : tab === 'disposed' ? ['disposed', 'written_off'].includes(x.status) : x.status === 'active'));
  const sales = ((d?.sales || []) as any[]).filter((x) => x.status === 'pending');
  const pending = (d?.assets || []).filter((x: any) => x.status === 'pending_confirmation').length + sales.length;
  const keep = can(inv, 'keep_books');
  async function depreciate() {
    try { const r = await rpc<any>('run_depreciation', { p_org: orgId, p_through: through }); toast(r?.total ? `Depreciation of ${N2(r.total)} posted` : 'Nothing to depreciate'); await qc.invalidateQueries({ queryKey: ['assets'] }); }
    catch (e) { toast((e as Error).message, 'err'); }
  }
  const rec = (d?.reconciliation || []) as any[];
  // Money in for an asset sold sits in the asset account until it is matched, so it explains that much of a difference.
  const off = rec.filter((r) => Math.abs(Number(r.ledger_cost) + Number(r.unmatched_sales || 0) - Number(r.register_cost)) > 0.01
    || Math.abs(Number(r.ledger_accumulated) - Number(r.register_accumulated)) > 0.01);
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
        : rec.length > 0 && <Alert kind="green" icon="check">The register agrees with the PPE accounts in the ledger{sales.length ? ', once the money in for assets sold is matched' : ''}.</Alert>}
      {sales.length > 0 && tab !== 'pending' && (
        <Alert kind="blue" icon="info">{sales.length} payment{sales.length === 1 ? '' : 's'} received for assets sold {sales.length === 1 ? 'waits' : 'wait'} to be matched to the asset.{' '}
          <button className="link" onClick={() => setTab('pending')}>Match {sales.length === 1 ? 'it' : 'them'}</button></Alert>
      )}
      {tab === 'pending' && sales.length > 0 && (
        <div className="card" style={{ overflow: 'hidden' }} data-testid="asset-sales">
          <div className="card-pad" style={{ borderBottom: '1px solid var(--row)' }}>
            <b>Money in for assets sold</b>
            <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>Say which asset each payment was for. Counta charges depreciation to the day of the sale and posts the gain or loss.</div>
          </div>
          {sales.map((x) => (
            <div key={x.id} className="card-pad row wrap" style={{ gap: 10, justifyContent: 'space-between', borderBottom: '1px solid var(--row)' }}>
              <div style={{ minWidth: 0, flex: '1 1 320px' }}>
                <div className="ellipsis"><b className="num">{N2(x.amount)}</b> · {x.narration || 'Money in'}</div>
                <div className="faint" style={{ fontSize: 12 }}>{fmtDay(x.date)} · {x.account || 'Bank'} · posted to {x.class_name}</div>
              </div>
              {keep && <button className="btn btn-primary btn-sm" onClick={() => setMatching(x)}>Match</button>}
            </div>
          ))}
        </div>
      )}
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: '90px minmax(180px,1.6fr) 140px 110px 120px 120px 120px 110px', minWidth: 1000 }}>
            <span>Asset</span><span>Description</span><span>Class</span><span>In use from</span><span className="right">Cost</span><span className="right">Depreciated</span><span className="right">Carrying</span><span />
          </div>
          {a.isLoading ? <SkeletonRows n={4} /> : !list.length ? <div style={{ padding: 20 }}><Empty>{tab === 'pending' ? (sales.length ? 'No new assets to confirm.' : 'Nothing to confirm. Bills and bank payments posted to an asset account land here.') : 'No assets here.'}</Empty></div> : list.map((x: any) => (
            <div key={x.id} className="tr" style={{ gridTemplateColumns: '90px minmax(180px,1.6fr) 140px 110px 120px 120px 120px 110px', minWidth: 1000 }}>
              <b>{x.number || '—'}</b>
              <span className="ellipsis">{x.name}<span className="faint" style={{ display: 'block', fontSize: 11 }}>{source(x)}{x.serial_no ? ` · ${x.serial_no}` : ''}{x.life_months ? ` · ${Math.round(x.life_months / 12 * 10) / 10} years` : ''}</span></span>
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
      {confirming && <ConfirmAsset asset={confirming} classes={d?.classes || []} assets={d?.assets || []} onClose={() => setConfirming(null)} />}
      {matching && <MatchSale sale={matching} assets={d?.assets || []} onClose={() => setMatching(null)} />}
      {adding && <AddAsset classes={d?.classes || []} onClose={() => setAdding(false)} />}
      {disposing && <Dispose asset={disposing} onClose={() => setDisposing(null)} />}
    </div>
  );
}

// Where a register record came from, in a few words.
function source(x: any) {
  if (x.vendor_name) return `${x.vendor_name} · ${x.bill_number}`;
  if (x.bank_line) return `Paid from ${x.bank_line.account || 'the bank'} on ${fmtDay(x.bank_line.date)}`;
  if (String(x.notes || '').includes("From last year's accounts")) return "From last year's accounts";
  return 'Added by hand';
}

function ConfirmAsset({ asset, classes, assets, onClose }: { asset: any; classes: any[]; assets: any[]; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const { data: inv } = useInventory();
  const [f, setF] = useState({ name: asset.name, class_account: asset.class_account || asset.cost_account || '', life_months: String(asset.life_months || ''), available_date: asset.available_date || today(), serial_no: asset.serial_no || '', location_id: asset.location_id || '', residual: '' });
  const [mode, setMode] = useState<'asset' | 'merge' | 'expense'>('asset');
  const expense = mode === 'expense';
  const [code, setCode] = useState('');
  const [into, setInto] = useState('');
  const [trade, setTrade] = useState(false);
  const [old, setOld] = useState({ asset_id: '', value: '' });
  const others = assets.filter((x) => x.id !== asset.id && ['active', 'pending_confirmation'].includes(x.status));
  const inUse = assets.filter((x) => x.id !== asset.id && x.status === 'active');
  const chart = useChart();
  const expenses = (chart.data?.accounts || []).filter((x: any) => !x.is_group && x.active && /^6/.test(x.code));
  async function go() {
    try {
      if (expense) await rpc('reject_asset', { p_asset: asset.id, p_expense_account: code });
      else if (mode === 'merge') await rpc('merge_asset', { p_asset: asset.id, p_into: into });
      else await rpc('confirm_asset', { p_asset: asset.id, p: { ...f, life_months: Number(f.life_months) || null, residual: money(f.residual) || 0, location_id: f.location_id || null,
        trade_in: trade && old.asset_id ? { asset_id: old.asset_id, value: money(old.value) } : null } });
      toast(expense ? 'Treated as an expense' : mode === 'merge' ? 'Added to the other asset' : 'Asset confirmed');
      await Promise.all(['assets', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title="Confirm the asset" sub={`${N2(asset.cost)} ${asset.vendor_name ? `from ${asset.vendor_name}` : asset.bank_line ? `paid on ${fmtDay(asset.bank_line.date)} (${asset.bank_line.narration || 'bank payment'})` : 'from a bill'}. Depreciation starts from the day it is ready for use.`} onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap" style={{ gap: 6 }} role="radiogroup" aria-label="What this payment was">
          {([['asset', 'A new asset'], ['merge', 'Part of another asset'], ['expense', 'Not an asset']] as const).map(([k, l]) => (
            <label key={k} className={'pill' + (mode === k ? ' on' : '')} style={{ cursor: 'pointer' }}>
              <input type="radio" name="asset-mode" checked={mode === k} onChange={() => setMode(k)} style={{ marginRight: 6 }} />{l}</label>
          ))}
        </div>
        {mode === 'merge' && <>
          <div className="faint" style={{ fontSize: 12 }}>A second instalment, import duty, delivery or installation belongs in the cost of the asset it was for.</div>
          <Field label="Which asset"><select className="input" value={into} onChange={(e) => setInto(e.target.value)}><option value="">Choose</option>
            {others.map((x) => <option key={x.id} value={x.id}>{x.number} · {x.name} ({N2(x.cost)})</option>)}</select></Field>
        </>}
        {mode === 'asset' && <>
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
        {asset.status === 'pending_confirmation' && inUse.length > 0 && <>
          <label className="check"><input type="checkbox" checked={trade} onChange={(e) => setTrade(e.target.checked)} />An old asset was given in part exchange</label>
          {trade && <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Old asset"><select className="input" value={old.asset_id} onChange={(e) => setOld({ ...old, asset_id: e.target.value })}><option value="">Choose</option>
              {inUse.map((x) => <option key={x.id} value={x.id}>{x.number} · {x.name}</option>)}</select></Field>
            <Field label="Value the seller gave for it" hint="Added to the new asset's cost; the old one leaves the register."><input className="input" inputMode="decimal" value={old.value} onChange={(e) => setOld({ ...old, value: e.target.value })} /></Field>
          </div>}
        </>}
        </>}
        {expense && <>
          <div className="faint" style={{ fontSize: 12 }}>A small item, a repair or service, or something bought to sell: the cost goes to an expense account.</div>
          <Field label="Expense account"><select className="input" value={code} onChange={(e) => setCode(e.target.value)}><option value="">Choose</option>{expenses.map((x: any) => <option key={x.code} value={x.code}>{x.code} {x.name}</option>)}</select></Field>
        </>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={(expense && !code) || (mode === 'merge' && !into) || (mode === 'asset' && trade && (!old.asset_id || !(money(old.value)! > 0)))} onClick={go}>
          {expense ? 'Treat as expense' : mode === 'merge' ? 'Add to that asset' : 'Confirm asset'}</button></div>
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
        <Field label="Paid for"><select className="input" value={f.funding} onChange={(e) => setF({ ...f, funding: e.target.value })}><option value="opening">Already owned when we started (opening balance)</option><option value="bank">From a bank or cash account</option><option value="vendor">On credit from a vendor</option><option value="director">By a director, personally (the business owes them)</option></select></Field>
        {f.funding === 'opening' && <Field label="Depreciation already charged before we started"><input className="input" inputMode="decimal" value={f.accumulated} onChange={(e) => setF({ ...f, accumulated: e.target.value })} placeholder="0.00" /></Field>}
        {f.funding === 'vendor' && <Field label="Vendor"><select className="input" value={f.vendor_id} onChange={(e) => setF({ ...f, vendor_id: e.target.value })}><option value="">Choose</option>{(bills.data?.vendors || []).map((v: any) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></Field>}
        {f.funding === 'bank' && <BankPicker cash value={f.bank_account_id} onChange={(v) => setF({ ...f, bank_account_id: v })} />}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={!f.name.trim() || !(money(f.cost)! > 0)} onClick={go}>Add asset</button></div>
    </Modal>
  );
}

function BankPicker({ value, onChange, cash }: { value: string; onChange: (v: string) => void; cash?: boolean }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const [list, setList] = useState<any[] | null>(null);
  if (list === null) moneyAccounts(orgId!).then((accounts) => setList((accounts || []).filter((a: any) => cash || a.kind !== 'cash'))).catch(() => setList([]));
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

// Money in on the bank for an asset sold: matched to the asset, or moved to the account it belongs in.
function MatchSale({ sale, assets, onClose }: { sale: any; assets: any[]; onClose: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const chart = useChart();
  const inUse = assets.filter((x) => x.status === 'active').sort((a, b) => Number(b.class_account === sale.class_account) - Number(a.class_account === sale.class_account));
  const [mode, setMode] = useState<'match' | 'elsewhere'>('match');
  const [f, setF] = useState({ asset_id: inUse.find((x) => x.class_account === sale.class_account)?.id || '', date: sale.date, account: '', note: '' });
  const [busy, setBusy] = useState(false);
  const accounts = (chart.data?.accounts || []).filter((x: any) => !x.is_group && x.active && !/^(15|101|1101|1102|2101|2102|2201|1402|2202|1401|9)/.test(x.code));
  const chosen = inUse.find((x) => x.id === f.asset_id);
  async function go() {
    setBusy(true);
    try {
      if (mode === 'match') {
        const r = await rpc<any>('match_asset_sale', { p_sale: sale.id, p: { asset_id: f.asset_id, date: f.date } });
        toast(Number(r?.gain) >= 0 ? `Matched: a gain of ${N2(r.gain)}` : `Matched: a loss of ${N2(-Number(r.gain))}`);
      } else {
        await rpc('asset_sale_elsewhere', { p_sale: sale.id, p_account: f.account, p_note: f.note || null });
        toast('Moved');
      }
      await Promise.all(['assets', 'inbox'].map((k) => qc.invalidateQueries({ queryKey: [k] }))); onClose();
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <Modal onClose={onClose} width={520}>
      <ModalHead title={`${N2(sale.amount)} received`} sub={`${fmtDay(sale.date)} · ${sale.narration || 'Money in'}`} onClose={onClose} />
      <div className="modal-body">
        <div className="row wrap" style={{ gap: 6 }} role="radiogroup" aria-label="What this money was">
          {([['match', 'An asset was sold'], ['elsewhere', 'It was something else']] as const).map(([k, l]) => (
            <label key={k} className={'pill' + (mode === k ? ' on' : '')} style={{ cursor: 'pointer' }}>
              <input type="radio" name="sale-mode" checked={mode === k} onChange={() => setMode(k)} style={{ marginRight: 6 }} />{l}</label>
          ))}
        </div>
        {mode === 'match' ? <>
          {!inUse.length && <Alert kind="amber" icon="alert">The register has no asset in use. Add the asset that was sold (Asset, with its opening depreciation), then match.</Alert>}
          <Field label="Asset sold"><select className="input" value={f.asset_id} onChange={(e) => setF({ ...f, asset_id: e.target.value })}><option value="">Choose</option>
            {inUse.map((x) => <option key={x.id} value={x.id}>{x.number} · {x.name} · carrying {N2(Number(x.cost) - Number(x.accumulated))}</option>)}</select></Field>
          <Field label="Sold on" hint="Depreciation runs to this day."><input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field>
          {chosen && <div className="muted" style={{ fontSize: 13 }}>Carrying amount {N2(Number(chosen.cost) - Number(chosen.accumulated))} before depreciation to the day of sale; the difference from {N2(sale.amount)} is the gain or loss.</div>}
        </> : <>
          <Field label="Account it belongs in"><select className="input" value={f.account} onChange={(e) => setF({ ...f, account: e.target.value })}><option value="">Choose</option>
            {accounts.map((x: any) => <option key={x.code} value={x.code}>{x.code} {x.name}</option>)}</select></Field>
          <Field label="Note (optional)"><input className="input" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder="A refund from a supplier" /></Field>
        </>}
      </div>
      <div className="modal-ft"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={busy || (mode === 'match' ? !f.asset_id : !f.account)} onClick={go}>{mode === 'match' ? 'Match the sale' : 'Move it'}</button></div>
    </Modal>
  );
}

export { fmtDay };
