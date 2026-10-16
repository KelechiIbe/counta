import { createClient } from '@supabase/supabase-js';

// Public values. Safe to ship to the browser; row level security protects the data.
export const SUPABASE_URL: string = import.meta.env.VITE_SUPABASE_URL || 'https://krtqqhndmncarwusukrw.supabase.co';
export const SUPABASE_KEY: string = import.meta.env.VITE_SUPABASE_ANON_KEY || 'sb_publishable_gpOuttGl-dS9nbpvexCmMw_S2xnsfcP';

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: 'counta-auth' },
});

export function cleanError(e: unknown): string {
  const msg = (e as any)?.message || (typeof e === 'string' ? e : 'Something went wrong.');
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return 'No connection. Check your data and try again.';
  if (/JWT|token is expired/i.test(msg)) return 'Your session expired. Sign in again.';
  if (/duplicate key value.*items_org_barcode/i.test(msg)) return 'Another item already uses that barcode.';
  if (/violates row-level security/i.test(msg)) return 'Your role does not allow this.';
  return msg.replace(/^ERROR:\s*/, '');
}

export async function rpc<T = any>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args ?? {});
  if (error) throw new Error(cleanError(error));
  return data as T;
}

export async function must<T>(p: PromiseLike<{ data: T | null; error: any }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Error(cleanError(error));
  return data as T;
}

export function photoUrl(path?: string | null): string | null {
  if (!path) return null;
  if (/^https?:/.test(path)) return path;
  return supabase.storage.from('item-photos').getPublicUrl(path).data.publicUrl;
}

export async function signedDoc(path?: string | null): Promise<string | null> {
  if (!path) return null;
  const { data } = await supabase.storage.from('documents').createSignedUrl(path, 60 * 30);
  return data?.signedUrl ?? null;
}

// Calls the Gemini-backed edge function. Returns { ok:false, reason:'not_configured' } when no key is set.
export async function ai<T = any>(action: string, payload: Record<string, unknown>): Promise<T & { ok?: boolean; reason?: string; error?: string }> {
  const { data, error } = await supabase.functions.invoke('ai', { body: { action, ...payload } });
  if (error) {
    let body: any = null;
    try { body = await (error as any).context?.json?.(); } catch { /* ignore */ }
    if (body) return body;
    return { ok: false, reason: 'error', error: cleanError(error) } as any;
  }
  return data as any;
}
