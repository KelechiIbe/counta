import { useMemo, useRef, useState } from 'react';
import { rpc } from '../lib/supabase';
import { cellText, detectHeader, parseDate, parseNum, pickSheet, readWorkbook, type Cell, type SheetData } from '../lib/sheet';
import { HISTORY_FIELDS, VENDOR_FIELDS, type SimpleField } from '../lib/migrate';
import { downloadBlob, reportCsv, safeName } from '../lib/exporters';
import { addDays, fmtDay, num, uuid } from '../lib/format';
import { Icon } from './Icon';
import { Alert, Field, Spinner } from './ui';

type Kind = 'vendors' | 'history';
const norm = (h: string) => String(h ?? '').toLowerCase().replace(/[*_\-.:#()/\\₦[\]]/g, ' ').replace(/\s+/g, ' ').trim();
const isTotal = (t: string) => /^(grand\s+)?(sub\s*)?totals?\b|^total for\b/i.test(t);

export interface SimpleResult { created: number; updated: number; skipped: { row: number; name: string; reason: string }[]; extra?: string; cutoff?: string }

// Suppliers or past sales from any sheet: pick the file, check which column is which, send it.
export function SimpleImport({ kind, orgId, source, importId, onDone }: { kind: Kind; orgId: string; source: string; importId: string; onDone?: (r: SimpleResult) => void }) {
  const fields: SimpleField[] = kind === 'vendors' ? VENDOR_FIELDS : HISTORY_FIELDS;
  const input = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState('');
  const [sheet, setSheet] = useState<SheetData | null>(null);
  const [headerIdx, setHeaderIdx] = useState(0);
  const [map, setMap] = useState<Record<string, number>>({});
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<SimpleResult | null>(null);
  const headers = useMemo(() => (sheet ? (sheet.rows[headerIdx] || []).map(cellText) : []), [sheet, headerIdx]);

  function match(h: string[]) {
    const out: Record<string, number> = {}; const used = new Set<number>();
    for (const f of fields) {
      let best = -1; let score = 0;
      h.forEach((raw, i) => {
        if (used.has(i)) return;
        const x = norm(raw);
        const s = f.syn.reduce((a, syn) => Math.max(a, x === syn ? 100 : syn.length > 3 && x.includes(syn) ? syn.length : 0), 0);
        if (s > score) { score = s; best = i; }
      });
      if (best >= 0) { out[f.key] = best; used.add(best); }
    }
    return out;
  }
  async function read(f: File) {
    setErr(null); setResult(null);
    try {
      const all = await readWorkbook(f);
      if (!all.length) throw new Error('That file has no rows.');
      // The header is the row whose cells name the most of this importer's fields; item-list detection misreads supplier lists.
      const s = all[pickSheet(all)];
      let h = detectHeader(s.rows); let best = 0;
      for (let i = 0; i < Math.min(20, s.rows.length); i++) {
        const n = Object.keys(match((s.rows[i] || []).map(cellText))).length;
        if (n > best) { best = n; h = i; }
      }
      setFile(f.name); setSheet(s); setHeaderIdx(h); setMap(match((s.rows[h] || []).map(cellText)));
    } catch (e: any) { setErr(e.message || 'Could not read that file.'); }
  }

  // Rows to send. Past-sales reports often put each product as a heading row above its sales lines.
  const rows = useMemo(() => {
    if (!sheet) return [];
    const out: Record<string, unknown>[] = []; let heading: string | null = null;
    const get = (r: Cell[], k: string) => (map[k] != null ? r[map[k]] ?? null : null);
    for (let i = headerIdx + 1; i < sheet.rows.length; i++) {
      const r = sheet.rows[i]; const texts = r.map(cellText); const filled = texts.filter(Boolean);
      if (!filled.length || isTotal(filled[0])) continue;
      if (kind === 'history' && filled.length === 1 && isNaN(Number(filled[0].replace(/,/g, '')))) { heading = filled[0]; continue; }
      const row: Record<string, unknown> = { row: sheet.rowNo?.[i] ?? i + 1 };
      if (kind === 'vendors') {
        for (const f of fields) { const v = get(r, f.key); if (v != null && cellText(v)) row[f.key] = cellText(v); }
        if (!row.name) continue;
      } else {
        const qty = parseNum(get(r, 'qty'));
        if (qty == null || qty <= 0) continue;
        row.qty = qty;
        const rev = parseNum(get(r, 'revenue')); if (rev != null) row.revenue = rev;
        const d = parseDate(get(r, 'date')); if (d) row.date = d;
        for (const k of ['item', 'sku', 'barcode', 'location']) { const v = get(r, k); if (v != null && cellText(v)) row[k] = cellText(v); }
        if (!row.item && !row.sku && !row.barcode && heading) row.item = heading;
        if (!row.item && !row.sku && !row.barcode) continue;
      }
      out.push(row);
    }
    return out;
  }, [sheet, headerIdx, map, kind, fields]);
  const needsPeriod = kind === 'history' && map.date == null;
  const ready = rows.length > 0 && fields.filter((f) => f.required).every((f) => map[f.key] != null) && (kind === 'vendors' || map.item != null || map.sku != null || map.barcode != null || rows.some((r) => r.item))
    && (!needsPeriod || (from && to && from <= to));

  async function send() {
    setBusy(true); setErr(null);
    const total: SimpleResult = { created: 0, updated: 0, skipped: [] };
    let firstDay = ''; let lastDay = ''; let items = 0;
    try {
      const size = kind === 'vendors' ? 1000 : 2000;
      for (let i = 0; i < rows.length; i += size) {
        const part = rows.slice(i, i + size);
        if (kind === 'vendors') {
          const r = await rpc<any>('import_vendors', { p_org: orgId, p_rows: part, p_options: { mode: 'update', import_id: importId, source, file_name: file } });
          total.created += r.created; total.updated += r.updated; total.skipped.push(...(r.skipped || []));
        } else {
          const r = await rpc<any>('import_sales_history', { p_org: orgId, p_rows: part, p_options: { import_id: importId, source, file_name: file, period_from: from || null, period_to: to || null } });
          total.created += r.imported; total.skipped.push(...(r.skipped || [])); items = Math.max(items, r.items || 0);
          if (r.from && (!firstDay || r.from < firstDay)) firstDay = r.from; if (r.to && r.to > lastDay) lastDay = r.to;
          if (r.cutoff) total.cutoff = r.cutoff;
        }
      }
      if (kind === 'history' && firstDay) total.extra = `Sales from ${fmtDay(firstDay)} to ${fmtDay(lastDay)}`;
      setResult(total); onDone?.(total);
    } catch (e: any) { setErr(e.message || 'The upload stopped.'); }
    setBusy(false);
  }

  if (result) {
    return (
      <div className="stack" style={{ gap: 10 }}>
        {result.created + result.updated === 0 ? (
          <Alert kind="yellow" icon="alert">
            Nothing came in from {file}.{kind === 'history' && result.cutoff && result.skipped.some((x) => x.reason.startsWith('Counta already records'))
              ? ` Counta already records your sales from ${fmtDay(addDays(result.cutoff, 1))}, and past sales only fill the time before that. Export the months before it.` : ' The list below says why for each row.'}
          </Alert>
        ) : (
          <Alert kind="green" icon="check">
            {kind === 'vendors' ? `${result.created} supplier${result.created === 1 ? '' : 's'} added${result.updated ? `, ${result.updated} updated` : ''}.` : `${num(result.created)} sales line${result.created === 1 ? '' : 's'} brought in. ${result.extra || ''}`}
          </Alert>
        )}
        {result.skipped.length > 0 && (
          <div className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}>
            <span className="muted">{result.skipped.length} row{result.skipped.length === 1 ? '' : 's'} left out{result.skipped[0] ? `, e.g. row ${result.skipped[0].row}: ${result.skipped[0].reason}` : ''}</span>
            <button className="btn btn-ghost btn-xs" onClick={() => downloadBlob(reportCsv([{ key: 'row', label: 'Row' }, { key: 'name', label: 'Name' }, { key: 'reason', label: 'Reason' }], result.skipped), `${safeName(file)} – rows left out.csv`)}><Icon name="download" size={13} />List</button>
          </div>
        )}
        <button className="btn btn-ghost btn-xs" style={{ alignSelf: 'flex-start', paddingLeft: 0 }} onClick={() => { setResult(null); setSheet(null); }}>Upload another file</button>
      </div>
    );
  }
  return (
    <div className="stack" style={{ gap: 10 }}>
      {!sheet ? (
        <button className="btn btn-secondary" style={{ alignSelf: 'flex-start' }} onClick={() => input.current?.click()}><Icon name="upload" size={15} />Choose a file</button>
      ) : (
        <>
          <div className="row m-wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
            <span style={{ fontSize: 13, fontWeight: 600 }}><Icon name="file" size={14} style={{ verticalAlign: -2, marginRight: 4 }} />{file} · {num(rows.length)} row{rows.length === 1 ? '' : 's'}</span>
            <button className="btn btn-ghost btn-xs" onClick={() => input.current?.click()}>Choose another</button>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 8 }}>
            <Field label="Column names are on">
              <select className="input input-sm" value={headerIdx} onChange={(e) => { const h = Number(e.target.value); setHeaderIdx(h); setMap(match((sheet.rows[h] || []).map(cellText))); }}>
                {sheet.rows.slice(0, 20).map((r, i) => <option key={i} value={i}>Row {sheet.rowNo?.[i] ?? i + 1}: {r.map(cellText).filter(Boolean).slice(0, 3).join(' · ').slice(0, 40)}</option>)}
              </select>
            </Field>
            {fields.map((f) => (
              <Field key={f.key} label={f.label + (f.required ? ' *' : '')}>
                <select className="input input-sm" value={map[f.key] ?? ''} onChange={(e) => setMap({ ...map, [f.key]: e.target.value === '' ? (undefined as any) : Number(e.target.value) })}>
                  <option value="">Not in this file</option>
                  {headers.map((h, i) => h ? <option key={i} value={i}>{h}</option> : null)}
                </select>
              </Field>
            ))}
          </div>
          {needsPeriod && (
            <div className="stack" style={{ gap: 6 }}>
              <div className="ink3" style={{ fontSize: 13 }}>This file has no dates, so it reads as totals for a period. Which period does it cover?</div>
              <div className="row" style={{ gap: 8 }}>
                <input className="input input-sm" type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="Period from" style={{ maxWidth: 170 }} />
                <span className="muted">to</span>
                <input className="input input-sm" type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="Period to" style={{ maxWidth: 170 }} />
              </div>
            </div>
          )}
          {rows.length > 0 && (
            <div style={{ overflow: 'auto', maxHeight: 180, border: '1px solid #EEF0F3', borderRadius: 10 }}>
              <table className="mini-table" style={{ width: '100%' }}>
                <thead><tr><th>Row</th>{fields.filter((f) => map[f.key] != null || (f.key === 'item' && rows.some((r) => r.item))).map((f) => <th key={f.key}>{f.label}</th>)}</tr></thead>
                <tbody>{rows.slice(0, 6).map((r, i) => <tr key={i}><td className="faint">{String(r.row)}</td>{fields.filter((f) => map[f.key] != null || (f.key === 'item' && rows.some((x) => x.item))).map((f) => <td key={f.key}>{String(r[f.key] ?? '')}</td>)}</tr>)}</tbody>
              </table>
            </div>
          )}
          <button className="btn btn-primary" style={{ alignSelf: 'flex-start' }} disabled={!ready || busy} onClick={send}>
            {busy ? <><Spinner small />Sending…</> : kind === 'vendors' ? `Add ${num(rows.length)} supplier${rows.length === 1 ? '' : 's'}` : `Bring in ${num(rows.length)} sales line${rows.length === 1 ? '' : 's'}`}
          </button>
        </>
      )}
      <input ref={input} type="file" accept=".xlsx,.xls,.xlsm,.csv,.ods" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) read(f); }} />
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}

export const newImportId = () => uuid();
