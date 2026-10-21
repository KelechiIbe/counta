// Deleting a business for good (admins only): what goes and who loses their login, what stops it, and the business's name
// typed to confirm. The database removes every record at once; the admin server function then removes its files, the
// logins, its bank feeds at Mono and any WhatsApp number it linked. A deletion that could not finish is listed on
// Businesses with Try again.
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { num, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError } from '../api';
import { Card } from '../ui';

type Person = { user_id: string; name: string; email: string | null; role: string; login: 'removed' | 'kept'; why: string | null };
type Preview = {
  org: { id: string; name: string; is_sample: boolean };
  people: Person[]; invited: number; samples: { id: string; name: string }[];
  counts: { sales: number; bills: number; customers: number; vendors: number; items: number; journals: number; branches: number; files: number; bank_feeds: number; tools: number };
  blockers: string[]; can_delete: boolean;
};
type Done = { ok: boolean; error?: string; name?: string; finished?: boolean; logins?: number; files?: number; errors?: string[] };

const norm = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
const plural = (n: number, one: string, many = one + 's') => `${num(n)} ${n === 1 ? one : many}`;

export function DeleteBusiness({ id, name }: { id: string; name: string }) {
  const [open, setOpen] = useState(false);
  return (
    <Card title="Delete this business" sub="For good: the business, everything in it and its files, and the logins of the people who are in no other business, so they can sign up again from the start. This cannot be undone."
      right={<button className="btn btn-danger btn-sm" onClick={() => setOpen(true)} data-testid="delete-business"><Icon name="trash" size={14} />Delete business</button>}>
      <div className="faint" style={{ fontSize: 13 }}>Refused while a wallet holds money or money is on its way. Anyone also in another business, in an accountant practice or on TaxStreem's team keeps their login.</div>
      {open && <DeleteModal id={id} name={name} onClose={() => setOpen(false)} />}
    </Card>
  );
}

function DeleteModal({ id, name, onClose }: { id: string; name: string; onClose: () => void }) {
  const nav = useNavigate();
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-delete-preview', id], queryFn: () => rpc<Preview>('admin_business_delete_preview', { p_org: id }), staleTime: 0 });
  const [typed, setTyped] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const d = q.data;
  const removed = d?.people.filter((p) => p.login === 'removed') || [];
  const kept = d?.people.filter((p) => p.login === 'kept') || [];
  const ready = !!d?.can_delete && norm(typed) === norm(name);

  async function go() {
    setBusy(true); setErr(null);
    const r = await edge<Done>('admin', { action: 'delete_business', org_id: id, confirm: typed });
    if (!r.ok) { setErr(r.error || 'The business was not deleted.'); setBusy(false); return; }
    await Promise.all([qc.invalidateQueries({ queryKey: ['admin-businesses'] }), qc.invalidateQueries({ queryKey: ['admin-subscriptions'] }),
      qc.invalidateQueries({ queryKey: ['admin-overview'] }), qc.invalidateQueries({ queryKey: ['admin-deletions'] })]);
    qc.removeQueries({ queryKey: ['admin-business', id] });
    toast(r.finished ? `${r.name} is deleted.` : `${r.name} is deleted. A few things are still to remove: Businesses shows Try again.`);
    nav('/admin/businesses');
  }

  return (
    <Modal onClose={busy ? () => {} : onClose} width={560}>
      <ModalHead title={`Delete ${name}`} sub="Read what goes before you confirm. It cannot be brought back." onClose={busy ? () => {} : onClose} />
      <div className="modal-body stack" style={{ gap: 14 }} data-testid="delete-preview">
        {q.isLoading ? <SkeletonRows n={4} /> : !d ? <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert> : (
          <>
            {d.blockers.map((b) => <Alert key={b} kind="red" icon="lock">{b}</Alert>)}
            <div style={{ fontSize: 14, lineHeight: 1.6 }}>
              <b>What goes</b>
              <div className="muted">{[plural(d.counts.sales, 'sale or invoice', 'sales and invoices'), plural(d.counts.bills, 'bill'), plural(d.counts.customers, 'customer'),
                plural(d.counts.vendors, 'supplier'), plural(d.counts.items, 'product'), plural(d.counts.journals, 'journal'), plural(d.counts.branches, 'branch', 'branches'),
                plural(d.counts.files, 'file')].join(', ')}.
                {d.counts.bank_feeds ? ` ${plural(d.counts.bank_feeds, 'bank feed')} at Mono stop${d.counts.bank_feeds === 1 ? 's' : ''}.` : ''}
                {d.counts.tools ? ` ${plural(d.counts.tools, 'connected tool')} and ${d.counts.tools === 1 ? 'its key' : 'their keys'} go.` : ''}
                {d.invited ? ` ${plural(d.invited, 'invitation')} not yet taken.` : ''}</div>
              {d.samples.length > 0 && <div className="muted">With it: {d.samples.map((s) => s.name).join(', ')} (sample business of a person whose login goes).</div>}
            </div>
            <div className="stack" style={{ gap: 6 }}>
              <b style={{ fontSize: 14 }}>Logins removed ({removed.length})</b>
              {!removed.length ? <div className="faint" style={{ fontSize: 13 }}>None. Everyone in it keeps their login.</div> : removed.map((p) => (
                <div key={p.user_id} className="row" style={{ gap: 8, fontSize: 13, alignItems: 'flex-start' }} data-testid="login-removed">
                  <span className="chip t-red" style={{ flex: 'none' }}>removed</span><span style={{ minWidth: 0, overflowWrap: 'anywhere' }}><b>{p.name}</b> · {p.role}{p.email ? ` · ${p.email}` : ''}</span>
                </div>
              ))}
              {kept.length > 0 && <b style={{ fontSize: 14, marginTop: 6 }}>Logins kept ({kept.length})</b>}
              {kept.map((p) => (
                <div key={p.user_id} className="row" style={{ gap: 8, fontSize: 13, alignItems: 'flex-start' }} data-testid="login-kept">
                  <span className="chip t-grey" style={{ flex: 'none' }}>kept</span><span style={{ minWidth: 0, overflowWrap: 'anywhere' }}><b>{p.name}</b>{p.email ? ` · ${p.email}` : ''} · {p.why}</span>
                </div>
              ))}
            </div>
            {d.can_delete && (
              <Field label={<>Type <b>{name}</b> to confirm</>}>
                <input className="input" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} data-testid="delete-confirm" disabled={busy} />
              </Field>
            )}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
          </>
        )}
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
        <button className="btn btn-primary" style={{ background: ready ? 'var(--red)' : undefined, borderColor: ready ? 'var(--red)' : undefined }} disabled={!ready || busy}
          onClick={() => void go()} data-testid="delete-go">{busy ? <Spinner small /> : <Icon name="trash" size={14} color="#fff" />}{busy ? 'Deleting' : 'Delete for good'}</button>
      </div>
    </Modal>
  );
}

// Deletions the server function could not finish (a login, files, a bank feed or a WhatsApp number left), with Try again.
export function UnfinishedDeletions() {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-deletions'], queryFn: () => rpc<{ id: number; at: string; name: string; by: string | null; result: { errors?: string[] } | null }[]>('admin_business_deletions') });
  const [busy, setBusy] = useState<number | null>(null);
  if (!q.data?.length) return null;
  async function again(id: number) {
    setBusy(id);
    const r = await edge<Done>('admin', { action: 'delete_business_finish', audit_id: id });
    if (!r.ok) toast(r.error || 'That did not work.', 'err');
    else toast(r.finished ? `Deleting ${r.name} is finished.` : `Still not finished: ${(r.errors || []).join(' ')}`, r.finished ? undefined : 'err');
    await qc.invalidateQueries({ queryKey: ['admin-deletions'] });
    setBusy(null);
  }
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="unfinished-deletions">
      {q.data.map((d) => (
        <Alert key={d.id} kind="amber" icon="clock">
          <div className="row wrap" style={{ gap: 10, justifyContent: 'space-between' }}>
            <span>Deleting <b>{d.name}</b> {when(d.at)}{d.by ? ` by ${d.by}` : ''} did not finish{d.result?.errors?.length ? `: ${d.result.errors.join(' ')}` : '.'}</span>
            <button className="btn btn-secondary btn-sm" disabled={busy !== null} onClick={() => void again(d.id)}>{busy === d.id ? <Spinner small /> : <Icon name="refresh" size={14} />}Try again</button>
          </div>
        </Alert>
      ))}
    </div>
  );
}
