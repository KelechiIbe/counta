// Arriving from TaxStreem: the signed token in the link becomes a Counta session, in the right business, with no password.
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { useSession } from '../../state/session';
import { Alert, Spinner } from '../../components/ui';

const TAXSTREEM: string = import.meta.env.VITE_MAIN_APP_URL || 'https://app.taxstreem.com';

export default function Sso() {
  const nav = useNavigate();
  const { setOrgId, refreshMemberships } = useSession();
  const [err, setErr] = useState<string | null>(null);
  const ran = useRef(false);
  useEffect(() => {
    if (ran.current) return;
    ran.current = true;
    const url = new URL(window.location.href);
    const token = url.searchParams.get('token') || new URLSearchParams(url.hash.slice(1)).get('token') || '';
    // The token is single-use and short-lived; keep it out of the history and of any later Referer header.
    window.history.replaceState(null, '', '/sso');
    (async () => {
      if (!token) { setErr('This link has no sign-in token. Open Counta from TaxStreem again.'); return; }
      const r = await edge<{ token_hash: string; type: string; org_id: string; next: string | null }>('taxstreem', { action: 'sso', token });
      if (r.ok === false || !r.token_hash) { setErr(r.error || 'Could not sign you in.'); return; }
      await supabase.auth.signOut().catch(() => {});
      let v = await supabase.auth.verifyOtp({ token_hash: r.token_hash, type: 'magiclink' });
      if (v.error) v = await supabase.auth.verifyOtp({ token_hash: r.token_hash, type: 'email' });
      if (v.error) { setErr(v.error.message); return; }
      setOrgId(r.org_id);
      await refreshMemberships().catch(() => {});
      setOrgId(r.org_id);
      nav(r.next || '/home', { replace: true });
    })();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 24 }}>
      {err ? (
        <div className="stack" style={{ gap: 12, maxWidth: 420 }}>
          <Alert kind="red" icon="alert">{err}</Alert>
          <a className="btn btn-primary" href={TAXSTREEM}>Back to TaxStreem</a>
        </div>
      ) : (
        <div className="stack" style={{ alignItems: 'center', gap: 14 }}><Spinner /><div className="muted">Signing you in from TaxStreem…</div></div>
      )}
    </div>
  );
}
