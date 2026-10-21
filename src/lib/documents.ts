// Documents: every file the business keeps in Counta, filed by year, month, kind and folder. The database lists them
// (documents_tree, documents_files); the files stay where they were stored, and the PDFs for sales documents, till days
// and PRNs are drawn when they are opened. A zip is put together here, in the browser, from the same files.
import { supabase, rpc } from './supabase';
import type { DocData } from '../components/InvoiceDoc';

export type DocCat = 'sales' | 'purchases' | 'tax' | 'bank' | 'accountant' | 'company' | 'other';
export const CATS: { id: DocCat; label: string; blurb: string }[] = [
  { id: 'sales', label: 'Sales', blurb: 'Invoices, receipts, credit notes, quotes, orders and delivery proofs' },
  { id: 'purchases', label: 'Purchases', blurb: 'Supplier invoices, input VAT claims, stock received and import entries' },
  { id: 'tax', label: 'Tax', blurb: 'Return files, filing evidence, PRNs and receipts from Flux' },
  { id: 'bank', label: 'Bank', blurb: 'Statements and bank letters' },
  { id: 'accountant', label: 'Accountant', blurb: 'What your accountant sent, and financial statements' },
  { id: 'company', label: 'Company', blurb: 'Registration, licences, contracts and insurance' },
  { id: 'other', label: 'Other', blurb: 'Anything else you keep' },
];
export const catLabel = (c: string) => CATS.find((x) => x.id === c)?.label || c;

export interface DocNode { year: number | null; month: number | null; cat: DocCat; folder: string; sub: string | null; n: number; bytes: number }
export interface DocTree { nodes: DocNode[]; can: Record<DocCat, boolean>; can_upload: boolean; business: string }
export interface DocFile {
  id: string; cat: DocCat; folder: string; sub: string | null; period: string | null; year: number | null; day: string | null; name: string;
  kind: 'file' | 'sale' | 'till' | 'prn'; path: string | null; mime: string | null; size: number | null; ref: string | null; party: string | null;
  amount: number | null; at: string | null; source: string;
}
// Where in the tree: a year (null: no date), a month (0: the full year), a kind, a folder and the folder's part ('' for
// files that sit in the folder itself).
export interface Place { year?: number | null; month?: number; cat?: DocCat; folder?: string; sub?: string }

export const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
export const monthLabel = (m: number) => (m === 0 ? 'Full year' : MONTHS[m - 1] || String(m));
export const yearLabel = (y: number | null) => (y == null ? 'No date' : String(y));

export const loadTree = (org: string) => rpc<DocTree>('documents_tree', { p_org: org });
export async function loadFiles(org: string, p: Record<string, unknown>): Promise<{ files: DocFile[]; more: boolean }> {
  return rpc('documents_files', { p_org: org, p });
}
// The filter documents_files takes for a place (the part '' is filtered here: the database has no "no part" filter).
export function placeFilter(at: Place, cat?: DocCat | 'all'): Record<string, unknown> {
  const p: Record<string, unknown> = {};
  if (at.year !== undefined) {
    p.year = at.year;
    if (at.year != null && at.month !== undefined) p.month = at.month;
  }
  const c = at.cat || (cat && cat !== 'all' ? cat : undefined);
  if (c) p.cat = c;
  if (at.folder) p.folder = at.folder;
  if (at.sub) p.sub = at.sub;
  return p;
}

// ------------------------------------------------------------------ names and types
const EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/heic': 'heic', 'text/csv': 'csv',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx', 'application/vnd.ms-excel': 'xls',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx', 'application/msword': 'doc', 'text/plain': 'txt', 'application/zip': 'zip' };
export function extOf(f: Pick<DocFile, 'kind' | 'path' | 'mime' | 'name'>): string {
  if (f.kind !== 'file') return 'pdf';
  const fromName = f.name.match(/\.([a-z0-9]{2,5})$/i)?.[1];
  const fromPath = String(f.path || '').match(/\.([a-z0-9]{2,5})$/i)?.[1];
  return (fromName || fromPath || EXT[String(f.mime || '').toLowerCase()] || 'file').toLowerCase();
}
export function formatOf(f: DocFile): string {
  const e = extOf(f);
  return ({ pdf: 'PDF', png: 'PNG image', jpg: 'JPEG image', jpeg: 'JPEG image', webp: 'WebP image', heic: 'HEIC image', xlsx: 'Excel workbook', xls: 'Excel workbook',
    csv: 'CSV file', docx: 'Word document', doc: 'Word document', txt: 'Text file', zip: 'Zip file' } as Record<string, string>)[e] || e.toUpperCase();
}
export const isImage = (f: DocFile) => ['png', 'jpg', 'jpeg', 'webp', 'gif'].includes(extOf(f));
export const isPdf = (f: DocFile) => extOf(f) === 'pdf';
// A name that is safe as a file name everywhere, with its extension.
export function fileName(f: DocFile): string {
  const e = extOf(f);
  let base = f.name.replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 120) || 'document';
  if (!new RegExp(`\\.${e}$`, 'i').test(base)) base += `.${e}`;
  return base;
}
export function sizeLabel(n?: number | null): string {
  if (!n) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
// Where a file sits, as words: "2026 · October · Sales · Invoices".
export function placeOf(f: DocFile): string {
  const m = f.period ? Number(f.period.slice(5, 7)) : f.year != null ? 0 : null;
  return [yearLabel(f.year), m != null && f.year != null ? monthLabel(m) : '', catLabel(f.cat), f.folder, f.sub || ''].filter(Boolean).join(' · ');
}

// ------------------------------------------------------------------ the file itself
// Generated PDFs are drawn from the data; stored files are downloaded with the person's own session, so the storage
// rules decide what they may read.
const saleCache = new Map<string, DocData>();
async function salesData(org: string, ids: string[]): Promise<Map<string, DocData>> {
  const need = ids.filter((id) => !saleCache.has(id));
  for (let i = 0; i < need.length; i += 200) {
    const rows = await rpc<any[]>('documents_sales', { p_org: org, p_ids: need.slice(i, i + 200) });
    for (const r of rows || []) saleCache.set(String(r.id), r as DocData);
  }
  return new Map(ids.filter((id) => saleCache.has(id)).map((id) => [id, saleCache.get(id)!]));
}

export async function fileBlob(org: string, f: DocFile, preloaded?: Map<string, DocData>): Promise<Blob> {
  const pdf = await import('./docPdf');
  if (f.kind === 'sale') {
    const d = preloaded?.get(String(f.ref)) || (await salesData(org, [String(f.ref)])).get(String(f.ref));
    if (!d) throw new Error('That document is no longer there.');
    return pdf.salePdf(d as any);
  }
  if (f.kind === 'till') return pdf.tillPdf(await rpc('documents_till', { p_org: org, p_day: f.ref }));
  if (f.kind === 'prn') return pdf.prnPdf(await rpc('documents_prn', { p_org: org, p_id: f.ref }));
  if (!f.path) throw new Error('This record has no file.');
  const { data, error } = await supabase.storage.from('documents').download(f.path);
  if (error || !data) throw new Error(/not.?found|404/i.test(String(error?.message)) ? 'The file is not in storage any more.' : (error?.message || 'The file did not download.'));
  return data.type || !f.mime ? data : new Blob([data], { type: f.mime });
}

// A link to look at a stored file for half an hour (images and PDFs show in the preview with it).
export async function viewUrl(f: DocFile): Promise<string | null> {
  if (f.kind !== 'file' || !f.path) return null;
  const { data } = await supabase.storage.from('documents').createSignedUrl(f.path, 60 * 30);
  return data?.signedUrl ?? null;
}

// ------------------------------------------------------------------ uploads
export const FOLDERS: Record<DocCat, string[]> = {
  sales: ['Invoices', 'Receipts', 'Credit notes', 'Delivery proofs', 'Contracts', 'Other'],
  purchases: ['Supplier invoices', 'Supplier credit notes', 'Import entries', 'Contracts', 'Other'],
  tax: ['VAT', 'WHT', 'Withholding VAT', 'CIT', 'Other'],
  bank: ['Statements', 'Loan papers', 'Other'],
  accountant: ['Working papers', 'Letters', 'Other'],
  company: ['Registration', 'Licences and permits', 'Contracts', 'Insurance', 'Other'],
  other: ['Other'],
};
export const MAX_UPLOAD = 25 * 1024 * 1024;
// A storage key Supabase accepts: plain letters, digits and a few marks.
export const storageSafe = (name: string) => name.normalize('NFKD').replace(/[^\w.\-() ]+/g, '_').replace(/\s+/g, ' ').trim().slice(-120) || 'file';

export async function uploadDocument(org: string, file: File, o: { cat: DocCat; folder: string; period: string | null; year: number | null; notes?: string }) {
  if (file.size > MAX_UPLOAD) throw new Error(`${file.name} is larger than 25 MB.`);
  const id = crypto.randomUUID();
  const path = o.cat === 'tax' ? `${org}/tax/uploads/${id}-${storageSafe(file.name)}` : `${org}/documents/${o.cat}/${id}-${storageSafe(file.name)}`;
  // The record first, so the database's checks run before anything is stored; taken out again if the upload fails.
  const saved = await rpc<{ id: string; path: string }>('document_save', { p_org: org, p: { path, name: file.name, mime: file.type || null, size: file.size,
    cat: o.cat, folder: o.cat === 'tax' && o.folder === 'Other' ? 'Uploaded' : o.folder, period: o.period, year: o.year, notes: o.notes || null } });
  const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
  if (error) {
    await rpc('document_delete', { p_org: org, p_id: saved.id }).catch(() => null);
    throw new Error(`${file.name} did not upload: ${error.message}`);
  }
  return saved;
}

// The file first: storage lets the uploader (or the owner) remove it only while Documents still lists it. Then the record.
export async function removeDocument(org: string, f: DocFile) {
  const id = f.id.replace(/^doc:/, '');
  if (f.path) {
    const { error } = await supabase.storage.from('documents').remove([f.path]);
    if (error) throw new Error(`The file could not be removed: ${error.message}`);
  }
  await rpc<{ ok: boolean; path: string }>('document_delete', { p_org: org, p_id: id });
}

// ------------------------------------------------------------------ zip
export interface ZipProgress { done: number; total: number; failed: { name: string; why: string }[] }

// Every file in a place, as a zip laid out the way Documents shows it: <business> documents/<year>/<month>/<kind>/<folder>/<part>/.
export async function zipPlace(org: string, business: string, files: DocFile[], onProgress: (p: ZipProgress) => void, cancelled: () => boolean): Promise<Blob> {
  const { zipSync, strToU8 } = await import('fflate');
  const root = `${business.replace(/[\\/:*?"<>|]+/g, '-').trim() || 'Counta'} documents`;
  const out: Record<string, Uint8Array> = {};
  const used = new Set<string>();
  const failed: { name: string; why: string }[] = [];
  const sales = await salesData(org, files.filter((f) => f.kind === 'sale' && f.ref).map((f) => String(f.ref)));
  let done = 0;
  onProgress({ done, total: files.length, failed });
  const queue = files.slice();
  const work = async () => {
    for (let f = queue.shift(); f; f = queue.shift()) {
      if (cancelled()) return;
      try {
        const blob = await fileBlob(org, f, sales);
        const m = f.period ? Number(f.period.slice(5, 7)) : f.year != null ? 0 : null;
        const dir = [root, yearLabel(f.year), m != null && f.year != null ? `${String(m).padStart(2, '0')} ${monthLabel(m)}` : '', catLabel(f.cat), f.folder, f.sub || '']
          .filter(Boolean).map((x) => x.replace(/[\\/:*?"<>|]+/g, '-')).join('/');
        let name = `${dir}/${fileName(f)}`;
        for (let i = 2; used.has(name.toLowerCase()); i++) name = `${dir}/${fileName(f).replace(/(\.[a-z0-9]+)$/i, ` (${i})$1`)}`;
        used.add(name.toLowerCase());
        out[name] = new Uint8Array(await blob.arrayBuffer());
      } catch (e) { failed.push({ name: f.name, why: (e as Error).message }); }
      done++;
      onProgress({ done, total: files.length, failed });
    }
  };
  await Promise.all([work(), work(), work(), work()]);
  if (cancelled()) throw new Error('cancelled');
  if (failed.length) out[`${root}/Files that could not be added.txt`] = strToU8(failed.map((x) => `${x.name}: ${x.why}`).join('\r\n'));
  // Stored, not squeezed again: PDFs and photos are compressed already.
  return new Blob([zipSync(out, { level: 0 })], { type: 'application/zip' });
}
