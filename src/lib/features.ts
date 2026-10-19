// Features TaxStreem has paused, for everyone or for this business, from the admin portal. A screen that offers one of them
// says so plainly instead of failing when it is used.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './supabase';
import { useSession } from '../state/session';

export type Feature = 'martina' | 'phone_calls' | 'payment_voice' | 'ai_reading' | 'email' | 'whatsapp' | 'payments';
export const PAUSED: Record<Feature, string> = {
  martina: 'TaxStreem has paused Martina for now. Everything on the screens works without her.',
  phone_calls: 'TaxStreem has paused phone calls for now. Orders and reminders still go out by WhatsApp or email.',
  payment_voice: 'TaxStreem has paused the spoken announcements for now. The device\'s own voice speaks meanwhile.',
  ai_reading: 'TaxStreem has paused AI reading for now. Lines can still be typed in by hand.',
  email: 'TaxStreem has paused email to customers for now. Messages wait and go once it is back.',
  whatsapp: 'TaxStreem has paused WhatsApp messages for now. Messages wait and go once it is back.',
  payments: 'TaxStreem has paused payments for now. Money already on its way is still recorded.',
};

export function useFeatures() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['org-features', orgId],
    enabled: !!orgId,
    staleTime: 60_000,
    // Before the portal's database changes are in, everything counts as on.
    queryFn: () => rpc<Partial<Record<Feature, boolean>>>('org_features', { p_org: orgId }).catch(() => ({})),
  });
}
export const isOn = (f: Partial<Record<Feature, boolean>> | undefined, k: Feature) => f?.[k] !== false;
