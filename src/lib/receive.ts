// Shared receiving logic for the desktop flow and the phone app.
import { ai, must, rpc, supabase } from './supabase';
import type { Inventory, Item, NewItemDraft, Receipt, ReceiptLine } from './types';
import { uuid } from './format';
import { pluralUnit, puAbbr, suAbbr } from './domain';

export type Source = 'typed' | 'hand' | 'manual';
export const DOUBT = 85;

export interface DraftLine extends ReceiptLine {
  id: string;
  touched?: boolean; // user edited or confirmed a doubtful reading (stored as a training correction)
}

// Phones produce 4–12MB photos. Downscale to ~2000px JPEG before upload so reading is fast on Nigerian data plans.
export async function compressImage(file: File, max = 2000, quality = 0.82): Promise<Blob> {
  if (!file.type.startsWith('image/') || file.type === 'image/gif') return file;
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, max / Math.max(bmp.width, bmp.height));
    if (scale === 1 && file.size < 2_500_000) { bmp.close?.(); return file; }
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
    c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
    bmp.close?.();
    const blob = await new Promise<Blob | null>((res) => c.toBlob(res, 'image/jpeg', quality));
    return blob && blob.size < file.size ? blob : file;
  } catch {
    return file;
  }
}

export async function uploadDocument(orgId: string, file: Blob, name = 'invoice'): Promise<{ path: string; mime: string }> {
  const mime = file.type || (name.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/jpeg');
  const ext = mime === 'application/pdf' ? 'pdf' : mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : 'jpg';
  const path = `${orgId}/receipts/${new Date().toISOString().slice(0, 10)}-${uuid()}.${ext}`;
  const { error } = await supabase.storage.from('documents').upload(path, file, { contentType: mime, upsert: false });
  if (error) throw new Error(error.message.includes('row-level') ? 'Your role cannot upload invoices.' : error.message);
  return { path, mime };
}

export function sourceFor(mode: Source, mime?: string | null): Receipt['source'] {
  if (mode === 'manual') return 'manual';
  if (mode === 'hand') return 'photo_handwritten';
  return mime === 'application/pdf' ? 'pdf' : 'photo_typed';
}

export async function startReceipt(args: {
  orgId: string; mode: Source; path?: string | null; mime?: string | null; location?: string | null; vendor?: string | null;
  po?: string | null; clientUuid?: string | null; device?: string | null; offline?: boolean;
}): Promise<Receipt> {
  return rpc<Receipt>('start_receipt', {
    p_org: args.orgId, p_source: sourceFor(args.mode, args.mime), p_document_path: args.path ?? null, p_document_mime: args.mime ?? null,
    p_location: args.location ?? null, p_vendor: args.vendor ?? null, p_po: args.po ?? null,
    p_client_uuid: args.clientUuid ?? null, p_device: args.device ?? null, p_offline: args.offline ?? false,
  });
}

export interface ReadResult { ok: boolean; reason?: string; error?: string; lines?: number; doubtful?: number; other_charges?: { label: string; amount: number }[] }
export async function readInvoice(receiptId: string): Promise<ReadResult> {
  return ai<ReadResult>('read_invoice', { receipt_id: receiptId });
}

export async function loadReceipt(id: string): Promise<Receipt> {
  return must<Receipt>(supabase.from('receipts').select('*, receipt_lines(*)').eq('id', id).single());
}

export function toDraft(lines: ReceiptLine[] | undefined): DraftLine[] {
  return [...(lines || [])].sort((a, b) => a.line_no - b.line_no).map((l) => ({ ...l, id: l.id || uuid(), qty: Number(l.qty), unit_cost: Number(l.unit_cost) }));
}

export function blankLine(n: number, item?: Item | null): DraftLine {
  return {
    id: uuid(), line_no: n, raw_text: null, item_id: item?.id ?? null, new_item: null, qty: 1, unit_kind: 'purchase',
    unit_label: item ? puAbbr(item.purchase_unit) : null, unit_cost: item ? Math.round(Number(item.last_cost ?? item.wac ?? 0) * item.pack_size * 100) / 100 : 0,
    confidence: 100, alt_reading: null, bbox: null, confirmed: true, model_reading: null, batch_no: null, expiry_date: null,
  };
}

export function lineItem(inv: Inventory | undefined, l: Pick<ReceiptLine, 'item_id'>): Item | null {
  return l.item_id ? inv?.items.find((i) => i.id === l.item_id) || null : null;
}

// Units a line can be counted in: purchase unit (carton) or selling unit (pack).
export function unitOptions(item: Item | null, nw: NewItemDraft | null): { kind: 'purchase' | 'selling'; label: string; hint: string }[] {
  const pu = item?.purchase_unit || nw?.purchase_unit || 'Carton';
  const su = item?.selling_unit || nw?.selling_unit || 'piece';
  const pack = Number(item?.pack_size || nw?.pack_size || 1);
  if (pack <= 1) return [{ kind: 'purchase', label: suAbbr(su), hint: su }];
  return [
    { kind: 'purchase', label: puAbbr(pu), hint: `${pu} of ${pack} ${pluralUnit(su, pack)}` },
    { kind: 'selling', label: suAbbr(su), hint: su },
  ];
}

export function unitLabel(item: Item | null, l: Pick<ReceiptLine, 'unit_kind' | 'new_item' | 'unit_label'>): string {
  const nw = l.new_item;
  const pack = Number(item?.pack_size || nw?.pack_size || 1);
  if (l.unit_kind === 'purchase' && pack > 1) return puAbbr(item?.purchase_unit || nw?.purchase_unit || 'Carton');
  return suAbbr(item?.selling_unit || nw?.selling_unit || l.unit_label || 'unit');
}

export function vatTreatment(item: Item | null, l: Pick<ReceiptLine, 'new_item'>): 'standard' | 'zero' | 'exempt' {
  return item?.vat_treatment || l.new_item?.vat_treatment || 'standard';
}

export function totals(inv: Inventory | undefined, lines: DraftLine[], vendorVat: boolean) {
  let net = 0; let base = 0;
  for (const l of lines) {
    const t = Math.round(Number(l.qty || 0) * Number(l.unit_cost || 0) * 100) / 100;
    net += t;
    if (vatTreatment(lineItem(inv, l), l) === 'standard') base += t;
  }
  const vat = vendorVat ? Math.round(base * 0.075 * 100) / 100 : 0;
  return { net: Math.round(net * 100) / 100, vat, gross: Math.round((net + vat) * 100) / 100, vatBase: base };
}

export function isDoubtful(l: DraftLine): boolean { return !l.confirmed; }

export function lineProblems(lines: DraftLine[]): string | null {
  if (!lines.length) return 'Add at least one line.';
  const doubt = lines.filter((l) => !l.confirmed).length;
  if (doubt) return `${doubt} line${doubt === 1 ? '' : 's'} still need${doubt === 1 ? 's' : ''} confirmation.`;
  const noItem = lines.filter((l) => !l.item_id && !(l.new_item?.name || '').trim()).length;
  if (noItem) return `${noItem} line${noItem === 1 ? ' has' : 's have'} no item. Pick one or name the new item.`;
  const badQty = lines.filter((l) => !(Number(l.qty) > 0)).length;
  if (badQty) return `${badQty} line${badQty === 1 ? ' needs' : 's need'} a quantity above zero.`;
  const badCost = lines.filter((l) => !(Number(l.unit_cost) > 0)).length;
  if (badCost) return `${badCost} line${badCost === 1 ? ' needs' : 's need'} a unit cost above zero.`;
  const badPack = lines.filter((l) => !l.item_id && !(Number(l.new_item?.pack_size) >= 1 && Number.isInteger(Number(l.new_item?.pack_size)))).length;
  if (badPack) return 'Pack size on a new item must be a whole number of at least 1.';
  return null;
}

// Persist header + lines, and store every correction as (raw_text, model_reading, user_reading).
export async function saveDraft(args: {
  receipt: Receipt; lines: DraftLine[]; removed: string[]; memberId: string;
  header: { vendor_id: string | null; vendor_name: string | null; invoice_no: string | null; location_id: string | null; vendor_vat_registered: boolean };
}) {
  const { receipt: r, lines, removed, memberId, header } = args;
  await must(supabase.from('receipts').update({ ...header, status: 'needs_review' }).eq('id', r.id));
  if (removed.length) await must(supabase.from('receipt_lines').delete().in('id', removed));
  if (lines.length) {
    const rows = lines.map((l, i) => ({
      id: l.id, receipt_id: r.id, org_id: r.org_id, line_no: i + 1, raw_text: l.raw_text, item_id: l.item_id,
      new_item: l.item_id ? null : l.new_item, qty: Number(l.qty), unit_kind: l.unit_kind, unit_label: l.unit_label,
      unit_cost: Number(l.unit_cost), confidence: l.confidence, alt_reading: l.alt_reading, bbox: l.bbox, confirmed: l.confirmed,
      model_reading: l.model_reading, batch_no: l.batch_no || null, expiry_date: l.expiry_date || null,
    }));
    await must(supabase.from('receipt_lines').upsert(rows));
  }
  const corrections = lines.filter((l) => l.touched && l.model_reading).map((l) => ({
    org_id: r.org_id, receipt_id: r.id, line_id: l.id, raw_text: l.raw_text, model_reading: l.model_reading,
    user_reading: { item_id: l.item_id, new_item: l.item_id ? null : l.new_item?.name, qty: Number(l.qty), unit_kind: l.unit_kind, unit_cost: Number(l.unit_cost) },
    created_by: memberId,
  }));
  if (corrections.length) {
    try { await supabase.from('ocr_corrections').insert(corrections); } catch { /* training data is best-effort */ }
    for (const l of lines) l.touched = false;
  }
}

export async function postReceipt(id: string): Promise<{ journal_ref: string; net: number; vat: number; gross: number; proposals: number }> {
  return rpc('post_receipt', { p_receipt: id });
}

export function readingLabel(item: Item | null, l: DraftLine): string {
  const name = item?.name || l.new_item?.name || 'Unmatched item';
  return `${Number(l.qty).toLocaleString('en-NG', { maximumFractionDigits: 3 })} ${unitLabel(item, l)} ${name}`;
}
