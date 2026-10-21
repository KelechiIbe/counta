// One changed return or set of statements: what the accountant changed, line by line against Counta's figures, the journal
// that books the changes, and the words they accept in their own name before Counta uses their version. The business sees
// the same page, read-only, and its owner can withdraw a version.
import { useEffect, useMemo, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc } from '../lib/supabase';
import { N2, when } from '../lib/format';
import { useToast } from '../state/session';
import { Icon } from '../components/Icon';
import { Alert, Modal, ModalHead, SkeletonRows, Spinner } from '../components/ui';
import { type ChangeRow, type JournalLine, type LinesCheck, openDoc, STATUS_CHIP, useFileVersion } from './api';

const amt = (v: unknown) => { const n = Number(String(v ?? '').replace(/,/g, '')); return Number.isFinite(n) ? Math.round(n * 100) / 100 : 0; };

export function FileReview({ id, onClose }: { id: string; onClose: () => void }) {
  const q = useFileVersion(id);
  const v = q.data;
  const qc = useQueryClient();
  const toast = useToast();
  const [lines, setLines] = useState<JournalLine[]>([]);
  const [noEntry, setNoEntry] = useState(false);
  const [reason, setReason] = useState('');
  const [accept, setAccept] = useState(false);
  const [check, setCheck] = useState<LinesCheck | null>(null);
  const [busy, setBusy] = useState<'check' | 'apply' | 'withdraw' | 'open' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [why, setWhy] = useState('');
  const [withdrawing, setWithdrawing] = useState(false);
  // Nothing to book (the figures did not change, or the change is not one Counta books): the reason box comes first.
  useEffect(() => {
    if (!v) return;
    setLines(v.proposal?.length ? v.proposal.map((l) => ({ ...l })) : [{ code: null }, { code: null }]);
    setCheck(v.proposal_check);
    setNoEntry(!v.proposal?.length && !(Array.isArray(v.changes) && v.changes.length));
  }, [v?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const changes: ChangeRow[] = Array.isArray(v?.changes) ? v!.changes : [];
  const totals = useMemo(() => lines.reduce((a, l) => ({ dr: a.dr + amt(l.debit), cr: a.cr + amt(l.credit) }), { dr: 0, cr: 0 }), [lines]);
  const used = noEntry ? [] : lines.filter((l) => amt(l.debit) || amt(l.credit));
  const set = (i: number, patch: Partial<JournalLine>) => { setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l))); setCheck(null); };

  async function runCheck() {
    setBusy('check'); setErr(null);
    try { setCheck(await rpc<LinesCheck>('filing_version_check', { p_version: id, p_lines: used })); } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function apply() {
    setBusy('apply'); setErr(null);
    try {
      await rpc('filing_version_apply', { p_version: id, p: { lines: used, reason: noEntry ? reason.trim() : null, accept } });
      await Promise.all(['filing-version', 'practice-client', 'practice-home', 'org-accountants', 'filing-current', 'filing-list'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      toast('Booked. Counta now uses your version.');
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function withdraw() {
    setBusy('withdraw'); setErr(null);
    try {
      await rpc('filing_version_withdraw', { p_version: id, p_reason: why.trim() });
      await Promise.all(['filing-version', 'practice-client', 'practice-home', 'org-accountants', 'filing-current', 'filing-list'].map((k) => qc.invalidateQueries({ queryKey: [k] })));
      toast('Withdrawn. Counta uses its own version again.');
      setWithdrawing(false);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }
  async function open() {
    if (!v) return;
    setBusy('open');
    try { await openDoc(v.file_path, v.file_name); } catch (e) { toast((e as Error).message, 'err'); }
    setBusy(null);
  }

  const [label, tone] = v ? STATUS_CHIP[v.status] : ['', ''];
  return (
    <Modal onClose={onClose} width={880}>
      <ModalHead title={v ? `${v.label.charAt(0).toUpperCase()}${v.label.slice(1)}` : 'Changed file'} onClose={onClose}
        sub={v ? `Version ${v.version}, uploaded by ${v.uploader_name || 'an accountant'}${v.practice_name ? ` of ${v.practice_name}` : ''} ${when(v.created_at)}` : undefined}
        extra={v && <span className={'chip ' + tone}>{label}</span>} />
      <div className="modal-body stack" style={{ gap: 14 }} data-testid="file-review">
        {q.isLoading ? <SkeletonRows n={6} /> : q.isError ? <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert> : v && (
          <>
            <div className="row wrap" style={{ gap: 8 }}>
              <button className="btn btn-secondary btn-sm" onClick={open} disabled={busy !== null}>{busy === 'open' ? <Spinner small /> : <Icon name="download" size={14} />}{v.file_name}</button>
              {v.base && <span className="faint" style={{ fontSize: 13 }}>Compared with version {v.base.version}, the one in use{v.base.accepted_name ? ` (${v.base.accepted_name})` : ''}.</span>}
              {!v.base && <span className="faint" style={{ fontSize: 13 }}>Compared with the file Counta makes from the books.</span>}
            </div>
            {v.note && <div className="card card-pad" style={{ fontSize: 14, background: 'var(--canvas)' }}><span className="mini-label">The accountant's note</span><div style={{ marginTop: 4 }}>{v.note}</div></div>}
            {(v.checks || []).map((c, i) => <Alert key={i} kind="amber" icon="alert">{c}</Alert>)}

            <div className="card" style={{ overflow: 'hidden' }}>
              <div className="card-hd"><b>What changed</b><span className="faint" style={{ fontSize: 12 }}>{changes.length ? `${changes.length} ${changes.length === 1 ? 'line' : 'lines'}` : 'nothing'}</span></div>
              {!changes.length ? <div className="card-pad faint" style={{ fontSize: 14 }}>The file has the same figures as Counta's. Nothing to book.</div> : (
                <div className="tbl">
                  <div className="tr head shade th" style={{ gridTemplateColumns: 'minmax(180px,1fr) 130px 130px 130px', minWidth: 600 }}>
                    <span>Line</span><span className="right">Counta</span><span className="right">The file</span><span className="right">Change</span>
                  </div>
                  {changes.map((c) => (
                    <div key={c.key} className="tr" style={{ gridTemplateColumns: 'minmax(180px,1fr) 130px 130px 130px', minWidth: 600 }}>
                      <span>{c.label}{v.kind === 'fs' && c.bookable === false && <span className="faint" style={{ fontSize: 11, display: 'block' }}>a total; follows the lines above it</span>}</span>
                      <span className="right num">{c.key === 'rows' ? Number(c.counta ?? 0) : N2(Number(c.counta ?? 0))}</span>
                      <span className="right num">{c.key === 'rows' ? Number(c.uploaded ?? 0) : N2(Number(c.uploaded ?? 0))}</span>
                      <span className="right num" style={{ fontWeight: 600, color: Number(c.difference) > 0 ? '#15803D' : '#B91C1C' }}>
                        {c.key === 'rows' ? `${Number(c.difference) > 0 ? '+' : ''}${Number(c.difference)}` : `${Number(c.difference) > 0 ? '+' : ''}${N2(Number(c.difference))}`}</span>
                    </div>
                  ))}
                </div>
              )}
              {v.payable_difference != null && Number(v.payable_difference) !== 0 && (
                <div className="card-pad" style={{ fontSize: 13, borderTop: '1px solid var(--row)' }}>
                  Tax to pay {Number(v.payable_difference) > 0 ? 'goes up' : 'goes down'} by <b>{N2(Math.abs(Number(v.payable_difference)))}</b>. Once this version is in use, Counta expects that amount when Flux asks for payment.
                </div>
              )}
            </div>

            {v.status === 'in_use' && (
              <div className="card card-pad stack" style={{ gap: 8, borderColor: '#BBF7D0', background: '#F0FDF4' }} data-testid="statement">
                <div className="row" style={{ gap: 8 }}><Icon name="shield" size={16} color="#15803D" /><b>The accountant's statement</b></div>
                <div style={{ fontSize: 14, lineHeight: 1.6 }}>{v.statement}</div>
                <div className="faint" style={{ fontSize: 12 }}>{v.accepted_name}{v.accepted_licence ? `, ${v.accepted_licence}` : ''} · accepted {when(v.accepted_at)}{v.journal_ref ? ` · journal ${v.journal_ref}` : ''}</div>
              </div>
            )}
            {v.status === 'withdrawn' && <Alert kind="grey" icon="undo">Withdrawn {when(v.withdrawn_at)}: {v.withdrawn_reason}. Counta uses its own version.</Alert>}
            {v.locked && v.status === 'review' && <Alert kind="amber" icon="lock">The return is already {v.locked}. This version can no longer replace it.</Alert>}

            {v.can_apply && !v.locked && (
              <div className="card card-pad stack" style={{ gap: 12 }} data-testid="book-changes">
                <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
                  <div><b>Book the changes</b><div className="faint" style={{ fontSize: 13, marginTop: 2 }}>Counta suggests this journal. Change the accounts or amounts as you need; it is dated the last day the {v.kind === 'fs' ? 'statements cover' : 'return covers'}.</div></div>
                  <label className="row" style={{ gap: 6, fontSize: 13 }}><input type="checkbox" checked={noEntry} onChange={(e) => { setNoEntry(e.target.checked); setCheck(null); }} />No entry needed</label>
                </div>
                {noEntry ? (
                  <label className="stack" style={{ gap: 4 }}>
                    <span className="mini-label">Why the books need no entry</span>
                    <textarea className="input" rows={2} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)}
                      placeholder="For example: the changes only move figures between lines of the return" />
                  </label>
                ) : (
                  <div className="stack" style={{ gap: 6 }}>
                    {lines.map((l, i) => (
                      <div key={i} className="row wrap" style={{ gap: 6 }} data-testid="journal-line">
                        <select className="input input-sm" style={{ flex: '2 1 240px', minWidth: 0 }} value={l.code || ''} aria-label={`Account, line ${i + 1}`}
                          onChange={(e) => set(i, { code: e.target.value || null })}>
                          <option value="">Choose the account</option>
                          {(v.accounts || []).map((a) => <option key={a.code} value={a.code}>{a.code} · {a.name}</option>)}
                        </select>
                        <input className="input input-sm num" style={{ width: 120 }} inputMode="decimal" placeholder="Debit" aria-label={`Debit, line ${i + 1}`}
                          value={l.debit ?? ''} onChange={(e) => set(i, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} />
                        <input className="input input-sm num" style={{ width: 120 }} inputMode="decimal" placeholder="Credit" aria-label={`Credit, line ${i + 1}`}
                          value={l.credit ?? ''} onChange={(e) => set(i, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} />
                        <input className="input input-sm" style={{ flex: '1 1 160px', minWidth: 0 }} placeholder="Note on the line" maxLength={200} value={l.memo || ''}
                          onChange={(e) => set(i, { memo: e.target.value })} aria-label={`Note, line ${i + 1}`} />
                        <button className="btn btn-ghost btn-sm" onClick={() => { setLines((ls) => ls.filter((_, j) => j !== i)); setCheck(null); }} aria-label={`Remove line ${i + 1}`}><Icon name="trash" size={14} /></button>
                      </div>
                    ))}
                    <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
                      <button className="btn btn-secondary btn-sm" onClick={() => setLines((ls) => [...ls, { code: null }])} disabled={lines.length >= 60}><Icon name="plus" size={14} />Add a line</button>
                      <span className="num" style={{ fontSize: 13, color: Math.abs(totals.dr - totals.cr) < 0.005 ? '#15803D' : '#B91C1C' }}>Debits {N2(totals.dr)} · Credits {N2(totals.cr)}</span>
                    </div>
                  </div>
                )}
                <div className="row wrap" style={{ gap: 8 }}>
                  <button className="btn btn-secondary btn-sm" onClick={runCheck} disabled={busy !== null}>{busy === 'check' ? <Spinner small /> : <Icon name="check" size={14} />}Check the journal</button>
                </div>
                {check && (
                  <div className="stack" style={{ gap: 6 }} data-testid="journal-check">
                    {check.problems.map((p, i) => <Alert key={i} kind="red" icon="alert">{p}</Alert>)}
                    {!check.problems.length && !check.remaining.length && <Alert kind="green" icon="check">It balances and books every change in the file.</Alert>}
                    {!check.problems.length && check.remaining.length > 0 && (
                      <Alert kind="amber" icon="alert">
                        After this journal the books still differ from the file on {check.remaining.map((r) => `${r.label} (${N2(r.left)})`).join(', ')}.
                        You can still book it; the difference stays your responsibility.
                      </Alert>
                    )}
                  </div>
                )}
                <div className="card card-pad stack" style={{ gap: 8, background: 'var(--canvas)' }}>
                  <span className="mini-label">What you accept</span>
                  <div style={{ fontSize: 14, lineHeight: 1.6 }} data-testid="statement-preview">
                    {(v.statement_preview || '').replace(/I booked them in the books with journal JE-…\. /, noEntry ? `They need no entry in the books, because ${reason.trim().replace(/\.$/, '') || '…'}. ` : 'I booked them in the books with journal JE-… (numbered when it posts). ')}
                  </div>
                  <label className="row" style={{ gap: 8, fontSize: 14, alignItems: 'flex-start' }}>
                    <input type="checkbox" checked={accept} onChange={(e) => setAccept(e.target.checked)} style={{ marginTop: 3 }} data-testid="accept" />
                    <span>I take professional responsibility for these changes, and Counta uses my version from now on.</span>
                  </label>
                </div>
              </div>
            )}
            {err && <Alert kind="red" icon="alert">{err}</Alert>}
            {withdrawing && (
              <div className="stack" style={{ gap: 6 }}>
                <input className="input" placeholder="Why it is withdrawn (the other side sees this)" value={why} onChange={(e) => setWhy(e.target.value)} maxLength={300} autoFocus />
              </div>
            )}
          </>
        )}
      </div>
      <div className="modal-ft">
        {v?.can_withdraw && !withdrawing && <button className="btn btn-ghost" onClick={() => setWithdrawing(true)} style={{ marginRight: 'auto' }}>Withdraw this version</button>}
        {withdrawing && <button className="btn btn-danger" style={{ marginRight: 'auto' }} disabled={busy !== null || why.trim().length < 5} onClick={withdraw}>{busy === 'withdraw' ? <Spinner small /> : null}Withdraw it</button>}
        <button className="btn btn-secondary" onClick={onClose}>Close</button>
        {v?.can_apply && !v.locked && (
          <button className="btn btn-primary" disabled={!accept || busy !== null || (noEntry ? reason.trim().length < 10 : !used.length)} onClick={apply} data-testid="apply">
            {busy === 'apply' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}{noEntry ? 'Use my version' : 'Book it and use my version'}
          </button>
        )}
      </div>
    </Modal>
  );
}
