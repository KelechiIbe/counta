// Where a filing-only business's year starts. The year before it, done in Counta, hands over its closing figures; otherwise
// the business gives last year's figures (typed in, or read by AI from last year's accounts once a year is paid for), or says
// there was nothing but the bank balances, or that last year's figures do not exist. The statements then say so.
import { useMemo, useRef, useState } from 'react';
import { useSession, useToast } from '../../state/session';
import { cleanError } from '../../lib/supabase';
import { edge, money } from '../../lib/api';
import { uploadDocument } from '../../lib/documents';
import { N2, fmtDay, when } from '../../lib/format';
import { OPENING_LINES, openingLeftOver, saveOpening, type FilingState, type FilingYear, type OpeningAsset } from '../../lib/filing';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, Spinner } from '../../components/ui';

// The fixed asset classes a business is most likely to have, first; the rest after.
export const CLASSES: [string, string][] = [
  ['1511', 'Motor vehicles'], ['1512', 'Buses and trucks'], ['1514', 'Office equipment'], ['1517', 'Computer hardware'], ['1519', 'Furniture and fittings'],
  ['1518', 'Office fixtures'], ['1513', 'Tools and equipment'], ['1504', 'Plant'], ['1506', 'Heavy equipment'], ['1502', 'Non-industrial buildings'],
  ['1503', 'Industrial buildings'], ['1501', 'Freehold land'], ['1526', 'Leasehold improvements'], ['1515', 'Medical equipment'], ['1516', 'Household equipment'],
  ['1509', 'Towers and cables'], ['1525', 'Distribution network'], ['1505', 'Ships, boats and yachts'], ['1507', 'Aircraft engines and fuselage'],
  ['1508', 'Aircraft and vessel furnishing'], ['1510', 'Trains and tracks'], ['1520', 'Assets under construction'], ['1521', 'Capital work in progress'],
  ['1522', 'Bearer plants'], ['1523', 'Biological assets'], ['1524', 'Petroleum development costs'], ['1527', 'Other property, plant and equipment'],
];
const SAID: Record<string, string> = {
  bank_only: 'The business had nothing at the start of the year apart from its bank balances.',
  no_figures: 'There are no figures from last year. The year starts from the bank balances, and the statements say so.',
};

export function OpeningStep({ s, y, onChanged }: { s: FilingState; y: FilingYear; onChanged: () => Promise<unknown> }) {
  const { orgId } = useSession();
  const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null);
  const [figures, setFigures] = useState(false);
  const [changing, setChanging] = useState(false);
  const o = y.opening;
  if (!o || o.source === 'began' || o.source === 'moved') return null;
  const approved = y.return?.status === 'approved' || !!y.return?.filed_at;
  const start = fmtDay(y.from);
  async function declare(kind: 'bank_only' | 'no_figures') {
    setBusy(kind);
    try { await saveOpening(orgId!, y.year, { kind }); await onChanged(); setChanging(false); toast('Saved'); }
    catch (e) { toast(cleanError(e), 'err'); }
    setBusy(null);
  }
  if (o.source === 'previous_year') {
    return (
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.5 }} data-testid="opening-previous">
        {y.year} starts where {o.previous_year} ends: its closing figures carry over, losses and tax values included. Approve the {o.previous_year} return
        first{o.done ? ', as it is.' : '.'}
      </div>
    );
  }
  const choices = (
    <div className="stack" style={{ gap: 8 }}>
      <div className="row wrap" style={{ gap: 8 }}>
        <button className="btn btn-primary btn-sm" disabled={!s.can_upload || busy !== null} onClick={() => setFigures(true)} data-testid="opening-figures">
          <Icon name="file" size={14} color="#fff" />Enter last year's figures</button>
        <button className="btn btn-secondary btn-sm" disabled={!s.can_upload || busy !== null} onClick={() => declare('bank_only')} data-testid="opening-bank-only">
          {busy === 'bank_only' && <Spinner small />}Nothing but the bank balances</button>
        <button className="btn btn-ghost btn-sm" disabled={!s.can_upload || busy !== null} onClick={() => declare('no_figures')} data-testid="opening-no-figures">
          {busy === 'no_figures' && <Spinner small />}No figures from last year</button>
      </div>
      {changing && <button className="btn btn-ghost btn-xs" style={{ alignSelf: 'flex-start' }} onClick={() => setChanging(false)}>Keep it as it is</button>}
    </div>
  );
  return (
    <div className="stack" style={{ gap: 8 }} data-testid="opening-step">
      {!o.done || changing ? (
        <>
          <div className="muted" style={{ fontSize: 13, lineHeight: 1.55, maxWidth: 760 }}>
            Counta needs what the business owned and owed at {start}: last year's financial statements or tax return have it. Bank balances come from step 1.
            If the business had nothing else, or last year's figures do not exist, say so; the statements will state where the year started.
          </div>
          {choices}
        </>
      ) : (
        <div className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
          <div style={{ fontSize: 13, lineHeight: 1.5, minWidth: 0, flex: '1 1 320px' }}>
            {o.source === 'figures'
              ? <>Last year's figures entered{o.by_name ? ` by ${o.by_name}` : ''}{o.at ? ` ${when(o.at)}` : ''}: {o.lines?.length || 0} balance{o.lines?.length === 1 ? '' : 's'}
                  {o.assets ? ` and ${o.assets} asset${o.assets === 1 ? '' : 's'}` : ''}{o.journal_ref ? `, posted on ${fmtDay(o.as_of)} (${o.journal_ref})` : ''}.</>
              : <>{SAID[o.source || '']}{o.by_name ? ` (${o.by_name}${o.at ? `, ${when(o.at)}` : ''})` : ''}</>}
          </div>
          {s.can_upload && !approved && <button className="btn btn-ghost btn-sm" onClick={() => (o.source === 'figures' ? setFigures(true) : setChanging(true))}>Change</button>}
        </div>
      )}
      {o.source === 'figures' && o.done && !changing && (
        <div className="faint" style={{ fontSize: 12 }}>Losses brought forward and tax written-down values from last year's return go in the return itself, under Adjustments.</div>
      )}
      {figures && <OpeningFigures y={y} onClose={() => setFigures(false)} onSaved={async () => { setFigures(false); setChanging(false); await onChanged(); }} />}
    </div>
  );
}

type Read = { ok?: boolean; error?: string; reason?: string; as_of?: string | null; is_accounts?: boolean; lines?: { key: string; amount: number }[];
  assets?: { class_account: string; name: string; cost: number; accumulated: number; in_use_from: string | null }[]; cash?: number;
  other?: { caption: string; amount: number }[]; confidence?: number; warnings?: string[] };

const blankAsset = (): OpeningAsset => ({ class_account: '1511', name: '', cost: '', accumulated: '', in_use_from: '' });

export function OpeningFigures({ y, onClose, onSaved }: { y: FilingYear; onClose: () => void; onSaved: () => Promise<unknown> }) {
  const { orgId } = useSession();
  const toast = useToast();
  const prev = y.opening?.lines || [];
  const [lines, setLines] = useState<Record<string, string>>(() => Object.fromEntries(prev.map((l) => [l.key, String(l.amount)])));
  const [assets, setAssets] = useState<OpeningAsset[]>(() => (y.opening?.asset_rows || []).map((a) => ({ class_account: a.class_account, name: a.name,
    cost: String(a.cost), accumulated: Number(a.accumulated) ? String(a.accumulated) : '', in_use_from: a.in_use_from || '' })));
  const [reading, setReading] = useState(false);
  const [read, setRead] = useState<Read | null>(null);
  const [saving, setSaving] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const asOf = fmtDay(y.opening?.as_of || y.from);
  const left = useMemo(() => openingLeftOver(lines, assets, money), [lines, assets]);
  const set = (k: string, v: string) => setLines((x) => ({ ...x, [k]: v }));
  const setAsset = (i: number, k: keyof OpeningAsset, v: string) => setAssets((xs) => xs.map((a, j) => (j === i ? { ...a, [k]: v } : a)));

  async function readAccounts(f: File) {
    setReading(true); setRead(null);
    try {
      const saved = await uploadDocument(orgId!, f, { cat: 'tax', folder: 'Other', period: null, year: y.year - 1, notes: `Last year's accounts, for where ${y.year} starts` });
      const r = await edge<Read>('atlas', { action: 'read_opening', org_id: orgId, path: saved.path, mime: f.type || null, year: y.year });
      if (r.ok === false) { toast(r.error || 'The accounts could not be read.', 'err'); setReading(false); return; }
      setRead(r);
      setLines(Object.fromEntries((r.lines || []).map((l) => [l.key, String(l.amount)])));
      setAssets((r.assets || []).map((a) => ({ class_account: a.class_account, name: a.name, cost: String(a.cost), accumulated: String(a.accumulated || ''),
        in_use_from: a.in_use_from || '' })));
    } catch (e) { toast(cleanError(e), 'err'); }
    setReading(false);
  }
  async function save() {
    setSaving(true);
    try {
      await saveOpening(orgId!, y.year, {
        kind: 'figures',
        lines: OPENING_LINES.filter((l) => money(lines[l.key] || '')).map((l) => ({ key: l.key, amount: money(lines[l.key]) })),
        assets: assets.filter((a) => a.name.trim() || money(a.cost)).map((a) => ({ class_account: a.class_account, name: a.name.trim(), cost: money(a.cost),
          accumulated: money(a.accumulated) || 0, in_use_from: a.in_use_from || null })),
      });
      toast(`Where ${y.year} starts is saved`); await onSaved();
    } catch (e) { toast(cleanError(e), 'err'); }
    setSaving(false);
  }
  const group = (g: 'owned' | 'owed' | 'capital', title: string) => (
    <fieldset className="stack" style={{ gap: 6, border: 0, padding: 0, margin: 0 }}>
      <legend style={{ fontWeight: 600, fontSize: 14, marginBottom: 4 }}>{title}</legend>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(230px, 1fr))', gap: 8 }}>
        {OPENING_LINES.filter((l) => l.group === g).map((l) => (
          <Field key={l.key} label={l.label} hint={l.hint}>
            <input className="input" inputMode="decimal" value={lines[l.key] || ''} onChange={(e) => set(l.key, e.target.value)} placeholder="0.00"
              aria-label={l.label} data-testid={`opening-${l.key}`} />
          </Field>
        ))}
      </div>
    </fieldset>
  );
  const anything = OPENING_LINES.some((l) => money(lines[l.key] || '')) || assets.some((a) => money(a.cost));
  return (
    <Modal onClose={onClose} width={860}>
      <ModalHead title={`Where ${y.year} starts`} sub={`What the business owned and owed at ${asOf}, from last year's financial statements. Bank balances come from the bank accounts.`} onClose={onClose} />
      <div className="modal-body stack" style={{ gap: 14 }}>
        <div className="card card-pad row wrap" style={{ gap: 10, justifyContent: 'space-between', background: 'var(--canvas)' }}>
          <div style={{ minWidth: 0, flex: '1 1 300px', fontSize: 13, lineHeight: 1.5 }}>
            <b>Have last year's accounts as a PDF or photo?</b> Counta reads the balance sheet and fills this in for you to check. It is kept under Documents.
          </div>
          <input ref={file} type="file" accept="application/pdf,image/jpeg,image/png,image/webp" hidden
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void readAccounts(f); }} />
          <button className="btn btn-secondary btn-sm" disabled={reading} onClick={() => file.current?.click()} data-testid="opening-read">
            {reading ? <Spinner small /> : <Icon name="sparkles" size={14} />}{reading ? 'Reading…' : 'Read last year\'s accounts'}</button>
        </div>
        {read && read.is_accounts === false && <Alert kind="amber" icon="alert">That does not look like a set of accounts. Check the figures, or type them in.</Alert>}
        {read && read.is_accounts !== false && (
          <Alert kind={Number(read.confidence) >= 80 ? 'blue' : 'amber'} icon="info">
            Read from the accounts{read.as_of ? ` at ${fmtDay(read.as_of)}` : ''}. Check every figure before saving.
            {read.as_of && read.as_of !== y.opening?.as_of ? ` The accounts are for a date other than ${asOf}.` : ''}
            {read.cash ? ` Bank and cash came to ${N2(read.cash)}; Counta takes these from the bank accounts.` : ''}
            {(read.other || []).length ? ` Not placed: ${(read.other || []).map((x) => `${x.caption} ${N2(x.amount)}`).join(', ')}.` : ''}
            {(read.warnings || []).length ? ` ${(read.warnings || []).join(' ')}` : ''}
          </Alert>
        )}
        {group('owned', 'What the business owned')}
        <fieldset className="stack" style={{ gap: 6, border: 0, padding: 0, margin: 0 }}>
          <legend style={{ fontWeight: 600, fontSize: 14, marginBottom: 4 }}>Property, plant and equipment</legend>
          <div className="faint" style={{ fontSize: 12 }}>Each class from the note to the accounts, or each item: what it cost and the depreciation charged on it so far. These join the asset register.</div>
          {assets.map((a, i) => (
            <div key={i} className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(150px,1.1fr) minmax(150px,1.3fr) 130px 130px 140px 36px', gap: 8, alignItems: 'end' }}>
              <Field label="Class"><select className="input" value={a.class_account} onChange={(e) => setAsset(i, 'class_account', e.target.value)} aria-label="Class">
                {CLASSES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}</select></Field>
              <Field label="Description"><input className="input" value={a.name} onChange={(e) => setAsset(i, 'name', e.target.value)} placeholder="Delivery van" aria-label="Description" /></Field>
              <Field label="Cost"><input className="input" inputMode="decimal" value={a.cost} onChange={(e) => setAsset(i, 'cost', e.target.value)} aria-label="Cost" /></Field>
              <Field label="Depreciation so far"><input className="input" inputMode="decimal" value={a.accumulated} onChange={(e) => setAsset(i, 'accumulated', e.target.value)} placeholder="0.00" aria-label="Depreciation so far" /></Field>
              <Field label="In use from"><input className="input" type="date" value={a.in_use_from} max={y.opening?.as_of} onChange={(e) => setAsset(i, 'in_use_from', e.target.value)} aria-label="In use from" /></Field>
              <button className="btn btn-ghost btn-sm" aria-label={`Remove ${a.name || 'this asset'}`} onClick={() => setAssets((xs) => xs.filter((_, j) => j !== i))}><Icon name="x" size={14} /></button>
            </div>
          ))}
          <button className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setAssets((xs) => [...xs, blankAsset()])} data-testid="opening-add-asset">
            <Icon name="plus" size={14} />Add an asset or class</button>
        </fieldset>
        {group('owed', 'What the business owed')}
        {group('capital', 'Capital')}
        <div className="card card-pad stack" style={{ gap: 4, background: 'var(--canvas)' }} data-testid="opening-left">
          <div className="row" style={{ justifyContent: 'space-between' }}><span>Left over for the bank balances</span><b className="num">{N2(left)}</b></div>
          <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>When the figures are complete this matches the bank balances at {asOf}. Whatever does not
            match stays in equity as opening balances to be confirmed.</div>
        </div>
      </div>
      <div className="modal-ft">
        <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn btn-primary" disabled={saving || !anything} onClick={save} data-testid="opening-save">{saving && <Spinner small />}Save the figures</button>
      </div>
    </Modal>
  );
}
