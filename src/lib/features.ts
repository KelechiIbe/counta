// Features that are off for this business: paused by TaxStreem from the admin portal, or left out of the business's plan. A
// screen that offers one of them says so plainly instead of failing when it is used.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { useSession } from '../state/session';

export type Feature = 'martina' | 'phone_calls' | 'payment_voice' | 'ai_reading' | 'email' | 'whatsapp' | 'payments' | 'bulk_payments' | 'bank_feeds' | 'supplier_portal';
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
};
const NAMES: Record<Feature, string> = { martina: 'Martina', phone_calls: 'Phone calls', payment_voice: 'Spoken announcements', ai_reading: 'AI reading',
  email: 'Email to customers', whatsapp: 'WhatsApp to customers', payments: 'Payments', bulk_payments: 'Bulk payments', bank_feeds: 'Bank feeds',
  supplier_portal: 'The supplier invoice portal' };
export type Features = Partial<Record<Feature, boolean>> & { _plan?: Partial<Record<Feature, boolean>> };
// Why a feature is off, in a sentence: not in the plan (the owner can change it), or paused by TaxStreem.
export const offNote = (f: Features | undefined, k: Feature) =>
  f?._plan?.[k] ? `${NAMES[k]} ${k === 'phone_calls' || k === 'bank_feeds' || k === 'bulk_payments' || k === 'payments' ? 'are' : 'is'} not in your plan. The owner can change the plan in Settings, Subscription.` : PAUSED[k];

export function useFeatures() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['org-features', orgId],
    enabled: !!orgId,
    staleTime: 60_000,
    // Before the portal's database changes are in, everything counts as on.
    queryFn: () => rpc<Features>('org_features', { p_org: orgId }).catch(() => ({} as Features)),
  });
}
export const isOn = (f: Features | undefined, k: Feature) => f?.[k] !== false;
