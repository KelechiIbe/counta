// A client's returns and statements, for its accountant: download Counta's version, change it in Excel, upload it again,
// then book the differences and accept responsibility (FileReview). Earlier versions stay listed with who did what.
import { useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../lib/supabase';
import { edge } from '../lib/api';
import { downloadBlob, safeName } from '../lib/exporters';
import { uuid, when } from '../lib/format';
import { useToast } from '../state/session';
import { Icon } from '../components/Icon';
import { Alert, Spinner } from '../components/ui';
import { FileReview } from './FileReview';
import { type ClientDetail, type FileBrief, KIND_LABEL, STATUS_CHIP } from './api';

type Kind = FileBrief['kind'];
const pad = (n: number) => String(n).padStart(2, '0');
const lastMonth = () => { const d = new Date(); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() - 1); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}`; };
const STATES = ['LA', 'FC', 'OG', 'RI', 'KN', 'OY', 'AN', 'DE', 'ED', 'EN', 'KD', 'AB', 'AK', 'IM', 'ON', 'OS', 'KW', 'BA', 'BO', 'PL', 'NI', 'KO', 'BE', 'CR', 'EB', 'EK',
  'GO', 'JI', 'KE', 'KT', 'NA', 'SO', 'TA', 'YO', 'ZA', 'AD'];

// The year the business's financial year that ended most recently began, as from and to dates.
function lastYear(fyStart: number) {
  const now = new Date();
  const y = now.getUTCMonth() + 1 >= fyStart ? now.getUTCFullYear() - 1 : now.getUTCFullYear() - 2;
  const from = `${y}-${pad(fyStart)}-01`;
  const end = new Date(Date.UTC(y + 1, fyStart - 1, 0));
  return { from, to: `${end.getUTCFullYear()}-${pad(end.getUTCMonth() + 1)}-${pad(end.getUTCDate())}` };
}

export function FilesPanel({ d }: { d: ClientDetail }) {
  const orgId = d.client.org_id!;
  const fy = lastYear(d.business?.fiscal_year_start || 1);
  const [kind, setKind] = useState<Kind>('vat');
  const [month, setMonth] = useState(lastMonth());
  const [authority, setAuthority] = useState('NRS');
  const [year, setYear] = useState(String(Number(fy.from.slice(0, 4))));
  const [from, setFrom] = useState(fy.from);
  const [to, setTo] = useState(fy.to);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<'down' | 'up' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const file = useRef<HTMLInputElement>(null);
  const qc = useQueryClient();
  const toast = useToast();
  const seat = d.my_seat?.status === 'active';
  const period = kind === 'vat' || kind === 'wht' ? month : kind === 'cit' ? year : `${from}:${to}`;

  async function download() {
    setBusy('down'); setErr(null);
    try {
      if (kind === 'fs') {
        // The statements are laid out in the browser, the same as the business's own Excel download.
        const pack = await rpc<any>('financial_statements_pack', { p_org: orgId, p_from: from, p_to: to });
        const [{ buildPack }, mod] = await Promise.all([import('../lib/fsPack'), import('../lib/fsExport')]);
        downloadBlob(await mod.packXlsx(buildPack(pack)), `${safeName(`${d.business?.name || 'Business'} financial statements ${pack?.periods?.to || to}`)}.xlsx`);
      } else {
        const body = kind === 'vat' ? { action: 'vat_file', period: month } : kind === 'wht' ? { action: 'wht_files', period: month, authority } : { action: 'cit_file', year: Number(year) };
        const r = await edge<any>('tax-files', { ...body, org_id: orgId, original: true });
        if (r.ok === false) throw new Error(r.error || 'Counta could not make the file.');
        const urls: string[] = kind === 'wht' ? (r.files || []).map((f: any) => f.url) : [r.url];
        for (const u of urls) { const a = document.createElement('a'); a.href = u; a.rel = 'noopener'; document.body.appendChild(a); a.click(); a.remove(); }
      }
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
  }

  async function upload(f: File) {
    setErr(null);
    if (!/\.xlsx$/i.test(f.name)) { setErr('Upload the Excel workbook (.xlsx) you changed.'); return; }
    if (f.size > 15_000_000) { setErr('The file is larger than 15 MB.'); return; }
    setBusy('up');
    try {
      // The statements' period is the one Counta reports on (a financial year can be cut to the books' start).
      let p = period;
      if (kind === 'fs') {
        const pack = await rpc<any>('financial_statements_pack', { p_org: orgId, p_from: from, p_to: to });
        p = `${pack?.periods?.from || from}:${pack?.periods?.to || to}`;
      }
      const path = `${orgId}/tax/accountant/${kind}/${p.replace(':', '_')}${kind === 'wht' ? `_${authority.replace(':', '_')}` : ''}/${uuid()}.xlsx`;
      const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', upsert: false });
      if (error) throw new Error(cleanError(error));
      const r = await edge<any>('tax-files', { action: 'accountant_upload', org_id: orgId, kind, period: p, authority: kind === 'wht' ? authority : null, path,
        file_name: f.name.slice(0, 160), note: note.trim() || null });
      if (r.ok === false) throw new Error(r.error || 'Counta could not read the file.');
      setNote('');
      await qc.invalidateQueries({ queryKey: ['practice-client'] });
      toast(r.version?.changes ? 'Uploaded. Review the changes and book them.' : 'Uploaded. The figures are the same as Counta\'s.');
      setOpen(r.version?.id || null);
    } catch (e) { setErr(cleanError(e)); }
    setBusy(null);
    if (file.current) file.current.value = '';
  }

  return (
    <div className="stack" style={{ gap: 14 }} data-testid="files-panel">
      {!seat && <Alert kind="amber" icon="lock">Your place in {d.business?.name || 'this business'} is switched off, so you cannot download or upload its returns. A partner can assign you to it.</Alert>}
      <div className="card card-pad stack" style={{ gap: 12 }}>
        <div className="row wrap" style={{ gap: 8 }}>
          {(['vat', 'wht', 'cit', 'fs'] as Kind[]).map((k) => (
            <button key={k} className={'btn btn-sm ' + (kind === k ? 'btn-primary' : 'btn-secondary')} onClick={() => setKind(k)}>{KIND_LABEL[k]}</button>
          ))}
        </div>
        <div className="row wrap" style={{ gap: 10, alignItems: 'flex-end' }}>
          {(kind === 'vat' || kind === 'wht') && (
            <label className="stack" style={{ gap: 4 }}><span className="mini-label">Month</span>
              <input className="input input-sm" type="month" value={month} onChange={(e) => setMonth(e.target.value)} aria-label="Month" /></label>
          )}
          {kind === 'wht' && (
            <label className="stack" style={{ gap: 4 }}><span className="mini-label">Paid to</span>
              <select className="input input-sm" value={authority} onChange={(e) => setAuthority(e.target.value)} aria-label="Tax authority">
                <option value="NRS">NRS</option>
                {STATES.map((s) => <option key={s} value={`SIRS:${s}`}>State revenue service ({s})</option>)}
              </select></label>
          )}
          {kind === 'cit' && (
            <label className="stack" style={{ gap: 4 }}><span className="mini-label">Accounting year</span>
              <input className="input input-sm num" style={{ width: 100 }} inputMode="numeric" value={year} onChange={(e) => setYear(e.target.value.replace(/\D/g, '').slice(0, 4))} aria-label="Year" /></label>
          )}
          {kind === 'fs' && (
            <>
              <label className="stack" style={{ gap: 4 }}><span className="mini-label">From</span><input className="input input-sm" type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="From" /></label>
              <label className="stack" style={{ gap: 4 }}><span className="mini-label">To</span><input className="input input-sm" type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="To" /></label>
            </>
          )}
          <button className="btn btn-secondary btn-sm" disabled={!seat || busy !== null} onClick={download}>{busy === 'down' ? <Spinner small /> : <Icon name="download" size={14} />}Download Counta's version</button>
        </div>
        <div className="row wrap" style={{ gap: 8, alignItems: 'center' }}>
          <input className="input input-sm" style={{ flex: '1 1 260px', minWidth: 0 }} maxLength={1500} placeholder="What you changed and why (the business sees this)" value={note} onChange={(e) => setNote(e.target.value)} />
          <input ref={file} type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" style={{ display: 'none' }} data-testid="upload-input"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) void upload(f); }} />
          <button className="btn btn-primary btn-sm" disabled={!seat || busy !== null} onClick={() => file.current?.click()}>{busy === 'up' ? <Spinner small /> : <Icon name="upload" size={14} color="#fff" />}Upload your changed file</button>
        </div>
        <div className="faint" style={{ fontSize: 12, lineHeight: 1.5 }}>
          Change the figures in the file Counta gives you and keep its layout. Counta reads the {kind === 'vat' ? 'form\'s lines' : kind === 'wht' ? 'schedule\'s rows and totals' : kind === 'cit' ? 'template\'s totals' : 'statement lines'} from your upload,
          shows every change, and suggests the journal that books them. Nothing is used until you accept it.
        </div>
        {err && <Alert kind="red" icon="alert">{err}</Alert>}
      </div>

      <div className="card" style={{ overflow: 'hidden' }}>
        <div className="card-hd"><b>Changed files</b><span className="faint" style={{ fontSize: 12 }}>{d.files.length}</span></div>
        {!d.files.length ? <div className="card-pad faint" style={{ fontSize: 14 }}>None yet. Files you upload appear here.</div> : d.files.map((f) => {
          const [label, tone] = STATUS_CHIP[f.status];
          return (
            <button key={f.id} className="tr click" style={{ gridTemplateColumns: 'minmax(200px,1fr) auto', width: '100%', textAlign: 'left', background: '#fff', border: 0, borderTop: '1px solid var(--row)' }}
              onClick={() => setOpen(f.id)}>
              <span style={{ minWidth: 0 }}>
                <span style={{ fontWeight: 600, display: 'block' }}>{f.label.charAt(0).toUpperCase() + f.label.slice(1)} <span className="faint" style={{ fontWeight: 400 }}>· version {f.version}</span></span>
                <span className="faint" style={{ fontSize: 12 }}>{f.changes} {f.changes === 1 ? 'change' : 'changes'} · {f.uploader_name} · {when(f.created_at)}{f.journal_ref ? ` · ${f.journal_ref}` : ''}</span>
              </span>
              <span className={'chip ' + tone}>{label}</span>
            </button>
          );
        })}
      </div>
      {open && <FileReview id={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
