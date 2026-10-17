// Production runs and jobs: types, the query hook and recipe arithmetic.
import { useQuery } from '@tanstack/react-query';
import { useSession } from '../state/session';
import { rpc } from './supabase';
import type { Item } from './types';

export interface JobMaterial { item_id: string; issued: number | null; returned: number; net: number; value: number | null; last_at: string }
export interface Job {
  id: string; ref: string; kind: 'production' | 'job'; name: string; location_id: string; status: 'open' | 'completed' | 'cancelled';
  output_item_id: string | null; planned_qty: number | null; produced_qty: number | null; output_unit_cost: number | null;
  charge_account: string | null; charge_account_name: string | null; customer: string | null; notes: string | null; due_date: string | null;
  created_at: string; closed_at: string | null; created_by_name: string | null; closed_by_name: string | null;
  materials: JobMaterial[]; materials_value: number | null; other_costs: number | null; wip: number | null; last_at: string;
}
export interface RecipeLine { item_id: string; qty: number; wastage_pct: number }
export interface Recipe { item_id: string; yield_qty: number; lines: RecipeLine[]; notes: string | null; updated_at: string }
export interface JobsPayload { jobs: Job[]; recipes: Recipe[]; accounts: { code: string; name: string }[]; default_account: string }

export function useJobs(enabled = true) {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['jobs', orgId],
    enabled: !!orgId && enabled,
    queryFn: async () => {
      const r = await rpc<JobsPayload>('get_jobs', { p_org: orgId });
      try { localStorage.setItem('counta.jobs.' + orgId, JSON.stringify(r)); } catch { /* quota */ }
      return r;
    },
    initialData: () => {
      try { const s = localStorage.getItem('counta.jobs.' + orgId); return s ? (JSON.parse(s) as JobsPayload) : undefined; } catch { return undefined; }
    },
    initialDataUpdatedAt: 0,
    staleTime: 15_000,
  });
}

export const jobNoun = (k: Job['kind']) => (k === 'production' ? 'production run' : 'job');
export const STATUS_LABEL: Record<Job['status'], string> = { open: 'Open', completed: 'Completed', cancelled: 'Cancelled' };

// What a recipe expects for a given output quantity, wastage included.
export function recipeNeeds(recipe: Recipe | undefined, outputQty: number): { item_id: string; qty: number }[] {
  if (!recipe || !(outputQty > 0)) return [];
  const batches = outputQty / Number(recipe.yield_qty || 1);
  return recipe.lines.map((l) => ({ item_id: l.item_id, qty: round3(Number(l.qty) * batches * (1 + Number(l.wastage_pct || 0) / 100)) }));
}

// Cost of one output unit from current average costs, or null when a component has no cost yet.
export function recipeUnitCost(recipe: Recipe | undefined, items: Item[]): number | null {
  if (!recipe) return null;
  let total = 0;
  for (const l of recipe.lines) {
    const it = items.find((i) => i.id === l.item_id);
    if (!it || it.wac == null) return null;
    total += Number(l.qty) * (1 + Number(l.wastage_pct || 0) / 100) * Number(it.wac);
  }
  return total / Number(recipe.yield_qty || 1);
}

export const round3 = (n: number) => Math.round(n * 1000) / 1000;
