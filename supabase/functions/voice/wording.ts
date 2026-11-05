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

// What Martina is told about the business: its words, how its profit is taxed, whether it is a professional services firm,
// and how it records its sales. Clinics, hotels and schools keep the till; other businesses that sell services only invoice.
export type BusinessFacts = { offering?: string | null; category_id?: string | null; category_label?: string | null;
  income_tax?: 'company' | 'personal' | 'exempt' | null; professional?: boolean | null };
const WALK_IN = ['health', 'hospitality', 'education'];
export function wordingNote(o: BusinessFacts | null | undefined) {
  const tax = !o?.income_tax ? ''
    : o.income_tax === 'company' ? 'It is a company: its income tax is companies income tax (CIT), with a return every year.'
    : o.income_tax === 'personal' ? 'It is a business name, not a company: it pays no companies income tax. Its profit is taxed as the owners\' personal income tax'
      + ' (each partner on their share), filed with the state by 31 March every year. Never talk to it about companies income tax or a CIT return.'
    : 'It is a not-for-profit body: its income is exempt from income tax unless it trades.';
  const prof = o?.professional ? 'It is a professional services firm, so it is never a small company for tax: it charges VAT on its fees whatever its size.' : '';
  if (!o?.offering) {
    return ['We do not yet know whether the business sells goods, services or both. Use neutral words ("what you sell or the services you offer", '
      + '"sales or revenue", "customers or clients") until you find out.', tax, prof].filter(Boolean).join(' ');
  }
  const w = wordsFor(o);
  const what = w.kind === 'goods' ? 'sells goods' : w.kind === 'services' ? 'sells services only, with no stock' : 'sells both goods and services';
  const till = w.kind !== 'services' ? '' : WALK_IN.includes(String(o.category_id || '')) ? 'It serves walk-in customers, so it can use the till as well as invoices.'
    : o.professional ? 'It issues invoices for its work and has no till.' : 'It records its sales by invoice or receipt and has no till.';
  return [
    `This business ${what}${o.category_label ? ` (${o.category_label})` : ''}. Use its words: say "${w.revenue}" for its income, "${w.customers}" for the people`
      + ` who pay it, "${w.items}" for what it sells, and "${w.sales}" for the documents of what it ${w.sell}s.`,
    w.has_stock ? '' : 'Never ask about stock, products sold, scanning or "what did you sell"; ask about work done, invoices raised and revenue.',
    till, tax, prof,
  ].filter(Boolean).join(' ');
}
