// Shown on a return or the statements while an accountant's changed version is the one in use: who changed it, that they
// take responsibility, and the changes. Counta's downloads and Flux use that version until it is withdrawn.
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { N2, when } from '../lib/format';
import { useSession } from '../state/session';
import { Icon } from '../components/Icon';
import type { FileBrief } from './api';
import { FileReview } from './FileReview';

type Current = FileBrief & { file_path: string; sha256: string; figures: unknown; changes: unknown };

export function useFilingCurrent(kind: FileBrief['kind'], period: string | null | undefined, authority?: string | null) {
  const { orgId } = useSession();
  return useQuery({ queryKey: ['filing-current', orgId, kind, period, authority || null], enabled: !!orgId && !!period, staleTime: 30_000, retry: false,
    queryFn: () => rpc<Current | null>('filing_version_current', { p_org: orgId, p_kind: kind, p_period: period, p_authority: authority || null }) });
}

export function VersionBanner({ kind, period, authority }: { kind: FileBrief['kind']; period: string | null | undefined; authority?: string | null }) {
  const q = useFilingCurrent(kind, period, authority);
  const [open, setOpen] = useState(false);
  const v = q.data;
  if (!v) return null;
  const n = Array.isArray(v.changes) ? v.changes.length : 0;
  return (
    <div className="card card-pad stack" style={{ gap: 6, borderColor: '#BFDBFE', background: '#EFF6FF' }} data-testid="version-banner">
      <div className="row wrap" style={{ gap: 8 }}>
        <Icon name="shield" size={16} color="#1D4ED8" />
        <b style={{ fontSize: 14 }}>Your accountant's version is in use</b>
      </div>
      <div style={{ fontSize: 13, lineHeight: 1.55 }}>
        {v.accepted_name}{v.accepted_licence ? ` (${v.accepted_licence})` : ''}{v.practice_name ? ` of ${v.practice_name}` : ''} changed {n} {n === 1 ? 'line' : 'lines'} of this {kind === 'fs' ? 'set of statements' : 'return'} {when(v.accepted_at)} and
        takes responsibility for the changes.{v.journal_ref ? ` The changes are booked in journal ${v.journal_ref}.` : ''}
        {v.payable_difference != null && Number(v.payable_difference) !== 0 ? ` Tax to pay ${Number(v.payable_difference) > 0 ? 'rises' : 'falls'} by ${N2(Math.abs(Number(v.payable_difference)))}.` : ''}
        {kind === 'fs' ? ' Download their file below; the statements on this page are still Counta\'s own.' : ' Counta\'s downloads and Flux use their file.'}
      </div>
      <div><button className="btn btn-secondary btn-sm" onClick={() => setOpen(true)}><Icon name="list" size={14} />See what changed</button></div>
      {open && <FileReview id={v.id} onClose={() => setOpen(false)} />}
    </div>
  );
}
