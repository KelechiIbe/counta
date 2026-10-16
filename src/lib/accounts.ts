// TaxStreem chart of accounts and Counta's posting rules.
//
// Every posting function on the server resolves its accounts through a posting role
// (inventory, purchases, payables...). posting_map() returns what each role points at for the
// current business, so screens never hard-code an account code.
import { useQuery } from '@tanstack/react-query';
import { must, rpc, supabase } from './supabase';
import { useSession } from '../state/session';

export interface Account {
  code: string; name: string; kind: string; category: string | null; normal_balance: 'debit' | 'credit' | null;
  parent_code: string | null; is_group: boolean; is_system: boolean; active: boolean; sort: number | null;
}
export interface PostingRole {
  role: Role; label: string; description: string; account_code: string; account_name: string;
  default_code: string; allowed: string; sort: number;
}
export type Role = 'inventory' | 'goods_in_transit' | 'purchases' | 'input_vat' | 'payables' | 'inventory_movement'
  | 'stock_variance' | 'stock_loss' | 'opening_equity' | 'landed_duty' | 'landed_freight';

// The order TaxStreem's Accounting > Chart of accounts screen uses.
export const CATEGORIES = [
  'Assets', 'Liabilities', 'Equity', 'Income', 'Cost of Sales', 'Expenses', 'Finance Costs & Taxation',
  'Other Comprehensive Income', 'System & Control',
] as const;

// Used before posting_map() has loaded, and by anyone reading the code. Same as posting_roles defaults.
const FALLBACK: Record<Role, [string, string]> = {
  inventory: ['1203', 'Inventory - Finished Goods'],
  goods_in_transit: ['1204', 'Goods in Transit'],
  purchases: ['5101', 'Purchases - Local'],
  input_vat: ['1402', 'VAT Input (Recoverable)'],
  payables: ['2101', 'Trade Payables - Local'],
  inventory_movement: ['5400', 'Inventory Movement (System)'],
  stock_variance: ['5400', 'Inventory Movement (System)'],
  stock_loss: ['6805', 'Inventory Write-Downs'],
  opening_equity: ['3999', 'Opening Balance Equity (System)'],
  landed_duty: ['5105', 'Import Duties & Landing Costs'],
  landed_freight: ['5104', 'Carriage Inwards & Clearing'],
};

export function useAccounts() {
  return useQuery({
    queryKey: ['accounts'],
    staleTime: 60 * 60 * 1000,
    queryFn: () => must<Account[]>(supabase.from('accounts').select('*').eq('active', true).order('sort')),
  });
}

export function usePostingMap() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['postingMap', orgId],
    enabled: !!orgId,
    staleTime: 5 * 60 * 1000,
    queryFn: () => rpc<PostingRole[]>('posting_map', { p_org: orgId }),
  });
}

// Items that point at their own inventory account, keyed by item id.
export function useItemAccounts() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['itemAccounts', orgId],
    enabled: !!orgId,
    queryFn: async () => {
      const rows = await must<{ id: string; inventory_account: string }[]>(
        supabase.from('items').select('id, inventory_account').eq('org_id', orgId!).not('inventory_account', 'is', null));
      return Object.fromEntries(rows.map((r) => [r.id, r.inventory_account])) as Record<string, string>;
    },
  });
}

export function acct(map: PostingRole[] | undefined, role: Role): { code: string; name: string } {
  const r = map?.find((x) => x.role === role);
  return r ? { code: r.account_code, name: r.account_name } : { code: FALLBACK[role][0], name: FALLBACK[role][1] };
}

export function accountName(accounts: Account[] | undefined, code: string): string {
  return accounts?.find((a) => a.code === code)?.name || Object.values(FALLBACK).find(([c]) => c === code)?.[1] || code;
}

// Accounts a role may point at: postable (not a header) and matching the role's pattern.
export function choicesFor(accounts: Account[] | undefined, allowed: string): Account[] {
  let re: RegExp;
  try { re = new RegExp(allowed); } catch { return []; }
  return (accounts || []).filter((a) => !a.is_group && re.test(a.code));
}

export function chartCsv(accounts: Account[]): string {
  const esc = (s: string) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
  const rows = accounts.map((a) => [a.code, a.name, a.category || '', a.normal_balance === 'credit' ? 'Credit' : 'Debit',
    a.parent_code || '', a.is_group ? 'Header' : a.is_system ? 'System' : 'Posting'].map(esc).join(','));
  return ['Account Code,Account Name,Category,Normal balance,Parent,Type', ...rows].join('\n');
}
