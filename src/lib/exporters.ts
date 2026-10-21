// Excel, CSV and PDF files for reports, the import template and the item list. The Excel and PDF
// libraries load only when someone downloads a file.
import type { Inventory, Location } from './types';
import type { RCol, ReportDef } from './reports';
import { CORE_FIELDS } from './sheet';
import { COMMON_FIELDS, ITEM_TYPES, fieldsFor, industryOf, typeLabel, type FieldDef } from './industries';

export interface ReportMeta { org: string; title: string; period: string; branch: string; by: string; generated: string; note?: string }

const BLUE = 'FF0072F5'; const GREY = 'FFF3F4F6'; const INK = 'FF111827';
const fmtFor = (t?: string) => t === 'money' ? '#,##0.00;[Red](#,##0.00)' : t === 'qty' ? '#,##0.###' : t === 'num' ? '#,##0.0' : t === 'pct' ? '0.0"%"' : t === 'int' ? '#,##0' : undefined;
const widthFor = (col: RCol) => col.width || (col.type === 'money' ? 16 : col.type === 'date' ? 12 : col.type && col.type !== 'text' ? 11 : Math.min(40, Math.max(12, col.label.length + 4)));
const colLetter = (n: number) => { let s = ''; n += 1; while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - 1) / 26); } return s; };

export function safeName(s: string) { return s.replace(/[^\w\- ]+/g, '').replace(/\s+/g, ' ').trim().slice(0, 80) || 'counta'; }

export function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = name; a.rel = 'noopener';
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

async function excel() {
  const mod: any = await import('exceljs');
  return (mod.default || mod) as typeof import('exceljs');
}

const toCell = (v: unknown, type?: string) => {
  if (v == null || v === '') return null;
  if (type === 'date' && typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v)) { const [y, m, d] = v.slice(0, 10).split('-').map(Number); return new Date(Date.UTC(y, m - 1, d)); }
  if (type && type !== 'text' && type !== 'date') { const n = Number(v); return isFinite(n) ? n : v; }
  return typeof v === 'boolean' ? (v ? 'Yes' : 'No') : v;
};

// One report on one worksheet: a title block, a frozen header row with filters, and a totals row.
function addReportSheet(wb: any, name: string, meta: ReportMeta, cols: RCol[], rows: Record<string, unknown>[], extraLines: string[] = []) {
  const ws = wb.addWorksheet(name.slice(0, 31), { views: [{ state: 'frozen', ySplit: 5 + extraLines.length }], pageSetup: { orientation: cols.length > 7 ? 'landscape' : 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0, paperSize: 9 } });
  ws.getCell('A1').value = meta.org; ws.getCell('A1').font = { bold: true, size: 14, color: { argb: INK } };
  ws.getCell('A2').value = meta.title; ws.getCell('A2').font = { bold: true, size: 12, color: { argb: BLUE } };
  ws.getCell('A3').value = `${meta.period} · ${meta.branch} · generated ${meta.generated} by ${meta.by}`; ws.getCell('A3').font = { size: 9, color: { argb: 'FF6B7280' } };
  extraLines.forEach((l, i) => { const c = ws.getCell(`A${4 + i}`); c.value = l; c.font = { size: 9, italic: true, color: { argb: 'FF374151' } }; });
  const hr = 5 + extraLines.length;
  const header = ws.getRow(hr);
  cols.forEach((col, i) => {
    const cell = header.getCell(i + 1);
    cell.value = col.label;
    cell.font = { bold: true, color: { argb: 'FFFFFFFF' }, size: 10 };
    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: BLUE } };
    cell.alignment = { vertical: 'middle', wrapText: true, horizontal: col.type && col.type !== 'text' && col.type !== 'date' ? 'right' : 'left' };
    ws.getColumn(i + 1).width = widthFor(col);
    const f = fmtFor(col.type); if (f) ws.getColumn(i + 1).numFmt = f;
    if (col.type === 'date') ws.getColumn(i + 1).numFmt = 'dd/mm/yyyy';
  });
  header.height = 30;
  rows.forEach((r, ri) => {
    const row = ws.getRow(hr + 1 + ri);
    cols.forEach((col, i) => { row.getCell(i + 1).value = toCell(r[col.key], col.type) as any; });
  });
  const last = hr + rows.length;
  if (rows.length && cols.some((c) => c.total)) {
    const tr = ws.getRow(last + 1);
    tr.getCell(1).value = 'Total';
    cols.forEach((col, i) => {
      if (!col.total) return;
      const L = colLetter(i);
      const result = rows.reduce((a, r) => a + (Number(r[col.key]) || 0), 0);
      tr.getCell(i + 1).value = { formula: `SUBTOTAL(9,${L}${hr + 1}:${L}${last})`, result: Math.round(result * 100) / 100 } as any;
    });
    tr.font = { bold: true };
    tr.eachCell((c: any) => { c.border = { top: { style: 'thin', color: { argb: INK } }, bottom: { style: 'double', color: { argb: INK } } }; c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: GREY } }; });
  }
  ws.autoFilter = { from: { row: hr, column: 1 }, to: { row: Math.max(hr, last), column: cols.length } };
  if (meta.note) { const n = ws.getCell(`A${last + 3}`); n.value = meta.note; n.font = { size: 9, italic: true, color: { argb: 'FF6B7280' } }; }
  return ws;
}

export async function reportXlsx(meta: ReportMeta, cols: RCol[], rows: Record<string, unknown>[], extraLines: string[] = []): Promise<Blob> {
  const ExcelJS = await excel();
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  addReportSheet(wb, meta.title, meta, cols, rows, extraLines);
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

export async function packXlsx(sheets: { meta: ReportMeta; def: ReportDef; cols: RCol[]; rows: Record<string, unknown>[]; extra?: string[] }[], cover: ReportMeta): Promise<Blob> {
  const ExcelJS = await excel();
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  const ws = wb.addWorksheet('Contents');
  ws.getCell('A1').value = cover.org; ws.getCell('A1').font = { bold: true, size: 14 };
  ws.getCell('A2').value = cover.title; ws.getCell('A2').font = { bold: true, size: 12, color: { argb: BLUE } };
  ws.getCell('A3').value = `${cover.period} · ${cover.branch} · generated ${cover.generated} by ${cover.by}`; ws.getCell('A3').font = { size: 9, color: { argb: 'FF6B7280' } };
  ws.getColumn(1).width = 36; ws.getColumn(2).width = 90;
  sheets.forEach((s, i) => {
    const r = ws.getRow(5 + i);
    r.getCell(1).value = { text: s.def.title, hyperlink: `#'${s.def.title.slice(0, 31)}'!A1` } as any;
    r.getCell(1).font = { color: { argb: BLUE }, underline: true };
    r.getCell(2).value = s.def.blurb;
  });
  for (const s of sheets) addReportSheet(wb, s.def.title, s.meta, s.cols, s.rows, s.extra);
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

export function reportCsv(cols: RCol[], rows: Record<string, unknown>[]): Blob {
  const q = (v: unknown) => {
    if (v == null) return '';
    const s = typeof v === 'boolean' ? (v ? 'Yes' : 'No') : String(v);
    return /[",\n\r]/.test(s) || /^[=+\-@]/.test(s) && isNaN(Number(s)) ? '"' + s.replace(/"/g, '""').replace(/^([=+\-@])/, "'$1") + '"' : s;
  };
  const lines = [cols.map((c) => q(c.label)).join(','), ...rows.map((r) => cols.map((c) => q(r[c.key])).join(','))];
  return new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
}

// jsPDF's built-in Helvetica only covers Latin-1, so ₦ and other symbols are spelt out and accented letters
// outside that range lose their accent (Ọ → O) instead of printing as garbage.
export const latin1 = (s: string) => s
  .replace(/₦\s?/g, 'NGN ').replace(/[−–—]/g, '-').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/…/g, '...').replace(/→/g, '>')
  .replace(/[^\u0000-\u00ff]/g, (ch) => { const base = ch.normalize('NFD')[0]; return base && base.charCodeAt(0) <= 0xff ? base : '?'; });
const pdfText = (v: unknown, t?: string) => latin1(pdfRaw(v, t));
const pdfRaw = (v: unknown, t?: string): string => {
  if (v == null || v === '') return '';
  if (t === 'date' && typeof v === 'string') { const [y, m, d] = v.slice(0, 10).split('-'); return d ? `${d}/${m}/${y}` : v; }
  if (t === 'money') return Number(v).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  if (t === 'qty' || t === 'num' || t === 'int') return Number(v).toLocaleString('en-NG', { maximumFractionDigits: 3 });
  if (t === 'pct') return Number(v).toFixed(1) + '%';
  return typeof v === 'boolean' ? (v ? 'Yes' : 'No') : String(v);
};

export async function reportPdf(meta: ReportMeta, cols: RCol[], rows: Record<string, unknown>[], extraLines: string[] = []): Promise<Blob> {
  const [{ jsPDF }, { autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const pc = cols.filter((c) => c.pdf !== false);
  const landscape = pc.length > 6;
  const doc = new jsPDF({ orientation: landscape ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' });
  const W = doc.internal.pageSize.getWidth();
  doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.setTextColor(17, 24, 39); doc.text(latin1(meta.org), 36, 40);
  doc.setFontSize(11); doc.setTextColor(0, 114, 245); doc.text(latin1(meta.title), 36, 58);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(107, 114, 128);
  doc.text(latin1(`${meta.period} · ${meta.branch} · generated ${meta.generated} by ${meta.by}`), 36, 72);
  let y = 84;
  for (const l of extraLines) { doc.text(latin1(l), 36, y); y += 11; }
  const totals = pc.some((c) => c.total) && rows.length
    ? [pc.map((c, i) => (i === 0 ? 'Total' : c.total ? pdfText(rows.reduce((a, r) => a + (Number(r[c.key]) || 0), 0), c.type) : ''))] : undefined;
  autoTable(doc as any, {
    startY: y + 4,
    head: [pc.map((c) => latin1(c.label))],
    body: rows.map((r) => pc.map((c) => pdfText(r[c.key], c.type))),
    foot: totals,
    showFoot: 'lastPage',
    theme: 'grid',
    styles: { font: 'helvetica', fontSize: pc.length > 10 ? 6.5 : 7.5, cellPadding: 3, overflow: 'linebreak', lineColor: [230, 230, 230], lineWidth: 0.4 },
    headStyles: { fillColor: [0, 114, 245], textColor: 255, fontStyle: 'bold' },
    footStyles: { fillColor: [243, 244, 246], textColor: [17, 24, 39], fontStyle: 'bold' },
    columnStyles: Object.fromEntries(pc.map((c, i) => [i, { halign: c.type && c.type !== 'text' && c.type !== 'date' ? 'right' : 'left' }])) as any,
    margin: { left: 36, right: 36, bottom: 40 },
    didDrawPage: () => {
      doc.setFontSize(7); doc.setTextColor(156, 163, 175);
      const page = (doc as any).internal.getCurrentPageInfo().pageNumber;
      doc.text(latin1(`Counta · TaxStreem · ${meta.title}`), 36, doc.internal.pageSize.getHeight() - 18);
      doc.text(`Page ${page}`, W - 36, doc.internal.pageSize.getHeight() - 18, { align: 'right' });
    },
  });
  if (meta.note) {
    const fy = ((doc as any).lastAutoTable?.finalY || y) + 16;
    doc.setFontSize(7.5); doc.setTextColor(107, 114, 128); doc.text(doc.splitTextToSize(latin1(meta.note), W - 72), 36, fy);
  }
  return doc.output('blob');
}

// ---------- import template and item list ----------
interface TCol { header: string; key: string; width: number; note?: string; list?: string[]; strict?: boolean; numFmt?: string; text?: boolean }

export function templateColumns(industry: string | undefined, locations: Location[], qtyWord = 'Opening qty'): TCol[] {
  const ind = industryOf(industry);
  const t = (k: string) => CORE_FIELDS.find((f) => f.key === k)!.template!;
  const attr = (f: FieldDef): TCol => ({
    header: f.label, key: 'attr:' + f.key, width: Math.max(14, Math.min(28, f.label.length + 2)), note: f.placeholder ? `For example ${f.placeholder.replace(/^e\.g\.\s*/, '')}` : f.hint,
    list: f.type === 'select' ? f.options : f.type === 'bool' ? ['Yes', 'No'] : undefined, strict: false,
    numFmt: f.type === 'number' ? '#,##0.##' : undefined,
  });
  const indKeys = new Set(ind.fields.map((f) => f.key));
  return [
    { header: t('name'), key: 'name', width: 36, note: 'Required. Write it the way your staff say it, with the size: "Peak Evaporated Milk 160g".' },
    { header: t('sku'), key: 'sku', width: 16, text: true, note: 'Your own code. Used to match items when you upload this sheet again.' },
    { header: t('barcode'), key: 'barcode', width: 17, text: true, note: 'The number under the barcode. Leave blank and Counta prints a QR label.' },
    { header: t('category'), key: 'category', width: 20, list: ind.categories, strict: false },
    { header: t('brand'), key: 'brand', width: 16 },
    { header: t('item_type'), key: 'item_type', width: 22, list: ITEM_TYPES.map((x) => x.label), strict: true, note: 'Goods for resale and finished goods need a selling price. Raw materials, packaging, consumables, spares and chemicals may leave it blank.' },
    { header: t('purchase_unit'), key: 'purchase_unit', width: 13, list: ind.purchaseUnits, strict: false, note: 'How you buy it: Carton, Bag, Bale, Drum…' },
    { header: t('pack_size'), key: 'pack_size', width: 12, numFmt: '0', note: 'How many selling units are in one purchase unit. 1 if you sell it as you buy it.' },
    { header: t('selling_unit'), key: 'selling_unit', width: 13, list: ind.sellingUnits, strict: false, note: 'How you sell or count it: piece, pack, tin, kg, length…' },
    { header: t('cost'), key: 'cost', width: 16, numFmt: '#,##0.00', note: 'What one selling unit costs you. Opening stock is valued at this.' },
    { header: t('price'), key: 'price', width: 18, numFmt: '#,##0.00' },
    { header: t('vat_treatment'), key: 'vat_treatment', width: 15, list: ['standard', 'zero', 'exempt'], strict: true },
    { header: t('reorder_floor'), key: 'reorder_floor', width: 12, numFmt: '#,##0.###', note: 'Reorder when stock falls to this many selling units.' },
    { header: t('vendor'), key: 'vendor', width: 20, note: 'Vendor name. New names are added to your vendors.' },
    ...(ind.nafdac ? [{ header: t('nafdac_no'), key: 'nafdac_no', width: 13 }] : []),
    ...(ind.batches ? [{ header: t('track_batches'), key: 'track_batches', width: 12, list: ['Yes', 'No'], strict: true }] : []),
    ...ind.fields.map(attr),
    ...COMMON_FIELDS.filter((f) => !indKeys.has(f.key)).map(attr),
    { header: t('description'), key: 'description', width: 30 },
    ...locations.map((l) => ({ header: `${qtyWord} – ${l.name} (selling units)`, key: 'qty@' + l.id, width: 16, numFmt: '#,##0.###', note: qtyWord === 'On hand' ? `Stock at ${l.name} when this list was downloaded. Uploading the sheet again does not change stock; use a count.` : `Stock at ${l.name} today, in selling units. Posts as opening stock for new items only.` })),
    ...(ind.batches ? [
      { header: t('batch_no'), key: 'batch_no', width: 13, text: true },
      { header: t('expiry_date'), key: 'expiry_date', width: 14, numFmt: 'dd/mm/yyyy', note: 'Day first: 30/06/2027. Month and year alone (06/2027) means the end of that month.' },
    ] : []),
  ];
}

function exampleValue(row: Record<string, string | number>, key: string, locations: Location[]) {
  if (key.startsWith('qty@')) return key === 'qty@' + locations[0]?.id ? row.qty ?? null : null;
  if (key === 'item_type') return row.item_type ? typeLabel(String(row.item_type)) : 'Goods for resale';
  if (key.startsWith('attr:')) return row[key.slice(5)] ?? null;
  if (key === 'expiry_date' && typeof row.expiry_date === 'string') {
    const [d, m, y] = row.expiry_date.split('/').map(Number); return new Date(Date.UTC(y, m - 1, d));
  }
  const v = row[key];
  return v === '' ? null : v ?? null;
}

async function buildTemplate(industry: string | undefined, locations: Location[], orgName: string, rows: Record<string, unknown>[] | null): Promise<Blob> {
  const ExcelJS = await excel();
  const ind = industryOf(industry);
  const cols = templateColumns(industry, locations, rows ? 'On hand' : 'Opening qty');
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  const items = wb.addWorksheet('Items', { views: [{ state: 'frozen', ySplit: 1, xSplit: 1 }] });
  const example = rows ? null : wb.addWorksheet('Example', { views: [{ state: 'frozen', ySplit: 1, xSplit: 1 }] });
  const guide = wb.addWorksheet('Guide');
  const lists = wb.addWorksheet('Lists', { state: 'veryHidden' });

  const setup = (ws: any) => {
    const hr = ws.getRow(1);
    cols.forEach((c, i) => {
      const cell = hr.getCell(i + 1);
      cell.value = c.header;
      cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: c.key === 'name' ? 'FF004FB0' : c.key.startsWith('attr:') ? 'FF4B5563' : c.key.startsWith('qty@') ? 'FF15803D' : BLUE } };
      cell.alignment = { vertical: 'middle', wrapText: true };
      if (c.note) cell.note = { texts: [{ text: c.note }] } as any;
      ws.getColumn(i + 1).width = c.width;
      if (c.numFmt) ws.getColumn(i + 1).numFmt = c.numFmt;
      if (c.text) ws.getColumn(i + 1).numFmt = '@';
    });
    hr.height = 42;
  };
  setup(items);
  // Dropdowns, from a hidden Lists sheet so long lists still fit.
  let li = 0;
  cols.forEach((c, i) => {
    if (!c.list?.length) return;
    li += 1;
    const L = colLetter(li - 1);
    lists.getCell(`${L}1`).value = c.header;
    c.list.forEach((v, j) => { lists.getCell(`${L}${j + 2}`).value = v; });
    const ref = `Lists!$${L}$2:$${L}$${c.list.length + 1}`;
    const target = colLetter(i);
    (items as any).dataValidations.add(`${target}2:${target}2000`, {
      type: 'list', allowBlank: true, formulae: [ref], showErrorMessage: !!c.strict, errorStyle: 'warning',
      errorTitle: 'Not in the list', error: 'Pick one of the listed values, or keep yours and Counta will try to read it.',
    });
  });
  if (rows) {
    rows.forEach((r, ri) => {
      const row = items.getRow(ri + 2);
      cols.forEach((c, i) => { const v = r[c.key]; row.getCell(i + 1).value = (v === '' || v == null ? null : v) as any; });
    });
  }
  items.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: cols.length } };
  if (example) {
    setup(example);
    ind.example.forEach((r, ri) => {
      const row = example.getRow(ri + 2);
      cols.forEach((c, i) => { row.getCell(i + 1).value = exampleValue(r, c.key, locations) as any; });
      row.font = { italic: true, color: { argb: 'FF4B5563' } };
    });
  }
  const g = [
    [`${orgName} · item import template`, 'h1'],
    [`${ind.label}. Fill the Items sheet and upload it from Inventory → Items → Upload.`, ''],
    ['', ''],
    ['What you need', 'h2'],
    ['Product name on every row. A selling price for goods you sell; raw materials, packaging, consumables, spares and chemicals may leave it blank.', ''],
    ['Everything else is optional. Leave a column blank rather than writing "nil" or "N/A".', ''],
    ['', ''],
    ['Units', 'h2'],
    ['"Buy by the" is how the item arrives (Carton, Bag, Drum). "Sell by the" is how you sell or count it (piece, pack, kg). "Units per purchase unit" links them: 1 carton = 40 packs.', ''],
    ['Costs, prices and quantities are per selling unit. If your figures are per carton, upload them anyway and tell Counta on the matching screen.', ''],
    ['', ''],
    ['Opening stock', 'h2'],
    ['Each "Opening qty" column is stock at that branch today. It posts once, for new items, as Dr Inventory / Cr Opening Balance Equity at the cost you give.', ''],
    ['Uploading the sheet again updates existing items (matched by Catalogue ID, barcode or name). Quantities of existing items change only through a stock count.', ''],
    ...(ind.batches ? [['Batch and expiry: one batch per row. Repeat the item on another row for a second batch.', ''] as [string, string]] : []),
    ['', ''],
    ['Your own sheet works too', 'h2'],
    ['You do not have to use this template. Upload the sheet you already keep and match its columns on screen; Martina suggests the matches.', ''],
  ];
  guide.getColumn(1).width = 120;
  g.forEach(([text, style], i) => {
    const cell = guide.getCell(`A${i + 1}`);
    cell.value = text; cell.alignment = { wrapText: true, vertical: 'top' };
    if (style === 'h1') cell.font = { bold: true, size: 14, color: { argb: BLUE } };
    else if (style === 'h2') cell.font = { bold: true, size: 11 };
  });
  wb.views = [{ activeTab: 0 } as any];
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

export function templateXlsx(industry: string | undefined, locations: Location[], orgName: string) {
  return buildTemplate(industry, locations, orgName, null);
}

// The item master in the template layout, so it can be edited and uploaded again.
export function itemsXlsx(inv: Inventory) {
  const fields = fieldsFor(inv.org.industry);
  const rows = inv.items.map((i) => {
    const r: Record<string, unknown> = {
      name: i.name, sku: i.sku, barcode: i.barcode, category: i.category, brand: i.brand, item_type: typeLabel(i.item_type),
      purchase_unit: i.purchase_unit, pack_size: i.pack_size, selling_unit: i.selling_unit,
      cost: inv.can_see_costs && i.wac != null ? Math.round(Number(i.wac) * 100) / 100 : null,
      price: Number(i.price) > 0 ? Number(i.price) : null, vat_treatment: i.vat_treatment, reorder_floor: Number(i.reorder_floor),
      vendor: inv.vendors.find((v) => v.id === i.preferred_vendor_id)?.name || null, nafdac_no: i.nafdac_no,
      track_batches: i.track_batches ? 'Yes' : 'No', description: i.description,
    };
    for (const f of fields) {
      const v = i.attributes?.[f.key];
      r['attr:' + f.key] = v == null ? null : f.type === 'bool' ? (v === true || /^(true|yes)$/i.test(String(v)) ? 'Yes' : 'No') : v;
    }
    for (const l of inv.locations) r['qty@' + l.id] = Number(i.qty?.[l.id] || 0) || null;
    return r;
  });
  return buildTemplate(inv.org.industry, inv.locations, inv.org.name, rows);
}

// ---------- the books: statements and ledgers ----------
// Statements carry _style (heading, subheading, line, subtotal, total, text, warning) and _indent on each row. Negative
// amounts print in brackets, as accountants expect; a zero prints as a dash.
export type StyledRow = Record<string, unknown> & { _style?: string; _indent?: number };
export interface AccountsSheet { meta: ReportMeta; cols: RCol[]; rows: StyledRow[]; extra?: string[] }
const ACC_FMT = '#,##0.00;(#,##0.00);"–"';

function addAccountsSheet(wb: any, s: AccountsSheet) {
  const { meta, cols, rows } = s;
  const extra = s.extra || [];
  const styled = rows.some((r) => r._style);
  const ws = wb.addWorksheet(meta.title.replace(/[*?:\\/[\]]/g, '').slice(0, 31), {
    views: [{ state: 'frozen', ySplit: 5 + extra.length }],
    pageSetup: { orientation: cols.length > 6 ? 'landscape' : 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0, paperSize: 9 },
  });
  ws.getCell('A1').value = meta.org; ws.getCell('A1').font = { bold: true, size: 14, color: { argb: INK } };
  ws.getCell('A2').value = meta.title; ws.getCell('A2').font = { bold: true, size: 12, color: { argb: BLUE } };
  ws.getCell('A3').value = `${meta.period} · ${meta.branch} · generated ${meta.generated} by ${meta.by}`; ws.getCell('A3').font = { size: 9, color: { argb: 'FF6B7280' } };
  extra.forEach((l, i) => { const cl = ws.getCell(`A${4 + i}`); cl.value = l; cl.font = { size: 9, italic: true, color: { argb: 'FF374151' } }; });
  const hr = 5 + extra.length;
  const header = ws.getRow(hr);
  cols.forEach((col, i) => {
    const cell = header.getCell(i + 1);
    cell.value = col.label;
    cell.font = { bold: true, color: { argb: styled ? INK : 'FFFFFFFF' }, size: 10 };
    if (!styled) cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: BLUE } };
    else cell.border = { bottom: { style: 'thin', color: { argb: INK } } };
    const numeric = col.type && col.type !== 'text' && col.type !== 'date';
    cell.alignment = { vertical: 'middle', wrapText: true, horizontal: numeric ? 'right' : 'left' };
    ws.getColumn(i + 1).width = i === 0 && styled ? 64 : widthFor(col);
    if (col.type === 'money') ws.getColumn(i + 1).numFmt = ACC_FMT;
    else { const f = fmtFor(col.type); if (f) ws.getColumn(i + 1).numFmt = f; }
    if (col.type === 'date') ws.getColumn(i + 1).numFmt = 'dd/mm/yyyy';
  });
  header.height = 30;
  rows.forEach((r, ri) => {
    const row = ws.getRow(hr + 1 + ri);
    const st = r._style || 'line';
    cols.forEach((col, i) => { row.getCell(i + 1).value = toCell(r[col.key], col.type) as any; });
    const first = row.getCell(1);
    first.alignment = { indent: Number(r._indent || 0) * 2, wrapText: st === 'text', vertical: 'top' };
    if (st === 'heading') { row.font = { bold: true, size: 11, color: { argb: INK } }; row.height = 20; }
    else if (st === 'subheading') row.font = { bold: true, italic: true, color: { argb: 'FF374151' } };
    else if (st === 'subtotal' || st === 'total') {
      row.font = { bold: true };
      cols.forEach((col, i) => {
        if (col.type !== 'money') return;
        row.getCell(i + 1).border = st === 'total'
          ? { top: { style: 'thin', color: { argb: INK } }, bottom: { style: 'double', color: { argb: INK } } }
          : { top: { style: 'thin', color: { argb: INK } } };
      });
    } else if (st === 'warning') row.font = { color: { argb: 'FFDC2626' } };
    else if (st === 'text') { row.font = { size: 10, color: { argb: 'FF374151' } }; ws.mergeCells(hr + 1 + ri, 1, hr + 1 + ri, cols.length); row.height = Math.min(120, 15 * Math.ceil(String(r[cols[0].key] || '').length / 110)); }
  });
  const last = hr + rows.length;
  if (!styled && rows.length && cols.some((cl) => cl.total)) {
    const tr = ws.getRow(last + 1);
    tr.getCell(1).value = 'Total';
    cols.forEach((col, i) => {
      if (!col.total) return;
      const L = colLetter(i);
      const result = rows.reduce((a, r) => a + (Number(r[col.key]) || 0), 0);
      tr.getCell(i + 1).value = { formula: `SUBTOTAL(9,${L}${hr + 1}:${L}${last})`, result: Math.round(result * 100) / 100 } as any;
      tr.getCell(i + 1).border = { top: { style: 'thin', color: { argb: INK } }, bottom: { style: 'double', color: { argb: INK } } };
    });
    tr.font = { bold: true };
  }
  if (!styled) ws.autoFilter = { from: { row: hr, column: 1 }, to: { row: Math.max(hr, last), column: cols.length } };
  if (meta.note) { const n = ws.getCell(`A${last + 3}`); n.value = meta.note; n.font = { size: 9, italic: true, color: { argb: 'FF6B7280' } }; }
}

export async function accountsXlsx(sheets: AccountsSheet[], cover?: ReportMeta): Promise<Blob> {
  const ExcelJS = await excel();
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  if (cover && sheets.length > 1) {
    const ws = wb.addWorksheet('Contents');
    ws.getCell('A1').value = cover.org; ws.getCell('A1').font = { bold: true, size: 14 };
    ws.getCell('A2').value = cover.title; ws.getCell('A2').font = { bold: true, size: 12, color: { argb: BLUE } };
    ws.getCell('A3').value = `${cover.period} · generated ${cover.generated} by ${cover.by}`; ws.getCell('A3').font = { size: 9, color: { argb: 'FF6B7280' } };
    ws.getColumn(1).width = 50;
    sheets.forEach((s, i) => {
      const cell = ws.getCell(`A${5 + i}`);
      const name = s.meta.title.replace(/[*?:\\/[\]]/g, '').slice(0, 31);
      cell.value = { text: s.meta.title, hyperlink: `#'${name}'!A1` } as any;
      cell.font = { color: { argb: BLUE }, underline: true };
    });
  }
  for (const s of sheets) addAccountsSheet(wb, s);
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

const accText = (v: unknown, t?: string) => {
  if (t === 'money') {
    if (v == null || v === '') return '';
    const n = Number(v);
    if (!Number.isFinite(n)) return String(v);
    if (Math.abs(n) < 0.005) return '-';
    const s = Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return n < 0 ? `(${s})` : s;
  }
  return pdfText(v, t);
};

export async function accountsPdf(sheets: AccountsSheet[], cover?: ReportMeta): Promise<Blob> {
  const [{ jsPDF }, { autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const wide = sheets.some((s) => s.cols.filter((c) => c.pdf !== false).length > 6);
  const doc = new jsPDF({ orientation: wide ? 'landscape' : 'portrait', unit: 'pt', format: 'a4' });
  const W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight();
  const footer = (title: string) => {
    doc.setFontSize(7); doc.setTextColor(156, 163, 175);
    doc.text(latin1(`Counta · TaxStreem · ${title}`), 36, H - 18);
    doc.text(`Page ${(doc as any).internal.getCurrentPageInfo().pageNumber}`, W - 36, H - 18, { align: 'right' });
  };
  if (cover && sheets.length > 1) {
    doc.setFont('helvetica', 'bold'); doc.setFontSize(20); doc.setTextColor(17, 24, 39); doc.text(latin1(cover.org), 36, 120);
    doc.setFontSize(14); doc.setTextColor(0, 114, 245); doc.text(latin1(cover.title), 36, 146);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(75, 85, 99); doc.text(latin1(cover.period), 36, 166);
    let y = 210;
    doc.setFontSize(10); doc.setTextColor(17, 24, 39);
    for (const s of sheets) { doc.text(latin1(s.meta.title), 36, y); y += 16; }
    if (cover.note) { doc.setFontSize(8); doc.setTextColor(107, 114, 128); doc.text(doc.splitTextToSize(latin1(cover.note), W - 72), 36, y + 20); }
    footer(cover.title);
  }
  sheets.forEach((s, si) => {
    if (si > 0 || (cover && sheets.length > 1)) doc.addPage();
    const pc = s.cols.filter((c) => c.pdf !== false);
    const styled = s.rows.some((r) => r._style);
    doc.setFont('helvetica', 'bold'); doc.setFontSize(12); doc.setTextColor(17, 24, 39); doc.text(latin1(s.meta.org), 36, 40);
    doc.setFontSize(11); doc.setTextColor(0, 114, 245); doc.text(latin1(s.meta.title), 36, 57);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(107, 114, 128);
    doc.text(latin1(`${s.meta.period} · ${s.meta.branch} · generated ${s.meta.generated} by ${s.meta.by}`), 36, 70);
    let y = 82;
    for (const l of s.extra || []) { doc.text(latin1(l), 36, y); y += 11; }
    const body: any[] = s.rows.map((r) => r._style === 'text'
      ? [{ content: accText(r[pc[0].key], pc[0].type), colSpan: pc.length }]
      : pc.map((c, i) => {
        const v = accText(r[c.key], c.type);
        return i === 0 && r._indent ? '    '.repeat(Number(r._indent)) + v : v;
      }));
    const totals = !styled && pc.some((c) => c.total) && s.rows.length
      ? [pc.map((c, i) => (i === 0 ? 'Total' : c.total ? accText(s.rows.reduce((a, r) => a + (Number(r[c.key]) || 0), 0), c.type) : ''))] : undefined;
    autoTable(doc as any, {
      startY: y + 4,
      head: [pc.map((c) => latin1(c.label))],
      body,
      foot: totals,
      showFoot: 'lastPage',
      theme: styled ? 'plain' : 'grid',
      styles: { font: 'helvetica', fontSize: pc.length > 10 ? 6.5 : 8, cellPadding: styled ? 2.5 : 3, overflow: 'linebreak', lineColor: [230, 230, 230], lineWidth: styled ? 0 : 0.4 },
      headStyles: styled ? { textColor: [17, 24, 39], fontStyle: 'bold', lineWidth: { bottom: 0.8 } as any, lineColor: [17, 24, 39] } : { fillColor: [0, 114, 245], textColor: 255, fontStyle: 'bold' },
      footStyles: { fillColor: [243, 244, 246], textColor: [17, 24, 39], fontStyle: 'bold' },
      columnStyles: Object.fromEntries(pc.map((c, i) => [i, { halign: c.type && c.type !== 'text' && c.type !== 'date' ? 'right' : 'left', ...(styled && i === 0 ? { cellWidth: 'auto' } : {}) }])) as any,
      didParseCell: (d: any) => {
        if (d.section !== 'body' || !styled) return;
        const st = s.rows[d.row.index]?._style || 'line';
        if (st === 'heading') { d.cell.styles.fontStyle = 'bold'; d.cell.styles.fontSize = 9.5; d.cell.styles.cellPadding = { top: 8, bottom: 3, left: 2.5, right: 2.5 }; }
        if (st === 'subheading') d.cell.styles.fontStyle = 'bolditalic';
        if (st === 'subtotal' || st === 'total') {
          d.cell.styles.fontStyle = 'bold';
          if (d.column.index > 0 && pc[d.column.index]?.type === 'money') {
            d.cell.styles.lineWidth = st === 'total' ? { top: 0.6, bottom: 1.6 } : { top: 0.6 };
            d.cell.styles.lineColor = [17, 24, 39];
          }
        }
        if (st === 'warning') d.cell.styles.textColor = [220, 38, 38];
        if (st === 'text') d.cell.styles.textColor = [55, 65, 81];
      },
      margin: { left: 36, right: 36, bottom: 40 },
      didDrawPage: () => footer(s.meta.title),
    });
    if (s.meta.note) {
      const fy = ((doc as any).lastAutoTable?.finalY || y) + 16;
      doc.setFontSize(7.5); doc.setTextColor(107, 114, 128); doc.text(doc.splitTextToSize(latin1(s.meta.note), W - 72), 36, fy);
    }
  });
  return doc.output('blob');
}

export function accountsCsv(cols: RCol[], rows: StyledRow[]): Blob {
  return reportCsv(cols, rows.map((r) => (r._indent ? { ...r, [cols[0].key]: '  '.repeat(Number(r._indent)) + String(r[cols[0].key] ?? '') } : r)));
}
