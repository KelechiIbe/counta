// The words a business uses for its own money and people: a shop has sales and customers, a law firm has revenue and
// clients, a school has fees and students. The same table lives in supabase/functions/voice/wording.ts for Martina; keep
// the two alike.
import { useInventory } from '../state/session';

export type Kind = 'goods' | 'services' | 'both';
export type Words = {
  kind: Kind; revenue: string; customer: string; customers: string; item: string; items: string; sale: string; sales: string;
  sell: string; has_stock: boolean;
};

const BASE: Record<Kind, Words> = {
  goods: { kind: 'goods', revenue: 'sales', customer: 'customer', customers: 'customers', item: 'product', items: 'products', sale: 'sale', sales: 'sales',
    sell: 'sell', has_stock: true },
  services: { kind: 'services', revenue: 'revenue', customer: 'client', customers: 'clients', item: 'service', items: 'services', sale: 'invoice',
    sales: 'invoices', sell: 'bill', has_stock: false },
  both: { kind: 'both', revenue: 'revenue', customer: 'customer', customers: 'customers', item: 'product or service', items: 'products and services',
    sale: 'sale', sales: 'sales', sell: 'sell', has_stock: true },
};

const BY_CATEGORY: Record<string, Partial<Words>> = {
  food: { item: 'menu item', items: 'menu items', sale: 'order', sales: 'orders' },
  health: { customer: 'patient', customers: 'patients', items: 'services' },
  education: { revenue: 'fees', customer: 'student', customers: 'students', item: 'course', items: 'courses and fees' },
  hospitality: { customer: 'guest', customers: 'guests', item: 'booking', items: 'rooms, events and services', sale: 'booking', sales: 'bookings' },
  real_estate: { customer: 'client', customers: 'clients and tenants', item: 'property or service', items: 'properties and services' },
  beauty: { customer: 'client', customers: 'clients', item: 'product or treatment', items: 'products and treatments' },
  auto: { item: 'part or service', items: 'parts and services' },
  logistics: { item: 'delivery or trip', items: 'deliveries and trips' },
  construction: { item: 'job', items: 'jobs and contracts', sale: 'invoice', sales: 'invoices' },
};

export function wordsFor(o: { offering?: string | null; category_id?: string | null } | null | undefined): Words {
  const kind: Kind = o?.offering === 'services' || o?.offering === 'both' ? o.offering : 'goods';
  return { ...BASE[kind], ...(BY_CATEGORY[String(o?.category_id || '')] || {}), kind };
}

// The words for the business open now (a shop's words until it says otherwise).
export function useWords(): Words {
  const { data: inv } = useInventory();
  const o = inv?.org as { offering?: string | null; category_id?: string | null } | undefined;
  return wordsFor(o);
}

// How the business sells, for the screens that change with it. A business that sells services only keeps no stock. Clinics,
// hotels and schools take walk-in customers, so they keep the till; a professional services firm (a law or accounting firm,
// a consultancy) issues invoices; any other services business records its sales by invoice or receipt. The database decides
// the same way in private.compliance_items.
export const WALK_IN = ['health', 'hospitality', 'education'];
export type Mode = { serviceOnly: boolean; walkIn: boolean; professional: boolean; till: boolean; stock: boolean };
type ModeOrg = { offering?: string | null; category_id?: string | null; professional_services?: boolean | null };
export function modeFor(o: ModeOrg | null | undefined): Mode {
  const serviceOnly = o?.offering === 'services';
  const cat = String(o?.category_id || '');
  const walkIn = serviceOnly && WALK_IN.includes(cat);
  const professional = serviceOnly && !walkIn && (o?.professional_services === true || cat === 'professional');
  return { serviceOnly, walkIn, professional, till: !serviceOnly || walkIn, stock: !serviceOnly };
}
export function useMode(): Mode {
  const { data: inv } = useInventory();
  return modeFor(inv?.org as ModeOrg | undefined);
}
export const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
