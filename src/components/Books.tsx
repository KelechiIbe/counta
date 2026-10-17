// Shared pieces for the books: a period bar, an export menu, and a table that shows any accounting report the way an
// accountant reads it (headings, subtotals with rules, totals with double rules, negatives in brackets).
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useInventory, useSession, useToast } from '../state/session';
import { Icon } from './Icon';
import { Alert, Empty, MenuButton, SkeletonRows, type MenuItem } from './ui';
import { accountsCsv, accountsPdf, accountsXlsx, downloadBlob, safeName, type AccountsSheet, type ReportMeta, type StyledRow } from '../lib/exporters';
import type { RCol } from '../lib/reports';
import { lastMonthEnd, monthStart, today, useReport, yearStart } from '../lib/api';
import { areport, periodLabel, prepRows, type ADef } from '../lib/accounting';
import { addDays, fmtDay } from '../lib/format';

export function acc(v: unknown, dp = 2): string {
  if (v == null || v === '') return '';
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  if (Math.abs(n) < 0.005) return '–';
  const s = Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: dp, maximumFractionDigits: dp });
  return n < 0 ? `(${s})` : s;
}

export function cellText(v: unknown, t?: string): string {
  if (v == null || v === '') return '';
  if (t === 'money') return acc(v);
  if (t === 'date' && typeof v === 'string') return fmtDay(v.slice(0, 10));
  if (t === 'pct') return Number(v).toFixed(1) + '%';
  if (t === 'qty' || t === 'num' || t === 'int') return Number(v).toLocaleString('en-NG', { maximumFractionDigits: t === 'int' ? 0 : 2 });
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  return String(v);
}

// ---------------------------------------------------------------- period
export type Period = { from: string; to: string };
export function presets(fy = 1): { id: string; label: string; p: Period }[] {
  const t = today();
  const lme = lastMonthEnd(t);
  const q = Math.floor((Number(t.slice(5, 7)) - 1) / 3) * 3 + 1;
  const ys = yearStart(t, fy);
  const lys = yearStart(addDays(ys, -1), fy);
  return [
    { id: 'mtd', label: 'This month', p: { from: monthStart(t), to: t } },
    { id: 'lm', label: 'Last month', p: { from: monthStart(lme), to: lme } },
    { id: 'qtd', label: 'This quarter', p: { from: `${t.slice(0, 4)}-${String(q).padStart(2, '0')}-01`, to: t } },
    { id: 'ytd', label: 'Year to date', p: { from: ys, to: t } },
    { id: 'ly', label: 'Last year', p: { from: lys, to: addDays(ys, -1) } },
  ];
}

export function PeriodBar({ value, onChange, asAt, extra }: { value: Period; onChange: (p: Period) => void; asAt?: boolean; extra?: ReactNode }) {
  const { data: inv } = useInventory();
  const list = presets(inv?.org.fiscal_year_start || 1);
  const on = list.find((x) => x.p.from === value.from && x.p.to === value.to)?.id;
  return (
    <div className="row wrap" style={{ gap: 8 }}>
      {!asAt && list.map((x) => <button key={x.id} className={'pill' + (on === x.id ? ' on' : '')} onClick={() => onChange(x.p)}>{x.label}</button>)}
      {!asAt && <input className="input input-sm" type="date" value={value.from} max={value.to} onChange={(e) => e.target.value && onChange({ ...value, from: e.target.value })} style={{ width: 150 }} aria-label="From" />}
      {!asAt && <span className="faint">to</span>}
      {asAt && <span className="muted" style={{ fontSize: 13 }}>As at</span>}
      <input className="input input-sm" type="date" value={value.to} min={asAt ? undefined : value.from} onChange={(e) => e.target.value && onChange({ ...value, to: e.target.value })} style={{ width: 150 }} aria-label={asAt ? 'As at' : 'To'} />
      {extra}
    </div>
  );
}

// ---------------------------------------------------------------- export
export function useMeta() {
  const { data: inv } = useInventory();
  const { session } = useSession();
  return (title: string, period: string, note?: string): ReportMeta => ({
    org: inv?.org.name || 'Counta', title, period, branch: 'All branches', note,
    by: inv?.me.display_name || session?.user.email || 'Counta', generated: new Date().toLocaleString('en-GB', { timeZone: 'Africa/Lagos', dateStyle: 'medium', timeStyle: 'short' }),
  });
}

export type ExportExtra = { key: string; label: string; hint?: string; run: () => Promise<void> };
export function ExportMenu({ sheets, name, disabled, cover, extra, formats = ['xlsx', 'pdf', 'csv'], label = 'Export' }: {
  sheets: () => AccountsSheet[] | Promise<AccountsSheet[]>; name: string; disabled?: boolean; cover?: ReportMeta;
  extra?: ExportExtra[]; formats?: ('xlsx' | 'pdf' | 'csv')[]; label?: string;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const toast = useToast();
  async function run(key: string, fn: () => Promise<void>) {
    setBusy(key);
    try { await fn(); } catch (e) { toast((e as Error).message || 'Could not make the file.', 'err'); }
    setBusy(null);
  }
  const go = (kind: 'xlsx' | 'pdf' | 'csv') => run(kind, async () => {
    const s = await sheets();
    const blob = kind === 'xlsx' ? await accountsXlsx(s, cover) : kind === 'pdf' ? await accountsPdf(s, cover) : accountsCsv(s[0].cols, s[0].rows);
    downloadBlob(blob, `${safeName(name)}.${kind}`);
  });
  const names = { xlsx: 'Excel workbook', pdf: 'PDF', csv: 'CSV' } as const;
  const items: MenuItem[] = [
    ...(extra || []).map((x) => ({ key: x.key, label: x.label, hint: x.hint, onClick: () => run(x.key, x.run) })),
    ...formats.map((k) => ({ key: k, label: names[k], onClick: () => go(k) })),
  ];
  return <MenuButton label={label} icon="download" items={items} disabled={disabled} busy={busy ? 'Preparing…' : undefined} />;
}

// ---------------------------------------------------------------- table
function useNarrow(q = '(max-width: 700px)') {
  const [m, setM] = useState(() => typeof window !== 'undefined' && window.matchMedia(q).matches);
  useEffect(() => {
    const mq = window.matchMedia(q);
    const on = () => setM(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, [q]);
  return m;
}

export function ReportTable({ cols, rows, onRow, costs = true, dense }: { cols: RCol[]; rows: StyledRow[]; onRow?: (r: StyledRow) => void; costs?: boolean; dense?: boolean }) {
  const styled = rows.some((r) => r._style);
  const narrow = useNarrow();
  // On a phone a statement keeps its line and amounts; the note references stay in the exports and on wider screens.
  const shown = cols.filter((c) => (costs || !c.cost) && !(narrow && styled && c.key === 'note'));
  const totals = !styled && shown.some((c) => c.total) && rows.length > 1;
  const tmpl = shown.map((c, i) => (i === 0 ? (styled ? (narrow ? 'minmax(110px,2fr)' : 'minmax(260px,2.4fr)') : 'minmax(160px,1.6fr)')
    : c.type === 'money' ? (narrow && styled ? 'minmax(min-content,1fr)' : 'minmax(110px,1fr)') : c.type === 'date' ? '110px' : c.type && c.type !== 'text' ? 'minmax(70px,.6fr)' : 'minmax(110px,1fr)')).join(' ');
  const minW = narrow && styled ? 0 : Math.max(640, shown.length * 120);
  const right = (c: RCol) => (c.type && c.type !== 'text' && c.type !== 'date' ? 'right' : 'left');
  const tight = narrow && styled ? { padding: '10px 12px', columnGap: 8, fontSize: 12 } : {};
  return (
    <div className="tbl">
      <div className="tr head shade th" style={{ gridTemplateColumns: tmpl, minWidth: minW, ...tight }}>
        {shown.map((c) => <span key={c.key} style={{ textAlign: right(c) as any }}>{c.label}</span>)}
      </div>
      {rows.map((r, i) => {
        const st = r._style || 'line';
        if (st === 'text') return <div key={i} className="tr" style={{ gridTemplateColumns: '1fr', minWidth: minW, color: '#374151', lineHeight: 1.55, ...tight }}>{String(r[shown[0].key] ?? '')}</div>;
        const bold = st === 'heading' || st === 'subtotal' || st === 'total' || st === 'subheading';
        return (
          <div key={i} className={'tr' + (onRow ? ' click' : '')} onClick={onRow ? () => onRow(r) : undefined}
            style={{ gridTemplateColumns: tmpl, minWidth: minW, padding: dense ? '7px 20px' : undefined, ...tight, fontWeight: bold ? 600 : 400, background: st === 'heading' ? '#FAFAFA' : undefined,
              color: st === 'warning' ? '#DC2626' : st === 'subheading' ? '#4B5563' : undefined, fontStyle: st === 'subheading' ? 'italic' : undefined }}>
            {shown.map((c, j) => (
              <span key={c.key} className={c.type === 'money' ? 'num' : undefined}
                style={{ textAlign: right(c) as any, paddingLeft: j === 0 ? Number(r._indent || 0) * (narrow ? 10 : 18) : undefined, minWidth: 0,
                  overflowWrap: c.type === 'money' ? undefined : 'anywhere', whiteSpace: c.type === 'money' ? 'nowrap' : undefined,
                  borderTop: c.type === 'money' && (st === 'subtotal' || st === 'total') && r[c.key] != null ? '1px solid #111827' : undefined,
                  borderBottom: c.type === 'money' && st === 'total' && r[c.key] != null ? '3px double #111827' : undefined, paddingTop: st === 'total' || st === 'subtotal' ? 4 : undefined }}>
                {cellText(r[c.key], c.type)}
              </span>
            ))}
          </div>
        );
      })}
      {totals && (
        <div className="tr" style={{ gridTemplateColumns: tmpl, minWidth: minW, fontWeight: 700, background: '#FAFAFA' }}>
          {shown.map((c, j) => <span key={c.key} className="num" style={{ textAlign: right(c) as any }}>{j === 0 ? 'Total' : c.total ? acc(rows.reduce((a, r) => a + (Number(r[c.key]) || 0), 0)) : ''}</span>)}
        </div>
      )}
    </div>
  );
}

// A whole report: fetch, check, show, export.
export function ReportPanel({ id, period, options = {}, title, actions, onRow, note }: {
  id: string; period: Period; options?: Record<string, unknown>; title?: string; actions?: ReactNode; onRow?: (r: StyledRow) => void; note?: ReactNode;
}) {
  const def: ADef = areport(id);
  const { data: inv } = useInventory();
  const from = def.period === 'asAt' ? null : period.from;
  const q = useReport(id, from, period.to, options);
  const meta = useMeta();
  const rows = prepRows(def, q.data?.rows || []);
  const cols = def.cols(q.data?.extra || {}).filter((c) => inv?.can_see_costs || !c.cost);
  const label = def.period === 'asAt' ? periodLabel(null, period.to) : periodLabel(period.from, period.to);
  const checks = checkLines(id, q.data?.extra || {});
  return (
    <div className="card" style={{ overflow: 'hidden' }}>
      <div className="card-hd">
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 600, fontSize: 15 }}>{title || def.title}</div>
          <div className="faint" style={{ fontSize: 12, marginTop: 2 }}>{label}{q.data?.extra?.org?.framework === 'ifrs_sme' ? ' · IFRS for SMEs' : def.statement ? ' · IFRS' : ''}</div>
        </div>
        <div className="row wrap">
          {actions}
          <ExportMenu name={`${inv?.org.name || 'Counta'} ${def.title} ${period.to}`} disabled={!q.data}
            sheets={() => [{ meta: meta(def.title, label), cols, rows, extra: checks.map((c) => c.text) }]} />
        </div>
      </div>
      {checks.filter((c) => !c.ok).map((c) => <div key={c.text} style={{ padding: '10px 20px 0' }}><Alert kind="red" icon="alert">{c.text}</Alert></div>)}
      {note && <div style={{ padding: '10px 20px 0' }}>{note}</div>}
      {def.statement && q.data && (!q.data.extra?.closed_through || q.data.extra.closed_through < period.to) && (
        <div style={{ padding: '10px 20px 0' }}><Alert kind="grey" icon="info">Draft: the books are open {q.data.extra?.closed_through ? `after ${fmtDay(q.data.extra.closed_through)}` : 'for this period'}, so these figures can still change. Close the month to lock them.</Alert></div>
      )}
      {q.isLoading ? <SkeletonRows n={8} /> : q.error ? <div style={{ padding: 20 }}><Alert kind="yellow" icon="shield">{(q.error as Error).message}</Alert></div>
        : !rows.length ? <div style={{ padding: 20 }}><Empty>Nothing in this period.</Empty></div>
        : <ReportTable cols={cols} rows={rows} onRow={onRow} costs={!!inv?.can_see_costs} />}
      {checks.some((c) => c.ok) && <div className="row wrap" style={{ gap: 12, padding: '12px 20px', borderTop: '1px solid #F3F4F6' }}>
        {checks.filter((c) => c.ok).map((c) => <span key={c.text} className="row" style={{ gap: 6, fontSize: 12, color: '#15803D' }}><Icon name="check" size={13} color="#15803D" />{c.text}</span>)}
      </div>}
    </div>
  );
}

// The arithmetic each report proves, shown under it and printed on the export.
export function checkLines(id: string, x: Record<string, any>): { ok: boolean; text: string }[] {
  const out: { ok: boolean; text: string }[] = [];
  if (id === 'sofp' && x.casts !== undefined) out.push({ ok: !!x.casts, text: x.casts ? 'Assets equal equity and liabilities' : `Does not cast: assets ${acc(x.check?.assets)} against ${acc(x.check?.equity_and_liabilities)}` });
  if (id === 'trial_balance' && x.balances !== undefined) out.push({ ok: !!x.balances, text: x.balances ? `Debits equal credits (${acc(x.total_dr)})` : `Out of balance: ${acc(x.total_dr)} against ${acc(x.total_cr)}` });
  if (id === 'cash_flow' && x.casts !== undefined) out.push({ ok: !!x.casts, text: x.casts ? 'Ends on the cash in the books' : 'Does not agree to the cash in the books' });
  if ((id === 'ar_ledger' || id === 'ap_ledger') && x.control_total !== undefined) {
    const ok = Math.abs(Number(x.subledger_total || 0) + Number(x.unassigned || 0) - Number(x.control_total || 0)) < 0.01;
    out.push({ ok, text: ok ? `Agrees to the ${id === 'ar_ledger' ? 'receivables' : 'payables'} account (${acc(x.control_total)})` : `Differs from the control account by ${acc(Number(x.control_total) - Number(x.subledger_total) - Number(x.unassigned))}` });
    if (Number(x.unassigned)) out.push({ ok: false, text: `${acc(x.unassigned)} in the control account has no ${id === 'ar_ledger' ? 'customer' : 'vendor'} on it` });
  }
  if (id === 'vat_return' && x.due) out.push({ ok: true, text: `File and pay by ${fmtDay(x.due)}` });
  return out;
}
