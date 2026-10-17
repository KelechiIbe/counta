// Systems a business might be moving from: how to get the data out, and how their export columns map to Counta.
// Column presets are matched on the start of the header, so "In stock [Ikeja]" matches "in stock".

export interface SourceSystem {
  id: string; name: string; short: string;
  items: string; vendors: string; sales: string; tip?: string;
  preset: Record<string, string>;
}

export const SYSTEMS: SourceSystem[] = [
  {
    id: 'qbo', name: 'QuickBooks Online', short: 'QuickBooks',
    items: 'Sales → Products and services → the export icon above the list (Export to Excel). Inventory items carry Quantity On Hand and Purchase Cost.',
    vendors: 'Expenses → Vendors → the export icon above the list.',
    sales: 'Reports → Sales by Product/Service Detail (or Summary) for the last three to twelve months → Export to Excel.',
    tip: 'Run Reports → Inventory Valuation Summary as at your go-live date and keep its total. Counta checks your upload against it.',
    preset: { 'product service name': 'name', 'product service': 'name', 'sales description': 'description', 'purchase description': 'note', type: 'note',
      'sales price rate': 'price', taxable: 'ignore', 'income account': 'note', 'expense account': 'note', 'purchase cost': 'cost',
      'quantity on hand': 'qty', 'quantity as of date': 'ignore', 'reorder point': 'reorder_floor', 'inventory asset account': 'note', 'preferred vendor': 'vendor' },
  },
  {
    id: 'qbd', name: 'QuickBooks Desktop', short: 'QuickBooks Desktop',
    items: 'Lists → Item List → Excel → Export all items. Or run Reports → Inventory → Inventory Valuation Summary as at your go-live date and export it, which has quantity and average cost.',
    vendors: 'Vendor Center → Excel → Export Vendor List.',
    sales: 'Reports → Sales → Sales by Item Detail → Excel.',
    preset: { item: 'name', 'item name': 'name', description: 'description', type: 'note', account: 'note', 'on hand': 'qty', 'avg cost': 'cost', 'asset value': 'value_total',
      'sales price': 'price', price: 'price', 'u m': 'selling_unit', 'reorder pt': 'reorder_floor', 'preferred vendor': 'vendor', mpn: 'note' },
  },
  {
    id: 'sage', name: 'Sage 50 / Sage Pastel', short: 'Sage',
    items: 'Run the Inventory Valuation report (or the Item List with quantities) as at your go-live date and export it to Excel.',
    vendors: 'Export the Vendor or Supplier List report to Excel.',
    sales: 'Run Sales by Item (or Item Sales History) for the last three to twelve months and export it.',
    preset: { 'item id': 'sku', 'item code': 'sku', code: 'sku', 'item description': 'name', description: 'name', 'qty on hand': 'qty', 'quantity on hand': 'qty',
      'unit cost': 'cost', 'average cost': 'cost', 'avg cost': 'cost', 'last unit cost': 'note', 'item value': 'value_total', value: 'value_total',
      'sales price 1': 'price', 'price level 1': 'price', 'selling price': 'price', 'item class': 'category', 'stocking u m': 'selling_unit', 'reorder point': 'reorder_floor' },
  },
  {
    id: 'zoho', name: 'Zoho Inventory or Zoho Books', short: 'Zoho',
    items: 'Items → the menu beside New → Export Items, as XLS or CSV.',
    vendors: 'Purchases → Vendors → the menu → Export Vendors.',
    sales: 'Reports → Sales → Sales by Item for the last three to twelve months → Export.',
    tip: 'Zoho exports both Opening Stock and Stock On Hand. Use Stock On Hand and leave Opening Stock out.',
    preset: { 'item name': 'name', rate: 'price', 'purchase rate': 'cost', 'stock on hand': 'qty', 'opening stock': 'note', 'opening stock value': 'note',
      unit: 'selling_unit', 'category name': 'category', 'reorder level': 'reorder_floor', 'preferred vendor': 'vendor', vendor: 'vendor', upc: 'barcode', ean: 'barcode',
      isbn: 'barcode', 'item type': 'note', 'product type': 'note', account: 'note', 'inventory account': 'note', 'purchase account': 'note', 'tax name': 'note',
      'tax percentage': 'note', 'purchase description': 'note', 'sales description': 'description', status: 'ignore', 'item id': 'ignore' },
  },
  {
    id: 'odoo', name: 'Odoo', short: 'Odoo',
    items: 'Inventory → Reporting → Stock (or Valuation), filtered to your go-live date → select all → Action → Export, with Product, Internal Reference, Quantity and Value.',
    vendors: 'Purchase → Vendors → list view → select all → Action → Export.',
    sales: 'Sales → Reporting → Sales, grouped by product and month → export.',
    preset: { 'internal reference': 'sku', product: 'name', name: 'name', 'sales price': 'price', cost: 'cost', 'quantity on hand': 'qty', 'on hand': 'qty', quantity: 'qty',
      'product category': 'category', 'unit of measure': 'selling_unit', 'total value': 'value_total', value: 'value_total', vendors: 'vendor' },
  },
  {
    id: 'tally', name: 'Tally Prime or Tally ERP 9', short: 'Tally',
    items: 'Gateway of Tally → Display More Reports → Inventory Books / Stock Summary, as at your go-live date → Export (Alt+E) to Excel.',
    vendors: 'Display → List of Accounts, Sundry Creditors group → Export.',
    sales: 'Display → Inventory Books → Stock Item → Monthly Summary, or the Sales Register with item details → Export.',
    tip: 'Stock Summary shows Rate and Value. Counta reads Rate as cost, and works cost out from Value where Rate is blank.',
    preset: { particulars: 'name', 'name of item': 'name', quantity: 'qty', 'closing quantity': 'qty', rate: 'cost', 'closing rate': 'cost', value: 'value_total',
      'closing value': 'value_total', 'stock group': 'category', group: 'category', units: 'selling_unit' },
  },
  {
    id: 'loyverse', name: 'Loyverse POS', short: 'Loyverse',
    items: 'Back office → Items → Item list → Export. Each store has its own In stock column, which Counta matches to your branches.',
    vendors: 'Back office → Inventory management → Suppliers.',
    sales: 'Back office → Reports → Sales by item, for the last three to twelve months → Export.',
    preset: { handle: 'ignore', name: 'name', 'in stock': 'qty', 'low stock': 'reorder_floor', 'optimal stock': 'note', 'available for sale': 'ignore',
      'track stock': 'ignore', 'sold by weight': 'note', 'option 1 name': 'note', 'option 1 value': 'note', 'option 2 name': 'note', 'option 2 value': 'note' },
  },
  {
    id: 'bc', name: 'Microsoft Dynamics 365 Business Central', short: 'Business Central',
    items: 'Items list → Open in Excel. Inventory is the quantity on hand.',
    vendors: 'Vendors list → Open in Excel.',
    sales: 'Item Ledger Entries filtered to Sale, for the last three to twelve months → Open in Excel.',
    preset: { no: 'sku', description: 'name', 'base unit of measure': 'selling_unit', inventory: 'qty', 'unit cost': 'cost', 'unit price': 'price',
      'vendor no': 'note', 'item category code': 'category', 'reorder point': 'reorder_floor', blocked: 'ignore' },
  },
  {
    id: 'square', name: 'Square', short: 'Square',
    items: 'Items → Actions → Export library. Each location has a Current Quantity column.',
    vendors: 'Items → Vendors → Export.',
    sales: 'Reports → Item sales for the last three to twelve months → Export.',
    preset: { 'item name': 'name', 'current quantity': 'qty', 'default unit cost': 'cost', gtin: 'barcode', 'default vendor name': 'vendor', token: 'ignore' },
  },
  {
    id: 'excel', name: 'Excel, Google Sheets or a ledger book', short: 'my spreadsheet',
    items: 'Use your own stock sheet as it is, or download Counta\'s template for your trade and fill it in. A stock count on the day is the best source.',
    vendors: 'Any list with supplier names, and phone numbers or emails if you have them.',
    sales: 'Any record of what sold: a daily sales book typed up, or totals per item for a period.',
    preset: {},
  },
];

export const systemById = (id: string | null | undefined) => SYSTEMS.find((s) => s.id === id);

// Suppliers and sales history use small field lists of their own.
export interface SimpleField { key: string; label: string; syn: string[]; required?: boolean }
export const VENDOR_FIELDS: SimpleField[] = [
  { key: 'name', label: 'Supplier name', required: true, syn: ['name', 'vendor', 'supplier', 'vendor name', 'supplier name', 'company', 'company name', 'display name', 'particulars', 'contact name'] },
  { key: 'phone', label: 'Phone', syn: ['phone', 'phone number', 'mobile', 'telephone', 'tel', 'whatsapp', 'work phone', 'mobile phone', 'contact phone'] },
  { key: 'email', label: 'Email', syn: ['email', 'e mail', 'email address', 'mail'] },
  { key: 'location', label: 'Address or area', syn: ['address', 'location', 'city', 'area', 'billing address', 'street', 'state'] },
  { key: 'tin', label: 'Tax ID', syn: ['tin', 'tax id', 'tax identification number', 'tax number', 'vat number', 'tax registration number', 'trn'] },
  { key: 'vat_registered', label: 'VAT registered (Yes/No)', syn: ['vat registered', 'vat', 'taxable', 'vat status'] },
  { key: 'credit_days', label: 'Credit days', syn: ['credit days', 'payment terms', 'terms', 'credit terms', 'due days'] },
  { key: 'lead_time_days', label: 'Delivery days', syn: ['lead time', 'lead time days', 'delivery days', 'days to deliver'] },
  { key: 'notes', label: 'Notes', syn: ['notes', 'note', 'remarks', 'comments', 'memo'] },
];
export const HISTORY_FIELDS: SimpleField[] = [
  { key: 'date', label: 'Date', syn: ['date', 'day', 'transaction date', 'sale date', 'invoice date', 'posting date', 'txn date'] },
  { key: 'item', label: 'Item name', syn: ['item', 'item name', 'product', 'product name', 'product service', 'description', 'name', 'particulars', 'memo description'] },
  { key: 'sku', label: 'SKU or code', syn: ['sku', 'item code', 'code', 'internal reference', 'item no', 'no', 'item id'] },
  { key: 'barcode', label: 'Barcode', syn: ['barcode', 'ean', 'upc', 'gtin'] },
  { key: 'location', label: 'Branch', syn: ['location', 'branch', 'store', 'shop', 'outlet', 'warehouse'] },
  { key: 'qty', label: 'Quantity sold', required: true, syn: ['qty', 'quantity', 'quantity sold', 'qty sold', 'items sold', 'units sold', 'sold'] },
  { key: 'revenue', label: 'Sales value', syn: ['amount', 'sales', 'net sales', 'revenue', 'gross sales', 'total', 'sales amount', 'value', 'line total'] },
];
