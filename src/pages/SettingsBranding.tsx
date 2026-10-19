// Branding: logo, colour and one of three invoice templates, with what the documents print about the business.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast, can } from '../state/session';
import { photoUrl, rpc, supabase } from '../lib/supabase';
import { Icon } from '../components/Icon';
import { Alert, Field, Label } from '../components/ui';
import { shrinkImage } from '../lib/images';
import { TAX_ID_HINT, isOldTin, taxIdError } from '../lib/taxid';
import { InvoiceDoc, ScaledDoc, TEMPLATES, cleanHex, sampleDoc, type Template } from '../components/InvoiceDoc';

export const SWATCHES = ['#0072F5', '#0B3B75', '#0F766E', '#15803D', '#B45309', '#C2410C', '#B91C1C', '#9D174D', '#6D28D9', '#111827'];
const SHOW: [string, string][] = [
  ['tin', 'Your Tax ID'], ['rc_number', 'Your RC number'], ['vat_status', 'VAT status of each line (0, 1, 2)'], ['amount_in_words', 'Amount in words'], ['signature', 'A line for a signature'],
];

// Uploads a picture to the business's own folder in storage and returns its path.
export async function uploadBrandImage(orgId: string, f: File, kind: 'logo' | 'banner'): Promise<string> {
  if (!/^image\/(png|jpe?g|webp)$/.test(f.type)) throw new Error('Choose a PNG, JPG or WebP picture.');
  if (f.size > 15 * 1024 * 1024) throw new Error('Choose a picture under 15 MB.');
  // Logos print at most a few centimetres wide; banners fill the top of the shop.
  const pic = await shrinkImage(f, kind === 'logo' ? 1000 : 2000, 0.88);
  // A new name each time, so nothing is overwritten and no one sees an old cached picture.
  const path = `${orgId}/brand/${kind}-${Date.now()}.${pic.ext}`;
  const { error } = await supabase.storage.from('item-photos').upload(path, pic.blob, { contentType: pic.type, cacheControl: '31536000' });
  if (error) throw new Error(error.message);
  return path;
}

export function ColorPicker({ value, onChange, disabled }: { value: string; onChange: (v: string) => void; disabled?: boolean }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  return (
    <div className="row wrap" style={{ gap: 8 }}>
      <input type="color" value={cleanHex(value)} disabled={disabled} onChange={(e) => onChange(e.target.value.toUpperCase())} aria-label="Pick a colour"
        style={{ width: 44, height: 38, padding: 2, border: '1px solid var(--line)', borderRadius: 10, background: '#fff', cursor: 'pointer' }} />
      <input className="input mono" value={text} disabled={disabled} style={{ width: 110 }} aria-label="Colour as a hex code"
        onChange={(e) => { setText(e.target.value); if (/^#[0-9a-f]{6}$/i.test(e.target.value.trim())) onChange(e.target.value.trim().toUpperCase()); }} />
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {SWATCHES.map((c) => (
          <button key={c} type="button" disabled={disabled} onClick={() => onChange(c)} aria-label={`Use ${c}`} title={c}
            style={{ width: 24, height: 24, borderRadius: 12, background: c, border: cleanHex(value) === c ? '2px solid #111827' : '2px solid #fff', boxShadow: '0 0 0 1px #E5E7EB', cursor: 'pointer' }} />
        ))}
      </div>
    </div>
  );
}

export function BrandingSection() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const fileRef = useRef<HTMLInputElement>(null);
  const o = inv?.org as Record<string, any> | undefined;
  const [f, setF] = useState<Record<string, any>>({});
  const [busy, setBusy] = useState<string | null>(null);
  useEffect(() => {
    if (!o) return;
    setF({ logo_path: o.logo_path || '', brand_color: cleanHex(o.brand_color), invoice_template: o.invoice_template || 'classic', website: o.website || '',
      invoice_footer: o.invoice_footer || '', invoice_note: o.invoice_note || '', address: o.address || '', tin: o.tin || '', rc_number: o.rc_number || '',
      phone: o.phone || '', email: o.email || '',
      invoice_show: { tin: true, rc_number: true, vat_status: true, amount_in_words: true, signature: false, ...(o.invoice_show || {}) } });
  }, [o?.id, o?.brand_color, o?.invoice_template, o?.logo_path]); // eslint-disable-line react-hooks/exhaustive-deps
  const preview = useMemo(() => o && sampleDoc({ name: o.name, address: f.address, phone: f.phone, email: f.email, tin: f.tin, rc_number: f.rc_number, logo_path: f.logo_path || null,
    brand_color: f.brand_color, invoice_template: f.invoice_template, website: f.website, invoice_footer: f.invoice_footer, payment_details: f.invoice_note,
    invoice_show: f.invoice_show }), [o, f]);
  if (!inv || !o || !f.brand_color) return null;
  const owner = can(inv, 'manage_settings');
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));

  async function pickLogo(file?: File) {
    if (!file) return;
    setBusy('logo');
    try { set('logo_path', await uploadBrandImage(orgId!, file, 'logo')); toast('Logo uploaded. Save to use it.'); }
    catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }
  const tinErr = taxIdError(f.tin, o.tin);
  async function save() {
    if (tinErr) { toast(tinErr, 'err'); return; }
    setBusy('save');
    try {
      await rpc('update_org_settings', { p_org: orgId, p_patch: { address: f.address, tin: f.tin, rc_number: f.rc_number, phone: f.phone, email: f.email } });
      await rpc('update_branding', { p_org: orgId, p_patch: { logo_path: f.logo_path || '', brand_color: f.brand_color, invoice_template: f.invoice_template, website: f.website,
        invoice_footer: f.invoice_footer, invoice_note: f.invoice_note, invoice_show: f.invoice_show } });
      toast('Branding saved'); await qc.invalidateQueries({ queryKey: ['inv'] });
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }

  return (
    <div id="branding" className="card card-pad stack" style={{ gap: 18, scrollMarginTop: 16 }}>
      <div>
        <Label>Branding</Label>
        <div className="muted" style={{ fontSize: 13, marginTop: 6, lineHeight: 1.5 }}>
          Your logo, colour and template go on invoices, receipts, quotes and credit notes, the customer's online copy, emails and the PDF.{!owner && ' Only people who can change settings edit them.'}
        </div>
      </div>
      <div className="brand-grid" style={{ display: 'grid', gridTemplateColumns: 'minmax(280px, 380px) minmax(0, 1fr)', gap: 24, alignItems: 'start' }}>
        <div className="stack" style={{ gap: 14 }}>
          <Field label="Logo" hint="PNG, JPG or WebP. A wide logo on a white or clear background prints best. Large pictures are resized for you.">
            <div className="row" style={{ gap: 12 }}>
              <div style={{ width: 120, height: 64, border: '1px dashed #D1D5DB', borderRadius: 10, display: 'grid', placeItems: 'center', background: '#FAFAFA', overflow: 'hidden', flex: 'none' }}>
                {f.logo_path ? <img src={photoUrl(f.logo_path) || ''} alt="Your logo" style={{ maxWidth: 112, maxHeight: 56, objectFit: 'contain' }} /> : <Icon name="image" size={22} color="#9CA3AF" />}
              </div>
              <div className="stack" style={{ gap: 6 }}>
                <input ref={fileRef} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={(e) => { pickLogo(e.target.files?.[0]); e.target.value = ''; }} />
                <button className="btn btn-secondary btn-sm" disabled={!owner || busy === 'logo'} onClick={() => fileRef.current?.click()}><Icon name="upload" size={14} />{busy === 'logo' ? 'Uploading…' : f.logo_path ? 'Change' : 'Upload logo'}</button>
                {f.logo_path && owner && <button className="btn btn-ghost btn-sm" onClick={() => set('logo_path', '')}>Remove</button>}
              </div>
            </div>
          </Field>
          <Field label="Brand colour" hint="Your main colour. Counta picks black or white text to sit on it."><ColorPicker value={f.brand_color} disabled={!owner} onChange={(v) => set('brand_color', v)} /></Field>
          <Field label="Template">
            <div className="stack" style={{ gap: 8 }}>
              {TEMPLATES.map((t) => (
                <button key={t.id} type="button" disabled={!owner} onClick={() => set('invoice_template', t.id)} className="card"
                  style={{ textAlign: 'left', padding: '10px 12px', cursor: 'pointer', borderColor: f.invoice_template === t.id ? f.brand_color : undefined, boxShadow: f.invoice_template === t.id ? `0 0 0 2px ${f.brand_color}` : undefined, background: '#fff' }}>
                  <div className="row" style={{ justifyContent: 'space-between' }}><b>{t.name}</b>{f.invoice_template === t.id && <Icon name="check" size={16} color={f.brand_color} />}</div>
                  <div className="muted" style={{ fontSize: 12.5 }}>{t.blurb}</div>
                </button>
              ))}
            </div>
          </Field>
          <Field label="Office address"><textarea className="input" disabled={!owner} value={f.address} onChange={(e) => set('address', e.target.value)} style={{ minHeight: 64 }} placeholder="Plot 5, Admiralty Way, Lekki, Lagos" /></Field>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <Field label="Tax ID" error={tinErr} hint={!tinErr && isOldTin(f.tin) ? 'This is an old TIN. Replace it with your 13-digit Tax ID.' : !tinErr ? TAX_ID_HINT : undefined}>
              <input className="input" disabled={!owner} value={f.tin} inputMode="numeric" maxLength={20} onChange={(e) => set('tin', e.target.value)} placeholder="13 digits" /></Field>
            <Field label="RC number"><input className="input" disabled={!owner} value={f.rc_number} onChange={(e) => set('rc_number', e.target.value)} /></Field>
            <Field label="Phone"><input className="input" disabled={!owner} value={f.phone} onChange={(e) => set('phone', e.target.value)} inputMode="tel" /></Field>
            <Field label="Email"><input className="input" disabled={!owner} value={f.email} onChange={(e) => set('email', e.target.value)} inputMode="email" /></Field>
          </div>
          <Field label="Website"><input className="input" disabled={!owner} value={f.website} onChange={(e) => set('website', e.target.value)} placeholder="www.yourbusiness.ng" /></Field>
          <Field label="Payment details" hint="Printed on every invoice: bank, account number and name, or how else to pay.">
            <textarea className="input" disabled={!owner} value={f.invoice_note} onChange={(e) => set('invoice_note', e.target.value)} style={{ minHeight: 72 }} placeholder={'GTBank · 0123456789 · Your Business Ltd'} />
          </Field>
          <Field label="Footer" hint="A line at the bottom, such as your registered office or a thank-you."><input className="input" disabled={!owner} value={f.invoice_footer} onChange={(e) => set('invoice_footer', e.target.value)} /></Field>
          <div className="stack" style={{ gap: 6 }}>
            <div className="mini-label">Show on documents</div>
            {SHOW.map(([k, l]) => (
              <label key={k} className="check"><input type="checkbox" disabled={!owner} checked={!!f.invoice_show[k]} onChange={(e) => set('invoice_show', { ...f.invoice_show, [k]: e.target.checked })} />{l}</label>
            ))}
          </div>
          {owner && <div><button className="btn btn-primary" disabled={busy === 'save'} onClick={save}>{busy === 'save' ? 'Saving…' : 'Save branding'}</button></div>}
          {!f.tin && <Alert kind="amber" icon="info">Add your Tax ID. Customers who are VAT-registered need it on your invoices to claim the VAT back.</Alert>}
        </div>
        <div className="stack" style={{ gap: 8, minWidth: 0 }}>
          <div className="mini-label">Preview with sample figures</div>
          <div style={{ background: '#F4F6F8', borderRadius: 14, padding: 14 }}>{preview && <ScaledDoc><InvoiceDoc d={preview} template={f.invoice_template as Template} fixed /></ScaledDoc>}</div>
        </div>
      </div>
    </div>
  );
}
