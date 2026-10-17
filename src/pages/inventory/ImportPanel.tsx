import { useMemo, useRef, useState, type DragEvent } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Drawer, Field, Spinner, XButton, Alert } from '../../components/ui';
import { Icon } from '../../components/Icon';
import { ai, rpc } from '../../lib/supabase';
import { aiStatus } from '../../lib/martina';
import { useInventory, useSession, useToast } from '../../state/session';
import { N, fmtDay, num } from '../../lib/format';
import { acct, usePostingMap } from '../../lib/accounts';
import { INDUSTRIES, ITEM_TYPES, defaultVat, fieldsFor, industryOf, typeSells } from '../../lib/industries';
import {
  CORE_FIELDS, autoMatch, buildRows, cellText, detectHeader, fieldChoices, parseDate, pickSheet, readWorkbook,
  type BuiltRow, type ColMap, type SheetData,
} from '../../lib/sheet';
import { downloadBlob, reportCsv, safeName, templateXlsx } from '../../lib/exporters';
import ItemForm from './ItemForm';

type Step = 'start' | 'reading' | 'map' | 'preview' | 'importing' | 'done';
type Basis = 'selling' | 'purchase';
const CHUNK = 250;

interface Result { created: number; updated: number; skipped: { row: number; name: string; reason: string }[]; stock_ignored: number; zero_cost: number; journals: string[]; opening_value: number }

// A migration passes its go-live date, the old system's name and one id for the whole upload, so the opening stock
// is dated correctly and the upload can be undone as a unit.
export interface MigrationContext { asOf: string; source: string; importId: string; expectedValue?: number | null; preset?: Record<string, string> }

export default function ImportPanel({ onClose, migration, onDone }: { onClose: () => void; migration?: MigrationContext; onDone?: (r: { created: number; updated: number; opening_value: number; skipped: number }) => void }) {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const posting = usePostingMap().data;
  const status = useQuery({ queryKey: ['aiStatus'], queryFn: aiStatus, staleTime: 5 * 60_000 });
  const [step, setStep] = useState<Step>('start');
  const [industry, setIndustry] = useState<string>(inv?.org.industry || 'retail');
  const [file, setFile] = useState('');
  const [sheets, setSheets] = useState<SheetData[]>([]);
  const [sheetIdx, setSheetIdx] = useState(0);
  const [headerIdx, setHeaderIdx] = useState(0);
  const [maps, setMaps] = useState<ColMap[]>([]);
  const [how, setHow] = useState<('exact' | 'close' | 'none' | 'ai')[]>([]);
  const [aiNote, setAiNote] = useState<string | null>(null);
  const [aiBusy, setAiBusy] = useState(false);
  const [aiRows, setAiRows] = useState<any[] | null>(null);
  const [loc, setLoc] = useState(inv?.locations.find((l) => l.is_main)?.id || inv?.locations[0]?.id || '');
  const [qtyIn, setQtyIn] = useState<Basis>('selling');
  const [costIn, setCostIn] = useState<Basis>('selling');
  const [priceIn, setPriceIn] = useState<Basis>('selling');
  const [mode, setMode] = useState<'update' | 'skip'>('update');
  const [err, setErr] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const [progress, setProgress] = useState(0);
  const [result, setResult] = useState<Result | null>(null);
  const [tplBusy, setTplBusy] = useState(false);
  const [manual, setManual] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const locations = inv?.locations || [];
  const ind = industryOf(inv?.org.industry);

  const sheet = sheets[sheetIdx];
  const headers = useMemo(() => (sheet ? (sheet.rows[headerIdx] || []).map(cellText) : []), [sheet, headerIdx]);
  const width = useMemo(() => (sheet ? Math.max(headers.length, ...sheet.rows.slice(headerIdx, headerIdx + 30).map((r) => r.length)) : 0), [sheet, headerIdx, headers]);
  const samples = useMemo(() => (sheet ? sheet.rows.slice(headerIdx + 1).filter((r) => r.some((c) => c != null && c !== '')).slice(0, 6) : []), [sheet, headerIdx]);

  function rematch(s: SheetData, h: number) {
    const hdr = Array.from({ length: Math.max((s.rows[h] || []).length, ...s.rows.slice(h, h + 30).map((r) => r.length)) }, (_, i) => cellText(s.rows[h]?.[i] ?? null));
    const m = autoMatch(hdr, inv?.org.industry, locations, s.rows.slice(h + 1, h + 9), migration?.preset || {});
    setMaps(m.maps); setHow(m.how); setAiNote(null); setAiRows(null);
    const plain = m.maps;
    if (plain.some((x) => x.field === 'qty_pu') && !plain.some((x) => x.field === 'qty')) setQtyIn('purchase');
    return { hdr, m };
  }

  async function readFile(f: File) {
    setErr(null);
    if (f.size > 15 * 1024 * 1024) { setErr('That file is over 15MB. Split it and try again.'); return; }
    setFile(f.name); setStep('reading');
    try {
      const all = await readWorkbook(f);
      if (!all.length) throw new Error('That file has no rows.');
      const si = pickSheet(all); const h = detectHeader(all[si].rows);
      setSheets(all); setSheetIdx(si); setHeaderIdx(h);
      const { hdr, m } = rematch(all[si], h);
      setStep('map');
      if (status.data?.configured !== false && m.how.some((x, i) => x !== 'exact' && hdr[i])) void askMartina(all[si], h, m.maps, m.how);
    } catch (e: any) { setErr(e.message || 'Could not read that file.'); setStep('start'); }
  }
  function onDrop(e: DragEvent) { e.preventDefault(); setDrag(false); const f = e.dataTransfer.files?.[0]; if (f) readFile(f); }

  // Martina matches the columns that were not an exact name match.
  async function askMartina(s = sheet, h = headerIdx, base = maps, baseHow = how) {
    if (!s) return;
    setAiBusy(true);
    const hdr = Array.from({ length: Math.max((s.rows[h] || []).length, ...s.rows.slice(h, h + 30).map((r) => r.length)) }, (_, i) => cellText(s.rows[h]?.[i] ?? null));
    const rows = s.rows.slice(h + 1).filter((r) => r.some((c) => c != null && c !== '')).slice(0, 6).map((r) => hdr.map((_, i) => cellText(r[i] ?? null)));
    const fields = [
      ...CORE_FIELDS.map((f) => ({ key: f.key, label: f.label })),
      ...fieldsFor(inv?.org.industry).map((f) => ({ key: 'attr:' + f.key, label: f.label, ...(f.options ? { options: f.options } : {}) })),
    ];
    const r = await ai<any>('map_columns', { headers: hdr, samples: rows, fields, locations: locations.map((l) => l.name), industry: inv?.org.industry });
    setAiBusy(false);
    if (!r?.ok) { setAiNote(r?.reason === 'not_configured' ? null : `Martina could not match the columns (${r?.error || 'try again'}). Match them below.`); return; }
    const valid = new Set(['note', 'ignore', ...fields.map((f) => f.key)]);
    const next = [...base]; const nextHow = [...baseHow] as typeof how;
    for (const col of r.columns || []) {
      const i = Number(col.index);
      if (!(i >= 0 && i < next.length) || !valid.has(col.field)) continue;
      if (baseHow[i] === 'exact') continue;
      const location = col.location ? locations.find((l) => l.name.toLowerCase() === String(col.location).toLowerCase())?.id || null : null;
      next[i] = { field: col.field, location }; nextHow[i] = 'ai';
    }
    setMaps(next); setHow(nextHow);
    if (!next.some((m) => m.field === 'qty_pu')) setQtyIn(r.quantities_in === 'purchase' ? 'purchase' : 'selling');
    if (!next.some((m) => m.field === 'cost_pu')) setCostIn(r.costs_per === 'purchase' ? 'purchase' : 'selling');
    if (!next.some((m) => m.field === 'price_pu')) setPriceIn(r.prices_per === 'purchase' ? 'purchase' : 'selling');
    setAiNote(r.summary || null);
  }

  // For sheets with no usable columns: Martina reads each line.
  async function readEachRow() {
    if (!sheet) return;
    setAiBusy(true); setErr(null);
    const lines = sheet.rows.slice(headerIdx).map((r, i) => ({ row: sheet.rowNo?.[headerIdx + i] ?? headerIdx + i + 1, text: r.map(cellText).filter(Boolean).join(' | ') })).filter((l) => l.text);
    const keys = fieldsFor(inv?.org.industry).map((f) => f.key);
    const out: any[] = [];
    for (let i = 0; i < Math.min(lines.length, 600); i += 100) {
      const r = await ai<any>('extract_rows', { lines: lines.slice(i, i + 100), attribute_keys: keys, industry: inv?.org.industry });
      if (!r?.ok) { setAiBusy(false); setErr(r?.error || 'Martina could not read the rows.'); return; }
      out.push(...(r.items || []));
    }
    setAiBusy(false);
    if (!out.length) { setErr('Martina found no products in that sheet.'); return; }
    setAiRows(out); setStep('preview');
  }

  const built: BuiltRow[] = useMemo(() => {
    if (aiRows) {
      return aiRows.map((it) => {
        const d: any = {
          row: it.row, name: it.name, brand: it.brand || undefined, category: it.category || undefined, item_type: ITEM_TYPES.some((t) => t.id === it.item_type) ? it.item_type : undefined,
          purchase_unit: it.purchase_unit || undefined, pack_size: it.pack_size || 1, selling_unit: it.selling_unit || undefined,
          price: it.price ?? undefined, cost: it.cost ?? undefined, barcode: it.barcode || undefined, sku: it.sku || undefined,
          attributes: it.attributes && Object.keys(it.attributes).length ? it.attributes : undefined,
          stock: it.qty > 0 ? [{ location_id: loc, qty: it.qty, batch_no: it.batch_no || null, expiry_date: parseDate(it.expiry_date) }] : [],
        };
        const issues: string[] = []; const warnings: string[] = ['Read by Martina'];
        if (!d.name) issues.push('No product name');
        if (typeSells(d.item_type) && !(d.price > 0)) issues.push('No selling price');
        return { row: it.row, data: d, issues, warnings };
      });
    }
    if (!sheet || step === 'start' || step === 'reading') return [];
    return buildRows(sheet.rows.map((r) => Array.from({ length: width }, (_, i) => r[i] ?? null)), headerIdx, maps, inv?.org.industry, { defaultLocation: loc, qtyIn, costIn, priceIn, rowNo: sheet.rowNo });
  }, [aiRows, sheet, headerIdx, maps, loc, qtyIn, costIn, priceIn, width, step, inv?.org.industry]);

  const existing = useMemo(() => {
    const bySku = new Map<string, string>(); const byCode = new Map<string, string>(); const byName = new Map<string, string>();
    for (const i of inv?.items || []) { if (i.sku) bySku.set(i.sku.toLowerCase(), i.id); if (i.barcode) byCode.set(i.barcode, i.id); byName.set(i.name.toLowerCase(), i.id); }
    return (d: any) => (d.sku && bySku.get(String(d.sku).toLowerCase())) || (d.barcode && byCode.get(String(d.barcode))) || (d.name && byName.get(String(d.name).toLowerCase().replace(/\s+/g, ' '))) || null;
  }, [inv]);

  // Accounting systems list services, non-stock lines and bundles beside real stock. None of those belong in an inventory.
  const nonStock = useMemo(() => {
    const out = new Set<number>();
    if (!sheet || aiRows) return out;
    const col = headers.findIndex((h) => /^(type|item type|product type|product service type|kind)$/i.test(h.replace(/[^a-z ]/gi, ' ').replace(/\s+/g, ' ').trim()));
    if (col < 0) return out;
    for (let i = headerIdx + 1; i < sheet.rows.length; i++) {
      const v = cellText(sheet.rows[i]?.[col] ?? null).trim().toLowerCase();
      if (/^(services?|non[- ]?inventory( part| item)?|non[- ]?stock( item)?|bundle|group|discount|other charge|subtotal|payment|sales tax( item)?|fixed asset)$/.test(v)) out.add(sheet.rowNo?.[i] ?? i + 1);
    }
    return out;
  }, [sheet, headerIdx, headers, aiRows]);

  const preview = useMemo(() => {
    const seen = new Set<string>();
    return built.map((b) => {
      if (nonStock.has(b.row)) return { ...b, state: 'skip' as const, qty: 0, value: 0, dup: false, why: 'Service or non-stock line' };
      const ex = existing(b.data);
      const key = String(b.data.name || '').toLowerCase();
      const dup = !ex && key && seen.has(key);
      if (key) seen.add(key);
      const state: 'new' | 'update' | 'skip' | 'problem' = b.issues.length && !(ex && mode === 'update' && b.issues.every((x) => x === 'No selling price')) ? 'problem'
        : ex ? (mode === 'update' ? 'update' : 'skip') : dup ? 'skip' : 'new';
      const qty = (b.data.stock || []).reduce((a: number, s: any) => a + Number(s.qty || 0), 0);
      return { ...b, state, qty, value: state === 'new' ? qty * Number(b.data.cost || 0) : 0, dup, why: '' };
    });
  }, [built, existing, mode, nonStock]);
  const counts = useMemo(() => ({
    new: preview.filter((p) => p.state === 'new').length, update: preview.filter((p) => p.state === 'update').length,
    skip: preview.filter((p) => p.state === 'skip').length, problem: preview.filter((p) => p.state === 'problem').length,
    value: preview.reduce((a, p) => a + p.value, 0), stockOnExisting: preview.filter((p) => p.state === 'update' && p.qty > 0).length,
    zeroCost: preview.filter((p) => p.state === 'new' && p.qty > 0 && !(Number(p.data.cost) > 0)).length,
    nonStock: preview.filter((p) => p.why).length,
  }), [preview]);

  const hasName = maps.some((m) => m.field === 'name');
  const hasPrice = maps.some((m) => m.field === 'price' || m.field === 'price_pu');
  const plainQty = maps.some((m) => m.field === 'qty' && !m.location);
  const plainCost = maps.some((m) => m.field === 'cost');
  const plainPrice = maps.some((m) => m.field === 'price');

  async function doImport() {
    const vat = defaultVat(inv?.org.industry);
    const rows = preview.filter((p) => p.state === 'new' || p.state === 'update').map((p) => (p.state === 'new' && !p.data.vat_treatment && vat !== 'standard' ? { ...p.data, vat_treatment: vat } : p.data));
    if (!rows.length) { setErr('Nothing to import. Check the matches or the rows with problems.'); return; }
    setStep('importing'); setProgress(0); setErr(null);
    const total: Result = { created: 0, updated: 0, skipped: [], stock_ignored: 0, zero_cost: 0, journals: [], opening_value: 0 };
    try {
      for (let i = 0; i < rows.length; i += CHUNK) {
        const part = Math.floor(i / CHUNK) + 1; const parts = Math.ceil(rows.length / CHUNK);
        const r = await rpc<any>('import_inventory', {
          p_org: orgId, p_rows: rows.slice(i, i + CHUNK),
          p_options: { mode, location_id: loc, file_name: parts > 1 ? `${file || 'import'} (part ${part} of ${parts})` : file || 'Spreadsheet import',
            ...(migration ? { as_of: migration.asOf, source: migration.source, import_id: migration.importId, expected_value: migration.expectedValue ?? null } : {}) },
        });
        total.created += r.created; total.updated += r.updated; total.skipped.push(...(r.skipped || []));
        total.stock_ignored += r.stock_ignored; total.zero_cost += r.zero_cost; total.opening_value += Number(r.opening_value || 0);
        if (r.journal_ref) total.journals.push(r.journal_ref);
        setProgress(Math.min(1, (i + CHUNK) / rows.length));
      }
      total.skipped.push(...preview.filter((p) => p.state === 'problem' || p.state === 'skip').map((p) => ({ row: p.row, name: p.data.name || '', reason: p.why || p.issues[0] || (p.dup ? 'Appears twice in the file' : 'Already in your items') })));
      setResult(total); setStep('done');
      onDone?.({ created: total.created, updated: total.updated, opening_value: total.opening_value, skipped: total.skipped.length });
      await Promise.all(['inv', 'ledger', 'activity'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
    } catch (e: any) {
      setResult(total.created || total.updated ? total : null);
      setErr(e.message || 'The import stopped.'); setStep(total.created || total.updated ? 'done' : 'preview');
    }
  }

  async function downloadTemplate() {
    setTplBusy(true);
    try {
      const blob = await templateXlsx(industry, locations, inv?.org.name || 'Counta');
      downloadBlob(blob, `Counta item template – ${industryOf(industry).label}.xlsx`);
    } catch (e: any) { toast(e.message || 'Could not build the template', 'err'); }
    setTplBusy(false);
  }

  const choices = useMemo(() => fieldChoices(inv?.org.industry), [inv?.org.industry]);
  const usedOnce = (f: string, i: number) => f !== 'qty' && f !== 'qty_pu' && maps.some((m, j) => j !== i && m.field === f);

  if (manual) return <ItemForm onClose={() => setManual(false)} />;
  return (
    <Drawer onClose={onClose} width={step === 'map' || step === 'preview' ? 760 : 560}>
      <div className="drawer-hd">
        <span style={{ width: 44, height: 44, borderRadius: '50%', background: '#F3F4F6', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="upload" size={20} color="#6B7280" /></span>
        <div className="grow" style={{ minWidth: 0 }}>
          <div style={{ fontFamily: 'var(--font-brand)', fontSize: 21, fontWeight: 600 }}>{migration ? `Items and stock from ${migration.source}` : 'Upload inventory'}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{step === 'map' ? `${file} · match the columns` : step === 'preview' ? `${file} · check before importing` : 'From our template or the sheet you already keep'}</div>
        </div>
        <XButton onClick={onClose} />
      </div>
      <div className="drawer-body">
        {step === 'start' && (
          <div className="stack" style={{ gap: 16 }}>
            {migration && <Alert kind="blue" icon="cal">Opening stock posts as at close of business on {fmtDay(migration.asOf)}, your go-live date. Upload the stock your old system shows for that day.</Alert>}
            <div className="card" style={{ padding: 16, borderRadius: 14, background: '#FAFCFF', borderColor: '#CFE3FF' }}>
              <div className="row" style={{ gap: 10, alignItems: 'flex-start' }}>
                <Icon name="download" size={18} color="#0072F5" style={{ marginTop: 2 }} />
                <div className="grow">
                  <div style={{ fontSize: 14, fontWeight: 600 }}>Start from a template</div>
                  <div className="ink3" style={{ fontSize: 13, lineHeight: 1.5, marginTop: 2 }}>Columns for your kind of business, dropdowns for units and VAT, an opening stock column for each branch, and a filled-in example.</div>
                  <div className="row m-wrap" style={{ gap: 8, marginTop: 10 }}>
                    <select className="input input-sm" style={{ maxWidth: 280 }} value={industry} onChange={(e) => setIndustry(e.target.value)} aria-label="Template for">
                      {INDUSTRIES.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
                    </select>
                    <button className="btn btn-secondary btn-sm" onClick={downloadTemplate} disabled={tplBusy}><Icon name="download" size={14} />{tplBusy ? 'Preparing…' : 'Download template'}</button>
                  </div>
                </div>
              </div>
            </div>
            <div onClick={() => input.current?.click()} onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && input.current?.click()}
              onDragOver={(e) => { e.preventDefault(); setDrag(true); }} onDragLeave={() => setDrag(false)} onDrop={onDrop}
              style={{ border: '1.5px dashed ' + (drag ? '#0072F5' : '#D1D5DB'), background: drag ? '#F0F7FF' : '#fff', borderRadius: 16, padding: '32px 20px', textAlign: 'center', cursor: 'pointer' }} role="button" tabIndex={0}>
              <div style={{ width: 44, height: 44, margin: '0 auto', borderRadius: 8, background: '#111827', color: '#fff', fontSize: 10, fontWeight: 700, display: 'grid', placeItems: 'center' }}>xlsx</div>
              <div style={{ fontSize: 15, marginTop: 14 }}><span style={{ color: '#0072F5', textDecoration: 'underline' }}>Choose a file</span> or drag it here</div>
              <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.5 }}>Excel, CSV or OpenDocument, up to 15MB. Your own layout is fine: Counta finds the header row and Martina matches the columns.</div>
              <input ref={input} type="file" accept=".xlsx,.xls,.xlsm,.csv,.ods" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) readFile(f); }} />
            </div>
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
            <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start', paddingLeft: 0 }} onClick={() => setManual(true)}><Icon name="plus" size={14} />Add items one at a time instead</button>
            <div className="hint">New items with a quantity post opening stock: Dr {acct(posting, 'inventory').code} {acct(posting, 'inventory').name} (or the account for their kind) / Cr {acct(posting, 'opening_equity').code} {acct(posting, 'opening_equity').name}, at the cost in the sheet.</div>
          </div>
        )}

        {step === 'reading' && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: '60px 0', textAlign: 'center' }}>
            <Spinner /><div style={{ fontSize: 15, fontWeight: 600 }}>Reading {file}</div><div className="muted" style={{ fontSize: 13 }}>Finding the item list and its header row</div>
          </div>
        )}

        {step === 'map' && sheet && (
          <div className="stack" style={{ gap: 12 }}>
            <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: sheets.length > 1 ? '1fr 1fr' : '1fr', gap: 10 }}>
              {sheets.length > 1 && (
                <Field label="Sheet">
                  <select className="input input-sm" value={sheetIdx} onChange={(e) => { const i = Number(e.target.value); const h = detectHeader(sheets[i].rows); setSheetIdx(i); setHeaderIdx(h); rematch(sheets[i], h); }}>
                    {sheets.map((s, i) => <option key={i} value={i}>{s.name} · {s.rows.length} rows</option>)}
                  </select>
                </Field>
              )}
              <Field label="Column names are on">
                <select className="input input-sm" value={headerIdx} onChange={(e) => { const h = Number(e.target.value); setHeaderIdx(h); rematch(sheet, h); }}>
                  {sheet.rows.slice(0, 25).map((r, i) => <option key={i} value={i}>Row {sheet.rowNo?.[i] ?? i + 1}: {r.map(cellText).filter(Boolean).slice(0, 4).join(' · ').slice(0, 60) || '(empty)'}</option>)}
                </select>
              </Field>
            </div>
            {aiBusy && <Alert kind="blue" icon="sparkles">Martina is matching the columns…</Alert>}
            {!aiBusy && aiNote && <Alert kind="blue" icon="sparkles">{aiNote}</Alert>}
            {(() => {
              const plainQty = maps.map((m, i) => (m.field === 'qty' && !m.location ? headers[i] : null)).filter(Boolean);
              return plainQty.length > 1 ? <Alert kind="yellow" icon="alert">{plainQty.length} columns are being added together as stock: {plainQty.join(', ')}. Leave out any that is not stock on hand today.</Alert> : null;
            })()}
            {!aiBusy && !aiNote && status.data?.configured && how.some((h, i) => h !== 'exact' && headers[i]) && (
              <button className="btn btn-secondary btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => askMartina()}><Icon name="sparkles" size={14} />Ask Martina to match the columns</button>
            )}
            <div className="muted" style={{ fontSize: 13, lineHeight: 1.45 }}>
              {built.length} rows found. Columns you do not match are kept on each item as notes, so nothing is lost.
            </div>
            <div className="stack" style={{ gap: 6 }}>
              {Array.from({ length: width }, (_, i) => i).map((i) => {
                const m = maps[i] || { field: 'ignore' };
                const sample = samples.map((r) => cellText(r[i] ?? null)).filter(Boolean).slice(0, 3).join(' · ');
                const ok = m.field !== 'note' && m.field !== 'ignore';
                return (
                  <div key={i} className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) minmax(0,1.1fr)', gap: 10, alignItems: 'center', border: '1px solid #E6E6E6', borderRadius: 10, padding: '8px 12px' }}>
                    <div style={{ minWidth: 0 }}>
                      <div className="ellipsis" style={{ fontSize: 13, fontWeight: 600 }}>{headers[i] || `Column ${i + 1}`}</div>
                      <div className="faint ellipsis" style={{ fontSize: 11 }}>{sample || 'empty'}</div>
                    </div>
                    <div className="row" style={{ gap: 6, minWidth: 0 }}>
                      <select className="input input-sm grow" value={m.field} aria-label={`Field for ${headers[i] || 'column ' + (i + 1)}`}
                        onChange={(e) => { const next = [...maps]; next[i] = { field: e.target.value, location: e.target.value === 'qty' || e.target.value === 'qty_pu' ? m.location || null : null }; setMaps(next); const nh = [...how]; nh[i] = 'exact'; setHow(nh); }}
                        style={{ fontWeight: 600, color: ok ? '#15803D' : m.field === 'note' ? '#C2410C' : '#6B7280', background: ok ? '#F0FDF4' : m.field === 'note' ? '#FFF7ED' : '#FAFAFA', borderColor: 'transparent', minWidth: 0 }}>
                        <option value="note">Keep as a note</option>
                        <option value="ignore">Leave out</option>
                        {choices.map((g) => (
                          <optgroup key={g.group} label={g.group === 'Details' ? `${ind.label} details` : g.group}>
                            {g.options.map((o) => <option key={o.value} value={o.value} disabled={usedOnce(o.value, i)}>{o.label}</option>)}
                          </optgroup>
                        ))}
                      </select>
                      {(m.field === 'qty' || m.field === 'qty_pu') && locations.length > 1 && (
                        <select className="input input-sm" style={{ maxWidth: 130 }} value={m.location || ''} aria-label="Branch"
                          onChange={(e) => { const next = [...maps]; next[i] = { ...m, location: e.target.value || null }; setMaps(next); }}>
                          <option value="">Default branch</option>
                          {locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                        </select>
                      )}
                      {how[i] === 'ai' && <span title="Matched by Martina"><Icon name="sparkles" size={14} color="#0072F5" /></span>}
                    </div>
                  </div>
                );
              })}
            </div>
            <div className="m-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 10 }}>
              <Field label="Default branch"><select className="input input-sm" value={loc} onChange={(e) => setLoc(e.target.value)}>{locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
              {plainQty && <Field label="Quantities are in"><select className="input input-sm" value={qtyIn} onChange={(e) => setQtyIn(e.target.value as Basis)}><option value="selling">Selling units</option><option value="purchase">Cartons / bags</option></select></Field>}
              {plainCost && <Field label="Costs are per"><select className="input input-sm" value={costIn} onChange={(e) => setCostIn(e.target.value as Basis)}><option value="selling">Selling unit</option><option value="purchase">Carton / bag</option></select></Field>}
              {plainPrice && <Field label="Prices are per"><select className="input input-sm" value={priceIn} onChange={(e) => setPriceIn(e.target.value as Basis)}><option value="selling">Selling unit</option><option value="purchase">Carton / bag</option></select></Field>}
            </div>
            {!hasName && <Alert kind="yellow" icon="alert">Match one column to Product name.{status.data?.configured ? ' If the sheet has no clear columns, Martina can read each row instead.' : ''}</Alert>}
            {hasName && !hasPrice && <Alert kind="yellow" icon="info">No price column is matched. Goods you sell need a selling price; raw materials, consumables and spares can come in without one.</Alert>}
            {status.data?.configured && (
              <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start', paddingLeft: 0 }} onClick={readEachRow} disabled={aiBusy}>
                <Icon name="sparkles" size={14} color="#0072F5" />{aiBusy ? 'Martina is reading…' : 'Messy sheet? Let Martina read each row instead'}
              </button>
            )}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </div>
        )}

        {step === 'preview' && (
          <div className="stack" style={{ gap: 12 }}>
            <div className="row wrap" style={{ gap: 8 }}>
              <span className="chip t-green">{counts.new} new</span>
              {counts.update > 0 && <span className="chip t-blue">{counts.update} to update</span>}
              {counts.skip > 0 && <span className="chip t-grey">{counts.skip} left as they are</span>}
              {counts.problem > 0 && <span className="chip t-red">{counts.problem} with problems</span>}
            </div>
            {preview.some((p) => existing(p.data)) && (
              <Field label="Items already in Counta">
                <select className="input input-sm" style={{ maxWidth: 360 }} value={mode} onChange={(e) => setMode(e.target.value as any)}>
                  <option value="update">Update their details from the sheet</option>
                  <option value="skip">Leave them as they are</option>
                </select>
              </Field>
            )}
            {counts.value > 0 && (
              <div style={{ background: '#FAFAFA', borderRadius: 12, padding: '12px 14px', fontSize: 13, lineHeight: 1.5 }}>
                Opening stock of <b>{N(counts.value)}</b> posts for new items: Dr inventory / Cr {acct(posting, 'opening_equity').code} {acct(posting, 'opening_equity').name}, by branch.
              </div>
            )}
            {counts.stockOnExisting > 0 && mode === 'update' && <Alert kind="blue" icon="info">{counts.stockOnExisting} existing item{counts.stockOnExisting === 1 ? ' has' : 's have'} a quantity in the sheet. Quantities of existing items change only through a stock count, so those are left out.</Alert>}
            {counts.nonStock > 0 && <Alert kind="blue" icon="info">{counts.nonStock} service or non-stock line{counts.nonStock === 1 ? ' is' : 's are'} left out. Counta keeps the things you hold on a shelf; services and charges stay in your accounts.</Alert>}
            {counts.zeroCost > 0 && <Alert kind="yellow" icon="alert">{counts.zeroCost} new item{counts.zeroCost === 1 ? ' has' : 's have'} stock but no cost, so that stock goes into the books at ₦0. Add a cost column, or go back and match it.</Alert>}
            <div className="card" style={{ borderRadius: 12, overflow: 'auto', maxHeight: 420 }}>
              <table className="mini-table">
                <thead><tr><th>Row</th><th>Item</th><th>Status</th><th className="right">Price</th><th className="right">Cost</th><th className="right">Pack</th><th className="right">Opening qty</th></tr></thead>
                <tbody>
                  {preview.slice(0, 200).map((p) => (
                    <tr key={p.row}>
                      <td className="faint">{p.row}</td>
                      <td style={{ minWidth: 180 }}>
                        <div style={{ fontWeight: 600 }}>{p.data.name || <span className="faint">No name</span>}</div>
                        <div className="faint" style={{ fontSize: 11 }}>{[p.data.category, p.data.brand, p.data.item_type && ITEM_TYPES.find((t) => t.id === p.data.item_type)?.label, ...Object.entries(p.data.attributes || {}).slice(0, 3).map(([, v]) => String(v))].filter(Boolean).join(' · ')}</div>
                        {p.warnings.filter((w) => w !== 'Read by Martina').length > 0 && <div style={{ fontSize: 11, color: '#A16207' }}>{p.warnings.filter((w) => w !== 'Read by Martina').join('; ')}</div>}
                      </td>
                      <td><span className={'chip ' + (p.state === 'new' ? 't-green' : p.state === 'update' ? 't-blue' : p.state === 'skip' ? 't-grey' : 't-red')}>{p.state === 'new' ? 'New' : p.state === 'update' ? 'Update' : p.state === 'skip' ? (p.why ? 'Not stock' : p.dup ? 'Duplicate' : 'Exists') : p.issues[0]}</span></td>
                      <td className="right num">{p.data.price != null ? N(p.data.price) : '—'}</td>
                      <td className="right num">{p.data.cost != null ? N(p.data.cost) : '—'}</td>
                      <td className="right">{p.data.pack_size || 1}</td>
                      <td className="right">{p.qty ? num(p.qty, 3) : '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {preview.length > 200 && <div className="faint" style={{ padding: 10, fontSize: 12 }}>Showing 200 of {preview.length} rows. All of them import.</div>}
            </div>
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </div>
        )}

        {step === 'importing' && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: '60px 0', textAlign: 'center' }}>
            <Spinner />
            <div style={{ fontSize: 15, fontWeight: 600 }}>Importing {counts.new + counts.update} items…</div>
            <div className="bar" style={{ width: 260 }}><div style={{ width: Math.round(progress * 100) + '%' }} /></div>
            <div className="muted" style={{ fontSize: 13 }}>Creating items, opening stock and its journal</div>
          </div>
        )}

        {step === 'done' && result && (
          <div className="stack" style={{ gap: 12 }}>
            <Alert kind="green" icon="check">
              {result.created} item{result.created === 1 ? '' : 's'} added{result.updated ? ` and ${result.updated} updated` : ''}.
              {result.opening_value > 0 ? ` Opening stock of ${N(result.opening_value)} posted in ${result.journals.join(', ')}.` : ''}
            </Alert>
            {result.stock_ignored > 0 && <Alert kind="blue" icon="info">Quantities for {result.stock_ignored} existing item{result.stock_ignored === 1 ? '' : 's'} were left out. Start a stock count to correct them.</Alert>}
            {result.zero_cost > 0 && <Alert kind="yellow" icon="alert">{result.zero_cost} item{result.zero_cost === 1 ? '' : 's'} came in at ₦0 cost. Their next receipt sets the cost.</Alert>}
            {result.skipped.length > 0 && (
              <div className="card" style={{ padding: 12, borderRadius: 12 }}>
                <div className="row" style={{ justifyContent: 'space-between', marginBottom: 6 }}>
                  <div style={{ fontSize: 13, fontWeight: 600 }}>{result.skipped.length} row{result.skipped.length === 1 ? '' : 's'} not imported</div>
                  <button className="btn btn-ghost btn-xs" onClick={() => downloadBlob(reportCsv([{ key: 'row', label: 'Row' }, { key: 'name', label: 'Item' }, { key: 'reason', label: 'Reason' }], result.skipped), `${safeName(file)} – rows not imported.csv`)}>
                    <Icon name="download" size={13} />Download list
                  </button>
                </div>
                <div className="stack" style={{ gap: 3, fontSize: 12, maxHeight: 200, overflowY: 'auto' }}>
                  {result.skipped.slice(0, 50).map((s, i) => <div key={i}><span className="faint">Row {s.row}</span> · {s.name || 'No name'} · <span className="muted">{s.reason}</span></div>)}
                </div>
              </div>
            )}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </div>
        )}
      </div>
      {step === 'map' && (
        <div className="drawer-ft">
          <button className="btn btn-secondary" onClick={() => { setStep('start'); setSheets([]); }}>Back</button>
          <button className="btn btn-primary" onClick={() => { setErr(null); setAiRows(null); setStep('preview'); }} disabled={!hasName || !built.length}>Check {built.length} rows</button>
        </div>
      )}
      {step === 'preview' && (
        <div className="drawer-ft">
          <button className="btn btn-secondary" onClick={() => { setAiRows(null); setStep(sheet ? 'map' : 'start'); }}>Back</button>
          <button className="btn btn-primary" onClick={doImport} disabled={!(counts.new + counts.update)}>Import {counts.new + counts.update} item{counts.new + counts.update === 1 ? '' : 's'}</button>
        </div>
      )}
      {step === 'done' && <div className="drawer-ft"><button className="btn btn-primary" onClick={onClose}>Done</button></div>}
    </Drawer>
  );
}

