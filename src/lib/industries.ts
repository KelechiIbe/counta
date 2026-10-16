// What an item record holds for each kind of business. Core fields are real columns on items;
// industry fields live in items.attributes under their key. The same catalogue drives the item form,
// the spreadsheet template, the column matcher and the item list export.

export type IndustryId = 'retail' | 'wholesale' | 'pharmacy' | 'food' | 'fashion' | 'electronics' | 'building' | 'agro'
  | 'manufacturing' | 'auto' | 'beauty' | 'industrial' | 'other';
export type ItemType = 'merchandise' | 'finished_good' | 'raw_material' | 'packaging' | 'work_in_progress' | 'consumable' | 'spare_part' | 'chemical';

export interface FieldDef {
  key: string; label: string; type: 'text' | 'number' | 'select' | 'date' | 'bool';
  options?: string[]; placeholder?: string; hint?: string; syn?: string[];
}

export const ITEM_TYPES: { id: ItemType; label: string; sells: boolean; account: string; hint: string }[] = [
  { id: 'merchandise', label: 'Goods for resale', sells: true, account: '1203', hint: 'Bought and sold as they are.' },
  { id: 'finished_good', label: 'Finished goods', sells: true, account: '1203', hint: 'Made by you and sold.' },
  { id: 'raw_material', label: 'Raw material', sells: false, account: '1201', hint: 'Used to make what you sell.' },
  { id: 'packaging', label: 'Packaging material', sells: false, account: '1201', hint: 'Cartons, labels, bottles, wrap.' },
  { id: 'work_in_progress', label: 'Work in progress', sells: false, account: '1202', hint: 'Partly made goods.' },
  { id: 'consumable', label: 'Consumable / supplies', sells: false, account: '1205', hint: 'Used up in running the business.' },
  { id: 'spare_part', label: 'Spare part / tool', sells: false, account: '1205', hint: 'Kept to maintain equipment.' },
  { id: 'chemical', label: 'Chemicals & materials', sells: false, account: '1206', hint: 'Chemicals, gases, lab and site materials.' },
];
export const typeSells = (t?: string | null) => !t || t === 'merchandise' || t === 'finished_good';
export const typeLabel = (t?: string | null) => ITEM_TYPES.find((x) => x.id === t)?.label || 'Goods for resale';

const STORAGE = ['Room temperature', 'Cool & dry (below 25°C)', 'Chilled (2–8°C)', 'Frozen (below −18°C)', 'Keep away from light'];
const CONDITION = ['New', 'Open box', 'Refurbished', 'Used (Tokunbo)'];

// Shared by every industry, shown under "More details".
export const COMMON_FIELDS: FieldDef[] = [
  { key: 'manufacturer', label: 'Manufacturer', type: 'text', syn: ['manufacturer', 'mfr', 'made by', 'producer', 'maker'] },
  { key: 'shelf_location', label: 'Shelf / bin location', type: 'text', placeholder: 'e.g. Aisle 3, Bay B', syn: ['shelf', 'bin', 'bin location', 'shelf location', 'location in store', 'rack', 'aisle'] },
  { key: 'country_of_origin', label: 'Country of origin', type: 'text', syn: ['country of origin', 'origin', 'country', 'coo', 'made in'] },
  { key: 'hs_code', label: 'HS code (imports)', type: 'text', syn: ['hs code', 'hs', 'tariff code', 'customs code'] },
  { key: 'max_stock', label: 'Maximum stock (selling units)', type: 'number', syn: ['max stock', 'maximum stock', 'max', 'maximum', 'max level'] },
];

export interface Industry {
  id: IndustryId; label: string; blurb: string; categories: string[]; purchaseUnits: string[]; sellingUnits: string[];
  types: ItemType[]; batches: boolean; nafdac: boolean; fields: FieldDef[];
  example: Record<string, string | number>[];
}

export const INDUSTRIES: Industry[] = [
  {
    id: 'retail', label: 'Supermarket & general retail', blurb: 'FMCG, provisions, household goods',
    categories: ['Beverages', 'Dairy', 'Noodles & pasta', 'Grains & staples', 'Breakfast', 'Snacks & confectionery', 'Toiletries', 'Household', 'Baby care', 'Frozen', 'General'],
    purchaseUnits: ['Carton', 'Pack', 'Crate', 'Bag', 'Bale', 'Dozen', 'Tray'], sellingUnits: ['piece', 'pack', 'sachet', 'tin', 'bottle', 'bar', 'tube', 'kg', 'litre'],
    types: ['merchandise'], batches: false, nafdac: true,
    fields: [
      { key: 'size', label: 'Size / weight / volume', type: 'text', placeholder: 'e.g. 70g, 50cl, 1kg', syn: ['size', 'weight', 'volume', 'net weight', 'net wt', 'content'] },
      { key: 'variant', label: 'Flavour / variant', type: 'text', syn: ['flavour', 'flavor', 'variant', 'variety', 'type'] },
      { key: 'wholesale_price', label: 'Wholesale price (₦ per selling unit)', type: 'number', syn: ['wholesale price', 'w/s price', 'ws price', 'bulk price', 'trade price'] },
    ],
    example: [
      { name: 'Indomie Chicken 70g', category: 'Noodles & pasta', brand: 'Indomie', price: 300, cost: 265, purchase_unit: 'Carton', pack_size: 40, selling_unit: 'pack', vat_treatment: 'standard', size: '70g', variant: 'Chicken', qty: 400 },
      { name: 'Peak Evaporated Milk 160g', category: 'Dairy', brand: 'Peak', price: 650, cost: 560, purchase_unit: 'Carton', pack_size: 48, selling_unit: 'tin', size: '160g', qty: 96 },
    ],
  },
  {
    id: 'wholesale', label: 'Wholesale & distribution', blurb: 'Distributors, depots, open-market traders',
    categories: ['Beverages', 'Food', 'Household', 'Personal care', 'Building', 'Electronics', 'General'],
    purchaseUnits: ['Carton', 'Case', 'Bag', 'Bale', 'Pallet', 'Crate', 'Drum', 'Tonne'], sellingUnits: ['carton', 'pack', 'piece', 'bag', 'case', 'dozen', 'kg', 'litre'],
    types: ['merchandise'], batches: false, nafdac: true,
    fields: [
      { key: 'size', label: 'Size / weight / volume', type: 'text', syn: ['size', 'weight', 'volume', 'net weight'] },
      { key: 'wholesale_price', label: 'Wholesale price (₦ per selling unit)', type: 'number', syn: ['wholesale price', 'w/s price', 'ws price', 'distributor price', 'trade price'] },
      { key: 'dealer_price', label: 'Dealer / sub-distributor price (₦)', type: 'number', syn: ['dealer price', 'sub dealer price', 'sub-distributor price', 'dealer'] },
      { key: 'min_order_qty', label: 'Minimum order quantity', type: 'number', syn: ['moq', 'min order', 'minimum order', 'minimum order quantity'] },
      { key: 'pallet_qty', label: 'Units per pallet', type: 'number', syn: ['pallet qty', 'units per pallet', 'per pallet', 'pallet'] },
    ],
    example: [
      { name: 'Coca-Cola 50cl PET', category: 'Beverages', brand: 'Coca-Cola', price: 5400, cost: 4800, purchase_unit: 'Pallet', pack_size: 84, selling_unit: 'pack', size: '12 x 50cl', wholesale_price: 5200, min_order_qty: 10, qty: 840 },
    ],
  },
  {
    id: 'pharmacy', label: 'Pharmacy & medical supplies', blurb: 'Drugs, consumables, devices',
    categories: ['Analgesics', 'Antibiotics', 'Antimalarials', 'Vitamins & supplements', 'Cough & cold', 'Antihypertensives', 'Diabetes care', 'Antacids & GI', 'Dermatologicals', 'Medical devices', 'Consumables', 'Personal care'],
    purchaseUnits: ['Carton', 'Box', 'Pack', 'Dozen', 'Roll'], sellingUnits: ['pack', 'strip', 'tablet', 'bottle', 'tube', 'vial', 'ampoule', 'sachet', 'piece'],
    types: ['merchandise', 'consumable'], batches: true, nafdac: true,
    fields: [
      { key: 'generic_name', label: 'Generic name / active ingredient', type: 'text', placeholder: 'e.g. Paracetamol', syn: ['generic name', 'generic', 'active ingredient', 'api', 'molecule', 'inn'] },
      { key: 'strength', label: 'Strength', type: 'text', placeholder: 'e.g. 500mg, 250mg/5ml', syn: ['strength', 'dose', 'dosage strength', 'mg'] },
      { key: 'dosage_form', label: 'Dosage form', type: 'select', options: ['Tablet', 'Capsule', 'Caplet', 'Syrup', 'Suspension', 'Injection', 'Infusion', 'Cream', 'Ointment', 'Gel', 'Drops', 'Inhaler', 'Suppository', 'Powder', 'Device', 'Other'], syn: ['dosage form', 'form', 'formulation', 'presentation'] },
      { key: 'pack_presentation', label: 'Pack presentation', type: 'text', placeholder: 'e.g. 10 x 10 tablets', syn: ['pack presentation', 'pack', 'presentation'] },
      { key: 'rx_status', label: 'Prescription status', type: 'select', options: ['OTC', 'Pharmacy only (P)', 'Prescription only (POM)', 'Controlled drug'], syn: ['prescription status', 'rx status', 'otc/pom', 'pom', 'otc', 'schedule', 'rx'] },
      { key: 'therapeutic_class', label: 'Therapeutic class', type: 'text', syn: ['therapeutic class', 'drug class', 'class', 'therapeutic category'] },
      { key: 'storage', label: 'Storage', type: 'select', options: STORAGE, syn: ['storage', 'storage condition', 'store at', 'temperature'] },
    ],
    example: [
      { name: 'Emzor Paracetamol 500mg', category: 'Analgesics', brand: 'Emzor', price: 400, cost: 300, purchase_unit: 'Carton', pack_size: 50, selling_unit: 'pack', vat_treatment: 'zero', nafdac_no: 'A4-0271', generic_name: 'Paracetamol', strength: '500mg', dosage_form: 'Tablet', rx_status: 'OTC', storage: 'Cool & dry (below 25°C)', qty: 100, batch_no: 'EMZ2406', expiry_date: '30/06/2027' },
      { name: 'Amoxicillin 500mg Capsules', category: 'Antibiotics', price: 1800, cost: 1350, purchase_unit: 'Box', pack_size: 10, selling_unit: 'pack', vat_treatment: 'zero', generic_name: 'Amoxicillin', strength: '500mg', dosage_form: 'Capsule', rx_status: 'Prescription only (POM)', qty: 30, batch_no: 'AMX118', expiry_date: '31/01/2027' },
    ],
  },
  {
    id: 'food', label: 'Restaurant, bakery & food service', blurb: 'Kitchens, eateries, bakeries, caterers',
    categories: ['Proteins', 'Vegetables & fruit', 'Grains & flour', 'Oils & fats', 'Spices & seasoning', 'Dairy & eggs', 'Drinks', 'Packaging', 'Cleaning supplies', 'Menu items'],
    purchaseUnits: ['Bag', 'Carton', 'Crate', 'Basket', 'Tray', 'Jerrycan', 'Drum', 'Pack'], sellingUnits: ['kg', 'g', 'litre', 'piece', 'portion', 'plate', 'loaf', 'bottle', 'pack'],
    types: ['raw_material', 'finished_good', 'packaging', 'consumable', 'merchandise'], batches: true, nafdac: true,
    fields: [
      { key: 'storage', label: 'Storage', type: 'select', options: ['Dry store', 'Chilled (0–5°C)', 'Frozen (below −18°C)', 'Room temperature'], syn: ['storage', 'store', 'storage area', 'temperature'] },
      { key: 'shelf_life_days', label: 'Shelf life (days)', type: 'number', syn: ['shelf life', 'shelf life days', 'days to expiry', 'life'] },
      { key: 'allergens', label: 'Allergens', type: 'text', placeholder: 'e.g. nuts, gluten, milk', syn: ['allergens', 'allergen', 'contains'] },
      { key: 'portion_size', label: 'Portion / yield', type: 'text', placeholder: 'e.g. 250g per plate', syn: ['portion', 'portion size', 'yield', 'serving size'] },
      { key: 'halal', label: 'Halal', type: 'bool', syn: ['halal'] },
    ],
    example: [
      { name: 'Frozen chicken (whole)', item_type: 'raw_material', category: 'Proteins', price: '', cost: 4200, purchase_unit: 'Carton', pack_size: 10, selling_unit: 'kg', vat_treatment: 'zero', storage: 'Frozen (below −18°C)', shelf_life_days: 180, qty: 40, expiry_date: '31/03/2027' },
      { name: 'Jollof rice & chicken', item_type: 'finished_good', category: 'Menu items', price: 4500, cost: 1900, selling_unit: 'plate', portion_size: '1 plate', qty: '' },
    ],
  },
  {
    id: 'fashion', label: 'Fashion, textiles & footwear', blurb: 'Boutiques, fabric stores, shoe shops',
    categories: ['Men', 'Women', 'Kids', 'Footwear', 'Bags & accessories', 'Fabrics', 'Native wear', 'Jewellery', 'Underwear'],
    purchaseUnits: ['Bale', 'Bundle', 'Carton', 'Dozen', 'Roll', 'Pack'], sellingUnits: ['piece', 'pair', 'yard', 'metre', 'set', 'bundle'],
    types: ['merchandise', 'raw_material'], batches: false, nafdac: false,
    fields: [
      { key: 'size', label: 'Size', type: 'text', placeholder: 'e.g. M, 42, 10 UK', syn: ['size', 'sizes', 'shoe size', 'dress size'] },
      { key: 'colour', label: 'Colour', type: 'text', syn: ['colour', 'color', 'shade'] },
      { key: 'material', label: 'Material / fabric', type: 'text', placeholder: 'e.g. Cotton, Ankara, Leather', syn: ['material', 'fabric', 'composition'] },
      { key: 'gender', label: 'For', type: 'select', options: ['Men', 'Women', 'Unisex', 'Boys', 'Girls', 'Babies'], syn: ['gender', 'sex', 'for', 'department'] },
      { key: 'style_code', label: 'Style / model code', type: 'text', syn: ['style', 'style code', 'model', 'design no', 'design number'] },
      { key: 'season', label: 'Season / collection', type: 'text', syn: ['season', 'collection'] },
    ],
    example: [
      { name: 'Ankara print 6 yards — blue', category: 'Fabrics', price: 12000, cost: 8500, purchase_unit: 'Bundle', pack_size: 10, selling_unit: 'piece', material: 'Cotton wax print', colour: 'Blue', qty: 20 },
      { name: 'Men leather loafers', category: 'Footwear', price: 28000, cost: 19500, purchase_unit: 'Carton', pack_size: 6, selling_unit: 'pair', size: '43', colour: 'Brown', material: 'Leather', gender: 'Men', qty: 12 },
    ],
  },
  {
    id: 'electronics', label: 'Electronics, phones & appliances', blurb: 'Phones, computers, solar, home appliances',
    categories: ['Phones & tablets', 'Laptops & computers', 'Accessories', 'TV & audio', 'Home appliances', 'Solar & power', 'Networking', 'Gaming'],
    purchaseUnits: ['Carton', 'Pack', 'Box', 'Pallet'], sellingUnits: ['piece', 'set', 'pack', 'pair', 'metre'],
    types: ['merchandise', 'spare_part'], batches: false, nafdac: false,
    fields: [
      { key: 'model', label: 'Model number', type: 'text', syn: ['model', 'model number', 'model no', 'part number', 'mpn'] },
      { key: 'specs', label: 'Key specification', type: 'text', placeholder: 'e.g. 8GB RAM, 256GB', syn: ['spec', 'specs', 'specification', 'capacity', 'storage', 'ram'] },
      { key: 'colour', label: 'Colour', type: 'text', syn: ['colour', 'color'] },
      { key: 'condition', label: 'Condition', type: 'select', options: CONDITION, syn: ['condition', 'grade', 'state', 'new/used'] },
      { key: 'warranty_months', label: 'Warranty (months)', type: 'number', syn: ['warranty', 'warranty months', 'guarantee'] },
      { key: 'son_number', label: 'SON / SONCAP number', type: 'text', syn: ['son', 'soncap', 'son number', 'mancap'] },
    ],
    example: [
      { name: 'Samsung Galaxy A15 128GB', category: 'Phones & tablets', brand: 'Samsung', price: 215000, cost: 188000, purchase_unit: 'Carton', pack_size: 10, selling_unit: 'piece', model: 'SM-A155F', specs: '6GB / 128GB', colour: 'Black', condition: 'New', warranty_months: 12, qty: 15 },
    ],
  },
  {
    id: 'building', label: 'Building materials & hardware', blurb: 'Cement, steel, tiles, paint, plumbing, electricals',
    categories: ['Cement & concrete', 'Iron rods & steel', 'Roofing', 'Tiles & sanitary', 'Paint', 'Plumbing', 'Electrical', 'Timber & boards', 'Tools', 'Fasteners'],
    purchaseUnits: ['Bag', 'Tonne', 'Bundle', 'Carton', 'Pallet', 'Trip', 'Drum', 'Length'], sellingUnits: ['bag', 'length', 'piece', 'kg', 'square metre', 'bucket', 'litre', 'sheet', 'carton'],
    types: ['merchandise', 'consumable'], batches: false, nafdac: false,
    fields: [
      { key: 'grade', label: 'Grade / specification', type: 'text', placeholder: 'e.g. 42.5R, Y12, 0.45mm', syn: ['grade', 'specification', 'spec', 'class', 'gauge'] },
      { key: 'dimensions', label: 'Dimensions', type: 'text', placeholder: 'e.g. 60 x 60 cm, 12m', syn: ['dimensions', 'dimension', 'size', 'length', 'thickness'] },
      { key: 'unit_weight_kg', label: 'Weight per selling unit (kg)', type: 'number', syn: ['weight', 'unit weight', 'kg', 'weight kg'] },
      { key: 'colour', label: 'Colour / finish', type: 'text', syn: ['colour', 'color', 'finish'] },
      { key: 'son_number', label: 'SON / MANCAP number', type: 'text', syn: ['son', 'soncap', 'mancap', 'son number', 'certification'] },
    ],
    example: [
      { name: 'Dangote Cement 42.5R 50kg', category: 'Cement & concrete', brand: 'Dangote', price: 9800, cost: 9100, purchase_unit: 'Trip', pack_size: 600, selling_unit: 'bag', grade: '42.5R', unit_weight_kg: 50, qty: 600 },
      { name: '12mm iron rod (Y12)', category: 'Iron rods & steel', price: 11500, cost: 10400, purchase_unit: 'Tonne', pack_size: 113, selling_unit: 'length', grade: 'Y12', dimensions: '12m', qty: 226 },
    ],
  },
  {
    id: 'agro', label: 'Agro-produce & farm inputs', blurb: 'Grains, tubers, livestock feed, seeds, fertiliser',
    categories: ['Grains', 'Tubers', 'Legumes', 'Vegetables', 'Fruits', 'Seeds', 'Fertiliser', 'Agrochemicals', 'Feeds', 'Livestock'],
    purchaseUnits: ['Bag', 'Tonne', 'Basket', 'Crate', 'Truck', 'Jerrycan', 'Carton'], sellingUnits: ['bag', 'kg', 'mudu', 'derica', 'paint bucket', 'tuber', 'basket', 'crate', 'litre', 'piece'],
    types: ['merchandise', 'raw_material'], batches: true, nafdac: true,
    fields: [
      { key: 'variety', label: 'Variety / grade', type: 'text', placeholder: 'e.g. Ofada, Grade A', syn: ['variety', 'grade', 'quality', 'class'] },
      { key: 'origin_state', label: 'Source state / farm', type: 'text', syn: ['origin', 'source', 'state', 'farm', 'source state'] },
      { key: 'moisture_pct', label: 'Moisture content (%)', type: 'number', syn: ['moisture', 'moisture content', 'mc'] },
      { key: 'harvest_season', label: 'Harvest / season', type: 'text', syn: ['harvest', 'season', 'harvest date', 'crop year'] },
      { key: 'active_ingredient', label: 'Active ingredient (agrochemicals)', type: 'text', syn: ['active ingredient', 'ai', 'formulation'] },
      { key: 'storage', label: 'Storage', type: 'select', options: ['Dry store', 'Cold room', 'Silo', 'Open shed'], syn: ['storage', 'store'] },
    ],
    example: [
      { name: 'Local rice (Ofada) 50kg', category: 'Grains', price: 78000, cost: 70000, purchase_unit: 'Bag', pack_size: 1, selling_unit: 'bag', vat_treatment: 'zero', variety: 'Ofada', origin_state: 'Ogun', moisture_pct: 13, qty: 40 },
      { name: 'NPK 20:10:10 fertiliser', category: 'Fertiliser', price: 42000, cost: 38500, purchase_unit: 'Bag', pack_size: 1, selling_unit: 'bag', vat_treatment: 'zero', active_ingredient: 'NPK 20:10:10', qty: 60 },
    ],
  },
  {
    id: 'manufacturing', label: 'Manufacturing & production', blurb: 'Factories, processors, packaging plants',
    categories: ['Raw materials', 'Packaging', 'Work in progress', 'Finished goods', 'Consumables', 'Spare parts', 'Chemicals'],
    purchaseUnits: ['Bag', 'Tonne', 'Drum', 'Roll', 'Pallet', 'Carton', 'Litre', 'Sheet'], sellingUnits: ['kg', 'tonne', 'litre', 'piece', 'carton', 'roll', 'sheet', 'pack'],
    types: ['raw_material', 'packaging', 'work_in_progress', 'finished_good', 'consumable', 'spare_part', 'chemical'], batches: true, nafdac: true,
    fields: [
      { key: 'specification', label: 'Specification / grade', type: 'text', syn: ['specification', 'spec', 'grade', 'standard'] },
      { key: 'supplier_code', label: 'Supplier part / material code', type: 'text', syn: ['supplier code', 'material code', 'supplier part', 'vendor code'] },
      { key: 'unit_weight_kg', label: 'Weight per unit (kg)', type: 'number', syn: ['weight', 'unit weight', 'net weight'] },
      { key: 'wastage_pct', label: 'Expected wastage (%)', type: 'number', syn: ['wastage', 'scrap', 'loss', 'wastage %'] },
      { key: 'quality_standard', label: 'Quality standard / certificate', type: 'text', syn: ['standard', 'certificate', 'son', 'iso', 'mancap'] },
      { key: 'storage', label: 'Storage', type: 'select', options: STORAGE, syn: ['storage', 'store'] },
    ],
    example: [
      { name: 'HDPE resin pellets', item_type: 'raw_material', category: 'Raw materials', price: '', cost: 1500, purchase_unit: 'Bag', pack_size: 25, selling_unit: 'kg', specification: 'HDPE blow-moulding grade', qty: 2500 },
      { name: '1L bottled water (case of 12)', item_type: 'finished_good', category: 'Finished goods', price: 2400, cost: 1300, purchase_unit: 'Pallet', pack_size: 60, selling_unit: 'carton', qty: 300 },
    ],
  },
  {
    id: 'auto', label: 'Auto parts & lubricants', blurb: 'Spare parts dealers, lubricant distributors, workshops',
    categories: ['Engine parts', 'Brakes', 'Suspension & steering', 'Electrical', 'Filters', 'Lubricants', 'Tyres & batteries', 'Body parts', 'Accessories'],
    purchaseUnits: ['Carton', 'Drum', 'Set', 'Pack', 'Pallet'], sellingUnits: ['piece', 'set', 'pair', 'litre', 'gallon', 'can'],
    types: ['merchandise', 'spare_part', 'consumable'], batches: false, nafdac: false,
    fields: [
      { key: 'part_number', label: 'Part number (OEM)', type: 'text', syn: ['part number', 'part no', 'oem', 'oem number', 'pn', 'p/n'] },
      { key: 'fits', label: 'Fits (make / model / year)', type: 'text', placeholder: 'e.g. Toyota Corolla 2008–2013', syn: ['fits', 'compatible', 'compatibility', 'vehicle', 'model', 'application'] },
      { key: 'position', label: 'Position', type: 'select', options: ['Front', 'Rear', 'Front left', 'Front right', 'Rear left', 'Rear right', 'Universal'], syn: ['position', 'side'] },
      { key: 'condition', label: 'Condition', type: 'select', options: CONDITION, syn: ['condition', 'state', 'new/used'] },
      { key: 'viscosity', label: 'Viscosity / grade (oils)', type: 'text', placeholder: 'e.g. 20W-50', syn: ['viscosity', 'sae', 'oil grade'] },
      { key: 'warranty_months', label: 'Warranty (months)', type: 'number', syn: ['warranty', 'guarantee'] },
    ],
    example: [
      { name: 'Brake pads — front (Corolla)', category: 'Brakes', brand: 'Bosch', price: 18500, cost: 14000, purchase_unit: 'Carton', pack_size: 10, selling_unit: 'set', part_number: '04465-02220', fits: 'Toyota Corolla 2008–2013', position: 'Front', condition: 'New', qty: 20 },
      { name: 'Engine oil 20W-50 4L', category: 'Lubricants', brand: 'Total', price: 21000, cost: 17500, purchase_unit: 'Carton', pack_size: 4, selling_unit: 'can', viscosity: '20W-50', qty: 48 },
    ],
  },
  {
    id: 'beauty', label: 'Beauty, cosmetics & salon', blurb: 'Cosmetics shops, salons, spas, hair vendors',
    categories: ['Skincare', 'Haircare', 'Makeup', 'Fragrance', 'Hair extensions & wigs', 'Nails', 'Salon supplies', 'Men grooming'],
    purchaseUnits: ['Carton', 'Pack', 'Dozen', 'Box', 'Bundle'], sellingUnits: ['piece', 'bottle', 'tube', 'jar', 'pack', 'bundle', 'set'],
    types: ['merchandise', 'consumable'], batches: true, nafdac: true,
    fields: [
      { key: 'shade', label: 'Shade / colour', type: 'text', syn: ['shade', 'colour', 'color', 'tone'] },
      { key: 'size', label: 'Size / volume', type: 'text', placeholder: 'e.g. 200ml', syn: ['size', 'volume', 'ml', 'weight'] },
      { key: 'skin_hair_type', label: 'Skin / hair type', type: 'text', syn: ['skin type', 'hair type', 'type'] },
      { key: 'length', label: 'Length (hair)', type: 'text', placeholder: 'e.g. 22 inches', syn: ['length', 'inches', 'inch'] },
      { key: 'product_line', label: 'Product line', type: 'text', syn: ['line', 'range', 'product line', 'collection'] },
    ],
    example: [
      { name: 'Nivea body lotion 400ml', category: 'Skincare', brand: 'Nivea', price: 5200, cost: 4100, purchase_unit: 'Carton', pack_size: 12, selling_unit: 'bottle', nafdac_no: '02-1234', size: '400ml', qty: 24, expiry_date: '31/12/2027' },
    ],
  },
  {
    id: 'industrial', label: 'Oil & gas, industrial supplies', blurb: 'Spares, valves, chemicals, PPE, site materials',
    categories: ['Spare parts', 'Valves & fittings', 'Pipes & tubulars', 'Chemicals', 'PPE & safety', 'Tools & equipment', 'Electrical & instrumentation', 'Consumables', 'Lubricants & fuels'],
    purchaseUnits: ['Piece', 'Set', 'Drum', 'Carton', 'Pallet', 'Length', 'Tonne', 'Cylinder'], sellingUnits: ['piece', 'set', 'length', 'litre', 'kg', 'drum', 'pair', 'metre'],
    types: ['spare_part', 'consumable', 'chemical', 'merchandise'], batches: true, nafdac: false,
    fields: [
      { key: 'part_number', label: 'Part number', type: 'text', syn: ['part number', 'part no', 'p/n', 'pn', 'item code', 'mpn'] },
      { key: 'specification', label: 'Specification / standard', type: 'text', placeholder: 'e.g. API 6D, ASTM A105', syn: ['specification', 'spec', 'standard', 'api', 'astm'] },
      { key: 'material_grade', label: 'Material grade', type: 'text', syn: ['material', 'material grade', 'grade', 'metallurgy'] },
      { key: 'size_rating', label: 'Size & pressure rating', type: 'text', placeholder: 'e.g. 4in Class 600', syn: ['size', 'rating', 'pressure rating', 'class', 'size rating'] },
      { key: 'serial_tracked', label: 'Serial numbers recorded', type: 'bool', syn: ['serialised', 'serialized', 'serial', 'serial tracked'] },
      { key: 'criticality', label: 'Criticality', type: 'select', options: ['Critical', 'Essential', 'General'], syn: ['criticality', 'critical', 'priority'] },
      { key: 'hazard_class', label: 'Hazard class', type: 'select', options: ['Non-hazardous', 'Flammable', 'Corrosive', 'Toxic', 'Oxidiser', 'Compressed gas', 'Explosive', 'Radioactive'], syn: ['hazard', 'hazard class', 'dg class', 'un class'] },
      { key: 'msds', label: 'Safety data sheet on file', type: 'bool', syn: ['msds', 'sds', 'safety data sheet'] },
      { key: 'certificate', label: 'Certificate / MTC number', type: 'text', syn: ['certificate', 'mtc', 'cert', 'coc'] },
    ],
    example: [
      { name: 'Gate valve 4in Class 600 RF', item_type: 'spare_part', category: 'Valves & fittings', price: '', cost: 1450000, purchase_unit: 'Piece', pack_size: 1, selling_unit: 'piece', part_number: 'GV-4-600-RF', specification: 'API 6D', material_grade: 'ASTM A105', size_rating: '4in Class 600', criticality: 'Critical', qty: 4 },
      { name: 'Corrosion inhibitor (25L)', item_type: 'chemical', category: 'Chemicals', price: '', cost: 185000, purchase_unit: 'Drum', pack_size: 1, selling_unit: 'drum', hazard_class: 'Corrosive', msds: 'Yes', qty: 12, batch_no: 'CI-2291', expiry_date: '30/09/2027' },
    ],
  },
  {
    id: 'other', label: 'Other', blurb: 'Anything else that holds stock',
    categories: ['General'], purchaseUnits: ['Carton', 'Pack', 'Bag', 'Box', 'Piece'], sellingUnits: ['piece', 'pack', 'kg', 'litre', 'set'],
    types: ['merchandise', 'consumable', 'raw_material', 'finished_good'], batches: false, nafdac: false,
    fields: [
      { key: 'size', label: 'Size / variant', type: 'text', syn: ['size', 'variant', 'weight', 'volume'] },
      { key: 'colour', label: 'Colour', type: 'text', syn: ['colour', 'color'] },
      { key: 'model', label: 'Model / reference', type: 'text', syn: ['model', 'reference', 'ref'] },
    ],
    example: [{ name: 'Sample product', category: 'General', price: 1000, cost: 700, purchase_unit: 'Carton', pack_size: 12, selling_unit: 'piece', qty: 24 }],
  },
];

export const industryOf = (id?: string | null): Industry => INDUSTRIES.find((i) => i.id === id) || INDUSTRIES[0];
// Nigeria Tax Act 2025, s.187: medicines, basic food and farm inputs are zero-rated. New items in these trades start there.
export const defaultVat = (id?: string | null): 'standard' | 'zero' => (id === 'pharmacy' || id === 'agro' ? 'zero' : 'standard');

// Every attribute field across industries, so the importer and item drawer can label a value even when
// it was captured under another industry.
export const ALL_FIELDS: FieldDef[] = (() => {
  const seen = new Map<string, FieldDef>();
  for (const f of COMMON_FIELDS) seen.set(f.key, f);
  for (const ind of INDUSTRIES) for (const f of ind.fields) if (!seen.has(f.key)) seen.set(f.key, f);
  return [...seen.values()];
})();
export const fieldLabel = (key: string) => ALL_FIELDS.find((f) => f.key === key)?.label || key.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());

export function fieldsFor(industry: IndustryId | string | undefined): FieldDef[] {
  const ind = industryOf(industry);
  const keys = new Set(ind.fields.map((f) => f.key));
  return [...ind.fields, ...COMMON_FIELDS.filter((f) => !keys.has(f.key))];
}

export function formatAttr(f: FieldDef | undefined, v: unknown): string {
  if (v == null || v === '') return '';
  if (f?.type === 'bool' || typeof v === 'boolean') return v === true || /^(true|yes|y|1)$/i.test(String(v)) ? 'Yes' : 'No';
  if (f?.type === 'number' && typeof v === 'number') return v.toLocaleString('en-NG');
  return String(v);
}
