// /r/:code: an accountant's own link to Counta. Shows who sent it and the welcome offer, keeps the code for after sign-up,
// and sends people to create an account or sign in. The business connects the accountant itself, from Home.
import { useEffect } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { type Preview, REF_RE, refCode } from '../../lib/partners';
import { useSession } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Spinner } from '../../components/ui';
import { PartnerBadge } from '../../components/PartnerBadge';
import { BrandSide } from '../auth/Auth';

export default function Referral() {
  const { code = '' } = useParams();
  const { session } = useSession();
  const ok = REF_RE.test(code);
  const q = useQuery({ queryKey: ['referral-preview', code], enabled: ok, retry: false, queryFn: () => rpc<Preview | null>('referral_preview', { p_code: code }) });
  const p = q.data;
  useEffect(() => { if (p) refCode.set(p.code); }, [p]);
  const offer = p?.offer;
  return (
    <div className="auth-wrap">
      <BrandSide />
      <div className="auth-form">
        <div className="auth-card stack" style={{ gap: 16 }} data-testid="referral-page">
          {!ok || (q.isFetched && !p) ? (
            <>
              <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 24, margin: 0 }}>This link is not complete</h1>
              <div className="muted" style={{ fontSize: 14 }}>Ask your accountant to send it again. You can still create your Counta account.</div>
              <Link className="btn btn-primary" to="/signup">Create your account</Link>
            </>
          ) : q.isLoading || !p ? <div className="row" style={{ justifyContent: 'center', padding: 30 }}><Spinner /></div> : (
            <>
              <div className="stack" style={{ gap: 8 }}>
                <span className="mini-label">Your accountant invites you</span>
                <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 26, margin: 0, lineHeight: 1.2 }}>{p.name}</h1>
                <div className="row wrap" style={{ gap: 6 }}>
                  <PartnerBadge tier={p.tier} />
                  {p.verified && <span className="chip t-green"><Icon name="shield" size={12} color="#15803D" />{p.licences.join(', ') || 'Licence'} verified by TaxStreem</span>}
                  {p.state && <span className="chip t-grey">{p.state}</span>}
                </div>
                {p.blurb && <div style={{ fontSize: 15, lineHeight: 1.55 }}>{p.blurb}</div>}
              </div>
              <div className="muted" style={{ fontSize: 14, lineHeight: 1.6 }}>
                {p.name} keeps clients' books and files their taxes in Counta. Create your account, add your business, and connect {p.name} as your
                accountant from Home. They work inside your books; they never move your money, and you can end it at any time.
              </div>
              {offer && (
                <Alert kind="green" icon="gift">
                  <b>{offer.percent}% off</b> your first {offer.payments > 1 ? `${offer.payments} payments` : 'payment'} for a Counta plan, when you connect {p.name} before you pay.
                </Alert>
              )}
              {session ? (
                <Link className="btn btn-primary" to="/home">Go to Counta and connect {p.name}</Link>
              ) : (
                <div className="stack" style={{ gap: 8 }}>
                  <Link className="btn btn-primary" to={`/signup?ref=${encodeURIComponent(p.code)}`}>Create your Counta account</Link>
                  <Link className="btn btn-secondary" to={`/login?ref=${encodeURIComponent(p.code)}`}>I already use Counta</Link>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
