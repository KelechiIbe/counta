// What each customer message says, shared by email and WhatsApp so the two always agree.
export const naira = (v: unknown) => {
  const n = Number(v);
  if (!Number.isFinite(n)) return '₦0.00';
  const s = Math.abs(n).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (n < 0 ? '-₦' : '₦') + s;
};
export function dueText(due?: string | null) {
  if (!due) return '';
  const d = new Date(due + 'T00:00:00Z');
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
}
export const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
export const first = (name: unknown) => String(name || '').trim().split(/\s+/)[0] || 'there';

export type Msg = { id: string; org_id?: string; channel: 'email' | 'whatsapp'; to_address: string; template: string; subject?: string; params: Record<string, any>;
  org: { name: string; email?: string; phone?: string; address?: string; tin?: string; website?: string; brand_color?: string; logo_path?: string;
    logo_url?: string | null; reply_to_email?: string; invoice_footer?: string } };

// The business's colour when it is a usable hex colour, Counta blue otherwise.
export const brandColor = (c?: string) => (/^#[0-9a-f]{6}$/i.test(String(c || '')) ? String(c) : '#0072F5');

const ROLE_PHRASE: Record<string, string> = { admin: 'an admin', manager: 'a manager', accountant: 'an accountant', staff: 'a member of staff', cashier: 'a cashier' };

// One place for what each message says, so email and WhatsApp agree.
export function wording(m: Msg) {
  const p = m.params || {}, biz = p.business || m.org?.name || 'Your supplier';
  const balance = Number(p.balance || 0), total = Number(p.total || 0);
  const due = dueText(p.due_date);
  switch (m.template) {
    case 'document': {
      const owed = balance > 0.004;
      return {
        heading: `${p.doc_label} ${p.number}`,
        lines: [`${biz} has sent you ${String(p.doc_label || 'a document').toLowerCase()} ${p.number} for ${naira(total)}.`,
          owed ? `${naira(balance)} is due${due ? ` by ${due}` : ''}.` : ''],
        button: owed ? 'View and pay' : 'View', link: p.link,
        wa: { name: 'counta_document', params: [first(p.customer_name), biz, `${String(p.doc_label || 'document').toLowerCase()} ${p.number}`, naira(total), p.link] },
      };
    }
    case 'receipt':
      return {
        heading: `Receipt ${p.number}`,
        lines: [`Thank you for buying from ${biz}.`, `Your receipt ${p.number} for ${naira(total)} is ready.`,
          balance > 0.004 ? `${naira(balance)} is still to pay.` : ''],
        button: 'View receipt', link: p.link,
        wa: { name: 'counta_receipt', params: [first(p.customer_name), biz, p.number, naira(total), p.link] },
      };
    case 'order':
      return {
        heading: `Order ${p.number}`,
        lines: [`${biz} has your order ${p.number} for ${naira(total)}.`, balance > 0.004 ? `You can pay ${naira(balance)} from the link below.` : 'It is paid in full.'],
        button: balance > 0.004 ? 'View and pay' : 'View order', link: p.link,
        wa: { name: 'counta_order', params: [first(p.customer_name), biz, p.number, naira(total), p.link] },
      };
    case 'reminder': {
      const when = due ? (new Date(p.due_date + 'T00:00:00Z').getTime() < Date.now() - 86400_000 ? `was due on ${due}` : `is due on ${due}`) : 'is outstanding';
      return {
        heading: `Payment reminder: ${p.number}`,
        lines: [`A reminder from ${biz}: ${naira(balance)} on ${p.number} ${when}.`, 'You can pay by bank transfer from the link below.'],
        button: 'Pay now', link: p.link,
        wa: { name: 'counta_payment_reminder', params: [first(p.customer_name), biz, naira(balance), p.number, when, p.link] },
      };
    }
    case 'statement': {
      const items = Array.isArray(p.open_items) ? p.open_items : [];
      return {
        heading: `Your statement from ${biz}`,
        lines: [`Your balance with ${biz} is ${naira(p.balance)}.`,
          ...items.slice(0, 12).map((i: any) => `${i.number}: ${naira(i.balance)}${i.due_date ? ` due ${dueText(i.due_date)}` : ''}`)],
        button: p.link ? 'View and pay' : '', link: p.link,
        wa: { name: 'counta_statement', params: [first(p.customer_name), biz, naira(p.balance), p.link || (m.org?.phone ? `Call ${m.org.phone}` : biz)] },
      };
    }
    case 'bill_returned': {
      // A supplier's invoice sent back unpaid: no Tax ID, no address for the state revenue service, or another reason.
      const why = p.reason === 'missing_tin' ? 'your Tax ID is missing. You can get it at taxid.nrs.gov.ng; please send it to us with an invoice that shows it'
        : p.reason === 'missing_state' ? 'we need your business address to know which state revenue service receives the withholding tax; please send it with an invoice that shows it'
        : String(p.note || '').replace(/\s+/g, ' ').slice(0, 300);
      return {
        heading: `Invoice ${p.number} returned`,
        lines: [`${biz} has returned your invoice ${p.number} for ${naira(total)} without paying it.`, ...String(p.note || '').split(/\n+/)],
        button: '', link: '',
        wa: { name: 'counta_bill_returned', params: [first(p.customer_name), biz, p.number, why] },
      };
    }
    case 'invite': {
      // A team invitation: email only, with a one-time link made as it is sent.
      const until = p.expires_at ? new Date(p.expires_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'Africa/Lagos' }) : '';
      return {
        heading: `Join ${biz} on Counta`,
        lines: [`${p.invited_by ? `${p.invited_by} has invited you` : 'You have been invited'} to join ${biz} on Counta as ${ROLE_PHRASE[String(p.role_label || '').toLowerCase()] || 'part of the team'}.`,
          `Use the button to sign up, or sign in, with ${p.email || m.to_address}. The link works once${until ? `, until ${until}` : ''}.`,
          'If you were not expecting this, you can ignore the email.'],
        button: 'Join the team', link: p.link, wa: null,
      };
    }
    case 'alert': {
      // Counta telling the business's owner something needs doing (a tax return due, invoices overdue, transactions to
      // confirm before the returns). Written by the database with the figures in; WhatsApp uses the template it names.
      const lines = (Array.isArray(p.lines) ? p.lines : [p.body]).map((l: unknown) => String(l ?? '').trim()).filter(Boolean).slice(0, 8);
      const wa = p.wa && typeof p.wa.name === 'string' && /^counta_[a-z_]+$/.test(p.wa.name) && Array.isArray(p.wa.params)
        ? { name: p.wa.name, params: p.wa.params.map((x: unknown) => String(x ?? '')) } : null;
      return { heading: String(p.heading || m.subject || 'Something needs doing in Counta'), lines, button: String(p.button || 'Open Counta'), link: p.link, wa,
        greet: first(p.person_name), from: 'Counta', footer: `Counta sends these for ${biz}. Choose which you get in Settings, Notifications.` };
    }
    default:
      return { heading: m.subject || biz, lines: [String(p.body || '')], button: p.link ? 'Open' : '', link: p.link, wa: null };
  }
}

type Words = ReturnType<typeof wording> & { greet?: string; from?: string; footer?: string };

export function emailHtml(m: Msg) {
  const w = wording(m) as Words, p = m.params || {};
  const biz = p.business || m.org?.name || '';
  const color = brandColor(m.org?.brand_color);
  const body = w.lines.filter(Boolean).map((l) => `<p style="margin:0 0 12px;font-size:15px;line-height:1.5;color:#1f2933">${esc(l)}</p>`).join('');
  const button = w.button && w.link
    ? `<p style="margin:20px 0"><a href="${esc(w.link)}" style="background:${color};color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:600;display:inline-block">${esc(w.button)}</a></p>`
    : '';
  const contact = [p.business_phone, p.reply_to].filter(Boolean).map(esc).join(' · ');
  const footer = [m.org?.address, m.org?.tin ? `Tax ID ${m.org.tin}` : '', m.org?.website].filter(Boolean).map((x) => esc(x)).join(' · ');
  const logo = m.org?.logo_url ? `<img src="${esc(m.org.logo_url)}" alt="${esc(biz)}" style="max-height:48px;max-width:180px;display:block;margin:0 0 14px" />` : '';
  return `<!doctype html><html><body style="margin:0;background:#f4f6f8;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" style="max-width:560px;background:#ffffff;border-radius:12px;padding:28px;border-top:4px solid ${color}" cellpadding="0" cellspacing="0"><tr><td>
${logo}<p style="margin:0 0 4px;font-size:13px;color:#52606d">${esc(biz)}</p>
<h1 style="margin:0 0 18px;font-size:20px;color:#102a43">${esc(w.heading)}</h1>
<p style="margin:0 0 12px;font-size:15px;color:#1f2933">Hello ${esc(w.greet ?? first(p.customer_name))},</p>
${body}${button}
${contact ? `<p style="margin:20px 0 0;font-size:13px;color:#52606d">Questions? ${contact}</p>` : ''}
${footer ? `<p style="margin:14px 0 0;font-size:12px;color:#829ab1">${footer}</p>` : ''}
</td></tr></table>
<p style="font-size:12px;color:#829ab1;margin:14px 0 0">${esc(w.footer || `Sent for ${biz} by Counta`)}</p>
</td></tr></table></body></html>`;
}

export function emailText(m: Msg) {
  const w = wording(m) as Words, p = m.params || {};
  return [`Hello ${w.greet ?? first(p.customer_name)},`, '', ...w.lines.filter(Boolean), '', w.link ? `${w.button || 'Open'}: ${w.link}` : '',
    '', [p.business_phone, p.reply_to].filter(Boolean).join(' · '), w.footer || ''].join('\n').trim();
}

