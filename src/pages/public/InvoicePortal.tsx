// The invoice portal: a business's link where its suppliers upload invoices, with no account. Counta reads each one at once
// and tells the supplier on the page (and by email or WhatsApp) anything they must fix.
import { useState } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { Frame } from './Public';

const toB64 = (f: File) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(f); });

export default function InvoicePortal() {
  const { token = '' } = useParams();
  const page = useQuery({ queryKey: ['invoice-portal', token], queryFn: () => rpc<any>('invoice_portal', { p_token: token }), retry: false });
  const [who, setWho] = useState({ name: '', email: '', phone: '' });
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<any>(null);
  const p = page.data;
  const emailOk = !who.email.trim() || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(who.email.trim());
  const phoneOk = !who.phone.trim() || who.phone.replace(/\D/g, '').length >= 10;
  const ready = who.name.trim().length >= 2 && (who.email.trim() || who.phone.trim()) && emailOk && phoneOk && file;
  async function send() {
    if (!file) return;
    if (!/^(application\/pdf|image\/(jpeg|png|webp))$/.test(file.type)) { setErr('Send the invoice as a PDF or a photo (JPEG, PNG or WebP).'); return; }
    if (file.size > 8 * 1024 * 1024) { setErr('The file is larger than 8 MB. Send a smaller PDF or a photo.'); return; }
    setBusy(true); setErr(null);
    try {
      const r = await edge<{ invoice: any }>('ai', { action: 'portal_upload', token, file: await toB64(file), file_name: file.name,
        submitter: { name: who.name.trim(), email: who.email.trim() || null, phone: who.phone.trim() || null } });
      if (r.ok === false) setErr(r.error || 'The invoice did not go through. Try again in a minute.');
      else setDone(r.invoice);
    } catch (e) { setErr((e as Error).message); }
    setBusy(false);
  }
  if (page.isLoading) return <Frame><div style={{ padding: 60, display: 'grid', placeItems: 'center' }}><Spinner /></div></Frame>;
  if (!p) return <Frame><Alert kind="yellow" icon="alert">This invoice link is not valid. Ask the business for its current link.</Alert></Frame>;
  const org = { name: p.business, logo_path: p.logo_path };
  if (!p.open) return <Frame org={org}><Alert kind="yellow" icon="info">{p.business} is not taking invoices on this link just now. Send your invoice to them directly.</Alert></Frame>;
  if (done) {
    const issues: string[] = done.issues || [];
    return (
      <Frame org={org}>
        <div className="card card-pad stack" style={{ gap: 12 }}>
          <div className="row" style={{ gap: 10 }}><Icon name="check" size={22} color="#15803D" /><div style={{ fontSize: 18, fontWeight: 700 }}>{p.business} has your invoice</div></div>
          <div className="muted" style={{ fontSize: 14 }}>Reference {done.number}. {done.status === 'reading' ? 'Counta is still reading it; you will hear if anything needs fixing.' : ''}</div>
          {done.failed ? <Alert kind="yellow" icon="alert">Counta could not read the file. {p.business} will look at it by hand; a clearer copy helps.</Alert>
            : issues.length ? (
              <Alert kind="amber" icon="alert">
                <b>Please fix these and send a corrected invoice:</b>
                <ul style={{ margin: '6px 0 0 18px', padding: 0 }}>{issues.map((t, i) => <li key={i} style={{ marginTop: 3 }}>{t}</li>)}</ul>
                {done.emailed && <div className="faint" style={{ fontSize: 12, marginTop: 6 }}>We have sent you these as well.</div>}
                <div className="faint" style={{ fontSize: 12, marginTop: 6 }}>An invoice without the Tax ID (where withholding tax applies) or, for a business, without its address, cannot be paid until it is corrected.</div>
              </Alert>
            ) : <Alert kind="green" icon="check">Counta checked it and found nothing for you to fix. {p.business} approves it for payment.</Alert>}
          <button className="btn btn-secondary" onClick={() => { setDone(null); setFile(null); }}>Send another invoice</button>
        </div>
      </Frame>
    );
  }
  return (
    <Frame org={org}>
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div>
          <div style={{ fontSize: 18, fontWeight: 700 }}>Send an invoice to {p.business}</div>
          <div className="muted" style={{ fontSize: 13.5, marginTop: 4 }}>Upload your invoice as a PDF or a clear photo. It is checked at once: the sums, VAT, your Tax ID, your address and the account to pay. Anything to fix is shown here and sent to you.</div>
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Your name or your business's" req><input className="input" value={who.name} maxLength={120} onChange={(e) => setWho({ ...who, name: e.target.value })} autoComplete="organization" /></Field>
          <Field label="Email" error={emailOk ? null : 'Check the email address.'}><input className="input" type="email" inputMode="email" value={who.email} onChange={(e) => setWho({ ...who, email: e.target.value })} autoComplete="email" /></Field>
          <Field label="WhatsApp number" hint="An email or a number, so you hear back." error={phoneOk ? null : 'Check the number.'}><input className="input" type="tel" inputMode="tel" value={who.phone} onChange={(e) => setWho({ ...who, phone: e.target.value })} autoComplete="tel" /></Field>
          <Field label="The invoice" req hint="PDF, JPEG, PNG or WebP, up to 8 MB.">
            <input className="input" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" onChange={(e) => { setFile(e.target.files?.[0] || null); setErr(null); }} />
          </Field>
        </div>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
        <button className="btn btn-primary" disabled={!ready || busy} onClick={send}>{busy ? <><Spinner small />Sending and checking…</> : 'Send the invoice'}</button>
        <div className="faint" style={{ fontSize: 11.5 }}>Your details go to {p.business} only, with the invoice.</div>
      </div>
    </Frame>
  );
}
