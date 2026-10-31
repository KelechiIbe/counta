// Receipts: on a Bluetooth thermal printer (ESC/POS over Web Bluetooth, Chrome on Android and desktop) or through the
// browser's print dialog on an 80 mm or A4 page.
import type { Sale } from './api';
import { vatPct } from './vat';
import { qrSvg } from './labels';

// Services that common 58 mm and 80 mm Bluetooth receipt printers expose.
const SERVICES = [
  '000018f0-0000-1000-8000-00805f9b34fb', 'e7810a71-73ae-499d-8c15-faa9aef0c3f2', '49535343-fe7d-4ae5-8fa9-9fafd205e455',
  '0000ff00-0000-1000-8000-00805f9b34fb', '0000ffe0-0000-1000-8000-00805f9b34fb', '0000fee7-0000-1000-8000-00805f9b34fb',
];
let char: any = null;
let deviceName = '';

export const bluetoothSupported = () => typeof navigator !== 'undefined' && !!(navigator as any).bluetooth;
export const printerName = () => (char ? deviceName : '');

async function findWritable(server: any): Promise<any> {
  const services = await server.getPrimaryServices();
  for (const s of services) {
    for (const c of await s.getCharacteristics()) {
      if (c.properties.writeWithoutResponse || c.properties.write) return c;
    }
  }
  throw new Error('This printer does not accept print jobs over Bluetooth.');
}

export async function connectPrinter(): Promise<string> {
  if (!bluetoothSupported()) throw new Error('This browser cannot reach Bluetooth printers. Use Chrome on Android or a computer.');
  const device = await (navigator as any).bluetooth.requestDevice({ acceptAllDevices: true, optionalServices: SERVICES });
  const server = await device.gatt.connect();
  char = await findWritable(server);
  deviceName = device.name || 'Printer';
  device.addEventListener('gattserverdisconnected', () => { char = null; });
  return deviceName;
}

async function write(bytes: Uint8Array) {
  if (!char) await connectPrinter();
  for (let i = 0; i < bytes.length; i += 180) {
    const chunk = bytes.slice(i, i + 180);
    if (char.properties.writeWithoutResponse) await char.writeValueWithoutResponse(chunk);
    else await char.writeValue(chunk);
  }
}

// ESC/POS: plain ASCII (₦ becomes "N"), 32 columns on 58 mm paper, 48 on 80 mm.
const ascii = (s: string) => s.replace(/₦/g, 'N').replace(/[−–—]/g, '-').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').normalize('NFD').replace(/[^\x20-\x7E]/g, '');
const amt = (n: number) => Number(n).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function receiptText(s: Sale, width = 32): string[] {
  const out: string[] = [];
  const pad = (l: string, r: string) => { l = ascii(l); r = ascii(r); const space = width - r.length; return (l.length > space - 1 ? l.slice(0, space - 1) : l).padEnd(space) + r; };
  const center = (t: string) => { t = ascii(t).slice(0, width); const p = Math.floor((width - t.length) / 2); return ' '.repeat(Math.max(p, 0)) + t; };
  const rule = '-'.repeat(width);
  out.push(center(s.org?.name || ''));
  if (s.org?.address) out.push(center(s.org.address));
  if (s.org?.phone) out.push(center(s.org.phone));
  if (s.org?.tin) out.push(center('Tax ID ' + s.org.tin));
  out.push(rule);
  out.push(pad(`${s.doc_type === 'receipt' ? 'Receipt' : s.doc_type === 'invoice' ? 'Invoice' : 'Document'} ${s.number}`, new Date(s.created_at).toLocaleString('en-GB', { timeZone: 'Africa/Lagos', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })));
  if (s.customer_name && !/walk-in/i.test(s.customer_name)) out.push(ascii('Customer: ' + s.customer_name).slice(0, width));
  out.push(rule);
  for (const l of s.lines || []) {
    out.push(ascii(l.description).slice(0, width));
    out.push(pad(`  ${Number(l.qty)} x ${amt(l.unit_price)}${Number(l.discount) ? ` -${amt(l.discount)}` : ''}`, amt(l.gross)));
  }
  out.push(rule);
  if (Number(s.vat_total)) out.push(pad(`VAT ${vatPct(s.issue_date || String(s.created_at || '').slice(0, 10) || null)} (included)`, amt(s.vat_total)));
  out.push(pad('TOTAL', 'N' + amt(s.total)));
  for (const p of s.payments || []) if (p.direction !== 'out') out.push(pad(`Paid ${p.method === 'flutterwave' || p.method === 'rail' ? 'transfer' : p.method}`, amt(p.amount)));
  if (Number(s.change)) out.push(pad('Change', amt(Number(s.change))));
  if (Number(s.balance) > 0.004) out.push(pad('Balance due', amt(s.balance)));
  out.push(rule);
  // The NRS e-invoice reference, once the receipt may reach the buyer.
  if (stamped(s)) {
    out.push(center('NRS e-invoice' + (s.einvoice!.state === 'signed' ? ', signed' : '')));
    const irn = 'IRN ' + s.einvoice!.irn;
    for (let i = 0; i < irn.length; i += width) out.push(center(irn.slice(i, i + width)));
    out.push(rule);
  }
  if (s.org?.receipt_footer) out.push(center(s.org.receipt_footer));
  out.push(center('Powered by Counta'));
  return out;
}

export async function printBluetooth(s: Sale, width = 32) {
  const enc = new TextEncoder();
  const lines = receiptText(s, width);
  const parts: number[] = [0x1b, 0x40]; // initialise
  lines.forEach((l, i) => {
    if (i === 0) parts.push(0x1b, 0x45, 1); // bold for the business name
    parts.push(...enc.encode(l + '\n'));
    if (i === 0) parts.push(0x1b, 0x45, 0);
  });
  parts.push(0x0a, 0x0a, 0x0a, 0x1d, 0x56, 0x42, 0x00); // feed and cut where the printer can
  await write(new Uint8Array(parts));
}

// A sale to an individual shows its IRN and QR code at once; one to a business once NRS has signed it.
const stamped = (s: Sale) => !!s.einvoice?.irn && (s.einvoice.state === 'signed' || (s.einvoice.kind === 'report' && ['waiting', 'sending'].includes(s.einvoice.state)));

// The browser's own print dialog, laid out for an 80 mm roll, with the NRS QR code under the receipt when it has one.
export async function printBrowser(s: Sale) {
  const w = window.open('', '_blank', 'width=420,height=640');
  if (!w) throw new Error('Allow pop-ups to print receipts.');
  const esc = (t: string) => t.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]!));
  let qr = '';
  if (stamped(s) && s.einvoice?.qr) { try { qr = await qrSvg(s.einvoice.qr, 150); } catch { qr = ''; } }
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${esc(s.number)}</title><style>
    @page { size: 80mm auto; margin: 4mm } body { font: 12px/1.35 ui-monospace, Menlo, monospace; margin: 0; } pre { margin: 0; white-space: pre-wrap; }
    .qr { text-align: center; margin-top: 6px } .qr svg { width: 38mm; height: 38mm }
  </style></head><body><pre>${esc(receiptText(s, 42).join('\n'))}</pre>${qr ? `<div class="qr">${qr}</div>` : ''}<script>window.onload = () => { window.print(); setTimeout(() => window.close(), 400); }<\/script></body></html>`);
  w.document.close();
}
