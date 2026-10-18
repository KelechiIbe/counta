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
import { ENTITY_TYPES, matrixRate, pct, useTaxProfile, useVendorTax } from '../../lib/tax';
import { COUNTRIES } from '../../lib/countries';
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
  const tax = useVendorTax(vendor.id);
  const prof = useTaxProfile();
  const states: string[] = (prof.data?.authorities || []).filter((a: any) => a.state).map((a: any) => a.state);
  const [f, setF] = useState({ tin: vendor.tin || '', rc_number: vendor.rc_number || '', wht_category: vendor.wht_category || '', bank_code: vendor.bank_code || '',
    account_number: vendor.account_number || '', account_name: vendor.account_name || '', default_account: vendor.default_account || '', address: vendor.address || '',
    entity_type: '', resident: true, country: 'NG', state: '', nin: '', is_manufacturer: false, wht_exempt: false, digital_supplier: false, connected_person: false });
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    const t = tax.data;
    if (!t || loaded) return;
    setF((x) => ({ ...x, entity_type: t.entity_type || (t.is_individual ? 'individual' : ''), resident: t.resident !== false, country: t.country || 'NG', state: t.state || '', nin: t.nin || '',
      is_manufacturer: !!t.is_manufacturer, wht_exempt: !!t.wht_exempt, digital_supplier: !!t.digital_supplier, connected_person: !!t.connected_person }));
    setLoaded(true);
  }, [tax.data]); // eslint-disable-line react-hooks/exhaustive-deps
  const [banks, setBanks] = useState<{ code: string; name: string }[]>([]);
  const st = useQuery({ queryKey: ['vstatement', vendor.id], enabled: tab === 'statement', queryFn: () => rpc<any>('vendor_statement', { p_vendor: vendor.id, p_from: null, p_to: null }) });
  useEffect(() => { edge<{ banks: any[] }>('payments', { action: 'banks' }).then((r) => setBanks(r.banks || [])); }, []);
  useEffect(() => {
    if (!/^\d{10}$/.test(f.account_number) || !f.bank_code || f.account_name) return;
    edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: f.account_number, bank_code: f.bank_code }).then((r) => r.account_name && setF((x) => ({ ...x, account_name: r.account_name })));
  }, [f.account_number, f.bank_code]); // eslint-disable-line react-hooks/exhaustive-deps
  const accounts = (chart.data?.accounts || []).filter((a: any) => !a.is_group && a.active && /^[56]/.test(a.code));
  const tinErr = taxIdError(f.tin, vendor.tin);
  const corporate = f.entity_type ? !!ENTITY_TYPES.find((e) => e.id === f.entity_type)?.corporate : !vendor.is_individual;
  const goesTo = f.wht_exempt || f.entity_type === 'government' ? 'No WHT: exempt' : corporate || !f.resident ? 'WHT goes to the NRS'
    : f.state ? `WHT goes to the ${f.state} state revenue service` : 'WHT goes to the revenue service of their state, so add the state before their bills are approved or paid';
  async function save() {
    // The tax fields come from the supplier's tax details; saving before they load would clear them.
    if (!loaded) { toast(tax.error ? (tax.error as Error).message : 'The supplier\'s details are still loading.', 'err'); return; }
    if (tinErr) { toast(tinErr, 'err'); return; }
    if (f.nin && !/^\d{11}$/.test(f.nin.replace(/\D/g, ''))) { toast('A NIN has 11 digits.', 'err'); return; }
    try {
      await rpc('save_vendor_details', { p_org: orgId, p_vendor: vendor.id, p_patch: { ...f, entity_type: f.entity_type || null, state: f.resident ? f.state || null : null,
        country: f.resident ? 'NG' : f.country, bank_name: banks.find((b) => b.code === f.bank_code)?.name || null } });
      toast('Vendor saved'); await Promise.all(['bills', 'bill', 'vendor-tax'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
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
            {tax.error && <Alert kind="yellow" icon="shield">{(tax.error as Error).message}</Alert>}
            {!f.tin && <Alert kind="yellow" icon="alert">Without a Tax ID, withholding tax on this vendor's bills is deducted at double the rate.</Alert>}
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="What kind of business"><select className="input" value={f.entity_type} onChange={(e) => setF({ ...f, entity_type: e.target.value })}>
                <option value="">Not set{vendor.is_individual ? ' (an individual)' : ' (a company)'}</option>{ENTITY_TYPES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></Field>
              <Field label="Based"><select className="input" value={f.resident ? 'NG' : 'abroad'} onChange={(e) => setF({ ...f, resident: e.target.value === 'NG', country: e.target.value === 'NG' ? 'NG' : f.country === 'NG' ? '' : f.country })}>
                <option value="NG">In Nigeria</option><option value="abroad">Abroad</option></select></Field>
              {f.resident ? (
                <Field label="State" hint="Decides which state service gets WHT for a supplier that is not a company."><select className="input" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value })}>
                  <option value="">Not known</option>{states.map((x) => <option key={x} value={x}>{x}</option>)}</select></Field>
              ) : (
                <Field label="Country"><select className="input" value={f.country} onChange={(e) => setF({ ...f, country: e.target.value })}><option value="">Choose</option>
                  {COUNTRIES.filter((c) => c.code !== 'NG').map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</select></Field>
              )}
              <Field label={f.resident ? 'Tax ID' : 'Nigerian Tax ID, if they have one'} error={tinErr} hint={tinErr ? undefined : !f.resident ? 'Without one the WHT rate doubles, as on the NRS schedule.' : isOldTin(f.tin) ? 'An old TIN. Ask them for their 13-digit Tax ID.' : TAX_ID_HINT}>
                <input className="input" inputMode="numeric" maxLength={20} placeholder="13 digits" value={f.tin} onChange={(e) => setF({ ...f, tin: e.target.value })} /></Field>
              <Field label="RC number"><input className="input" value={f.rc_number} onChange={(e) => setF({ ...f, rc_number: e.target.value })} /></Field>
              {!corporate && f.resident && <Field label="NIN" hint="For an individual without a Tax ID."><input className="input" inputMode="numeric" maxLength={11} value={f.nin} onChange={(e) => setF({ ...f, nin: e.target.value.replace(/\D/g, '') })} /></Field>}
            </div>
            <Field label="Withholding tax on what they supply"><select className="input" value={f.wht_category} onChange={(e) => setF({ ...f, wht_category: e.target.value })}><option value="">Choose</option>
              {whtRates.map((w) => { const r = matrixRate(w, corporate, f.resident); return <option key={w.code} value={w.code}>{w.name}{w.code === 'none' ? '' : ` · ${r == null ? 'not withheld' : pct(f.tin ? r : r * 2)}`}</option>; })}</select></Field>
            <div className="stack" style={{ gap: 6 }}>
              <label className="check"><input type="checkbox" checked={f.is_manufacturer} onChange={(e) => setF({ ...f, is_manufacturer: e.target.checked })} />Makes the goods it sells us (no WHT on its own goods)</label>
              <label className="check"><input type="checkbox" checked={f.wht_exempt} onChange={(e) => setF({ ...f, wht_exempt: e.target.checked })} />Exempt from withholding tax (has an exemption from the NRS)</label>
              {!f.resident && <label className="check"><input type="checkbox" checked={f.digital_supplier} onChange={(e) => setF({ ...f, digital_supplier: e.target.checked })} />A digital service registered for Nigerian VAT (charges its own VAT)</label>}
              <label className="check"><input type="checkbox" checked={f.connected_person} onChange={(e) => setF({ ...f, connected_person: e.target.checked })} />A connected person (related company, director or shareholder)</label>
            </div>
            <div className="faint" style={{ fontSize: 12 }}>{goesTo}.{!f.resident && !f.digital_supplier ? ' VAT on services they supply is self-charged at 7.5% and paid to the NRS by the 14th.' : ''}
              {tax.data?.state_needed && !f.state ? ' Without it, send their bills back to ask for the address.' : ''}</div>
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
