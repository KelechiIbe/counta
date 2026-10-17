// The online shop: a catalogue link for WhatsApp, Instagram and TikTok that follows live stock, takes orders and payment
// by transfer or link, and lands orders in Orders & deliveries.
import { useEffect, useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useInventory, useSession, useToast } from '../../state/session';
import { rpc } from '../../lib/supabase';
import { money } from '../../lib/api';
import { qrSvg } from '../../lib/labels';
import { Icon } from '../../components/Icon';
import { Alert, Field } from '../../components/ui';

export default function Shop() {
  const { data: inv } = useInventory();
  const { orgId } = useSession();
  const toast = useToast();
  const qc = useQueryClient();
  const o = inv?.org;
  const [f, setF] = useState<Record<string, any>>({});
  const [qr, setQr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!o) return;
    setF({ shop_slug: o.shop_slug || o.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40), shop_enabled: !!o.shop_enabled, shop_title: o.shop_title || o.name,
      shop_note: o.shop_note || '', shop_whatsapp: o.shop_whatsapp || o.phone || '', shop_location_id: o.shop_location_id || inv?.locations[0]?.id || '', shop_delivery_fee: String(o.shop_delivery_fee ?? ''),
      shop_pickup: o.shop_pickup !== false, shop_delivery: !!o.shop_delivery, shop_show_stock: !!o.shop_show_stock, shop_categories: (o as any).shop_categories || null,
      receipt_footer: o.receipt_footer || '', max_cashier_discount_pct: String(o.max_cashier_discount_pct ?? 0) });
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
