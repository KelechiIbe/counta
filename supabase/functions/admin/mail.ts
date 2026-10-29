// The admin team's own emails (an invitation to the portal, the welcome): the words come from the database
// (svc_staff_mail), laid out here the way Counta's other emails look.
export type StaffWords = {
  to: string; reply_to?: string | null; link: string; subject: string; heading: string; greet?: string | null;
  lines: string[]; button: string; footer?: string | null;
};

export const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const first = (name: unknown) => String(name || '').trim().split(/\s+/)[0] || 'there';
const lines = (w: StaffWords) => (Array.isArray(w.lines) ? w.lines : []).map((l) => String(l ?? '').trim()).filter(Boolean).slice(0, 6);

export function staffHtml(w: StaffWords) {
  const color = '#0072F5';
  const body = lines(w).map((l) => `<p style="margin:0 0 12px;font-size:15px;line-height:1.5;color:#1f2933">${esc(l)}</p>`).join('');
  return `<!doctype html><html><body style="margin:0;background:#f4f6f8;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" style="max-width:560px;background:#ffffff;border-radius:12px;padding:28px;border-top:4px solid ${color}" cellpadding="0" cellspacing="0"><tr><td>
<p style="margin:0 0 4px;font-size:13px;color:#52606d">Counta by TaxStreem</p>
<h1 style="margin:0 0 18px;font-size:20px;color:#102a43">${esc(w.heading)}</h1>
<p style="margin:0 0 12px;font-size:15px;color:#1f2933">Hello ${esc(first(w.greet))},</p>
${body}
<p style="margin:20px 0"><a href="${esc(w.link)}" style="background:${color};color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:600;display:inline-block">${esc(w.button)}</a></p>
<p style="margin:0;font-size:13px;color:#52606d">Or open this address: <a href="${esc(w.link)}" style="color:${color};word-break:break-all">${esc(w.link)}</a></p>
</td></tr></table>
<p style="font-size:12px;color:#829ab1;margin:14px 0 0">${esc(w.footer || 'Sent by Counta for TaxStreem.')}</p>
</td></tr></table></body></html>`;
}

export function staffText(w: StaffWords) {
  return [`Hello ${first(w.greet)},`, '', ...lines(w), '', `${w.button}: ${w.link}`, '', w.footer || 'Sent by Counta for TaxStreem.'].join('\n').trim();
}
