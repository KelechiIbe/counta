// Settings for the books (statements, AI posting, tax), customer messages, and the link with TaxStreem.
import { useEffect, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast, can } from '../state/session';
import { rpc } from '../lib/supabase';
import { edge, money, useMessages } from '../lib/api';
import { when } from '../lib/format';
import { Icon } from '../components/Icon';
import { Alert, Field, Label } from '../components/ui';
import { TAX_ID_HINT, isOldTin, taxIdError } from '../lib/taxid';

function Section({ id, title, sub, children }: { id?: string; title: string; sub?: string; children: ReactNode }) {
  return (
    <div id={id} className="card card-pad sec" style={{ display: 'grid', gridTemplateColumns: 'minmax(200px,280px) 1fr', gap: 24, scrollMarginTop: 16 }}>
      <div><Label>{title}</Label>{sub && <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>{sub}</div>}</div>
      <div className="stack" style={{ gap: 14, minWidth: 0 }}>{children}</div>
    </div>
  );
}
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const MONTH_END = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
// The financial year is twelve months, so its end fixes its start: a year ending on 30 June starts on 1 July.
// Counta stores the month it starts in; this screen asks for the end, the way accountants and the CAC put it.
const endLabel = (m: number) => (m === 2 ? '28 February (29 in a leap year)' : `${MONTH_END[m - 1]} ${MONTHS[m - 1]}`);
const endFromStart = (start: number) => ((start + 10) % 12) + 1;
const startFromEnd = (end: number) => (end % 12) + 1;

export function BooksSection() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const [f, setF] = useState<Record<string, any>>({});
  useEffect(() => {
    const o = inv?.org;
    if (!o) return;
    setF({ tin: o.tin || '', rc_number: o.rc_number || '', address: o.address || '', fiscal_year_start: String(o.fiscal_year_start || 1), reporting_framework: o.reporting_framework || 'ifrs',
      principal_activity: o.principal_activity || '', auto_post_threshold: String(Math.round(Number(o.auto_post_threshold || 0.8) * 100)), cash_sales_without_invoices: !!o.cash_sales_without_invoices,
      capitalisation_threshold: String(o.capitalisation_threshold ?? ''), prices_include_vat: !!o.prices_include_vat, invoice_terms_days: String(o.invoice_terms_days ?? 30),
      invoice_note: o.invoice_note || '', books_start: o.books_start || '', wht_small_company: !!o.wht_small_company });
  }, [inv?.org]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const owner = can(inv, 'manage_settings');
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  const tinErr = taxIdError(f.tin, inv.org.tin);
  const start = Number(f.fiscal_year_start || 1);
  async function save() {
    if (tinErr) { toast(tinErr, 'err'); return; }
    const pct = Number(f.auto_post_threshold);
    if (!(pct >= 80 && pct <= 100)) { toast('Atlas posts on its own only when at least 80% sure. Choose 80 to 100.', 'err'); return; }
    try {
      await rpc('update_org_settings', { p_org: orgId, p_patch: { tin: f.tin, rc_number: f.rc_number, address: f.address, fiscal_year_start: Number(f.fiscal_year_start), auto_post_threshold: pct / 100,
        cash_sales_without_invoices: f.cash_sales_without_invoices, capitalisation_threshold: money(f.capitalisation_threshold) ?? undefined, prices_include_vat: f.prices_include_vat,
        invoice_terms_days: Number(f.invoice_terms_days) || 0, invoice_note: f.invoice_note, books_start: f.books_start || null } });
      await rpc('update_books_settings', { p_org: orgId, p_patch: { reporting_framework: f.reporting_framework, principal_activity: f.principal_activity, wht_small_company: f.wht_small_company } });
      toast('Saved'); await qc.invalidateQueries({ queryKey: ['inv'] });
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  return (
    <Section id="books" title="Books and tax" sub={owner ? 'How the statements are prepared and when Atlas may post on its own.' : 'Only people who can change settings edit these.'}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
        <Field label="Tax ID" error={tinErr} hint={!tinErr && isOldTin(f.tin) ? 'An old TIN. Replace it with your 13-digit Tax ID.' : !tinErr ? TAX_ID_HINT : undefined}>
          <input className="input" disabled={!owner} inputMode="numeric" maxLength={20} placeholder="13 digits" value={f.tin || ''} onChange={(e) => set('tin', e.target.value)} /></Field>
        <Field label="RC number"><input className="input" disabled={!owner} value={f.rc_number || ''} onChange={(e) => set('rc_number', e.target.value)} /></Field>
        <Field label="Financial year ends on" hint={`So each year runs from 1 ${MONTHS[start - 1]} to ${endLabel(endFromStart(start))}.`}>
          <select className="input" disabled={!owner} value={endFromStart(start)} onChange={(e) => set('fiscal_year_start', String(startFromEnd(Number(e.target.value))))}>
            {MONTHS.map((m, i) => <option key={m} value={i + 1}>{endLabel(i + 1)}</option>)}
          </select></Field>
      </div>
      <Field label="Registered address" hint="Printed on invoices and in note 1 to the statements."><input className="input" disabled={!owner} value={f.address || ''} onChange={(e) => set('address', e.target.value)} /></Field>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(220px,1fr))', gap: 12 }}>
        <Field label="Statements prepared under"><select className="input" disabled={!owner} value={f.reporting_framework} onChange={(e) => set('reporting_framework', e.target.value)}><option value="ifrs">IFRS Accounting Standards</option><option value="ifrs_sme">IFRS for SMEs</option></select></Field>
        <Field label="Principal activity" hint="For note 1."><input className="input" disabled={!owner} value={f.principal_activity || ''} onChange={(e) => set('principal_activity', e.target.value)} placeholder="Wholesale and retail of groceries" /></Field>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(220px,1fr))', gap: 12 }}>
        <Field label="Atlas posts on its own when at least (%) sure" hint="Never below 80%. Anything less waits in the books inbox for you."><input className="input" disabled={!owner} inputMode="numeric" value={f.auto_post_threshold || ''} onChange={(e) => set('auto_post_threshold', e.target.value)} /></Field>
        <Field label="Smallest purchase treated as an asset (₦)" hint="Below this, equipment is expensed."><input className="input" disabled={!owner} inputMode="decimal" value={f.capitalisation_threshold || ''} onChange={(e) => set('capitalisation_threshold', e.target.value)} /></Field>
        <Field label="Books start on" hint="Opening balances are dated the day before."><input className="input" disabled={!owner} type="date" value={f.books_start || ''} onChange={(e) => set('books_start', e.target.value)} /></Field>
      </div>
      <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.cash_sales_without_invoices} onChange={(e) => set('cash_sales_without_invoices', e.target.checked)} />We take money for sales that are not rung up in Counta (so Atlas may treat unexplained money in as sales)</label>
      <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.wht_small_company} onChange={(e) => set('wht_small_company', e.target.checked)} />Small company: no WHT on bills under ₦2m from suppliers with a Tax ID (WHT Regulations 2024)</label>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(220px,1fr))', gap: 12 }}>
        <Field label="Invoices are due after (days)"><input className="input" disabled={!owner} inputMode="numeric" value={f.invoice_terms_days || ''} onChange={(e) => set('invoice_terms_days', e.target.value)} /></Field>
        <label className="check" style={{ alignSelf: 'end' }}><input type="checkbox" disabled={!owner} checked={!!f.prices_include_vat} onChange={(e) => set('prices_include_vat', e.target.checked)} />Our prices include VAT</label>
      </div>
      <Field label="Payment details on invoices" hint="Bank name and account number customers pay into."><textarea className="input" disabled={!owner} value={f.invoice_note || ''} onChange={(e) => set('invoice_note', e.target.value)} /></Field>
      {owner && <div><button className="btn btn-primary" onClick={save}>Save</button></div>}
    </Section>
  );
}

export function MessagesSection() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const msgs = useMessages();
  const status = useQuery({ queryKey: ['msg-status'], queryFn: () => edge<{ email: boolean; whatsapp: boolean; sender?: string | null; sender_set?: boolean; email_key?: boolean }>('messaging', { action: 'status' }), staleTime: 60_000 });
  const s = msgs.data?.settings;
  const [f, setF] = useState({ reminders_enabled: false, reminder_days: '-3, 0, 3, 7, 14', reply_to_email: '' });
  useEffect(() => { if (s) setF({ reminders_enabled: !!s.reminders_enabled, reminder_days: (s.reminder_days || []).join(', '), reply_to_email: s.reply_to_email || '' }); }, [s?.reminders_enabled, s?.reply_to_email]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!inv) return null;
  const owner = can(inv, 'manage_settings');
  async function save() {
    try {
      await rpc('update_message_settings', { p_org: orgId, p_patch: { reminders_enabled: f.reminders_enabled, reply_to_email: f.reply_to_email,
        reminder_days: f.reminder_days.split(/[,\s]+/).filter(Boolean).map(Number).filter((n) => Number.isFinite(n)) } });
      toast('Saved'); await qc.invalidateQueries({ queryKey: ['messages'] });
    } catch (e) { toast((e as Error).message, 'err'); }
  }
  const recent = (msgs.data?.messages || []).slice(0, 6);
  return (
    <Section id="messages" title="Customer messages" sub="Invoices, receipts, statements and payment reminders by email and WhatsApp, each with a link to pay.">
      <div className="row wrap" style={{ gap: 8 }}>
        <span className={'chip ' + (status.data?.email ? 't-green' : 't-grey')}>Email {status.data?.email ? 'on' : 'off'}</span>
        <span className={'chip ' + (status.data?.whatsapp ? 't-green' : 't-grey')}>WhatsApp {status.data?.whatsapp ? 'on' : 'off'}</span>
        {status.data?.sender && <span className="chip t-grey" style={{ whiteSpace: "normal", wordBreak: "break-word" }}>Sends from {inv.org.name} via Counta &lt;{status.data.sender}&gt;</span>}
      </div>
      {status.data?.email_key && status.data.sender_set && !status.data.sender && <Alert kind="red" icon="alert">The sending address (RESEND_FROM) has no email address in it. It should be an address on the domain verified in Resend, such as billing@yourdomain.com.</Alert>}
      {status.data && (!status.data.email || !status.data.whatsapp) && <Alert kind="blue" icon="info">TaxStreem switches these on for everyone with its Resend and WhatsApp Business keys. Until then, messages wait and go out as soon as they are on.</Alert>}
      <label className="check"><input type="checkbox" disabled={!owner} checked={f.reminders_enabled} onChange={(e) => setF({ ...f, reminders_enabled: e.target.checked })} />Remind customers about unpaid invoices automatically</label>
      <Field label="On these days from the due date" hint="Negative is before it is due: -3, 0, 3, 7, 14."><input className="input" disabled={!owner || !f.reminders_enabled} value={f.reminder_days} onChange={(e) => setF({ ...f, reminder_days: e.target.value })} style={{ maxWidth: 260 }} /></Field>
      <Field label="Replies go to" hint="Customers who reply to an email reach this address."><input className="input" disabled={!owner} value={f.reply_to_email} onChange={(e) => setF({ ...f, reply_to_email: e.target.value })} placeholder={inv.org.email || 'accounts@yourbusiness.ng'} style={{ maxWidth: 360 }} /></Field>
      {owner && <div><button className="btn btn-primary" onClick={save}>Save</button></div>}
      {recent.length > 0 && <div className="stack" style={{ gap: 4 }}><div className="mini-label">Latest</div>{recent.map((m: any) => (
        <div key={m.id} className="row" style={{ justifyContent: 'space-between', fontSize: 13 }}><span className="ellipsis"><Icon name={m.channel === 'whatsapp' ? 'wa' : 'mail'} size={13} /> {m.subject || m.template} · {m.to_address}</span>
          <span className={m.status === 'failed' ? '' : 'faint'} style={m.status === 'failed' ? { color: 'var(--red)' } : undefined} title={m.error || undefined}>{m.status} · {when(m.created_at)}</span></div>
      ))}
        {recent.filter((m: any) => m.status === 'failed' && m.error).slice(0, 1).map((m: any) => <Alert key={m.id} kind="red" icon="alert">Last failure: {m.error}</Alert>)}
      </div>}
    </Section>
  );
}

export function TaxStreemSection() {
  const { data: inv } = useInventory();
  if (!inv) return null;
  return (
    <Section id="taxstreem" title="TaxStreem" sub="Counta opens from your TaxStreem account with single sign-on; Prism sends supplier bills here.">
      {inv.org.taxstreem_org_id ? <Alert kind="green" icon="check">Linked to TaxStreem business {inv.org.taxstreem_org_id}. People you add in TaxStreem can open Counta without a separate password.</Alert>
        : <Alert kind="grey" icon="info">Not linked yet. Open Counta from TaxStreem once and this business is linked.</Alert>}
    </Section>
  );
}
