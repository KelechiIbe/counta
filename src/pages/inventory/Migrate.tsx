import { useEffect, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { can, useInventory, useSession } from '../../state/session';
import { useAction } from '../../lib/queries';
import { rpc } from '../../lib/supabase';
import { N, addDays, fmtDay, num, uuid, when } from '../../lib/format';
import { SYSTEMS, systemById } from '../../lib/migrate';
import { Icon } from '../../components/Icon';
import { SimpleImport } from '../../components/SimpleImport';
import { Alert, Chip, Field } from '../../components/ui';
import ImportPanel from './ImportPanel';

interface ImportRow {
  id: string; kind: 'items' | 'vendors' | 'sales_history'; source_system: string | null; file_name: string | null; as_of: string | null;
  rows_created: number; rows_updated: number; rows_skipped: number; opening_value: number; expected_value: number | null;
  period_from: string | null; period_to: string | null; items: number; vendors: number; journals: string[] | null;
  by_location: Record<string, number> | null; status: 'posted' | 'reversed'; created_at: string; created_by: string | null; can_undo: boolean;
}
interface Plan { system: string | null; asOf: string; expected: string; itemsId: string; vendorsId: string; historyId: string }

export default function Migrate() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const qc = useQueryClient();
  const key = 'counta.migrate.' + orgId;
  const [plan, setPlanState] = useState<Plan>(() => {
    const fresh: Plan = { system: null, asOf: addDays(new Date().toISOString().slice(0, 10), -1), expected: '', itemsId: uuid(), vendorsId: uuid(), historyId: uuid() };
    try { const s = localStorage.getItem(key); return s ? { ...fresh, ...JSON.parse(s) } : fresh; } catch { return fresh; }
  });
  const setPlan = (p: Partial<Plan>) => setPlanState((x) => { const n = { ...x, ...p }; try { localStorage.setItem(key, JSON.stringify(n)); } catch { /* private mode */ } return n; });
  const [upload, setUpload] = useState(false);
  const imports = useQuery({ queryKey: ['imports', orgId], enabled: !!orgId && !!inv?.can_see_costs, queryFn: () => rpc<ImportRow[]>('get_imports', { p_org: orgId }) });
  useEffect(() => {
    // An upload that was undone cannot take more chunks; start a fresh one.
    const items = imports.data?.find((i) => i.id === plan.itemsId);
    if (items?.status === 'reversed') setPlan({ itemsId: uuid() });
  }, [imports.data]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  if (!can(inv, 'edit_prices')) return <div className="container"><Alert kind="yellow" icon="shield">Moving your stock into Counta needs the Edit costs and prices permission. Ask the owner.</Alert></div>;
  const sys = systemById(plan.system);
  // Every items upload still standing for this go-live day counts towards the check, from any browser or person.
  const itemsImport = (imports.data || []).filter((i) => i.kind === 'items' && i.status === 'posted' && String(i.as_of || '').slice(0, 10) === plan.asOf)
    .reduce<ImportRow | null>((a, i) => (!a ? { ...i, journals: [...(i.journals || [])], by_location: { ...(i.by_location || {}) } } : {
      ...a, items: a.items + Number(i.items || 0), rows_updated: a.rows_updated + i.rows_updated, rows_skipped: a.rows_skipped + i.rows_skipped,
      opening_value: Number(a.opening_value) + Number(i.opening_value), journals: [...(a.journals || []), ...(i.journals || [])],
      by_location: Object.entries(i.by_location || {}).reduce((m, [k, v]) => ({ ...m, [k]: Number(m[k] || 0) + Number(v) }), a.by_location || {}),
    }), null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['imports'] });
  const expected = plan.expected === '' ? null : Number(plan.expected);
  const diff = itemsImport && expected != null ? Number(itemsImport.opening_value) - expected : null;
  return (
    <div className="container" style={{ maxWidth: 1040 }}>
      <div className="ink3" style={{ fontSize: 14, maxWidth: 760, lineHeight: 1.55 }}>
        Bring your items, stock, suppliers and past sales across from the system you use now. Counta opens on exactly the stock your old system closes on, dated your go-live day, so the two agree to the naira. Every upload can be undone until something happens to what it created.
      </div>

      <Step n={1} title="Where are you coming from?" done={!!sys}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(190px,1fr))', gap: 8 }}>
          {SYSTEMS.map((s) => (
            <button key={s.id} className="card" onClick={() => setPlan({ system: s.id })} aria-pressed={plan.system === s.id}
              style={{ padding: '12px 14px', textAlign: 'left', cursor: 'pointer', font: 'inherit', borderColor: plan.system === s.id ? '#0072F5' : undefined, background: plan.system === s.id ? '#F0F7FF' : undefined }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{s.name}</div>
            </button>
          ))}
        </div>
      </Step>

      {sys && (
        <Step n={2} title={`Get your data out of ${sys.short}`}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(230px,1fr))', gap: 12 }}>
            <How icon="package" title="Items and stock">{sys.items}</How>
            <How icon="truck" title="Suppliers">{sys.vendors}</How>
            <How icon="history" title="Past sales">{sys.sales}</How>
          </div>
          {sys.tip && <Alert kind="blue" icon="info">{sys.tip}</Alert>}
          <div className="faint" style={{ fontSize: 12 }}>Menu names differ a little between versions. Any Excel or CSV export works; Counta finds the columns.</div>
        </Step>
      )}

      <Step n={sys ? 3 : 2} title="Pick your go-live date" done={!!plan.asOf}>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,220px) minmax(0,260px) minmax(0,1fr)', gap: 14, alignItems: 'start' }}>
          <Field label="Opening stock as at close of"><input className="input" type="date" value={plan.asOf} max={inv.today} onChange={(e) => setPlan({ asOf: e.target.value })} /></Field>
          <Field label={`What ${sys?.short || 'your old system'} says the stock is worth`} hint="From its valuation report for that day. Optional, but it lets Counta check the upload.">
            <input className="input" type="number" inputMode="decimal" min={0} value={plan.expected} placeholder="₦" onChange={(e) => setPlan({ expected: e.target.value })} />
          </Field>
          <div className="ink3" style={{ fontSize: 13, lineHeight: 1.55, paddingTop: 22 }}>
            Post every invoice and sale for that day in {sys?.short || 'the old system'}, count the shelves at close of business if you can, then export. From the next morning, record everything in Counta.
          </div>
        </div>
      </Step>

      <Step n={sys ? 4 : 3} title="Items and opening stock" done={!!itemsImport}>
        {!itemsImport ? (
          <div className="row m-wrap" style={{ gap: 12 }}>
            <button className="btn btn-primary" disabled={!plan.asOf} onClick={() => setUpload(true)}><Icon name="upload" size={16} color="#fff" />Upload items and stock</button>
            <span className="muted" style={{ fontSize: 13 }}>Opening stock is dated {fmtDay(plan.asOf)}. Large files go up in parts and still count as one upload.</span>
          </div>
        ) : (
          <div className="stack" style={{ gap: 12 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 10 }}>
              <Fig label="Items added" value={num(itemsImport.items)} sub={itemsImport.rows_updated ? `${itemsImport.rows_updated} existing updated` : `${itemsImport.rows_skipped} rows left out`} />
              <Fig label={`Opening stock, ${fmtDay(itemsImport.as_of)}`} value={N(itemsImport.opening_value)} sub={(itemsImport.journals || []).join(', ')} />
              {expected != null && <Fig label={`${sys?.short || 'Old system'} says`} value={N(expected)} sub={diff != null && Math.abs(diff) < 1 ? 'Agrees to the naira' : `Difference ${N(diff || 0)}`} tone={diff != null && Math.abs(diff) < 1 ? 'green' : 'amber'} />}
            </div>
            {itemsImport.by_location && Object.keys(itemsImport.by_location).length > 1 && (
              <div className="ink3" style={{ fontSize: 13 }}>By branch: {Object.entries(itemsImport.by_location).map(([k, v]) => `${k} ${N(v)}`).join(' · ')}</div>
            )}
            {diff != null && Math.abs(diff) >= 1 && (
              <Alert kind="yellow" icon="info">
                The upload is {N(Math.abs(diff))} {diff > 0 ? 'more' : 'less'} than {sys?.short || 'the old system'}. Usual causes: rows left out for a missing price or name, items with no cost, or quantities read in cartons instead of pieces. Fix the sheet, undo this upload below and send it again, or post the difference later with a stock count.
              </Alert>
            )}
            <div className="row" style={{ gap: 8 }}>
              <button className="btn btn-secondary btn-sm" onClick={() => setUpload(true)}><Icon name="plus" size={14} />Upload more items</button>
              <Link className="btn btn-ghost btn-sm" to="/inventory/reports">Check the stock valuation report</Link>
            </div>
          </div>
        )}
      </Step>

      <Step n={sys ? 5 : 4} title="Suppliers" optional>
        <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5 }}>Names, phone numbers, emails and Tax IDs, so purchase orders, Martina's supplier calls and the input VAT schedule work from day one. Suppliers already in Counta are updated.</div>
        <SimpleImport kind="vendors" orgId={orgId!} source={sys?.name || 'Spreadsheet'} importId={plan.vendorsId} onDone={() => { refresh(); qc.invalidateQueries({ queryKey: ['inv'] }); setPlan({ vendorsId: uuid() }); }} />
      </Step>

      <Step n={sys ? 6 : 5} title="Past sales" optional>
        <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5 }}>Three to twelve months of sales per item. Reorder suggestions, slow-stock flags and Martina's forecasts then work from day one instead of after a month. Past sales never change stock or the books, and history stops the day before Counta's own sales begin.</div>
        <SimpleImport kind="history" orgId={orgId!} source={sys?.name || 'Spreadsheet'} importId={plan.historyId} onDone={() => { refresh(); qc.invalidateQueries({ queryKey: ['inv'] }); setPlan({ historyId: uuid() }); }} />
      </Step>

      <ImportsList rows={imports.data || []} />

      {upload && (
        <ImportPanel onClose={() => { setUpload(false); refresh(); }}
          migration={{ asOf: plan.asOf, source: sys?.name || 'Spreadsheet', importId: plan.itemsId, expectedValue: expected, preset: sys?.preset }}
          onDone={() => refresh()} />
      )}
    </div>
  );
}

function Step({ n, title, done, optional, children }: { n: number; title: string; done?: boolean; optional?: boolean; children: ReactNode }) {
  return (
    <div className="card card-pad stack" style={{ gap: 12 }}>
      <div className="row" style={{ gap: 10 }}>
        <span style={{ width: 26, height: 26, borderRadius: '50%', display: 'grid', placeItems: 'center', fontSize: 13, fontWeight: 700, flex: 'none',
          background: done ? '#15803D' : '#F0F7FF', color: done ? '#fff' : '#0072F5' }}>{done ? <Icon name="check" size={14} color="#fff" sw={3} /> : n}</span>
        <div style={{ fontSize: 16, fontWeight: 600 }}>{title}</div>
        {optional && <Chip label="Optional" t="t-grey" />}
      </div>
      {children}
    </div>
  );
}

function How({ icon, title, children }: { icon: string; title: string; children: ReactNode }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: 12 }}>
      <div className="row" style={{ gap: 8, marginBottom: 6 }}><Icon name={icon} size={16} color="#0072F5" /><b style={{ fontSize: 13.5 }}>{title}</b></div>
      <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5 }}>{children}</div>
    </div>
  );
}

function Fig({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'green' | 'amber' }) {
  return (
    <div style={{ border: '1px solid #EEF0F3', borderRadius: 12, padding: '10px 12px' }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 17, fontWeight: 600, marginTop: 3 }} className="num">{value}</div>
      {sub && <div style={{ fontSize: 12, marginTop: 2, color: tone === 'green' ? '#15803D' : tone === 'amber' ? '#A16207' : '#6B7280' }}>{sub}</div>}
    </div>
  );
}

const KIND: Record<ImportRow['kind'], string> = { items: 'Items and stock', vendors: 'Suppliers', sales_history: 'Past sales' };

function ImportsList({ rows }: { rows: ImportRow[] }) {
  const { data: inv } = useInventory();
  const { run, busy } = useAction();
  const [confirm, setConfirm] = useState<string | null>(null);
  if (!rows.length || !inv) return null;
  const owner = can(inv, 'owner');
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd"><div className="label">Uploads</div></div>
      <div style={{ overflow: 'auto' }}>
        <table className="mini-table" style={{ width: '100%', minWidth: 760 }}>
          <thead><tr><th>What</th><th>From</th><th>File</th><th className="right">Rows</th><th className="right">Opening stock</th><th>When</th><th /></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} style={{ opacity: r.status === 'reversed' ? 0.55 : 1 }}>
                <td style={{ fontWeight: 600 }}>{KIND[r.kind]}{r.as_of ? <div className="faint" style={{ fontSize: 11, fontWeight: 400 }}>as at {fmtDay(r.as_of)}</div> : null}{r.period_from ? <div className="faint" style={{ fontSize: 11, fontWeight: 400 }}>{fmtDay(r.period_from)} to {fmtDay(r.period_to)}</div> : null}</td>
                <td className="ink3">{r.source_system || '—'}</td>
                <td className="ink3 ellipsis" style={{ maxWidth: 200 }}>{r.file_name}</td>
                <td className="right num">{num(r.rows_created)}{r.rows_updated ? ` + ${num(r.rows_updated)} updated` : ''}</td>
                <td className="right num">{r.kind === 'items' ? N(r.opening_value) : '—'}</td>
                <td className="ink3">{when(r.created_at)}{r.created_by ? ' · ' + r.created_by : ''}</td>
                <td className="right" style={{ whiteSpace: 'nowrap' }}>
                  {r.status === 'reversed' ? <Chip label="Undone" t="t-grey" /> : owner && (r.can_undo ? (
                    confirm === r.id ? (
                      <span className="row" style={{ gap: 4, justifyContent: 'flex-end' }}>
                        <button className="btn btn-xs btn-secondary" onClick={() => setConfirm(null)}>Keep</button>
                        <button className="btn btn-xs btn-primary" style={{ background: '#B91C1C' }} disabled={busy}
                          onClick={() => run(() => rpc('undo_import', { p_import: r.id }), { ok: 'Upload undone', invalidate: ['imports', 'inv', 'ledger', 'activity'] }).then(() => setConfirm(null))}>Undo it</button>
                      </span>
                    ) : <button className="btn btn-ghost btn-xs" onClick={() => setConfirm(r.id)}><Icon name="undo" size={13} />Undo</button>
                  ) : <span className="faint" style={{ fontSize: 12 }} title="Something has happened to these items since. Correct them with a stock count.">In use</span>)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {owner && <div className="faint" style={{ fontSize: 12, padding: '10px 20px' }}>Undo reverses the opening stock entry and archives the items an upload created. Updates it made to existing items stay.</div>}
    </div>
  );
}
