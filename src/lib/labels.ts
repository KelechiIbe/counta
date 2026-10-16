import QRCode from 'qrcode';
import type { Item } from './types';
import { N } from './format';

// Opens a print-ready 50mm shelf label with a QR code (or the EAN as a QR when a barcode exists).
export async function printLabel(item: Pick<Item, 'name' | 'qr_code' | 'barcode' | 'price' | 'selling_unit'>, org: string) {
  const code = item.barcode || item.qr_code;
  const svg = await QRCode.toString(code, { type: 'svg', margin: 0, width: 140, errorCorrectionLevel: 'M' });
  const w = window.open('', '_blank', 'width=420,height=560');
  if (!w) throw new Error('Allow pop-ups to print labels.');
  const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string));
  w.document.write(`<!doctype html><html><head><title>Label · ${esc(item.name)}</title>
  <style>@page{size:50mm 50mm;margin:0}body{margin:0;font-family:Inter,Helvetica,Arial,sans-serif}
  .l{width:50mm;height:50mm;padding:3mm;box-sizing:border-box;display:flex;flex-direction:column;align-items:center;justify-content:space-between}
  .n{font-size:8.5pt;font-weight:600;text-align:center;line-height:1.15;max-height:20pt;overflow:hidden}.q svg{width:26mm;height:26mm}
  .p{font-size:11pt;font-weight:700}.c{font-size:6pt;color:#555;font-family:ui-monospace,monospace}</style></head>
  <body><div class="l"><div class="n">${esc(item.name)}</div><div class="q">${svg}</div><div class="p">${N(item.price)} / ${esc(item.selling_unit)}</div><div class="c">${esc(code)} · ${esc(org)}</div></div>
  <script>window.onload=function(){setTimeout(function(){window.print()},200)}</script></body></html>`);
  w.document.close();
}

export async function qrSvg(text: string, size = 96): Promise<string> {
  return QRCode.toString(text, { type: 'svg', margin: 0, width: size, errorCorrectionLevel: 'M' });
}
