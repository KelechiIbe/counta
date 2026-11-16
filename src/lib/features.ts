// Features that are off for this business: paused by TaxStreem from the admin portal, or left out of the business's plan. A
// screen that offers one of them says so plainly instead of failing when it is used.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { useSession } from '../state/session';

export type Feature = 'martina' | 'phone_calls' | 'payment_voice' | 'ai_reading' | 'email' | 'whatsapp' | 'payments' | 'bulk_payments' | 'bank_feeds' | 'supplier_portal'
  | 'selling' | 'purchases' | 'inventory' | 'vat_wht';
export const PAUSED: Record<Feature, string> = {
  martina: 'TaxStreem has paused Martina for now. Everything on the screens works without her.',
  phone_calls: 'TaxStreem has paused phone calls for now. Orders and reminders still go out by WhatsApp or email.',
  payment_voice: 'TaxStreem has paused the spoken announcements for now. The device\'s own voice speaks meanwhile.',
  ai_reading: 'TaxStreem has paused AI reading for now. Lines can still be typed in by hand.',
  email: 'TaxStreem has paused email to customers for now. Messages wait and go once it is back.',
  whatsapp: 'TaxStreem has paused WhatsApp messages for now. Messages wait and go once it is back.',
  payments: 'TaxStreem has paused payments for now. Money already on its way is still recorded.',
  bulk_payments: 'TaxStreem has paused bulk payments for now. Single payouts still work.',
  bank_feeds: 'TaxStreem has paused bank feeds for now. Statements can still be uploaded.',
  supplier_portal: 'TaxStreem has paused the supplier invoice portal for now. Invoices can still be uploaded here.',
  selling: 'TaxStreem has switched selling off for this business.',
  purchases: 'TaxStreem has switched bills and vendors off for this business.',
  inventory: 'TaxStreem has switched inventory off for this business.',
  vat_wht: 'TaxStreem has switched the VAT and WHT returns off for this business.',
};
const NAMES: Record<Feature, string> = { martina: 'Martina', phone_calls: 'Phone calls', payment_voice: 'Spoken announcements', ai_reading: 'AI reading',
  email: 'Email to customers', whatsapp: 'WhatsApp to customers', payments: 'Payments', bulk_payments: 'Bulk payments', bank_feeds: 'Bank feeds',
  supplier_portal: 'The supplier invoice portal', selling: 'Selling', purchases: 'Purchases', inventory: 'Inventory', vat_wht: 'Filing VAT and WHT returns' };
export type Features = Partial<Record<Feature, boolean>> & { _plan?: Partial<Record<Feature, boolean>> };
// Why a feature is off, in a sentence: not in the plan (the owner can change it), or paused by TaxStreem.
export const offNote = (f: Features | undefined, k: Feature) =>
  f?._plan?.[k] ? `${NAMES[k]} ${k === 'phone_calls' || k === 'bank_feeds' || k === 'bulk_payments' || k === 'payments' ? 'are' : 'is'} not in your plan. The owner can change the plan in Settings, Subscription.` : PAUSED[k];

// The last answer for each business is kept on the device, so menus show at once on the next visit. When the check cannot
// be made and nothing is kept, the answer stays unknown (undefined): parts a plan can leave out stay hidden until it comes,
// and are never shown just because the check failed.
const FEATS_KEY = 'counta.feats.';
export function useFeatures() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['org-features', orgId],
    enabled: !!orgId,
    staleTime: 60_000,
    retry: 3,
    queryFn: async () => {
      const f = await rpc<Features>('org_features', { p_org: orgId });
      try { localStorage.setItem(FEATS_KEY + orgId, JSON.stringify(f || {})); } catch { /* private mode */ }
      return f || ({} as Features);
    },
    initialData: () => { try { const v = localStorage.getItem(FEATS_KEY + orgId); return v ? (JSON.parse(v) as Features) : undefined; } catch { return undefined; } },
    initialDataUpdatedAt: 0,
  });
}
export const isOn = (f: Features | undefined, k: Feature) => f?.[k] !== false;
// A part of the app the business's plan leaves out (the Annual filing package leaves out selling, purchases, inventory and the
// monthly returns): hidden from the menu, and its pages say so.
export const planOff = (f: Features | undefined, k: Feature) => f?.[k] === false && !!f?._plan?.[k];
// For menus: a part the plan may leave out shows only once the plan is known to include it.
export const planHidden = (f: Features | undefined, k: Feature) => f === undefined || planOff(f, k);
