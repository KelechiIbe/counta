// A product from two photos taken on a phone: the front (name, brand, size) and the back (barcode, NAFDAC number, maker).
// The phone reads the barcode itself; Gemini reads the rest. The person checks everything before it is saved.

const NL = String.fromCharCode(10);

export const PRODUCT_SYSTEM = [
  'You read the packaging of a product a Nigerian business sells, from photos of its front and back, so it can be added to the',
  'business\'s stock list in Counta. Read only what is printed; leave a field empty when it is not shown. Never guess a price.',
  'name: how a shop would list it, brand first, then the product, variant and size, for example "Peak Full Cream Milk Powder 400g"',
  'or "Indomie Instant Noodles Chicken 70g". Title case, no marketing words.',
  'selling_unit: the single unit a customer buys (tin, sachet, bottle, can, pack, carton, bag, piece, tube, box, roll, bar, jar, pair).',
  'If the pack shows how many come in a carton or case (for example "24 x 400g"), give pack_size and purchase_unit.',
  'category: one of the business\'s categories when one fits, otherwise a short new one.',
  'barcode_digits: the digits printed under the barcode, if readable. nafdac_no: the NAFDAC registration number, if printed.',
  'expiry_date and batch_no only when printed (dates as YYYY-MM-DD).',
  'item_type: merchandise for goods bought to resell, finished_good for goods the business makes.',
  'confidence: 0 to 1, how sure you are of the name and size together. Add warnings for anything the person should check.',
].join(NL);

const nstr = { type: 'STRING', nullable: true };
export const PRODUCT_SCHEMA = {
  type: 'OBJECT',
  properties: {
    name: { type: 'STRING' }, brand: nstr, variant: nstr, size: nstr, description: nstr, category: nstr,
    selling_unit: nstr, purchase_unit: nstr, pack_size: { type: 'INTEGER', nullable: true },
    barcode_digits: nstr, nafdac_no: nstr, manufacturer: nstr, country_of_origin: nstr, expiry_date: nstr, batch_no: nstr,
    item_type: { type: 'STRING', enum: ['merchandise', 'finished_good'] },
    confidence: { type: 'NUMBER' },
    warnings: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['name', 'item_type', 'confidence', 'warnings'],
};

const line = (v: unknown, n: number) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
const opt = (v: unknown, n: number) => line(v, n) || null;

// EAN-13, EAN-8, UPC-A and UPC-E with a correct check digit, or nothing.
export function validBarcode(v: unknown): string | null {
  const d = String(v ?? '').replace(/\D/g, '');
  if (![8, 12, 13, 14].includes(d.length)) return null;
  const digits = d.split('').map(Number);
  const check = digits.pop()!;
  const sum = digits.reverse().reduce((s, n, i) => s + n * (i % 2 === 0 ? 3 : 1), 0);
  return (10 - (sum % 10)) % 10 === check ? d : null;
}

const UNITS = ['tin', 'sachet', 'bottle', 'can', 'pack', 'carton', 'bag', 'piece', 'tube', 'box', 'roll', 'bar', 'jar', 'pair', 'packet', 'cup', 'crate', 'kg', 'litre'];

export function cleanProduct(d: any, deviceBarcode: string | null, categories: string[]) {
  const warnings: string[] = (Array.isArray(d?.warnings) ? d.warnings : []).map((w: unknown) => line(w, 200)).filter(Boolean).slice(0, 4);
  const printed = validBarcode(d?.barcode_digits);
  let barcode = deviceBarcode;
  if (!barcode && printed) barcode = printed;
  if (deviceBarcode && printed && deviceBarcode !== printed) warnings.push('The digits printed under the barcode differ from what the camera read. Scan it once more.');
  if (!barcode && d?.barcode_digits) warnings.push('The barcode could not be read. Scan it, or type the digits.');
  const su = line(d?.selling_unit, 20).toLowerCase();
  const pu = line(d?.purchase_unit, 20);
  const pack = Number(d?.pack_size);
  const cat = line(d?.category, 40);
  const known = categories.find((c) => c.toLowerCase() === cat.toLowerCase());
  const expiry = /^\d{4}-\d{2}-\d{2}$/.test(String(d?.expiry_date || '')) ? String(d.expiry_date) : null;
  const conf = Number(d?.confidence);
  return {
    name: line(d?.name, 120), brand: opt(d?.brand, 60), variant: opt(d?.variant, 60), size: opt(d?.size, 30), description: opt(d?.description, 300),
    category: known || cat || null, selling_unit: UNITS.includes(su) ? su : su ? su.slice(0, 20) : 'piece',
    purchase_unit: pu ? pu.charAt(0).toUpperCase() + pu.slice(1).toLowerCase() : null,
    pack_size: Number.isInteger(pack) && pack >= 1 && pack <= 1000 ? pack : null,
    barcode, nafdac_no: opt(d?.nafdac_no, 30), manufacturer: opt(d?.manufacturer, 120), country_of_origin: opt(d?.country_of_origin, 60),
    expiry_date: expiry, batch_no: opt(d?.batch_no, 40),
    item_type: d?.item_type === 'finished_good' ? 'finished_good' : 'merchandise',
    confidence: Number.isFinite(conf) ? Math.max(0, Math.min(1, Math.round(conf * 100) / 100)) : 0,
    warnings,
  };
}
