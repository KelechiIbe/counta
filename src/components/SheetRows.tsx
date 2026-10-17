// Reads any Excel or CSV export, finds the sheet and header row that hold the fields asked for, lets the person check
// which column is which, and hands back the rows. The caller decides what to do with them.
import { useMemo, useRef, useState } from 'react';
import { cellText, readWorkbook, type Cell, type SheetData } from '../lib/sheet';
import { num } from '../lib/format';
import { Icon } from './Icon';
import { Alert, Field, Spinner } from './ui';

export interface SheetField { key: string; label: string; syn: string[]; required?: boolean; hint?: string }
const norm = (h: string) => String(h ?? '').toLowerCase().replace(/[*_\-.:#()/\\₦[\]]/g, ' ').replace(/\s+/g, ' ').trim();
const isTotal = (t: string) => /^(grand\s+)?(sub\s*)?totals?\b|^total for\b|^total\s/i.test(t.trim());
// Sheets a template carries for reference (examples, instructions, lists behind the dropdowns). They are read only
// when nothing else in the file holds the fields.
const REFERENCE = /example|sample|guide|instruction|how to|read ?me|^lists?$|^banks?$|^bank (list|codes?)$|^codes?$|^lookups?$|^settings$/i;

// Which columns of a header row are which fields: an exact heading wins, and among exact headings the synonym listed
// first ("Open balance" before "Amount"); otherwise the longest synonym found inside the heading.
export function matchFields(fields: SheetField[], h: string[]): Record<string, number> {
  const out: Record<string, number> = {}; const used = new Set<number>();
  for (const f of fields) {
    let best = -1; let score = 0;
    h.forEach((raw, i) => {
      if (used.has(i)) return;
      const x = norm(raw);
      if (!x) return;
      const s = f.syn.reduce((a, syn, k) => Math.max(a, x === syn ? 1000 - k : syn.length > 3 && x.includes(syn) ? syn.length : 0), 0);
      if (s > score) { score = s; best = i; }
    });
    if (best >= 0) { out[f.key] = best; used.add(best); }
  }
  return out;
}

// The header row of a sheet: the row in the first 25 whose cells name the most fields.
export function headerOf(fields: SheetField[], s: SheetData): { h: number; found: number; required: number } {
  let h = 0; let best = -1; let req = 0;
  for (let i = 0; i < Math.min(25, s.rows.length); i++) {
    const m = matchFields(fields, (s.rows[i] || []).map(cellText));
    const n = Object.keys(m).length;
    if (n > best) { best = n; h = i; req = fields.filter((f) => f.required && m[f.key] != null).length; }
  }
  return { h, found: Math.max(best, 0), required: req };
}

// The sheet that holds the rows: the one whose header names the most required fields, then the most fields, then has
// the most rows under it. A workbook's reference sheets (a bank list of 500 rows, say) never win over the sheet
// people fill in.
export function chooseSheet(fields: SheetField[], sheets: SheetData[]): number {
  const score = (s: SheetData) => {
    const { h, found, required } = headerOf(fields, s);
    const rows = s.rows.slice(h + 1).filter((r) => r.filter((c) => c != null && c !== '').length >= 2).length;
    return required * 1e6 + found * 1e4 + Math.min(rows, 9999);
  };
  const pick = (only: boolean) => {
    let best = -1; let bestScore = -1;
    sheets.forEach((s, i) => {
      if (only && REFERENCE.test(s.name.trim())) return;
      const v = score(s);
      if (v > bestScore) { bestScore = v; best = i; }
    });
    return best;
  };
  const i = pick(true);
  return i >= 0 ? i : Math.max(pick(false), 0);
}

export function SheetRows({ fields, onRows, action, need, note }: {
  fields: SheetField[]; action: (n: number) => string; note?: string;
  // At least one of these keys must be mapped (beyond the required ones), e.g. debit/credit or balance.
  need?: string[][];
  onRows: (rows: (Record<string, Cell> & { _row: number })[], file: string) => Promise<void>;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState('');
  const [sheets, setSheets] = useState<SheetData[]>([]);
  const [sheet, setSheet] = useState<SheetData | null>(null);
  const [headerIdx, setHeaderIdx] = useState(0);
  const [map, setMap] = useState<Record<string, number | undefined>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const headers = useMemo(() => (sheet ? (sheet.rows[headerIdx] || []).map(cellText) : []), [sheet, headerIdx]);
  const match = (h: string[]) => matchFields(fields, h);
  // Reports often leave the first column's heading empty (QuickBooks puts account names there). A required text field
  // that found no heading takes the first unnamed column that holds text.
  function fillBlank(s: SheetData, h: number, m: Record<string, number>) {
    const head = (s.rows[h] || []).map(cellText);
    const taken = new Set(Object.values(m));
    for (const f of fields.filter((x) => x.required && m[x.key] == null)) {
      const width = Math.max(head.length, ...s.rows.slice(h + 1, h + 30).map((r) => r.length));
      for (let c = 0; c < width; c++) {
        if (taken.has(c) || (head[c] || '').trim()) continue;
        const texts = s.rows.slice(h + 1, h + 30).map((r) => cellText(r[c] ?? null)).filter(Boolean);
        if (texts.length >= 2 && texts.filter((t) => isNaN(Number(t.replace(/,/g, '')))).length >= texts.length * 0.6) { m[f.key] = c; taken.add(c); break; }
      }
    }
    return m;
  }
  function open(s: SheetData) {
    const { h } = headerOf(fields, s);
    setSheet(s); setHeaderIdx(h); setMap(fillBlank(s, h, match((s.rows[h] || []).map(cellText))));
  }
  async function read(f: File) {
    setErr(null);
    try {
      const all = await readWorkbook(f);
      if (!all.length) throw new Error('That file has no rows.');
      setFile(f.name); setSheets(all);
      open(all[chooseSheet(fields, all)]);
    } catch (e: any) { setErr(e.message || 'Could not read that file.'); }
  }
  const rows = useMemo(() => {
    if (!sheet) return [];
    const out: (Record<string, Cell> & { _row: number })[] = [];
    for (let i = headerIdx + 1; i < sheet.rows.length; i++) {
      const r = sheet.rows[i];
      const filled = r.map(cellText).filter(Boolean);
      if (!filled.length || isTotal(filled[0])) continue;
      const row: Record<string, Cell> & { _row: number } = { _row: sheet.rowNo?.[i] ?? i + 1 };
      let any = false;
      for (const f of fields) { const c = map[f.key]; if (c != null) { row[f.key] = r[c] ?? null; if (cellText(r[c] ?? null)) any = true; } }
      if (any) out.push(row);
    }
    return out;
  }, [sheet, headerIdx, map, fields]);
  const ready = rows.length > 0 && fields.filter((f) => f.required).every((f) => map[f.key] != null) && (!need || need.some((set) => set.every((k) => map[k] != null)));
  const shownFields = fields.filter((f) => map[f.key] != null);

  async function send() {
    setBusy(true); setErr(null);
    try { await onRows(rows, file); setSheet(null); setSheets([]); setFile(''); }
    catch (e: any) { setErr(e.message || 'The upload stopped.'); }
    setBusy(false);
  }
  return (
    <div className="stack" style={{ gap: 10 }}>
      {!sheet ? (
        <div className="row wrap">
          <button className="btn btn-secondary" onClick={() => input.current?.click()}><Icon name="upload" size={15} />Choose a file</button>
          {note && <span className="faint" style={{ fontSize: 12 }}>{note}</span>}
        </div>
      ) : (
        <>
          <div className="row m-wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
            <span style={{ fontSize: 13, fontWeight: 600 }}><Icon name="file" size={14} style={{ verticalAlign: -2, marginRight: 4 }} />{file} · {num(rows.length)} row{rows.length === 1 ? '' : 's'}</span>
            <span className="row"><button className="btn btn-ghost btn-xs" onClick={() => input.current?.click()}>Choose another</button><button className="btn btn-ghost btn-xs" onClick={() => { setSheet(null); setSheets([]); setFile(''); }}>Cancel</button></span>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 8 }}>
            {sheets.length > 1 && (
              <Field label="Sheet">
                <select className="input input-sm" value={sheets.indexOf(sheet)} onChange={(e) => open(sheets[Number(e.target.value)])} aria-label="Sheet">
                  {sheets.map((s, i) => <option key={i} value={i}>{s.name}</option>)}
                </select>
              </Field>
            )}
            <Field label="Column names are on">
              <select className="input input-sm" value={headerIdx} onChange={(e) => { const h = Number(e.target.value); setHeaderIdx(h); setMap(fillBlank(sheet, h, match((sheet.rows[h] || []).map(cellText)))); }}>
                {sheet.rows.slice(0, 25).map((r, i) => <option key={i} value={i}>Row {sheet.rowNo?.[i] ?? i + 1}: {r.map(cellText).filter(Boolean).slice(0, 3).join(' · ').slice(0, 40)}</option>)}
              </select>
            </Field>
            {fields.map((f) => (
              <Field key={f.key} label={f.label + (f.required ? ' *' : '')} hint={f.hint}>
                <select className="input input-sm" value={map[f.key] ?? ''} onChange={(e) => setMap({ ...map, [f.key]: e.target.value === '' ? undefined : Number(e.target.value) })}>
                  <option value="">Not in this file</option>
                  {Array.from({ length: Math.max(headers.length, ...sheet.rows.slice(headerIdx + 1, headerIdx + 10).map((r) => r.length)) }, (_, i) => (
                    <option key={i} value={i}>{headers[i] || `Column ${String.fromCharCode(65 + (i % 26))} (no heading)`}</option>
                  ))}
                </select>
              </Field>
            ))}
          </div>
          {rows.length > 0 && shownFields.length > 0 && (
            <div style={{ overflow: 'auto', maxHeight: 200, border: '1px solid #EEF0F3', borderRadius: 10 }}>
              <table className="mini-table" style={{ width: '100%' }}>
                <thead><tr><th>Row</th>{shownFields.map((f) => <th key={f.key}>{f.label}</th>)}</tr></thead>
                <tbody>{rows.slice(0, 6).map((r, i) => <tr key={i}><td className="faint">{r._row}</td>{shownFields.map((f) => <td key={f.key}>{cellText(r[f.key] ?? null)}</td>)}</tr>)}</tbody>
              </table>
            </div>
          )}
          {!ready && rows.length > 0 && <div className="faint" style={{ fontSize: 12 }}>Choose the columns marked * {need ? `and ${need.map((s) => s.map((k) => fields.find((f) => f.key === k)?.label).join(' and ')).join(', or ')}` : ''}.</div>}
          <button className="btn btn-primary" style={{ alignSelf: 'flex-start' }} disabled={!ready || busy} onClick={send}>{busy ? <><Spinner small />Sending…</> : action(rows.length)}</button>
        </>
      )}
      <input ref={input} type="file" accept=".xlsx,.xls,.xlsm,.csv,.ods" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) read(f); }} />
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
    </div>
  );
}
