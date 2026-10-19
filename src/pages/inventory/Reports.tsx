import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { useSuggestions } from '../../shell/needsAction';
import { rpc } from '../../lib/supabase';
import { N, fmtDay } from '../../lib/format';
import { useAccounts } from '../../lib/accounts';
import {
  GROUPS, PACK, REPORTS, clientRows, reportById, itemAttrCols,
  type RCol, type ReportDef,
} from '../../lib/reports';
import { downloadBlob, itemsXlsx, packXlsx, reportCsv, reportPdf, reportXlsx, safeName, type ReportMeta } from '../../lib/exporters';
import { Icon } from '../../components/Icon';
import { PeriodPicker } from '../../components/PeriodPicker';
import { useScreenPeriod } from '../../lib/period';
import { Alert, Label, Spinner } from '../../components/ui';

interface RpcResult { rows: Record<string, unknown>[]; extra: Record<string, any>; from: string; to: string; truncated: boolean; can_see_costs: boolean }

const fmt = (v: unknown, t?: string) => {
  if (v == null || v === '') return '';
  if (t === 'date' && typeof v === 'string') return fmtDay(v.slice(0, 10));
  if (t === 'money') { const n = Number(v); return n < 0 ? '(' + N(-n) + ')' : N(n); }
  if (t === 'qty' || t === 'num') return Number(v).toLocaleString('en-NG', { maximumFractionDigits: 3 });
  if (t === 'int') return Number(v).toLocaleString('en-NG');
  if (t === 'pct') return Number(v).toFixed(1) + '%';
  return typeof v === 'boolean' ? (v ? 'Yes' : 'No') : String(v);
};

export default function Reports() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const { suggestions } = useSuggestions();
  const accounts = useAccounts().data;
  const [id, setId] = useState<string>(() => { try { return localStorage.getItem('counta.report') || 'valuation'; } catch { return 'valuation'; } });
  const today = inv?.today || new Date().toISOString().slice(0, 10);
  const [range, setRange] = useScreenPeriod(orgId, 'inventory-reports', 'mtd', inv?.org.fiscal_year_start || 1);
  const [loc, setLoc] = useState('');
  const [item, setItem] = useState('');
  const [acctSel, setAcctSel] = useState<string>('');
  const [busy, setBusy] = useState<string | null>(null);
  const def = reportById(id);
  const costs = !!inv?.can_see_costs;
  const blocked = def.needsCosts && !costs;
  const pick = (r: string) => { setId(r); try { localStorage.setItem('counta.report', r); } catch { /* private mode */ } };

  const params = (d: ReportDef) => ({
    p_org: orgId, p_report: d.id,
    p_from: d.period === 'range' ? range.from : null,
    p_to: d.period === 'none' ? null : range.to,
    p_location: d.location ? loc || null : null,
    p_item: d.item ? item || null : null,
    p_accounts: d.accounts && acctSel ? (acctSel === '*' ? ['*'] : [acctSel]) : null,
  });
  const q = useQuery({
    queryKey: ['report', id, def.period === 'range' ? range.from : '', def.period === 'none' ? '' : range.to, loc, item, acctSel],
    queryFn: () => rpc<RpcResult>('inventory_report', params(def)),
    enabled: !!inv && def.source === 'rpc' && !blocked,
    staleTime: 30_000,
  });

  const cols: RCol[] = useMemo(() => {
    if (!inv) return [];
    const base = def.cols.filter((c) => costs || !c.cost);
    return def.id === 'items' ? [...base, ...itemAttrCols(inv)] : base;
  }, [def, costs, inv]);
  const rows: Record<string, unknown>[] = useMemo(() => {
    if (!inv) return [];
    if (def.source === 'rpc') return q.data?.rows || [];
    const r = clientRows(def, inv, suggestions);
    if (def.id === 'items') return r.map((row, i) => { const it = inv.items[i]; const a: Record<string, unknown> = { ...row }; for (const [k, v] of Object.entries(it?.attributes || {})) a['attr:' + k] = v; return a; });
    return r;
  }, [def, q.data, inv, suggestions]);
  if (!inv) return null;

  const locName = loc ? inv.locations.find((l) => l.id === loc)?.name || 'Branch' : 'All branches';
  const periodText = (d: ReportDef) => d.period === 'range' ? `${fmtDay(range.from)} to ${fmtDay(range.to)}` : d.period === 'asAt' ? `As at ${fmtDay(range.to)}` : `As at ${fmtDay(today)}`;
  const meta = (d: ReportDef): ReportMeta => ({
    org: inv.org.name, title: d.title, period: periodText(d), branch: d.location ? locName : 'All branches',
    by: inv.me.display_name, generated: new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }),
    note: d.id === 'valuation' || d.id === 'movement_summary' ? 'Values at weighted average cost. Landed charges absorbed into stock are included.' : undefined,
  });
  const extraLines = (d: ReportDef, data?: RpcResult): string[] => {
    if (d.id === 'valuation' && data?.extra && !loc && !item) {
      const total = (data.rows || []).reduce((a, r) => a + (Number(r.value) || 0), 0);
      const gl = Number(data.extra.gl_inventory || 0); const git = Number(data.extra.gl_in_transit || 0);
      const diff = Math.round((total - gl) * 100) / 100;
      const allow = Number(data.extra.allowance || 0);
      const lines = [`Inventory accounts in the ledger: ${N(gl)}${git ? ` · goods in transit ${N(git)}` : ''} · ${Math.abs(diff) < 1 ? 'agrees with this report' : `difference ${N(diff)}`}`];
      if (allow) lines.push(`Less allowance for stock below cost ${N(allow)} · carrying amount ${N(total - allow)}`);
      return lines;
    }
    return [];
  };

  async function exportAs(kind: 'xlsx' | 'csv' | 'pdf') {
    if (!rows.length) { toast('Nothing to export for these filters.', 'err'); return; }
    setBusy(kind);
    try {
      const name = `${safeName(inv!.org.name)} – ${def.title} – ${def.period === 'range' ? `${range.from} to ${range.to}` : range.to}`;
      const lines = extraLines(def, q.data);
      const outRows = def.id === 'items' ? rows.map((r) => ({ ...r })) : rows;
      if (kind === 'xlsx' && def.id === 'items') downloadBlob(await itemsXlsx(inv!), `${safeName(inv!.org.name)} – item list.xlsx`);
      else if (kind === 'xlsx') downloadBlob(await reportXlsx(meta(def), cols, outRows, lines), name + '.xlsx');
      else if (kind === 'csv') downloadBlob(reportCsv(cols, outRows), name + '.csv');
      else downloadBlob(await reportPdf(meta(def), cols, outRows, lines), name + '.pdf');
    } catch (e: any) { toast(e.message || 'Export failed', 'err'); }
    setBusy(null);
  }

  async function exportPack() {
    setBusy('pack');
    try {
      const defs = PACK.map(reportById).filter((d) => !d.needsCosts || costs);
      const sheets = [];
      for (const d of defs) {
        const data = await rpc<RpcResult>('inventory_report', { ...params(d), p_item: null, p_accounts: null });
        sheets.push({ meta: meta(d), def: d, cols: d.cols.filter((c) => costs || !c.cost), rows: data.rows, extra: extraLines(d, data) });
      }
      const cover: ReportMeta = { ...meta(reportById('movement_summary')), title: 'Month-end inventory pack' };
      downloadBlob(await packXlsx(sheets, cover), `${safeName(inv!.org.name)} – inventory pack – ${range.from} to ${range.to}.xlsx`);
    } catch (e: any) { toast(e.message || 'Could not build the pack', 'err'); }
    setBusy(null);
  }

  const totals = cols.filter((c) => c.total).map((c) => [c.key, rows.reduce((a, r) => a + (Number(r[c.key]) || 0), 0)] as const);
  const shown = rows.slice(0, 300);
  const itemsSorted = [...inv.items].sort((a, b) => a.name.localeCompare(b.name));
  const usedAccts = accounts?.filter((a) => /^120[1-7]$/.test(a.code) || a.code === '1204') || [];

  return (
    <div className="container">
      <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
        <div className="ink3" style={{ fontSize: 14, maxWidth: 680, lineHeight: 1.5 }}>Stock, ledger, purchase, sales and control reports from the same postings as your books. Download any of them as Excel, CSV or PDF.</div>
        {costs && <button className="btn btn-secondary" onClick={exportPack} disabled={!!busy}><Icon name="download" size={16} />{busy === 'pack' ? 'Building the pack…' : 'Month-end pack (Excel)'}</button>}
      </div>

      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(220px,260px) minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
        <div className="card hide-sm" style={{ padding: 8 }}>
          {GROUPS.map((g) => (
            <div key={g} style={{ marginBottom: 6 }}>
              <div className="mini-label" style={{ padding: '10px 10px 4px' }}>{g}</div>
              {REPORTS.filter((r) => r.group === g).map((r) => {
                const off = r.needsCosts && !costs;
                return (
                  <button key={r.id} onClick={() => pick(r.id)} className="nav-item" title={off ? 'Needs the See margins permission' : r.blurb}
                    style={{ fontSize: 13.5, padding: '7px 10px', width: '100%', background: id === r.id ? '#F0F7FF' : undefined, color: off ? '#9CA3AF' : id === r.id ? '#0072F5' : undefined, fontWeight: id === r.id ? 600 : 500 }}>
                    {r.title}
                  </button>
                );
              })}
            </div>
          ))}
        </div>
        <div className="show-sm">
          <select className="input" value={id} onChange={(e) => pick(e.target.value)} aria-label="Report">
            {GROUPS.map((g) => <optgroup key={g} label={g}>{REPORTS.filter((r) => r.group === g).map((r) => <option key={r.id} value={r.id} disabled={r.needsCosts && !costs}>{r.title}</option>)}</optgroup>)}
          </select>
        </div>

        <div className="card" style={{ overflow: 'hidden', minWidth: 0 }}>
          <div className="card-pad" style={{ borderBottom: '1px solid #F3F4F6' }}>
            <div className="row m-wrap" style={{ justifyContent: 'space-between', gap: 10, alignItems: 'flex-start' }}>
              <div style={{ minWidth: 0, flex: '1 1 280px' }}>
                <Label>{def.group}</Label>
                <div style={{ fontSize: 18, fontWeight: 600, marginTop: 4 }}>{def.title}</div>
                <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 4 }}>{def.blurb}</div>
              </div>
              <div className="row" style={{ gap: 6, flex: 'none' }}>
                <button className="btn btn-primary btn-sm" onClick={() => exportAs('xlsx')} disabled={!!busy || blocked}><Icon name="download" size={14} color="#fff" />{busy === 'xlsx' ? 'Excel…' : 'Excel'}</button>
                <button className="btn btn-secondary btn-sm" onClick={() => exportAs('csv')} disabled={!!busy || blocked}>CSV</button>
                <button className="btn btn-secondary btn-sm" onClick={() => exportAs('pdf')} disabled={!!busy || blocked}>{busy === 'pdf' ? 'PDF…' : 'PDF'}</button>
              </div>
            </div>
            <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 10, marginTop: 14 }}>
              {def.period === 'range' && (
                <div className="stack" style={{ gap: 4, fontSize: 12, color: '#6B7280' }}>Period
                  <PeriodPicker value={range} onChange={setRange} presets={['mtd', 'lm', 'qtd', 'lq', 'ytd', 'ly', 'l12']} />
                </div>
              )}
              {def.period === 'asAt' && (
                <label className="stack" style={{ gap: 4, fontSize: 12, color: '#6B7280' }}>As at
                  <input className="input input-sm" type="date" value={range.to} max={today} onChange={(e) => e.target.value && setRange({ from: range.from <= e.target.value ? range.from : e.target.value, to: e.target.value, preset: null })} />
                </label>
              )}
              {def.location && inv.locations.length > 1 && (
                <label className="stack" style={{ gap: 4, fontSize: 12, color: '#6B7280' }}>Branch
                  <select className="input input-sm" value={loc} onChange={(e) => setLoc(e.target.value)}>
                    <option value="">All branches</option>{inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                  </select>
                </label>
              )}
              {def.item && (
                <label className="stack" style={{ gap: 4, fontSize: 12, color: '#6B7280' }}>Item
                  <select className="input input-sm" value={item} onChange={(e) => setItem(e.target.value)}>
                    <option value="">All items</option>{itemsSorted.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                  </select>
                </label>
              )}
              {def.accounts && (
                <label className="stack" style={{ gap: 4, fontSize: 12, color: '#6B7280' }}>Accounts
                  <select className="input input-sm" value={acctSel} onChange={(e) => setAcctSel(e.target.value)}>
                    <option value="">Inventory accounts</option>
                    <option value="*">Every account Counta posts to</option>
                    {usedAccts.map((a) => <option key={a.code} value={a.code}>{a.code} {a.name}</option>)}
                  </select>
                </label>
              )}
            </div>
          </div>

          {blocked ? (
            <div className="card-pad"><Alert kind="yellow" icon="shield">This report shows costs. Ask the owner for the See margins permission.</Alert></div>
          ) : def.source === 'rpc' && q.isLoading ? (
            <div style={{ display: 'grid', placeItems: 'center', minHeight: 220 }}><Spinner /></div>
          ) : def.source === 'rpc' && q.error ? (
            <div className="card-pad"><Alert kind="red" icon="alert">{(q.error as Error).message}</Alert></div>
          ) : (
            <>
              {extraLines(def, q.data).map((l) => <div key={l} className="card-pad" style={{ paddingTop: 12, paddingBottom: 0 }}><Alert kind={/agrees|carrying/.test(l) ? (/allowance/.test(l) ? 'blue' : 'green') : 'yellow'} icon={/agrees/.test(l) ? 'check' : 'info'}>{l}</Alert></div>)}
              <div className="row" style={{ justifyContent: 'space-between', padding: '12px 20px 0', fontSize: 12 }}>
                <span className="muted">{rows.length.toLocaleString('en-NG')} row{rows.length === 1 ? '' : 's'}{rows.length > shown.length ? ` · showing the first ${shown.length}; downloads include every row` : ''}{q.data?.truncated ? ' · capped at 50,000 rows, narrow the period' : ''}</span>
                {!costs && def.cols.some((c) => c.cost) && <span className="faint">Cost columns hidden for your role</span>}
              </div>
              <div style={{ overflow: 'auto', maxHeight: 560, margin: '8px 0 0' }}>
                {rows.length ? (
                  <table className="mini-table report-table">
                    <thead><tr>{cols.map((c) => <th key={c.key} className={c.type && c.type !== 'text' && c.type !== 'date' ? 'right' : ''}>{c.label}</th>)}</tr></thead>
                    <tbody>
                      {shown.map((r, i) => (
                        <tr key={i} className={String(r.type || r.memo || '').match(/brought forward|Opening balance/) ? 'sub' : ''}>
                          {cols.map((c) => <td key={c.key} className={c.type && c.type !== 'text' && c.type !== 'date' ? 'right num' : ''} style={{ color: (c.type === 'money' || c.type === 'qty') && Number(r[c.key]) < 0 ? '#DC2626' : undefined }}>{fmt(r[c.key], c.type)}</td>)}
                        </tr>
                      ))}
                    </tbody>
                    {totals.length > 0 && (
                      <tfoot><tr>{cols.map((c, i) => { const t = totals.find(([k]) => k === c.key); return <td key={c.key} className={t ? 'right num' : ''}>{i === 0 ? 'Total' : t ? fmt(t[1], c.type) : ''}</td>; })}</tr></tfoot>
                    )}
                  </table>
                ) : <div className="muted" style={{ padding: '28px 20px', fontSize: 14 }}>Nothing for these filters. Try a longer period or all branches.</div>}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
