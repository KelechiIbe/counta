// How Counta reaches businesses about what needs doing (push, email, WhatsApp and Martina's calls), and the tax offices'
// accounts that tax wallets may pay into.
import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, SkeletonRows, Spinner } from '../../components/ui';
import { tidyError, useSettings } from '../api';
import { Card, grid, PageHead, Toggle } from '../ui';

type F = { group: string; key: string; label: string; what: string; kind: 'bool' | 'int' | 'list' };
const FIELDS: F[] = [
  { group: 'tax_deadline', key: 'push', label: 'Push before a tax deadline', what: 'Free. To whoever files tax.', kind: 'bool' },
  { group: 'tax_deadline', key: 'days_before', label: 'Push, days before', what: 'Also on the day, and every three days when late.', kind: 'list' },
  { group: 'tax_deadline', key: 'email', label: 'Email before a tax deadline', what: 'Cheap. To the owner.', kind: 'bool' },
  { group: 'tax_deadline', key: 'whatsapp', label: 'WhatsApp before a tax deadline', what: 'A paid utility message (template counta_tax_deadline).', kind: 'bool' },
  { group: 'tax_deadline', key: 'message_days_before', label: 'Email and WhatsApp, days before', what: 'Also on the day, and weekly when late.', kind: 'list' },
  { group: 'tax_deadline', key: 'call', label: 'Martina calls the owner', what: 'The dearest channel: once, before a return is due.', kind: 'bool' },
  { group: 'tax_deadline', key: 'call_days_before', label: 'Call, days before', what: '', kind: 'int' },
  { group: 'invoices', key: 'push', label: 'Push about invoices due and overdue', what: 'Every morning, to whoever records sales.', kind: 'bool' },
  { group: 'invoices', key: 'due_soon_days', label: 'Invoices due within (days)', what: 'Counted with the overdue ones.', kind: 'int' },
  { group: 'invoices', key: 'email', label: 'Email the weekly invoice digest', what: 'And the day an invoice first goes overdue.', kind: 'bool' },
  { group: 'invoices', key: 'whatsapp', label: 'WhatsApp the weekly invoice digest', what: 'Template counta_invoices_due.', kind: 'bool' },
  { group: 'invoices', key: 'digest_weekday', label: 'Digest day (1 Monday to 7 Sunday)', what: '', kind: 'int' },
  { group: 'confirm', key: 'push_from_day', label: 'Push transactions to confirm from day', what: 'Of the month, until the 20th: bank lines, receipts and schedules the returns need.', kind: 'int' },
  { group: 'confirm', key: 'email', label: 'Email transactions to confirm', what: '', kind: 'bool' },
  { group: 'confirm', key: 'whatsapp', label: 'WhatsApp transactions to confirm', what: 'Template counta_confirm_items.', kind: 'bool' },
  { group: 'confirm', key: 'message_days', label: 'Email and WhatsApp on days', what: 'Of the month.', kind: 'list' },
  { group: 'customer_calls', key: 'enabled', label: 'Martina follows up overdue invoices', what: 'Only for businesses that turn it on in their Settings.', kind: 'bool' },
  { group: 'customer_calls', key: 'min_days_overdue', label: 'At least this many days overdue', what: '', kind: 'int' },
  { group: 'customer_calls', key: 'min_amount', label: 'At least this much owed (naira)', what: 'Smaller invoices are not worth a call.', kind: 'int' },
  { group: 'customer_calls', key: 'per_org_per_day', label: 'Calls per business per day', what: '', kind: 'int' },
  { group: 'customer_calls', key: 'repeat_days', label: 'Days before calling about the same invoice again', what: '', kind: 'int' },
  { group: 'customer_calls', key: 'weekdays_only', label: 'Weekdays only', what: 'Customers are not called at weekends.', kind: 'bool' },
];
const GROUP_TITLE: Record<string, string> = { tax_deadline: 'Tax deadlines', invoices: 'Invoices due and overdue', confirm: 'Transactions to confirm before the returns', customer_calls: 'Martina and overdue customers' };

function AlertSettings() {
  const s = useSettings();
  const qc = useQueryClient();
  const toast = useToast();
  const d: any = s.data;
  const [form, setForm] = useState<Record<string, any>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const cur = (g: string, k: string) => d?.alerts?.[g]?.[k];
  const show = (v: any) => (Array.isArray(v) ? v.join(', ') : String(v ?? ''));
  function fill() {
    if (!d?.alerts) return;
    const f: Record<string, any> = {};
    for (const x of FIELDS) f[`${x.group}.${x.key}`] = x.kind === 'bool' ? Boolean(cur(x.group, x.key)) : show(cur(x.group, x.key));
    f['calls.from'] = String(d.alerts.calls?.hours?.[0] ?? 9); f['calls.to'] = String(d.alerts.calls?.hours?.[1] ?? 17);
    setForm(f);
  }
  useEffect(fill, [d]); // eslint-disable-line react-hooks/exhaustive-deps
  if (s.isLoading) return <SkeletonRows n={6} />;
  if (!d) return <Alert kind="red" icon="alert">{tidyError(s.error)}</Alert>;
  if (!d.alerts) return <Alert kind="amber" icon="info">The database update for alerts is not in yet.</Alert>;
  const changed = FIELDS.filter((x) => (x.kind === 'bool' ? form[`${x.group}.${x.key}`] !== Boolean(cur(x.group, x.key)) : form[`${x.group}.${x.key}`] !== show(cur(x.group, x.key))));
  const hoursChanged = form['calls.from'] !== String(d.alerts.calls?.hours?.[0] ?? 9) || form['calls.to'] !== String(d.alerts.calls?.hours?.[1] ?? 17);
  async function save() {
    const patch: Record<string, any> = {};
    for (const x of changed) {
      const v = form[`${x.group}.${x.key}`];
      let val: any = v;
      if (x.kind === 'int') { val = Number(String(v).replace(/,/g, '')); if (!Number.isInteger(val) || val < 0) { setErr(`${x.label}: a whole number from 0.`); return; } }
      if (x.kind === 'list') { val = String(v).split(/[,\s]+/).filter(Boolean).map(Number); if (val.some((n: number) => !Number.isInteger(n) || n < 0 || n > 60)) { setErr(`${x.label}: whole numbers from 0 to 60, separated by commas.`); return; } }
      (patch[x.group] ||= {})[x.key] = val;
    }
    if (hoursChanged) patch.calls = { hours: [Number(form['calls.from']), Number(form['calls.to'])] };
    setBusy(true); setErr(null);
    try { await rpc('admin_save_setting', { p_key: 'alerts', p_value: patch }); await qc.invalidateQueries({ queryKey: ['admin-settings'] }); toast('Alert settings saved'); }
    catch (e) { setErr(tidyError(e)); }
    setBusy(false);
  }
  const by = d.updated?.alerts;
  const n = changed.length + (hoursChanged ? 1 : 0);
  return (
    <Card title="Alerts" sub={`Everything that needs doing shows as a number in the menu and a push notification. Messages and calls cost money, so they are kept for what matters, cheapest first. A business can stop email, WhatsApp and calls to itself in its Settings. ${by ? `Last changed ${when(by.at)}${by.by ? ` by ${by.by}` : ''}.` : ''}`}
      right={n ? <div className="row" style={{ gap: 6 }}>
        <button className="btn btn-ghost btn-sm" disabled={busy} onClick={fill}>Undo</button>
        <button className="btn btn-primary btn-sm" disabled={busy} onClick={save}>{busy ? <Spinner small /> : null}Save {n} change{n === 1 ? '' : 's'}</button>
      </div> : undefined}>
      {err && <Alert kind="red" icon="alert">{err}</Alert>}
      {Object.keys(GROUP_TITLE).map((g) => (
        <div key={g} className="stack" style={{ gap: 8 }}>
          <div className="mini-label">{GROUP_TITLE[g]}</div>
          <div style={grid(240)}>
            {FIELDS.filter((x) => x.group === g).map((x) => {
              const k = `${x.group}.${x.key}`;
              return x.kind === 'bool' ? (
                <div key={k} className="row" style={{ justifyContent: 'space-between', gap: 10, alignItems: 'flex-start' }}>
                  <span style={{ minWidth: 0 }}><span style={{ fontSize: 13, fontWeight: 600 }}>{x.label}</span>{x.what && <span className="faint" style={{ display: 'block', fontSize: 12 }}>{x.what}</span>}</span>
                  <Toggle on={!!form[k]} label={x.label} disabled={busy} onChange={(v) => setForm({ ...form, [k]: v })} />
                </div>
              ) : (
                <label key={k} className="stack" style={{ gap: 4, minWidth: 0 }}>
                  <span style={{ fontSize: 13, fontWeight: 600 }}>{x.label}</span>
                  <input className="input num" value={form[k] ?? ''} onChange={(e) => setForm({ ...form, [k]: e.target.value })} aria-label={x.label} />
                  {x.what && <span className="faint" style={{ fontSize: 12 }}>{x.what}</span>}
                </label>
              );
            })}
          </div>
        </div>
      ))}
      <div className="mini-label">Calling hours (Lagos time)</div>
      <div className="row wrap" style={{ gap: 8 }}>
        <input className="input num" style={{ width: 90 }} value={form['calls.from'] ?? ''} onChange={(e) => setForm({ ...form, 'calls.from': e.target.value })} aria-label="Calls from" />
        <span className="muted">to</span>
        <input className="input num" style={{ width: 90 }} value={form['calls.to'] ?? ''} onChange={(e) => setForm({ ...form, 'calls.to': e.target.value })} aria-label="Calls until" />
        <span className="faint" style={{ fontSize: 12 }}>Hours from 7 to 22. A call queued outside them waits for the next opening.</span>
      </div>
    </Card>
  );
}

// The tax authorities Counta knows (tax_authorities), the federal one first.
const AUTHORITIES: [string, string][] = [["NRS", "Nigeria Revenue Service"], ["SIRS:AB", "Abia State Internal Revenue Service"], ["SIRS:AD", "Adamawa State Internal Revenue Service"], ["SIRS:AK", "Akwa Ibom State Internal Revenue Service"], ["SIRS:AN", "Anambra State Internal Revenue Service"], ["SIRS:BA", "Bauchi State Internal Revenue Service"], ["SIRS:BY", "Bayelsa State Board of Internal Revenue"], ["SIRS:BE", "Benue State Internal Revenue Service"], ["SIRS:BO", "Borno State Internal Revenue Service"], ["SIRS:CR", "Cross River State Internal Revenue Service"], ["SIRS:DE", "Delta State Internal Revenue Service"], ["SIRS:EB", "Ebonyi State Internal Revenue Service"], ["SIRS:ED", "Edo State Internal Revenue Service"], ["SIRS:EK", "Ekiti State Internal Revenue Service"], ["SIRS:EN", "Enugu State Internal Revenue Service"], ["SIRS:FC", "Federal Capital Territory Internal Revenue Service"], ["SIRS:GO", "Gombe State Internal Revenue Service"], ["SIRS:IM", "Imo State Internal Revenue Service"], ["SIRS:JI", "Jigawa State Internal Revenue Service"], ["SIRS:KD", "Kaduna State Internal Revenue Service"], ["SIRS:KN", "Kano State Internal Revenue Service"], ["SIRS:KT", "Katsina State Internal Revenue Service"], ["SIRS:KE", "Kebbi State Internal Revenue Service"], ["SIRS:KO", "Kogi State Internal Revenue Service"], ["SIRS:KW", "Kwara State Internal Revenue Service"], ["SIRS:LA", "Lagos State Internal Revenue Service"], ["SIRS:NA", "Nasarawa State Internal Revenue Service"], ["SIRS:NI", "Niger State Internal Revenue Service"], ["SIRS:OG", "Ogun State Internal Revenue Service"], ["SIRS:ON", "Ondo State Internal Revenue Service"], ["SIRS:OS", "Osun State Internal Revenue Service"], ["SIRS:OY", "Oyo State Internal Revenue Service"], ["SIRS:PL", "Plateau State Internal Revenue Service"], ["SIRS:RI", "Rivers State Internal Revenue Service"], ["SIRS:SO", "Sokoto State Internal Revenue Service"], ["SIRS:TA", "Taraba State Internal Revenue Service"], ["SIRS:YO", "Yobe State Internal Revenue Service"], ["SIRS:ZA", "Zamfara State Internal Revenue Service"]];

type Payee = { id?: string; name: string; kinds: string[]; authority: string | null; bank_code: string; bank_name: string | null; account_number: string; account_name: string; note: string | null; active: boolean };
const EMPTY: Payee = { name: '', kinds: ['vat'], authority: 'NRS', bank_code: '', bank_name: '', account_number: '', account_name: '', note: '', active: true };

function TaxPayees() {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-tax-payees'], queryFn: () => rpc<Payee[]>('admin_tax_payees') });
  const banks = useQuery({ queryKey: ['flw-banks'], staleTime: 3600_000, queryFn: () => edge<{ banks: { code: string; name: string }[] }>('payments', { action: 'banks' }) });
  const [edit, setEdit] = useState<Payee | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function resolve() {
    if (!edit || !/^\d{10}$/.test(edit.account_number) || !edit.bank_code) return;
    setBusy('resolve'); setErr(null);
    const r = await edge<{ account_name: string }>('payments', { action: 'resolve_account', account_number: edit.account_number, bank_code: edit.bank_code });
    if (r.ok === false) setErr(r.error || 'The bank did not confirm the account.'); else setEdit({ ...edit, account_name: r.account_name });
    setBusy(null);
  }
  async function save() {
    if (!edit) return;
    setBusy('save'); setErr(null);
    try { await rpc('admin_save_tax_payee', { p: edit }); await qc.invalidateQueries({ queryKey: ['admin-tax-payees'] }); toast('Saved'); setEdit(null); }
    catch (e) { setErr(tidyError(e)); }
    setBusy(null);
  }
  const list = q.data || [];
  return (
    <Card title="Tax accounts for tax wallets" sub="A business's tax wallet pays only into these accounts, for the taxes each one takes, with the payment reference the tax office gave. Check each account number with the tax office before adding it."
      right={!edit ? <button className="btn btn-primary btn-sm" onClick={() => { setEdit({ ...EMPTY }); setErr(null); }}>Add an account</button> : undefined} pad={false}>
      {q.isLoading ? <div className="card-pad"><SkeletonRows n={3} /></div> : q.error ? <div className="card-pad"><Alert kind="red" icon="alert">{tidyError(q.error)}</Alert></div>
        : !list.length && !edit ? <div className="card-pad muted" style={{ fontSize: 14 }}>None yet. Until one is added, businesses pay tax from their bank and the tax wallet shows the money waiting.</div>
        : list.map((p) => (
          <div key={p.id} className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1.4fr) minmax(0,1fr) auto' }}>
            <div style={{ minWidth: 0 }}><b>{p.name}</b> {!p.active && <span className="chip t-grey">Off</span>}
              <div className="faint" style={{ fontSize: 12 }}>{p.kinds.map((k) => ({ vat: 'VAT', wht: 'WHT', wvat: 'Withholding VAT' } as Record<string, string>)[k]).join(', ')}{p.authority ? ` · ${p.authority}` : ''}{p.note ? ` · ${p.note}` : ''}</div></div>
            <div style={{ minWidth: 0 }}>{p.account_name}<div className="faint" style={{ fontSize: 12 }}>{p.bank_name || p.bank_code} · {p.account_number}</div></div>
            <button className="btn btn-ghost btn-sm" onClick={() => { setEdit({ ...p }); setErr(null); }}>Change</button>
          </div>
        ))}
      {edit && (
        <div className="card-pad stack" style={{ gap: 10, borderTop: '1px solid var(--line)' }}>
          {err && <Alert kind="red" icon="alert">{err}</Alert>}
          <div style={grid(220)}>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Name</span><input className="input" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} placeholder="NRS VAT collection account" /></label>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Tax authority</span>
              <select className="input" value={edit.authority || ''} onChange={(e) => setEdit({ ...edit, authority: e.target.value || null })}>
                {AUTHORITIES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}<option value="">Not one authority</option>
              </select></label>
            <div className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Takes</span>
              <div className="row wrap" style={{ gap: 10 }}>{[['vat', 'VAT'], ['wht', 'WHT'], ['wvat', 'Withholding VAT']].map(([k, l]) => (
                <label key={k} className="check"><input type="checkbox" checked={edit.kinds.includes(k)} onChange={(e) => setEdit({ ...edit, kinds: e.target.checked ? [...edit.kinds, k] : edit.kinds.filter((x) => x !== k) })} />{l}</label>
              ))}</div></div>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Bank</span>
              <select className="input" value={edit.bank_code} onChange={(e) => setEdit({ ...edit, bank_code: e.target.value, bank_name: (banks.data?.banks || []).find((b) => b.code === e.target.value)?.name || null, account_name: '' })}>
                <option value="">Choose</option>{(banks.data?.banks || []).map((b) => <option key={b.code} value={b.code}>{b.name}</option>)}
              </select></label>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Account number</span>
              <input className="input num" inputMode="numeric" maxLength={10} value={edit.account_number} onChange={(e) => setEdit({ ...edit, account_number: e.target.value.replace(/\D/g, ''), account_name: '' })} onBlur={resolve} /></label>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Account name (from the bank)</span>
              <div className="row" style={{ gap: 6 }}><input className="input" value={edit.account_name} readOnly placeholder="Checked with the bank" />
                <button className="btn btn-secondary btn-sm" disabled={busy !== null || !/^\d{10}$/.test(edit.account_number) || !edit.bank_code} onClick={resolve}>{busy === 'resolve' ? <Spinner small /> : 'Check'}</button></div></label>
            <label className="stack" style={{ gap: 4 }}><span style={{ fontSize: 13, fontWeight: 600 }}>Note (optional)</span><input className="input" value={edit.note || ''} onChange={(e) => setEdit({ ...edit, note: e.target.value })} /></label>
            {edit.id && <div className="row" style={{ gap: 10 }}><span style={{ fontSize: 13, fontWeight: 600 }}>In use</span><Toggle on={edit.active} label="In use" onChange={(v) => setEdit({ ...edit, active: v })} /></div>}
          </div>
          <div className="row" style={{ gap: 6, justifyContent: 'flex-end' }}>
            <button className="btn btn-ghost btn-sm" onClick={() => setEdit(null)}>Cancel</button>
            <button className="btn btn-primary btn-sm" disabled={busy !== null || !edit.name.trim() || !edit.account_name || !edit.kinds.length} onClick={save}>{busy === 'save' ? <Spinner small /> : null}Save</button>
          </div>
        </div>
      )}
    </Card>
  );
}

export default function AlertsPage() {
  return (
    <>
      <PageHead title="Alerts and tax wallets" sub="What reaches each business, by which channel, and where tax wallets may pay tax." />
      <AlertSettings />
      <TaxPayees />
    </>
  );
}
