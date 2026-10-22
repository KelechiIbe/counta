// The Counta Partner programme from the business's side: connecting the accountant whose link brought it, the partner
// directory in Settings, Your accountant, and the welcome offer on the plan page.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../../lib/supabase';
import { type Listing, type Offer, type PartnerPublic, refCode, useOrgPartner } from '../../lib/partners';
import { useInventory, useSession, useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Spinner } from '../../components/ui';
import { PartnerBadge } from '../../components/PartnerBadge';
import { SERVICES } from '../../practice/api';

const offerText = (o: Offer) => `${o.percent}% off your ${o.payments > 1 ? `next ${o.payments} payments` : 'first payment'} for a Counta plan`;

// Home: "LedgerPro & Co invited you to Counta. Connect them as your accountant?"
export function PartnerInvite() {
  const { orgId, session, memberships } = useSession();
  const { data: inv } = useInventory();
  const qc = useQueryClient();
  const toast = useToast();
  const code = refCode.get() || ((session?.user?.user_metadata as any)?.ref as string | undefined) || null;
  const owner = inv?.me.role === 'owner' && !memberships.find((m) => m.org_id === orgId)?.is_sample;
  const noKey = `counta-ref-no-${orgId}-${code}`;
  const [hidden, setHidden] = useState(() => { try { return localStorage.getItem(noKey) === '1'; } catch { return false; } });
  const [busy, setBusy] = useState(false);
  const q = useQuery({ queryKey: ['referral-offer', orgId, code], enabled: !!orgId && !!code && owner && !hidden, retry: false,
    queryFn: () => rpc<{ connected: boolean; practice: PartnerPublic; offer: Offer | null } | null>('referral_offer', { p_org: orgId, p_code: code }) });
  const d = q.data;
  if (!d || d.connected || hidden) return null;
  function later() { try { localStorage.setItem(noKey, '1'); } catch { /* private mode */ } setHidden(true); }
  async function connect() {
    setBusy(true);
    try {
      await rpc('referral_connect', { p_org: orgId, p_code: code });
      refCode.clear();
      await Promise.all(['referral-offer', 'org-partner', 'org-accountants'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      toast(`${d!.practice.name} is now your accountant`);
    } catch (e) { toast(cleanError(e), 'err'); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 10, borderColor: '#BFDBFE' }} data-testid="partner-invite">
      <div className="row wrap" style={{ gap: 8 }}>
        <Icon name="award" size={18} color="#1D4ED8" />
        <b className="grow" style={{ fontSize: 15 }}>{d.practice.name} invited you to Counta</b>
        <PartnerBadge tier={d.practice.tier} small />
      </div>
      <div style={{ fontSize: 14, lineHeight: 1.55 }}>Connect them as your accountant: they keep your books and prepare your tax returns inside Counta. They never move money,
        and you choose what they may do and can end it at any time.{d.offer ? <> You also get <b>{offerText(d.offer)}</b>.</> : null}</div>
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={connect}>{busy ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Connect {d.practice.name}</button>
        <button className="btn btn-ghost btn-sm" disabled={busy} onClick={later}>Not now</button>
      </div>
    </div>
  );
}

// The plan page: the welcome offer still open to the business.
export function OfferNote() {
  const { orgId } = useSession();
  const q = useOrgPartner(orgId);
  const o = q.data?.offer;
  if (!o) return null;
  return <Alert kind="green" icon="gift" style={{ marginBottom: 12 }}><span data-testid="partner-offer">Welcome offer from {o.practice}: {offerText(o)}. It comes off at checkout.</span></Alert>;
}

// Settings, Your accountant: the tier of each partner already connected.
export function ConnectedBadge({ practiceId }: { practiceId: string }) {
  const { orgId } = useSession();
  const q = useOrgPartner(orgId);
  const p = q.data?.partners.find((x) => x.id === practiceId);
  return p ? <PartnerBadge tier={p.tier} small /> : null;
}

export function PartnerDirectory() {
  const { orgId } = useSession();
  const op = useOrgPartner(orgId);
  const [open, setOpen] = useState(false);
  const [state, setState] = useState('');
  const q = useQuery({ queryKey: ['partner-directory', orgId, state], enabled: open && !!orgId,
    queryFn: () => rpc<Listing[]>('partner_directory', { p_org: orgId, p_state: state || null }) });
  if (!op.data?.directory) return null;
  if (!open) {
    return (
      <div className="row wrap" style={{ gap: 8 }}>
        <span className="muted" style={{ fontSize: 14 }}>No accountant yet?</span>
        <button className="btn btn-secondary btn-sm" onClick={() => setOpen(true)} data-testid="open-directory"><Icon name="award" size={14} />Find a Counta Partner</button>
      </div>
    );
  }
  return (
    <div className="stack" style={{ gap: 10 }} data-testid="partner-directory">
      <div className="row wrap" style={{ gap: 8 }}>
        <b className="grow" style={{ fontSize: 14 }}>Counta Partners</b>
        <input className="input input-sm" style={{ width: 160 }} placeholder="State, such as Lagos" value={state} onChange={(e) => setState(e.target.value)} aria-label="State" />
        <button className="btn btn-ghost btn-sm" onClick={() => setOpen(false)}>Close</button>
      </div>
      <div className="faint" style={{ fontSize: 13 }}>Accountants whose ICAN, ANAN or CITN licence TaxStreem verified. Ask one to take you on; they answer in their portal.</div>
      {q.isLoading ? <Spinner small /> : q.isError ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>
        : !q.data?.length ? <div className="muted" style={{ fontSize: 14 }}>No partners listed{state ? ` in ${state}` : ''} yet.</div>
        : q.data.map((p) => <ListingCard key={p.id} p={p} />)}
    </div>
  );
}

function ListingCard({ p }: { p: Listing }) {
  const { orgId } = useSession();
  const qc = useQueryClient();
  const toast = useToast();
  const [asking, setAsking] = useState(false);
  const [f, setF] = useState({ note: '', services: ['bookkeeping', 'vat', 'wht', 'cit', 'statements'] as string[] });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function ask() {
    setBusy(true); setErr(null);
    try {
      await rpc('directory_request', { p_org: orgId, p_practice: p.id, p: f });
      await Promise.all(['partner-directory', 'org-accountants'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      toast(`Asked ${p.name}. They answer in their portal.`); setAsking(false);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(false);
  }
  return (
    <div className="card card-pad stack" style={{ gap: 8 }} data-testid="partner-listing">
      <div className="row wrap" style={{ gap: 8 }}>
        <b className="grow" style={{ fontSize: 15, minWidth: 0 }}>{p.name}</b>
        <PartnerBadge tier={p.tier} small />
      </div>
      <div className="faint" style={{ fontSize: 13 }}>{[p.kind === 'sole' ? 'Sole practitioner' : 'Firm', p.state, p.licences.length ? `${p.licences.join(', ')} verified` : null].filter(Boolean).join(' · ')}</div>
      {p.blurb && <div style={{ fontSize: 14, lineHeight: 1.5 }}>{p.blurb}</div>}
      {p.connected ? <span className="chip t-green" style={{ alignSelf: 'flex-start' }}>Your accountant</span>
        : p.requested ? <span className="chip t-blue" style={{ alignSelf: 'flex-start' }}>Asked; waiting for their answer</span>
        : !asking ? <div><button className="btn btn-primary btn-sm" onClick={() => setAsking(true)}>Ask {p.name} to take us on</button></div>
        : (
          <div className="stack" style={{ gap: 8 }}>
            <div className="row wrap" style={{ gap: 6 }}>
              {SERVICES.map(([k, label]) => (
                <label key={k} className="check" style={{ fontSize: 13 }}><input type="checkbox" checked={f.services.includes(k)}
                  onChange={(e) => setF({ ...f, services: e.target.checked ? [...f.services, k] : f.services.filter((x) => x !== k) })} />{label}</label>
              ))}
            </div>
            <Field label="A note for them"><textarea className="input" maxLength={500} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} style={{ minHeight: 56 }}
              placeholder="What we do, and what we need help with" /></Field>
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
            <div className="row wrap" style={{ gap: 8 }}>
              <button className="btn btn-primary btn-sm" disabled={busy || !f.services.length} onClick={ask}>{busy ? <Spinner small /> : null}Send the request</button>
              <button className="btn btn-ghost btn-sm" onClick={() => setAsking(false)}>Cancel</button>
            </div>
          </div>
        )}
    </div>
  );
}
