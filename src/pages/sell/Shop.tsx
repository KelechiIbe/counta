// The online shop: a catalogue link for WhatsApp, Instagram and TikTok that follows live stock, takes orders and payment
// by transfer or link, and lands orders in Orders & deliveries.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { photoUrl, rpc } from '../../lib/supabase';
import { money } from '../../lib/api';
import { qrSvg } from '../../lib/labels';
import { Icon } from '../../components/Icon';
import { Alert, Field } from '../../components/ui';
import { ColorPicker, uploadBrandImage } from '../SettingsBranding';
import { cleanHex } from '../../components/InvoiceDoc';

export default function Shop() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const o = inv?.org;
  const [f, setF] = useState<Record<string, any>>({});
  const [qr, setQr] = useState('');
  const [busy, setBusy] = useState(false);
  const [look, setLook] = useState<Record<string, any>>({});
  const [uploading, setUploading] = useState(false);
  const bannerRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!o) return;
    setF({ shop_slug: o.shop_slug || o.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40), shop_enabled: !!o.shop_enabled, shop_title: o.shop_title || o.name,
      shop_note: o.shop_note || '', shop_whatsapp: o.shop_whatsapp || o.phone || '', shop_location_id: o.shop_location_id || inv?.locations[0]?.id || '', shop_delivery_fee: String(o.shop_delivery_fee ?? ''),
      shop_pickup: o.shop_pickup !== false, shop_delivery: !!o.shop_delivery, shop_show_stock: !!o.shop_show_stock, shop_categories: (o as any).shop_categories || null,
      receipt_footer: o.receipt_footer || '', max_cashier_discount_pct: String(o.max_cashier_discount_pct ?? 0) });
    setLook({ brand_color: cleanHex(o.brand_color), shop_banner_path: o.shop_banner_path || '', shop_tagline: o.shop_tagline || '', shop_min_order: String(Number(o.shop_min_order || 0) || ''),
      shop_pay_on_delivery: o.shop_pay_on_delivery !== false, instagram: o.shop_socials?.instagram || '', facebook: o.shop_socials?.facebook || '', tiktok: o.shop_socials?.tiktok || '', x: o.shop_socials?.x || '' });
  }, [o?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const url = `${window.location.origin}/shop/${f.shop_slug || ''}`;
  useEffect(() => { if (f.shop_slug) qrSvg(url, 160).then(setQr).catch(() => {}); }, [url]); // eslint-disable-line react-hooks/exhaustive-deps
  const categories = useMemo(() => Array.from(new Set((inv?.items || []).filter((i) => Number(i.price) > 0).map((i) => i.category))).sort(), [inv?.items]);
  if (!inv || !o) return null;
  const owner = inv.me.role === 'owner';
  const shown = inv.items.filter((i) => Number(i.price) > 0 && (!f.shop_categories || f.shop_categories.includes(i.category)));
  const set = (k: string, v: any) => setF((x) => ({ ...x, [k]: v }));
  async function save() {
    setBusy(true);
    try {
      await rpc('update_sales_settings', { p_org: orgId, p_patch: { ...f, shop_delivery_fee: money(f.shop_delivery_fee) || 0, max_cashier_discount_pct: Number(f.max_cashier_discount_pct) || 0,
        shop_location_id: f.shop_location_id || null } });
      await rpc('update_branding', { p_org: orgId, p_patch: { brand_color: look.brand_color, shop_banner_path: look.shop_banner_path || '', shop_tagline: look.shop_tagline,
        shop_min_order: money(look.shop_min_order) || 0, shop_pay_on_delivery: !!look.shop_pay_on_delivery,
        shop_socials: { instagram: look.instagram, facebook: look.facebook, tiktok: look.tiktok, x: look.x } } });
      toast('Saved'); await qc.invalidateQueries({ queryKey: ['inv'] });
    } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(false);
  }
  return (
    <div className="container" style={{ maxWidth: 1000 }}>
      {!owner && <Alert kind="yellow" icon="shield">Only the owner changes the shop and till settings.</Alert>}
      <div className="card card-pad m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 200px', gap: 20 }}>
        <div className="stack" style={{ gap: 12 }}>
          <label className="check" style={{ fontWeight: 600 }}><input type="checkbox" disabled={!owner} checked={!!f.shop_enabled} onChange={(e) => set('shop_enabled', e.target.checked)} />The shop is open</label>
          <Field label="Shop link" hint="Lowercase letters, numbers and dashes.">
            <div className="row"><span className="faint" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{window.location.host}/shop/</span>
              <input className="input" disabled={!owner} value={f.shop_slug || ''} onChange={(e) => set('shop_slug', e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''))} /></div>
          </Field>
          {o.shop_enabled && o.shop_slug && (
            <div className="row wrap">
              <a className="btn btn-secondary btn-sm" href={`/shop/${o.shop_slug}`} target="_blank" rel="noreferrer"><Icon name="external" size={14} />Open the shop</a>
              <button className="btn btn-secondary btn-sm" onClick={() => navigator.clipboard?.writeText(`${window.location.origin}/shop/${o.shop_slug}`).then(() => toast('Link copied'))}><Icon name="copy" size={14} />Copy link</button>
              <a className="btn btn-secondary btn-sm" href={`https://wa.me/?text=${encodeURIComponent(`Shop from ${o.name}: ${window.location.origin}/shop/${o.shop_slug}`)}`} target="_blank" rel="noreferrer"><Icon name="wa" size={14} />Share on WhatsApp</a>
            </div>
          )}
        </div>
        {f.shop_slug && <div style={{ textAlign: 'center' }}><div dangerouslySetInnerHTML={{ __html: qr }} style={{ width: 160, margin: '0 auto' }} /><div className="faint" style={{ fontSize: 11, marginTop: 6 }}>Print it for the counter or the van</div></div>}
      </div>
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="label">What customers see</div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Shop name"><input className="input" disabled={!owner} value={f.shop_title || ''} onChange={(e) => set('shop_title', e.target.value)} /></Field>
          <Field label="WhatsApp for questions"><input className="input" disabled={!owner} value={f.shop_whatsapp || ''} onChange={(e) => set('shop_whatsapp', e.target.value)} inputMode="tel" /></Field>
        </div>
        <Field label="A note at the top"><textarea className="input" disabled={!owner} value={f.shop_note || ''} onChange={(e) => set('shop_note', e.target.value)} placeholder="Orders before 2pm go out the same day in Lagos." /></Field>
        <Field label="Stock comes from"><select className="input" disabled={!owner} value={f.shop_location_id || ''} onChange={(e) => set('shop_location_id', e.target.value)} style={{ maxWidth: 320 }}>{inv.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select></Field>
        <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.shop_show_stock} onChange={(e) => set('shop_show_stock', e.target.checked)} />Show how many are left (items out of stock are always hidden)</label>
        <div className="row wrap" style={{ gap: 16 }}>
          <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.shop_pickup} onChange={(e) => set('shop_pickup', e.target.checked)} />Customers can pick up</label>
          <label className="check"><input type="checkbox" disabled={!owner} checked={!!f.shop_delivery} onChange={(e) => set('shop_delivery', e.target.checked)} />We deliver</label>
          {f.shop_delivery && <Field label="Delivery charge"><input className="input input-sm" disabled={!owner} inputMode="decimal" value={f.shop_delivery_fee} onChange={(e) => set('shop_delivery_fee', e.target.value)} style={{ width: 140 }} /></Field>}
        </div>
        <Field label="Categories in the shop" hint={`${shown.length} items with a price will show.`}>
          <div className="row wrap" style={{ gap: 6 }}>
            <button className={'pill' + (!f.shop_categories ? ' on' : '')} disabled={!owner} onClick={() => set('shop_categories', null)}>All</button>
            {categories.map((c) => {
              const on = !!f.shop_categories?.includes(c);
              return <button key={c} className={'pill' + (on ? ' on' : '')} disabled={!owner} onClick={() => set('shop_categories', on ? (f.shop_categories as string[]).filter((x) => x !== c) : [...(f.shop_categories || []), c])}>{c}</button>;
            })}
          </div>
        </Field>
      </div>
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="label">Look and checkout</div>
        <Field label="Banner" hint="A wide picture across the top of the shop, about 1500 × 500. PNG, JPG or WebP; large pictures are resized for you.">
          <div className="stack" style={{ gap: 8 }}>
            <div style={{ width: '100%', maxWidth: 520, aspectRatio: '3 / 1', borderRadius: 12, overflow: 'hidden', background: look.brand_color || '#0072F5', display: 'grid', placeItems: 'center' }}>
              {look.shop_banner_path ? <img src={photoUrl(look.shop_banner_path) || ''} alt="Shop banner" style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
                : <span style={{ color: '#fff', opacity: 0.85, fontSize: 13 }}>Your colour shows here until you add a banner</span>}
            </div>
            <div className="row">
              <input ref={bannerRef} type="file" accept="image/png,image/jpeg,image/webp" hidden onChange={async (e) => {
                const file = e.target.files?.[0]; e.target.value = '';
                if (!file) return;
                setUploading(true);
                try { const path = await uploadBrandImage(orgId!, file, 'banner'); setLook((x) => ({ ...x, shop_banner_path: path })); toast('Banner uploaded. Save to use it.'); }
                catch (err) { toast((err as Error).message, 'err'); }
                setUploading(false);
              }} />
              <button className="btn btn-secondary btn-sm" disabled={!owner || uploading} onClick={() => bannerRef.current?.click()}><Icon name="upload" size={14} />{uploading ? 'Uploading…' : look.shop_banner_path ? 'Change banner' : 'Upload banner'}</button>
              {look.shop_banner_path && owner && <button className="btn btn-ghost btn-sm" onClick={() => setLook((x) => ({ ...x, shop_banner_path: '' }))}>Remove</button>}
            </div>
          </div>
        </Field>
        <Field label="Colour" hint="Shared with your invoices and emails. The logo comes from Settings, Branding."><ColorPicker value={look.brand_color || '#0072F5'} disabled={!owner} onChange={(v) => setLook((x) => ({ ...x, brand_color: v }))} /></Field>
        <Field label="Tagline"><input className="input" disabled={!owner} value={look.shop_tagline || ''} onChange={(e) => setLook((x) => ({ ...x, shop_tagline: e.target.value }))} placeholder="Fresh groceries delivered across Lekki and VI" maxLength={120} /></Field>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: 10 }}>
          {([['instagram', 'Instagram'], ['facebook', 'Facebook'], ['tiktok', 'TikTok'], ['x', 'X']] as const).map(([k, l]) => (
            <Field key={k} label={l}><input className="input" disabled={!owner} value={look[k] || ''} onChange={(e) => setLook((x) => ({ ...x, [k]: e.target.value }))} placeholder="handle" /></Field>
          ))}
        </div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, alignItems: 'end' }}>
          <Field label="Smallest order" hint="Leave empty for no minimum."><input className="input" disabled={!owner} inputMode="decimal" value={look.shop_min_order || ''} onChange={(e) => setLook((x) => ({ ...x, shop_min_order: e.target.value }))} /></Field>
          <label className="check"><input type="checkbox" disabled={!owner} checked={!!look.shop_pay_on_delivery} onChange={(e) => setLook((x) => ({ ...x, shop_pay_on_delivery: e.target.checked }))} />Customers can pay on delivery or at pickup</label>
        </div>
        <div className="faint" style={{ fontSize: 12 }}>Checkout runs in four steps: cart, the customer's details, pickup or delivery, then payment. Each order lands in Orders & deliveries and the customer gets a page to pay and follow it.</div>
      </div>
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="label">Till</div>
        <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
          <Field label="Most a cashier can discount (%)" hint="More than this needs a manager."><input className="input" disabled={!owner} inputMode="decimal" value={f.max_cashier_discount_pct} onChange={(e) => set('max_cashier_discount_pct', e.target.value)} /></Field>
          <Field label="Line at the bottom of receipts"><input className="input" disabled={!owner} value={f.receipt_footer || ''} onChange={(e) => set('receipt_footer', e.target.value)} placeholder="Thank you for shopping with us" /></Field>
        </div>
      </div>
      {owner && <div><button className="btn btn-primary" disabled={busy} onClick={save}>Save</button></div>}
    </div>
  );
}
