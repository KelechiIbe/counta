// The intake's lookups (20261125000100_director_identity.sql, the mono function's intake_* actions): the business found on
// CAC fills the intake's fields (its registered name, kind, number, Tax ID, address, industry, directors and owners of a
// quarter or more) for the partner to check and save; and a person's NIN checked with NIMC, which keeps the name NIMC
// holds and the NIN's last four digits with the intake. Each lookup counts against the person's daily lookups.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../lib/supabase';
import { edge } from '../lib/api';
import { when } from '../lib/format';
import { Icon } from '../components/Icon';
import { Alert, Spinner } from '../components/ui';

export type CacPerson = { kind: 'director' | 'beneficial_owner'; name: string; role?: string | null; ownership_pct?: number | null; nationality?: string | null };
export type CacFields = {
  lookup_id: string; legal_name: string; entity_type: string | null; rc_number: string | null; tax_id: string | null; address: string | null;
  industry: string | null; people: CacPerson[]; active: boolean | null; registered_on: string | null;
};
type Candidate = { id: string | number; name?: string; rc_number?: string; classification?: string; active?: boolean | null; registered_on?: string; address?: string };
export type Lookups = { cac: { name: string; rc_number: string; classification: string; active: boolean | null; at: string; tax_id: string | null } | null;
  nin_checks: { name: string; last4: string; at: string; by: string | null }[] };

// A name as it reads in a sentence ("ZARIA MILLS LIMITED" -> "Zaria Mills Limited"), keeping words like "&" and "PLC".
export function titleName(s: string): string {
  return s.toLowerCase().replace(/\b([a-z])([a-z']*)/g, (_, a: string, b: string) => a.toUpperCase() + b).replace(/\bPlc\b/g, 'PLC').replace(/\bLlc\b/g, 'LLC');
}

export const useIntakeLookups = (iid: string | null) => useQuery({ queryKey: ['intake-lookups', iid], enabled: !!iid, staleTime: 30_000,
  queryFn: () => rpc<Lookups>('practice_intake_lookups', { p_intake: iid }) });

// Find the business on CAC and use its record. onFound gets the intake's fields and the lookup to attach once saved.
export function CacFinder({ pid, initial, onFound, attached }: { pid: string; initial: string; onFound: (f: CacFields, taxNote: string | null) => void; attached: Lookups['cac'] | null }) {
  const [query, setQuery] = useState(initial);
  const [found, setFound] = useState<{ lookup_id: string; candidates: Candidate[] } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function search() {
    setBusy('search'); setErr(null); setFound(null);
    const r = await edge<any>('mono', { action: 'intake_cac_search', practice_id: pid, query: query.trim() });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The CAC search did not go through just now.'); return; }
    setFound({ lookup_id: r.lookup_id, candidates: r.candidates || [] });
  }
  async function pick(c: Candidate) {
    if (!found) return;
    setBusy(String(c.id)); setErr(null);
    const r = await edge<any>('mono', { action: 'intake_cac_select', practice_id: pid, lookup_id: found.lookup_id, cac_id: String(c.id) });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The CAC record could not be read just now.'); return; }
    setFound(null);
    onFound(r.fields as CacFields, r.tax_note ?? null);
  }
  return (
    <div className="stack" style={{ gap: 10, padding: 14, background: 'var(--surface-2, #F8FAFC)', borderRadius: 10 }} data-testid="intake-cac">
      <div style={{ fontWeight: 600, fontSize: 14 }}>Find the business on CAC</div>
      {attached && (
        <div className="muted" style={{ fontSize: 13 }} data-testid="intake-cac-attached">
          From CAC: {attached.name}{attached.rc_number ? `, ${attached.rc_number}` : ''}{attached.active === false ? ' (inactive on CAC)' : ''}, found {when(attached.at)}.
        </div>
      )}
      <form className="row wrap" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); if (query.trim().length >= 2) void search(); }}>
        <input className="input" style={{ flex: '1 1 240px' }} value={query} maxLength={100} placeholder="Business name or RC number" aria-label="Business name or RC number"
          onChange={(e) => setQuery(e.target.value)} data-testid="intake-cac-query" />
        <button className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} disabled={busy === 'search' || query.trim().length < 2} data-testid="intake-cac-search">
          {busy === 'search' ? <Spinner small /> : <Icon name="search" size={14} />}Search CAC
        </button>
      </form>
      {found && (found.candidates.length ? (
        <ul className="stack" style={{ gap: 6, listStyle: 'none', margin: 0, padding: 0 }} data-testid="intake-cac-results">
          {found.candidates.map((c) => (
            <li key={String(c.id)}>
              <button type="button" className="btn btn-ghost" style={{ width: '100%', justifyContent: 'space-between', textAlign: 'left', minHeight: 44 }}
                disabled={!!busy} onClick={() => pick(c)} data-testid="intake-cac-pick">
                <span style={{ minWidth: 0 }}>
                  <span style={{ fontWeight: 600 }}>{c.name}</span>
                  <span className="muted" style={{ fontSize: 13 }}>{[c.rc_number, c.classification?.replace(/_/g, ' ').toLowerCase(), c.active === false ? 'inactive' : null].filter(Boolean).join(' · ')}</span>
                </span>
                {busy === String(c.id) ? <Spinner small /> : <span style={{ fontSize: 13 }}>Use this</span>}
              </button>
            </li>
          ))}
        </ul>
      ) : <div className="muted" style={{ fontSize: 13 }}>CAC has nothing by that name or number. Check the spelling, or fill the fields in yourself.</div>)}
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      <div className="faint" style={{ fontSize: 12 }}>The record fills the fields below and the directors and owners. Check them, then save.</div>
    </div>
  );
}

// A person's NIN checked with NIMC from the intake. onChecked gets the name NIMC holds and the last four digits.
export function NinCheck({ pid, iid, onChecked }: { pid: string; iid: string; onChecked: (name: string, last4: string) => void }) {
  const q = useIntakeLookups(iid);
  const qc = useQueryClient();
  const [nin, setNin] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function check() {
    setBusy(true); setErr(null);
    const r = await edge<any>('mono', { action: 'intake_nin', practice_id: pid, intake_id: iid, nin: nin.replace(/\D/g, '') });
    setBusy(false);
    if (r?.ok === false) { setErr(r.error || 'The NIN check did not go through just now.'); return; }
    setNin('');
    await qc.invalidateQueries({ queryKey: ['intake-lookups', iid] });
    onChecked(String(r.result?.name || ''), String(r.result?.last4 || ''));
  }
  const checks = q.data?.nin_checks || [];
  return (
    <div className="stack" style={{ gap: 10, padding: 14, background: 'var(--surface-2, #F8FAFC)', borderRadius: 10 }} data-testid="intake-nin">
      <div style={{ fontWeight: 600, fontSize: 14 }}>Check a person's NIN</div>
      <div className="muted" style={{ fontSize: 13 }}>NIMC's name for the NIN is kept with the intake, with its last four digits. The NIN itself is not kept.</div>
      <form className="row wrap" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); if (nin.replace(/\D/g, '').length === 11) void check(); }}>
        <input className="input" style={{ flex: '1 1 200px' }} value={nin} maxLength={13} inputMode="numeric" autoComplete="off" placeholder="11 digits" aria-label="NIN"
          onChange={(e) => setNin(e.target.value.replace(/[^\d ]/g, ''))} data-testid="intake-nin-input" />
        <button className="btn btn-secondary btn-sm" style={{ minHeight: 40 }} disabled={busy || nin.replace(/\D/g, '').length !== 11} data-testid="intake-nin-check">
          {busy ? <Spinner small /> : <Icon name="shield" size={14} />}Check with NIMC
        </button>
      </form>
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      {checks.length > 0 && (
        <ul className="stack" style={{ gap: 4, listStyle: 'none', margin: 0, padding: 0, fontSize: 13 }} data-testid="intake-nin-checks">
          {checks.map((c, i) => <li key={i}><Icon name="check" size={13} /> {c.name}, NIN ending {c.last4}, {when(c.at)}{c.by ? ` by ${c.by}` : ''}</li>)}
        </ul>
      )}
    </div>
  );
}
