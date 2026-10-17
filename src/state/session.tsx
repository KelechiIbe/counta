import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc, supabase } from '../lib/supabase';
import type { Inventory, Perm } from '../lib/types';
import { Icon } from '../components/Icon';

// ---------------- toast ----------------
type ToastMsg = { text: string; tone: 'ok' | 'err' } | null;
const ToastCtx = createContext<(text: string, tone?: 'ok' | 'err') => void>(() => {});
export function ToastProvider({ children }: { children: ReactNode }) {
  const [msg, setMsg] = useState<ToastMsg>(null);
  const t = useRef<number>();
  const show = useCallback((text: string, tone: 'ok' | 'err' = 'ok') => {
    window.clearTimeout(t.current); setMsg({ text, tone });
    t.current = window.setTimeout(() => setMsg(null), tone === 'err' ? 4200 : 2600);
  }, []);
  return (
    <ToastCtx.Provider value={show}>
      {children}
      {msg && (
        <div className="toast" role="status" aria-live="polite">
          {msg.tone === 'ok' ? <Icon name="check" size={16} color="#4ADE80" sw={2.5} /> : <Icon name="alert" size={16} color="#F87171" />}
          <span>{msg.text}</span>
        </div>
      )}
    </ToastCtx.Provider>
  );
}
export const useToast = () => useContext(ToastCtx);

// ---------------- auth + business ----------------
export interface Membership { member_id: string; org_id: string; role: string; name: string; is_sample: boolean; email: string | null }
interface SessionCtx {
  session: Session | null; ready: boolean; memberships: Membership[]; orgId: string | null; setOrgId: (id: string | null) => void;
  // True while the businesses of someone who just signed in are being fetched.
  loadingMemberships: boolean;
  refreshMemberships: () => Promise<Membership[]>; signOut: () => Promise<void>;
}
const Ctx = createContext<SessionCtx>(null as any);
const ORG_KEY = 'counta.org';
const safeGet = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const safeSet = (k: string, v: string | null) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch { /* ignore */ } };

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [loadingMemberships, setLoadingMemberships] = useState(false);
  const [orgId, setOrgIdState] = useState<string | null>(safeGet(ORG_KEY));
  const qc = useQueryClient();

  const setOrgId = useCallback((id: string | null) => { setOrgIdState(id); safeSet(ORG_KEY, id); }, []);

  const refreshMemberships = useCallback(async () => {
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) { setMemberships([]); return []; }
    try { await rpc('claim_invites'); } catch { /* offline is fine */ }
    const { data, error } = await supabase.from('members').select('id, role, org_id, orgs(id, name, is_sample, email)')
      .eq('user_id', u.user.id).eq('status', 'active');
    if (error) throw error;
    const list: Membership[] = (data || []).filter((m: any) => m.orgs).map((m: any) => ({
      member_id: m.id, org_id: m.org_id, role: m.role, name: m.orgs.name, is_sample: m.orgs.is_sample, email: m.orgs.email,
    })).sort((a, b) => Number(a.is_sample) - Number(b.is_sample) || a.name.localeCompare(b.name));
    setMemberships(list);
    try { localStorage.setItem('counta.memberships', JSON.stringify(list)); } catch { /* ignore */ }
    setOrgIdState((cur) => {
      const next = cur && list.some((m) => m.org_id === cur) ? cur : list[0]?.org_id ?? null;
      safeSet(ORG_KEY, next); return next;
    });
    return list;
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      if (data.session) {
        try { await refreshMemberships(); } catch {
          try { setMemberships(JSON.parse(localStorage.getItem('counta.memberships') || '[]')); } catch { /* ignore */ }
        }
      }
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((evt, s) => {
      setSession(s);
      if (evt === 'SIGNED_IN') {
        setLoadingMemberships(true);
        refreshMemberships().catch(() => {}).finally(() => setLoadingMemberships(false));
      }
      if (evt === 'SIGNED_OUT') { setMemberships([]); qc.clear(); }
    });
    return () => sub.subscription.unsubscribe();
  }, [refreshMemberships, qc]);

  const signOut = useCallback(async () => { await supabase.auth.signOut(); setOrgId(null); }, [setOrgId]);

  const value = useMemo(() => ({ session, ready, memberships, orgId, setOrgId, refreshMemberships, signOut, loadingMemberships }),
    [session, ready, memberships, orgId, setOrgId, refreshMemberships, signOut, loadingMemberships]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
export const useSession = () => useContext(Ctx);

// ---------------- the inventory snapshot ----------------
export function useInventory() {
  const { orgId } = useSession();
  return useQuery({
    queryKey: ['inv', orgId],
    enabled: !!orgId,
    queryFn: async () => {
      const inv = await rpc<Inventory>('get_inventory', { p_org: orgId });
      try { localStorage.setItem('counta.inv.' + orgId, JSON.stringify(inv)); } catch { /* quota */ }
      return inv;
    },
    initialData: () => {
      try { const s = localStorage.getItem('counta.inv.' + orgId); return s ? (JSON.parse(s) as Inventory) : undefined; } catch { return undefined; }
    },
    initialDataUpdatedAt: 0,
    staleTime: 20_000,
  });
}

export function can(inv: Inventory | undefined, perm: Perm | 'owner'): boolean {
  if (!inv) return false;
  const me = inv.me;
  if (me.role === 'owner') return true;
  if (perm === 'owner') return false;
  return Boolean((me as any)['p_' + perm]);
}
