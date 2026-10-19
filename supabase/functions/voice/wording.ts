// The words a business uses for its own money and people: a shop has sales and customers, a law firm has revenue and
// clients, a school has fees and students. The same table lives in src/lib/wording.ts for the screens; keep the two alike.

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

// What Martina is told about the business's words.
export function wordingNote(o: { offering?: string | null; category_id?: string | null; category_label?: string | null } | null | undefined) {
  if (!o?.offering) {
    return 'We do not yet know whether the business sells goods, services or both. Use neutral words ("what you sell or the services you offer", '
      + '"sales or revenue", "customers or clients") until you find out.';
  }
  const w = wordsFor(o);
  const what = w.kind === 'goods' ? 'sells goods' : w.kind === 'services' ? 'sells services only, with no stock' : 'sells both goods and services';
  return [
    `This business ${what}${o.category_label ? ` (${o.category_label})` : ''}. Use its words: say "${w.revenue}" for its income, "${w.customers}" for the people`
      + ` who pay it, "${w.items}" for what it sells, and "${w.sales}" for the documents of what it ${w.sell}s.`,
    w.has_stock ? '' : 'Never ask about stock, products sold or "what did you sell"; ask about work done, invoices raised and revenue.',
  ].filter(Boolean).join(' ');
}
