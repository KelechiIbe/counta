// Choosing an account without knowing the chart: up to five likely accounts in plain words (Atlas's best guess first),
// and a search over the whole chart by what the money was for.
import { useMemo, useState } from 'react';
import { Icon } from './Icon';
import { accountHint, searchAccounts, type ChartAccount } from '../lib/accountHints';

export type PickOption = { code: string; why?: string; guess?: boolean };

export function AccountPicker({ accounts, options, value, onChange, disabled, sure }: {
  accounts: ChartAccount[]; options: PickOption[]; value: string; onChange: (code: string) => void; disabled?: boolean; sure?: number | null;
}) {
  const [q, setQ] = useState('');
  const byCode = useMemo(() => new Map(accounts.map((a) => [a.code, a])), [accounts]);
  const shown = options.filter((o) => byCode.has(o.code)).slice(0, 5);
  const results = useMemo(() => searchAccounts(accounts, q, 8), [accounts, q]);
  // An account picked from the search stays on screen as the choice.
  const picked = value && !shown.some((o) => o.code === value) && byCode.has(value) ? value : null;
  const row = (code: string, opts: { why?: string; guess?: boolean; from?: string } = {}) => {
    const a = byCode.get(code)!;
    const on = value === code;
    const plain = accountHint(code);
    // A hint that only repeats the account's name says nothing.
    const bare = (t: string) => t.toLowerCase().replace(/&/g, 'and').replace(/[^a-z]/g, '');
    const hint = opts.why || (bare(plain) === bare(a.name) ? '' : plain);
    return (
      <button key={(opts.from || 'o') + code} type="button" className={'acct-opt' + (on ? ' on' : '')} aria-pressed={on} disabled={disabled}
        onClick={() => { onChange(code); if (opts.from === 'search') setQ(''); }} data-testid="acct-opt" data-code={code}>
        <span className="acct-dot" aria-hidden="true">{on && <Icon name="check" size={12} color="#fff" />}</span>
        <span style={{ minWidth: 0, flex: 1 }}>
          <span className="row wrap" style={{ gap: 6 }}>
            <b style={{ fontWeight: 600 }}>{a.name}</b>
            {opts.guess && <span className="chip t-blue">Atlas's best guess{sure != null ? ` · ${Math.round(sure * 100)}% sure` : ''}</span>}
            {opts.from === 'search' && <span className="chip t-grey">From your search</span>}
          </span>
          {hint && <span className="faint" style={{ display: 'block', fontSize: 12, marginTop: 1 }}>{hint}</span>}
        </span>
        <span className="faint num" style={{ fontSize: 11, flex: 'none' }}>{code}</span>
      </button>
    );
  };
  return (
    <div className="stack" style={{ gap: 6 }} role="group" aria-label="Where does it belong?">
      {shown.length > 0 && <div className="faint" style={{ fontSize: 12 }}>The likeliest accounts. Tap one, or search for another below.</div>}
      {picked && row(picked, { from: 'picked' })}
      {shown.map((o) => row(o.code, { why: o.why, guess: o.guess }))}
      <div className="acct-search">
        <Icon name="search" size={15} color="#9CA3AF" />
        <input className="input input-sm" value={q} onChange={(e) => setQ(e.target.value)} disabled={disabled}
          placeholder="Search all accounts: diesel, salary, rent, loan…" aria-label="Search all accounts" />
      </div>
      {q.trim() && (results.length ? <div className="stack" style={{ gap: 6 }} data-testid="acct-results">{results.map((a) => row(a.code, { from: 'search' }))}</div>
        : <div className="faint" style={{ fontSize: 12 }}>No account matches “{q.trim()}”. Try another word, such as what was bought or who was paid.</div>)}
    </div>
  );
}
