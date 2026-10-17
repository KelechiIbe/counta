export type Perm = 'record_sales' | 'receive_stock' | 'count_stock' | 'approve_adjustments' | 'edit_prices' | 'approve_pos' | 'transfer_stock' | 'see_margins' | 'issue_stock';
export const PERMS: { key: Perm; label: string }[] = [
  { key: 'record_sales', label: 'Record sales' },
  { key: 'receive_stock', label: 'Receive stock' },
  { key: 'count_stock', label: 'Count stock' },
  { key: 'approve_adjustments', label: 'Approve adjustments' },
  { key: 'edit_prices', label: 'Edit costs & prices' },
  { key: 'approve_pos', label: 'Approve POs' },
  { key: 'transfer_stock', label: 'Transfer stock' },
  { key: 'issue_stock', label: 'Issue to jobs' },
  { key: 'see_margins', label: 'See margins' },
];

export interface Org {
  id: string; name: string; email: string | null; phone: string | null; timezone: string; vat_registered: boolean;
  margin_threshold: number; safety_days: number; cover_days: number; cash_available: number | null;
  voice_trust_threshold: number; is_sample: boolean; created_at: string; industry?: string;
  spot_checks_per_day?: number; spot_check_last?: string | null;
}
export interface Location { id: string; org_id: string; name: string; code: string; address: string | null; is_main: boolean; }
export interface Vendor {
  id: string; org_id: string; name: string; location: string | null; channel: 'whatsapp' | 'email' | 'phone'; phone: string | null; email: string | null;
  vat_registered: boolean; lead_time_days: number; credit_days: number; fill_rate: number | null; price_stability: 'High' | 'Medium' | 'Low' | null; notes: string | null;
}
export interface Member {
  id: string; display_name: string; role: 'owner' | 'manager' | 'staff' | 'cashier'; title: string | null; location_id: string | null;
  status: string; email: string | null; phone: string | null; has_login: boolean; is_me: boolean; voice_confirmed: number;
  perms: Record<Perm, boolean>;
}
export interface MeRow {
  id: string; org_id: string; role: Member['role']; display_name: string; location_id: string | null; voice_confirmed: number;
  p_record_sales: boolean; p_receive_stock: boolean; p_count_stock: boolean; p_approve_adjustments: boolean; p_edit_prices: boolean;
  p_approve_pos: boolean; p_transfer_stock: boolean; p_see_margins: boolean; p_issue_stock?: boolean;
}
export interface Item {
  id: string; name: string; photo_path: string | null; barcode: string | null; sku: string | null; qr_code: string; category: string;
  vat_treatment: 'standard' | 'zero' | 'exempt'; nafdac_no: string | null; purchase_unit: string; pack_size: number; selling_unit: string;
  informal_unit: boolean; track_batches: boolean; reorder_floor: number; preferred_vendor_id: string | null; alt_vendor_id: string | null;
  price: number; import_priced: boolean; notes: Record<string, string>; needs_review: boolean; created_at: string;
  item_type?: string; brand?: string | null; description?: string | null; attributes?: Record<string, string | number | boolean>; inventory_account?: string | null;
  wac: number | null; last_cost: number | null; replacement_cost: number | null; replacement_source: string | null;
  qty: Record<string, number>; sold_30: number; sold_prev30: number; revenue_30: number; cogs_30: number | null;
  last_sale_at: string | null; first_at: string | null; last_move_at: string | null; snoozed_until: string | null; has_history?: boolean;
}
export interface Batch {
  id: string; item_id: string; location_id: string; batch_no: string; expiry_date: string | null; qty_remaining: number; qty_received: number;
  quarantined: boolean; quarantined_at: string | null;
}
export interface Inventory {
  org: Org; me: MeRow; can_see_costs: boolean; now: string; today: string; locations: Location[]; vendors: Vendor[];
  members: Member[]; items: Item[]; batches: Batch[];
}
export interface LedgerRow {
  gid: string; movement_id: string; type: string; n: number; n_items: number; item_id: string; item_name: string; selling_unit: string;
  purchase_unit: string; pack_size: number; qty: number; value: number | null; unit_cost?: number | null; sales_value: number | null;
  recorded_at: string; synced_at: string; offline: boolean; location_id: string; location_ids: string[]; author_name: string | null;
  approver_name?: string | null; channel: string; device_id: string | null; reason: string | null; note: string | null; review_status: string | null;
  journal_ref: string | null; journal_memo: string | null; receipt_ref: string | null; document_path: string | null; vendor_name: string | null;
  receipt_id: string | null; count_session_id: string | null; transfer_id: string | null; job_id?: string | null;
}
export interface ReceiptLine {
  id?: string; receipt_id?: string; org_id?: string; line_no: number; raw_text: string | null; item_id: string | null;
  new_item: NewItemDraft | null; qty: number; unit_kind: 'purchase' | 'selling'; unit_label: string | null; unit_cost: number;
  confidence: number; alt_reading: { label: string; qty: number; unit_kind?: 'purchase' | 'selling' } | null; bbox: number[] | null;
  confirmed: boolean; model_reading: any; batch_no: string | null; expiry_date: string | null;
}
export interface NewItemDraft {
  name: string; category?: string; purchase_unit?: string; pack_size?: number; selling_unit?: string; price?: number | null;
  vat_treatment?: 'standard' | 'zero' | 'exempt'; track_batches?: boolean; barcode?: string | null;
}
export interface Receipt {
  id: string; org_id: string; ref: string; vendor_id: string | null; vendor_name: string | null; location_id: string | null;
  source: 'pdf' | 'photo_typed' | 'photo_handwritten' | 'manual'; document_path: string | null; document_mime: string | null;
  invoice_no: string | null; invoice_date: string | null; vendor_vat_registered: boolean; prices_include_vat: boolean;
  status: 'reading' | 'needs_review' | 'posted' | 'discarded'; net: number; input_vat: number; gross: number; journal_id: string | null;
  po_id: string | null; ai_model: string | null; ai_error: string | null; created_at: string; posted_at: string | null; created_by: string | null;
  receipt_lines?: ReceiptLine[];
}
export interface CountSession {
  id: string; org_id: string; ref: string; location_id: string; area: string; assignee_id: string | null;
  status: 'open' | 'awaiting_reasons' | 'awaiting_approval' | 'approved'; created_by: string | null; submitted_at: string | null;
  approved_by: string | null; approved_at: string | null; device_id: string | null; offline: boolean; rejected_count: number; created_at: string;
  source?: 'manual' | 'spot_check';
  count_lines?: { item_id: string; counted: number | null; expected: number | null; reason: string | null; note: string | null }[];
}
export interface Proposal {
  id: string; item_id: string; item_name: string; selling_unit: string; kind: 'cost_increase' | 'below_replacement' | 'margin_compressed';
  status: 'open' | 'applied' | 'dismissed'; old_cost: number | null; new_cost: number | null; old_price: number; suggested_price: number;
  target_margin: number | null; source_ref: string | null; created_at: string; decided_at: string | null; decided_by_name: string | null;
}
export interface PurchaseOrder {
  id: string; ref: string; vendor_id: string | null; location_id: string | null; status: 'draft' | 'sent' | 'received' | 'cancelled';
  sent_via: string | null; total: number; fx_note: string | null; note: string | null; sent_at: string | null; received_at: string | null; created_at: string;
  po_lines: { id: string; item_id: string; qty: number; unit_cost: number; total: number }[];
}
export interface Transfer {
  id: string; ref: string; item_id: string; qty: number; unit_cost: number; from_location_id: string; to_location_id: string;
  status: 'in_transit' | 'received'; created_by: string | null; received_by: string | null; created_at: string; received_at: string | null;
}

export const REASONS = ['Breakage', 'Expired', 'Theft suspected', 'Miscount', 'Unrecorded sale', 'Other'] as const;
