// Vendors: what the business owes each, their Tax ID and withholding tax category, bank details for paying from the wallet,
// the account their bills usually go to, and a statement.
import { useEffect, useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { edge, today, useBills, useChart } from '../../lib/api';
import { N2, fmtDay } from '../../lib/format';
import { Icon } from '../../components/Icon';
import { Alert, Drawer, Empty, Field, Pills, SkeletonRows } from '../../components/ui';
import { TAX_ID_HINT, isOldTin, taxIdError } from '../../lib/taxid';
import { ExportMenu, acc, useMeta } from '../../components/Books';

export default function Vendors() {
  const { data: inv } = useInventory();
  const bills = useBills({}, true);
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<any | null>(null);
  const list = useMemo(() => (bills.data?.vendors || []).filter((v: any) => !q.trim() || v.name.toLowerCase().includes(q.trim().toLowerCase()))
    .sort((a: any, b: any) => Number(b.balance) - Number(a.balance) || a.name.localeCompare(b.name)), [bills.data, q]);
  if (!inv) return null;
  return (
    <div className="container">
      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><div className="row" style={{ flex: 1 }}><Icon name="search" size={15} color="#9CA3AF" /><input className="input input-sm" style={{ border: 0, boxShadow: 'none' }} placeholder="Find a vendor" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search vendors" /></div></div>
        <div className="tbl">
          <div className="tr head shade th hide-sm" style={{ gridTemplateColumns: 'minmax(180px,1.5fr) 140px minmax(160px,1fr) 150px 130px', minWidth: 800 }}><span>Vendor</span><span>Tax ID</span><span>WHT</span><span>Bank</span><span className="right">We owe</span></div>
          {bills.isLoading ? <SkeletonRows n={6} /> : bills.error ? <div style={{ padding: 20 }}><Alert kind="yellow" icon="shield">{(bills.error as Error).message}</Alert></div> : !list.length ? <div style={{ padding: 20 }}><Empty>No vendors yet.</Empty></div> : list.map((v: any) => (
            <div key={v.id} className="tr click" onClick={() => setOpen(v)} style={{ gridTemplateColumns: 'minmax(180px,1.5fr) 140px minmax(160px,1fr) 150px 130px', minWidth: 800 }}>
              <b className="ellipsis">{v.name}</b>
              <span className="muted">{v.tin ? <>{v.tin}{isOldTin(v.tin) && <span className="faint" style={{ display: 'block', fontSize: 11 }}>old TIN</span>}</> : <span style={{ color: '#C2410C' }}>No Tax ID</span>}</span>
              <span className="muted ellipsis">{(bills.data?.wht_rates || []).find((w: any) => w.code === v.wht_category)?.name || 'Not set'}</span>
              <span className="muted">{v.account_number ? `${v.bank_name || v.bank_code} · ${v.account_number.slice(-4)}` : '—'}</span>
              <span className="right num" style={{ color: Number(v.balance) > 0 ? '#C2410C' : undefined }}>{Number(v.balance) ? N2(v.balance) : '—'}</span>
            </div>
          ))}
        </div>
      </div>
      {open && <VendorDrawer vendor={open} whtRates={bills.data?.wht_rates || []} onClose={() => setOpen(null)} />}
    </div>
  );
}

function VendorDrawer({ vendor, whtRates, onClose }: { vendor: any; whtRates: any[]; onClose: () => void }) {
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const chart = useChart();
  const meta = useMeta();
  const [tab, setTab] = useState<'statement' | 'details'>('statement');
  const [f, setF] = useState({ tin: vendor.tin || '', rc_number: vendor.rc_number || '', is_individual: !!vendor.is_individual, wht_category: vendor.wht_category || '', bank_code: vendor.bank_code || '',
    account_number: vendor.account_number || '', account_name: vendor.account_name || '', default_account: vendor.default_account || '', address: vendor.address || '' });
  const [banks, setBanks] = useState<{ code: string; name: string }[]>([]);
  const st = useQuery({ queryKey: ['vstatement', vendor.id], enabled: tab === 'statement', queryFn: () => rpc<any>('vendor_statement', { p_vendor: vendor.id, p_from: null, p_to: null }) });
  useEffect(() => { edge<{ banks: any[] }>('payments', { action: 'banks' }).then((r) => setBanks(r.banks || [])); }, []);
  useEffect(() => {
    if (!/^\d{10}$/.test(f.account_number) || !f.bank_code || f.account_name) return;
    edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: f.account_number, bank_code: f.bank_code }).then((r) => r.account_name && setF((x) => ({ ...x, account_name: r.account_name })));
  }, [f.account_number, f.bank_code]); // eslint-disable-line react-hooks/exhaustive-deps
  const accounts = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^[56]/.test(a.code));
  const tinErr = taxIdError(f.tin, vendor.tin);
  async function save() {
    if (tinErr) { toast(tinErr, 'err'); return; }
    try {
      await rpc('save_vendor_details', { p_org: orgId, p_vendor: vendor.id, p_patch: { ...f, bank_name: banks.find((b) => b.code === f.bank_code)?.name || null } });
      toast('Vendor saved'); await qc.invalidateQueries({ queryKey: ['bills'] });
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  const s = st.data;
  return (
    <Drawer onClose={onClose} width={680}>
      <div className="drawer-hd"><div className="grow"><div className="drawer-title">{vendor.name}</div><div className="muted" style={{ fontSize: 13 }}>{Number(vendor.balance) > 0 ? `We owe ${N2(vendor.balance)}` : 'Nothing owed'}</div></div>
        <button className="x-btn" onClick={onClose} aria-label="Close"><Icon name="x" size={18} /></button></div>
      <div className="drawer-body stack" style={{ gap: 14 }}>
        <Pills value={tab} onChange={setTab} options={[{ id: 'statement', label: 'Statement' }, { id: 'details', label: 'Tax and bank details' }]} />
        {tab === 'details' ? (
          <div className="stack" style={{ gap: 12 }}>
            {!f.tin && <Alert kind="yellow" icon="alert">Without a Tax ID, withholding tax on this vendor's bills is deducted at double the rate.</Alert>}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Tax ID" error={tinErr} hint={tinErr ? undefined : isOldTin(f.tin) ? 'An old TIN. Ask them for their 13-digit Tax ID.' : TAX_ID_HINT}>
                <input className="input" inputMode="numeric" maxLength={20} placeholder="13 digits" value={f.tin} onChange={(e) => setF({ ...f, tin: e.target.value })} /></Field>
              <Field label="RC number"><input className="input" value={f.rc_number} onChange={(e) => setF({ ...f, rc_number: e.target.value })} /></Field>
            </div>
            <label className="check"><input type="checkbox" checked={f.is_individual} onChange={(e) => setF({ ...f, is_individual: e.target.checked })} />An individual, not a company</label>
            <Field label="Withholding tax on what they supply"><select className="input" value={f.wht_category} onChange={(e) => setF({ ...f, wht_category: e.target.value })}><option value="">Choose</option>{whtRates.map((w) => <option key={w.code} value={w.code}>{w.name} · {(Number(f.is_individual ? w.rate_individual : w.rate_company) * 100).toFixed(1)}%</option>)}</select></Field>
            <Field label="Their bills usually go to"><select className="input" value={f.default_account} onChange={(e) => setF({ ...f, default_account: e.target.value })}><option value="">No default</option>{accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}</select></Field>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Bank"><select className="input" value={f.bank_code} onChange={(e) => setF({ ...f, bank_code: e.target.value, account_name: '' })}><option value="">Choose</option>{banks.map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}</select></Field>
              <Field label="Account number"><input className="input" inputMode="numeric" maxLength={10} value={f.account_number} onChange={(e) => setF({ ...f, account_number: e.target.value.replace(/\D/g, ''), account_name: '' })} /></Field>
            </div>
            <Field label="Account name" hint="Confirmed by the bank."><input className="input" value={f.account_name} onChange={(e) => setF({ ...f, account_name: e.target.value })} /></Field>
            <Field label="Address"><input className="input" value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
            <div><button className="btn btn-primary" onClick={save}>Save</button></div>
          </div>
        ) : !s ? <SkeletonRows n={5} /> : (
          <div className="stack" style={{ gap: 12 }}>
            <div className="row" style={{ justifyContent: 'flex-end' }}>
              <ExportMenu name={`${vendor.name} statement ${today()}`} sheets={() => [{ meta: meta(`Vendor statement · ${vendor.name}`, `${fmtDay(s.from)} to ${fmtDay(s.to)}`),
                cols: [{ key: 'date', label: 'Date', type: 'date' }, { key: 'ref', label: 'Journal' }, { key: 'memo', label: 'Details' }, { key: 'credit', label: 'Billed', type: 'money' }, { key: 'debit', label: 'Paid', type: 'money' }, { key: 'balance', label: 'Balance', type: 'money' }],
                rows: [{ memo: 'Opening balance', balance: s.opening, _style: 'subheading' }, ...s.lines, { memo: 'Closing balance', balance: s.closing, _style: 'total' }] }]} />
            </div>
            <div className="card" style={{ overflow: 'hidden' }}>
              <div className="tr head shade th" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px' }}><span>Date</span><span>Details</span><span className="right">Billed</span><span className="right">Paid</span><span className="right">Balance</span></div>
              {(s.lines || []).map((l: any, i: number) => (
                <div key={i} className="tr" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px' }}>
                  <span className="muted">{fmtDay(l.date)}</span><span className="ellipsis">{l.memo}</span><span className="right num">{Number(l.credit) ? acc(l.credit) : ''}</span><span className="right num">{Number(l.debit) ? acc(l.debit) : ''}</span><span className="right num">{acc(l.balance)}</span>
                </div>
              ))}
              <div className="tr" style={{ gridTemplateColumns: '100px minmax(0,1fr) 110px 110px 120px', fontWeight: 700, background: '#FAFAFA' }}><span /><span>Closing balance</span><span /><span /><span className="right num">{acc(s.closing)}</span></div>
            </div>
            {Number(s.wht_withheld) > 0 && <div className="muted" style={{ fontSize: 13 }}>Withholding tax deducted from this vendor so far: <b>{N2(s.wht_withheld)}</b>. Give them the receipts when you remit it.</div>}
          </div>
        )}
      </div>
    </Drawer>
  );
}
