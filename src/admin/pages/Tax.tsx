// The tax rule book every business's figures come from: VAT, companies income tax, capital allowances and withholding tax.
// Rules are dated, so a change applies from a day and earlier periods keep the rate they had.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, lagosToday, N, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, SkeletonRows, Spinner } from '../../components/ui';
import { pct, tidyError } from '../api';
import { Card, PageHead } from '../ui';

type Rule = {
  key: string; label: string; source: string | null; current: number | null;
  history: { from: string; value: number; source: string | null; set_at: string | null; set_by: string | null; removable: boolean }[];
};
type Wht = { code: string; name: string; company: number; individual: number; note: string | null; updated_at: string | null; updated_by: string | null };
type TaxData = { rules: Rule[]; wht: Wht[]; today: string };
type Template = { id: string; file: string; sha256: string; title: string; url: string };

const isRate = (k: string) => /rate/.test(k) || /cap$/.test(k) || k === 'ca_retention' || k === 'ca_restriction';
const show = (k: string, v: number | null) => (v == null ? '—' : isRate(k) ? pct(v) : N(v));
// "7.5" means 7.5% for a rate; thresholds are naira.
const parse = (k: string, s: string) => { const n = Number(s.replace(/[,%₦\s]/g, '')); return Number.isFinite(n) ? (isRate(k) ? Math.round(n * 1e6) / 1e8 : n) : NaN; };

function RuleRow({ r, today }: { r: Rule; today: string }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [open, setOpen] = useState(false);
  const [from, setFrom] = useState(today);
  const [value, setValue] = useState('');
  const [source, setSource] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-tax'] });
  async function save() {
    const v = parse(r.key, value);
    if (!value.trim() || Number.isNaN(v)) { setErr(isRate(r.key) ? 'Enter the rate as a percentage, like 7.5.' : 'Enter the amount in naira.'); return; }
    setBusy(true); setErr(null);
    try {
      await rpc('admin_set_tax_rule', { p_key: r.key, p_from: from, p_value: v, p_source: source.trim() || null });
      toast(`${r.label}: ${show(r.key, v)} from ${fmtDay(from)}`);
      setOpen(false); setValue(''); setSource(''); await refresh();
    } catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  async function remove(day: string) {
    if (confirm !== day) { setConfirm(day); return; }
    setBusy(true); setConfirm(null);
    try { await rpc('admin_remove_tax_rule', { p_key: r.key, p_from: day }); toast('Removed'); await refresh(); }
    catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  const upcoming = r.history.find((h) => h.from > today);
  return (
    <div style={{ borderTop: '1px solid var(--line)' }}>
      <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.8fr) minmax(0,1fr) auto', borderTop: 0 }}>
        <div style={{ minWidth: 0 }}>
          <b>{r.label}</b>
          <div className="faint mono" style={{ fontSize: 11 }}>{r.key}</div>
        </div>
        <div style={{ minWidth: 0 }}>
          <b className="num" style={{ fontSize: 16 }}>{show(r.key, r.current)}</b>
          {upcoming && <div className="faint" style={{ fontSize: 12 }}>{show(r.key, upcoming.value)} from {fmtDay(upcoming.from)}</div>}
        </div>
        <button className="btn btn-secondary btn-sm" onClick={() => setOpen(!open)} aria-expanded={open}>{open ? 'Close' : 'Change'}</button>
      </div>
      {open && (
        <div className="stack" style={{ gap: 12, padding: '12px 16px 16px', background: 'var(--canvas)', borderTop: '1px solid var(--line)' }}>
          <div className="stack" style={{ gap: 4, fontSize: 13 }}>
            <span className="mini-label">History</span>
            {r.history.map((h) => (
              <div key={h.from} className="row wrap" style={{ gap: 8, justifyContent: 'space-between' }}>
                <span style={{ minWidth: 0 }}>From {fmtDay(h.from)}: <b className="num">{show(r.key, h.value)}</b>{' '}
                  <span className="faint">{h.source || ''}{h.set_by ? ` · ${h.set_by}, ${when(h.set_at)}` : ''}</span></span>
                {h.removable && <button className={'btn btn-sm ' + (confirm === h.from ? 'btn-danger' : 'btn-ghost')} disabled={busy} onClick={() => remove(h.from)} onBlur={() => setConfirm(null)}>{confirm === h.from ? 'Remove it' : 'Remove'}</button>}
              </div>
            ))}
          </div>
          <div className="row wrap" style={{ gap: 10, alignItems: 'flex-end' }}>
            <Field label="From" style={{ flex: '0 1 170px' }}><input className="input" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
            <Field label={isRate(r.key) ? 'Rate (%)' : 'Amount (₦)'} style={{ flex: '0 1 170px' }}>
              <input className="input num" inputMode="decimal" placeholder={isRate(r.key) ? (r.current != null ? String(Math.round(r.current * 1e6) / 1e4) : '') : ''} value={value} onChange={(e) => setValue(e.target.value)} />
            </Field>
            <Field label="Law or circular" style={{ flex: '1 1 220px' }}><input className="input" placeholder="Finance Act 2026, section 4" value={source} onChange={(e) => setSource(e.target.value)} /></Field>
            <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save</button>
          </div>
          <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>Periods before the day keep the rate they had, so returns already prepared do not change. A new rule from a day that already has one replaces it.</div>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
        </div>
      )}
    </div>
  );
}

function WhtRow({ w }: { w: Wht }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [edit, setEdit] = useState(false);
  const [co, setCo] = useState('');
  const [ind, setInd] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const fix = (v: number) => String(Math.round(v * 1e6) / 1e4);
  async function save() {
    const c = parse('rate', co), i = parse('rate', ind);
    if (Number.isNaN(c) || Number.isNaN(i) || !co.trim() || !ind.trim()) { setErr('Enter both rates as percentages, like 5.'); return; }
    setBusy(true); setErr(null);
    try { await rpc('admin_set_wht_rate', { p_code: w.code, p_company: c, p_individual: i }); toast(`${w.name} saved`); setEdit(false); await qc.invalidateQueries({ queryKey: ['admin-tax'] }); }
    catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  return (
    <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.6fr) minmax(0,1.4fr) auto' }}>
      <div style={{ minWidth: 0 }}>
        <b>{w.name}</b>
        {w.note && <div className="faint" style={{ fontSize: 12, lineHeight: 1.45 }}>{w.note}</div>}
        {w.updated_at && <div className="faint" style={{ fontSize: 12 }}>Changed {when(w.updated_at)}{w.updated_by ? ` by ${w.updated_by}` : ''}</div>}
      </div>
      {edit ? (
        <div className="stack" style={{ gap: 8, minWidth: 0 }}>
          <div className="row" style={{ gap: 8 }}>
            <Field label="Company (%)" style={{ flex: 1 }}><input className="input num" inputMode="decimal" value={co} onChange={(e) => setCo(e.target.value)} /></Field>
            <Field label="Individual (%)" style={{ flex: 1 }}><input className="input num" inputMode="decimal" value={ind} onChange={(e) => setInd(e.target.value)} /></Field>
          </div>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
        </div>
      ) : (
        <div style={{ fontSize: 14 }}><span className="faint">Company</span> <b className="num">{pct(w.company)}</b> <span className="faint" style={{ marginLeft: 10 }}>Individual</span> <b className="num">{pct(w.individual)}</b></div>
      )}
      <div className="row" style={{ gap: 6, justifyContent: 'flex-end' }}>
        {w.code === 'none' ? null : edit ? (
          <>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { setEdit(false); setErr(null); }}>Cancel</button>
            <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save</button>
          </>
        ) : <button className="btn btn-secondary btn-sm" onClick={() => { setCo(fix(w.company)); setInd(fix(w.individual)); setEdit(true); }}>Change</button>}
      </div>
    </div>
  );
}

function Templates() {
  const q = useQuery({ queryKey: ['admin-templates'], queryFn: () => edge<{ templates: Template[] }>('tax-files', { action: 'templates' }) });
  const list = q.data?.ok === false ? [] : q.data?.templates || [];
  return (
    <Card title="Official templates" sub="The Rev360 and NRS spreadsheets Counta fills for filing. Each is pinned by its fingerprint, so a file changed on the server is refused. A new version comes with an update to Counta." pad={false}>
      {q.isLoading ? <div className="card-pad"><SkeletonRows n={3} /></div> : q.data?.ok === false ? <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{q.data.error || 'Could not list the templates.'}</Alert></div>
        : list.map((t) => (
          <div key={t.id} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1fr) auto' }}>
            <div style={{ minWidth: 0 }}><b>{t.title}</b><div className="faint mono ellipsis" style={{ fontSize: 11 }}>{t.file} · {t.sha256.slice(0, 16)}…</div></div>
            <a className="btn btn-secondary btn-sm" href={t.url} target="_blank" rel="noreferrer"><Icon name="download" size={14} />Download</a>
          </div>
        ))}
    </Card>
  );
}

export default function Tax() {
  const q = useQuery({ queryKey: ['admin-tax'], queryFn: () => rpc<TaxData>('admin_tax') });
  const today = q.data?.today || lagosToday();
  const vat = (q.data?.rules || []).filter((r) => r.key === 'vat_rate');
  const cit = (q.data?.rules || []).filter((r) => r.key !== 'vat_rate' && !r.key.startsWith('ca_rate:'));
  const ca = (q.data?.rules || []).filter((r) => r.key.startsWith('ca_rate:'));
  return (
    <>
      <PageHead title="Tax rules" sub="The rates and thresholds behind every business's VAT, withholding tax and companies income tax figures. Change one when the law changes, from the day it takes effect." />
      {q.isError && <Alert kind="red" icon="alert">{tidyError(q.error)}</Alert>}
      {q.isLoading ? <SkeletonRows n={8} /> : q.data && (
        <>
          <Card title="VAT" sub="Used on invoices, bills, receipts, credit notes, customs entries and the monthly return." pad={false}>{vat.map((r) => <RuleRow key={r.key} r={r} today={today} />)}</Card>
          <Card title="Withholding tax" sub="Rates by kind of payment. A change applies to bills recorded from then on; bills already recorded keep their deduction." pad={false}>
            {q.data.wht.map((w) => <WhtRow key={w.code} w={w} />)}
          </Card>
          <Card title="Companies income tax" sub="Rates, levies and the small company test, from the Nigeria Tax Act 2025." pad={false}>{cit.map((r) => <RuleRow key={r.key} r={r} today={today} />)}</Card>
          {ca.length > 0 && <Card title="Capital allowances" sub="Annual allowance by class of asset." pad={false}>{ca.map((r) => <RuleRow key={r.key} r={r} today={today} />)}</Card>}
          <Templates />
        </>
      )}
    </>
  );
}
