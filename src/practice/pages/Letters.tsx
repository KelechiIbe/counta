// Engagement letters. /practice/:pid/letters: the practice's templates (the improved default letter is always there; a
// partner can copy it, write one, import the firm's own letter from Word, or use a PDF that is signed as it stands).
// /practice/:pid/letters/:lid: one letter, drafted from a client's intake: its details and clauses while it is a draft, the
// partner's signature for the firm, sending it to the client's signer, a signed copy uploaded instead, voiding it, and its
// record of events. Partners and managers see letters; only a partner changes templates, signs, sends, uploads or voids.
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../../lib/supabase';
import { edge } from '../../lib/api';
import { fmtDay, when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Icon } from '../../components/Icon';
import { Alert, Field, Modal, ModalHead, SkeletonRows, Spinner } from '../../components/ui';
import { Card, PageHead } from '../../admin/ui';
import { LetterEditor } from '../LetterEditor';
import { docxToBlocks } from '../letterDocx';
import { type LetterDetail, type LetterStatus, type LetterTemplate, openDoc, useLetter, useLetterTemplates, usePracticeHome } from '../api';
import { LETTER_FIELDS, type LetterBody, type MergeValues } from '../../../supabase/functions/_shared/letter.ts';

export const LETTER_STATUS: Record<LetterStatus, [string, string]> = {
  draft: ['Draft', 't-grey'], partner_signed: ['Signed by the firm', 't-blue'], sent: ['Sent for signing', 't-amber'],
  completed: ['Signed by both sides', 't-green'], uploaded: ['Signed copy recorded', 't-green'], void: ['Void', 't-red'],
};
const EVENT_WORD: Record<string, string> = {
  drafted: 'Drafted', partner_signed: 'Signed by the firm', sent: 'Sent for signing', opened: 'Opened by the signer', code_sent: 'Code sent to the signer',
  code_failed: 'Wrong code entered', signed: 'Signed by the client', uploaded: 'Signed copy recorded', voided: 'Voided',
  document_changed: 'Signing refused: the stored letter no longer matches the one the firm signed',
};
// Fields worked out from others (capitals, amounts in words), filled at signing, or set by the letter's kind: not typed.
const DERIVED = new Set(['client.name_upper', 'engagement.title_upper', 'fees.amount_words', 'fees.deposit_words', 'signer.name', 'signer.title',
  'signer.date', 'signature.firm', 'signature.client', 'mode.full_mandate']);
const YES_NO = new Set(['service.advisory', 'service.bookkeeping', 'service.monthly', 'service.annual', 'service.other']);
const FIELD_LABEL: Record<string, string> = {
  'letter.date': 'Date of the letter', 'contact.title': 'Addressee\'s title', 'contact.name': 'Addressee', 'contact.salutation': 'Salutation ("Dear …")',
  'client.name': 'Client\'s legal name', 'client.address': 'Client\'s address', 'client.reg_label': 'Registration label (RC, BN, IT)',
  'client.rc_number': 'Registration number', 'client.description': 'What the client does', 'engagement.title_lower': 'Services, as the title says them',
  'engagement.start_date': 'Work covered from', 'proposal.date': 'Date of the firm\'s proposal', 'firm.name': 'Firm', 'firm.email': 'Firm email',
  'firm.phone': 'Firm phone', 'firm.city': 'Firm\'s city', 'fees.frequency': 'Fee basis (monthly, quarterly…)', 'fees.amount': 'Fee (NGN)',
  'fees.deposit': 'Expenses deposit (NGN, 0 for none)', 'fees.billing_day': 'Billing day', 'fees.billing_period': 'Billing period (month, quarter…)',
  'fees.payment_days': 'Days to pay an invoice', 'fees.suspend_days': 'Days unpaid before work pauses', 'service.advisory': 'Tax review and advisory',
  'service.bookkeeping': 'Accounting setup and bookkeeping', 'service.monthly': 'Monthly VAT, WHT and PAYE', 'service.annual': 'Annual income tax',
  'service.other': 'Another service', 'service.other_text': 'The other service, described', 'service.days': 'Days to deliver monthly work',
  'partner.name': 'Engagement partner', 'partner.title': 'Partner\'s title', 'partner.email': 'Partner\'s email', 'team.assistant': 'Assisted by',
  'conflicts.note': 'Note on the conflicts check (optional)', 'liability.cap_basis': 'Liability cap: higher or lower', 'retention.years': 'Years files are kept',
  'termination.notice_days': 'Notice to end the engagement (days)', 'termination.handover_days': 'Days to hand over records', 'arbitration.seat': 'Seat of arbitration',
};
// Values for previewing a template: every service shown, the letter's own defaults.
const PREVIEW_MERGE: MergeValues = {
  'service.advisory': true, 'service.bookkeeping': true, 'service.monthly': true, 'service.annual': true, 'liability.cap_basis': 'lower', 'retention.years': 6,
  'fees.frequency': 'monthly', 'fees.amount': 250000, 'fees.deposit': 50000, 'fees.billing_day': 20, 'fees.billing_period': 'month', 'fees.payment_days': 14,
  'fees.suspend_days': 30, 'service.days': 7, 'termination.notice_days': 30, 'termination.handover_days': 14, 'arbitration.seat': 'Lagos',
  'client.name': 'Client Name Limited', 'firm.name': 'Your Firm', 'partner.name': 'Engagement Partner', 'partner.title': 'Partner',
};
const plainName = (s: string) => s.normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^[^A-Za-z0-9_-]+/, '').replace(/\.{2,}/g, '.').slice(-90) || 'file';
async function sha256Hex(f: File) {
  const buf = await crypto.subtle.digest('SHA-256', await f.arrayBuffer());
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function Busy({ on, children }: { on: boolean; children: ReactNode }) {
  return <>{on ? <Spinner small /> : null}{children}</>;
}

// ------------------------------------------------------------------ templates
export default function LettersPage({ pid }: { pid: string }) {
  const home = usePracticeHome(pid);
  const list = useLetterTemplates(pid);
  const qc = useQueryClient();
  const toast = useToast();
  const partner = home.data?.me.role === 'partner';
  const [edit, setEdit] = useState<{ id?: string; name: string; body: LetterBody } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const docx = useRef<HTMLInputElement>(null);
  const pdf = useRef<HTMLInputElement>(null);
  const templates = list.data || [];
  const def = templates.find((t) => t.is_default && t.kind === 'blocks') || templates.find((t) => t.kind === 'blocks');

  async function save(p: Record<string, unknown>, done: string) {
    setBusy(String(p.id || 'new')); setErr(null);
    try {
      const t = await rpc<LetterTemplate>('practice_letter_template_save', { p_practice: pid, p });
      await qc.invalidateQueries({ queryKey: ['letter-templates', pid] });
      toast(done);
      return t;
    } catch (e) {
      setErr(cleanError(e));
      return null;
    } finally {
      setBusy(null);
    }
  }
  async function importDocx(f: File) {
    setErr(null);
    try {
      const body = await docxToBlocks(f);
      setEdit({ name: f.name.replace(/\.docx$/i, '').slice(0, 80), body });
    } catch (e) {
      setErr((e as Error).message);
    }
  }
  async function importPdf(f: File) {
    setErr(null);
    if (!/\.pdf$/i.test(f.name) || (f.type && f.type !== 'application/pdf')) { setErr('Choose a PDF file.'); return; }
    if (f.size > 15 * 1024 * 1024) { setErr('That PDF is larger than 15 MB.'); return; }
    setBusy('pdf');
    try {
      const path = `practice/${pid}/letters/templates/${Date.now()}-${plainName(f.name).replace(/\.pdf$/i, '')}.pdf`;
      const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: 'application/pdf', upsert: false });
      if (error) throw new Error('The PDF could not be uploaded just now.');
      await save({ name: f.name.replace(/\.pdf$/i, '').slice(0, 80) || 'Letter (PDF)', kind: 'pdf', pdf_path: path }, 'PDF template added');
    } catch (e) {
      setErr(cleanError(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageHead title="Engagement letters" sub="Templates for the letters your clients sign. A letter is drafted from a client's intake, then signed by a partner and sent to the client." right={partner ? (
        <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
          <button className="btn btn-secondary" onClick={() => def?.body && setEdit({ name: 'New letter', body: def.body })} disabled={!def?.body} data-testid="letter-template-new">
            <Icon name="plus" size={16} />New template
          </button>
          <button className="btn btn-secondary" onClick={() => docx.current?.click()} data-testid="letter-import-docx"><Icon name="upload" size={16} />Import from Word</button>
          <button className="btn btn-secondary" onClick={() => pdf.current?.click()} disabled={busy === 'pdf'} data-testid="letter-import-pdf">
            <Busy on={busy === 'pdf'}><Icon name="file" size={16} /></Busy>Use a PDF
          </button>
          <input ref={docx} type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document" hidden
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) importDocx(f); }} />
          <input ref={pdf} type="file" accept="application/pdf,.pdf" hidden
            onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) importPdf(f); }} />
        </div>
      ) : undefined} />
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      {!partner && home.data && <Alert kind="grey" icon="info">Only a partner changes the practice's templates.</Alert>}
      <Card pad={false}>
        {list.isLoading ? <div style={{ padding: 16 }}><SkeletonRows n={3} /></div> : list.isError ? (
          <div style={{ padding: 16 }}><Alert kind="red" icon="alert">{cleanError(list.error)}</Alert></div>
        ) : templates.map((t) => (
          <div key={t.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', gap: 12, padding: '12px 16px', alignItems: 'center' }} data-testid="letter-template-row">
            <div style={{ minWidth: 0 }}>
              <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                <b className="ellipsis">{t.name}</b>
                {t.is_default && <span className="chip t-blue">Default</span>}
                {t.kind === 'pdf' && <span className="chip t-grey">PDF, signed as it stands</span>}
                {t.archived && <span className="chip t-grey">Archived</span>}
              </div>
              <div className="muted" style={{ fontSize: 13 }}>{t.created_by_name ? `${t.created_by_name} · ` : ''}changed {when(t.updated_at)}</div>
            </div>
            <div className="row" style={{ gap: 6, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
              {t.kind === 'pdf' && t.pdf_path && <button className="btn btn-ghost btn-sm" onClick={() => openDoc(t.pdf_path!).catch((e) => setErr(cleanError(e)))}>Open</button>}
              {partner && t.kind === 'blocks' && t.body && <button className="btn btn-ghost btn-sm" onClick={() => setEdit({ id: t.id, name: t.name, body: t.body! })}>Edit</button>}
              {partner && !t.is_default && !t.archived && (
                <button className="btn btn-ghost btn-sm" disabled={busy === t.id} onClick={() => save({ id: t.id, is_default: true }, `${t.name} is now the default letter`)}>Make default</button>
              )}
              {partner && !t.is_default && (
                <button className="btn btn-ghost btn-sm" disabled={busy === t.id} onClick={() => save({ id: t.id, archived: !t.archived }, t.archived ? 'Template restored' : 'Template archived')}>
                  {t.archived ? 'Restore' : 'Archive'}
                </button>
              )}
            </div>
          </div>
        ))}
      </Card>
      {edit && <TemplateEditor pid={pid} initial={edit} busy={busy !== null} onClose={() => setEdit(null)}
        onSave={async (name, body) => { if (await save({ ...(edit.id ? { id: edit.id } : { kind: 'blocks' }), name, body }, 'Template saved')) setEdit(null); }} />}
    </>
  );
}

function TemplateEditor({ initial, busy, onClose, onSave }: {
  pid: string; initial: { id?: string; name: string; body: LetterBody }; busy: boolean; onClose: () => void; onSave: (name: string, body: LetterBody) => void;
}) {
  const [name, setName] = useState(initial.name);
  const [body, setBody] = useState(initial.body);
  const [variant, setVariant] = useState<'full' | 'involved'>('full');
  return (
    <Modal onClose={onClose} width={1180}>
      <ModalHead title={initial.id ? 'Edit template' : 'New template'} sub="The preview shows every service with sample details. Numbers are added for you." onClose={onClose} />
      <div className="stack" style={{ gap: 12, padding: '0 20px 20px' }}>
        <div className="row" style={{ gap: 12, flexWrap: 'wrap', alignItems: 'flex-end' }}>
          <Field label="Template name" req style={{ flex: '1 1 260px' }}>
            <input className="input" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} />
          </Field>
          <Field label="Preview as" style={{ flex: '0 0 auto' }}>
            <select className="input" value={variant} onChange={(e) => setVariant(e.target.value as 'full' | 'involved')}>
              <option value="full">Full mandate letter</option>
              <option value="involved">Involved letter</option>
            </select>
          </Field>
        </div>
        <LetterEditor body={body} merge={{ ...PREVIEW_MERGE, 'mode.full_mandate': variant === 'full' }} variant={variant} editable onChange={setBody} />
        <div className="row" style={{ justifyContent: 'flex-end', gap: 8 }}>
          <button className="btn btn-secondary" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" disabled={busy || name.trim().length < 2} onClick={() => onSave(name.trim(), body)} data-testid="letter-save">
            <Busy on={busy}>{null}</Busy>Save template
          </button>
        </div>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ one letter
export function LetterPage({ pid }: { pid: string }) {
  const { lid = '' } = useParams();
  const home = usePracticeHome(pid);
  const q = useLetter(lid);
  const qc = useQueryClient();
  const toast = useToast();
  const l = q.data;
  const partner = home.data?.me.role === 'partner';
  const [merge, setMerge] = useState<MergeValues>({});
  const [blocks, setBlocks] = useState<LetterBody | null>(null);
  const [title, setTitle] = useState('');
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [sigName, setSigName] = useState('');
  const [signer, setSigner] = useState({ name: '', email: '', title: '' });
  const [voiding, setVoiding] = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const upload = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!l) return;
    setMerge(l.merge || {}); setBlocks(l.blocks); setTitle(l.title); setDirty(false);
    const s = l.signers[0];
    setSigner({ name: s?.name || String(l.merge['contact.name'] || ''), email: s?.email || '', title: s?.title || String(l.merge['contact.title'] || '') });
  }, [l?.id, l?.updated_at]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (home.data && !sigName) setSigName(home.data.me.display_name || ''); }, [home.data]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [dirty]);

  const draft = l?.status === 'draft';
  const fields = useMemo(() => LETTER_FIELDS.filter((f) => !DERIVED.has(f)), []);

  async function act<T>(key: string, fn: () => Promise<T>, done?: string) {
    setBusy(key); setErr(null);
    try {
      const r = await fn();
      await qc.invalidateQueries({ queryKey: ['letter', lid] });
      if (l?.intake_id) await qc.invalidateQueries({ queryKey: ['practice-intake', l.intake_id] });
      if (done) toast(done);
      return r;
    } catch (e) {
      setErr(cleanError(e));
      return null;
    } finally {
      setBusy(null);
    }
  }
  const saveDraft = () => act('save', async () => {
    const p: Record<string, unknown> = { merge, title };
    if (partner && l?.source === 'template' && blocks) p.blocks = blocks.blocks;
    const r = await rpc<LetterDetail>('practice_letter_save', { p_letter: lid, p });
    setDirty(false);
    return r;
  }, 'Letter saved');
  const signForFirm = () => act('sign', async () => {
    if (dirty) throw new Error('Save your changes before signing.');
    const r = await edge<any>('practice', { action: 'letter_freeze', letter_id: lid, signature_name: sigName.trim() || null });
    if (r?.ok === false) throw new Error(r.error || 'The letter could not be signed just now.');
    return r;
  }, 'Signed for the firm');
  const send = () => act('send', () => rpc<LetterDetail>('practice_letter_send', { p_letter: lid, p: { name: signer.name, email: signer.email, title: signer.title || null } }),
    l?.status === 'sent' ? 'Sent again with a new link' : 'Sent to the client for signing');
  const uploadSigned = (f: File) => act('upload', async () => {
    if (!/\.pdf$/i.test(f.name)) throw new Error('Choose the signed letter as a PDF.');
    if (f.size > 15 * 1024 * 1024) throw new Error('That PDF is larger than 15 MB.');
    const sha = await sha256Hex(f);
    const path = `practice/${pid}/letters/${lid}/signed-${Date.now()}.pdf`;
    const { error } = await supabase.storage.from('documents').upload(path, f, { contentType: 'application/pdf', upsert: false });
    if (error) throw new Error('The signed copy could not be uploaded just now.');
    return rpc<LetterDetail>('practice_letter_upload_signed', { p_letter: lid, p: { path, sha256: sha } });
  }, 'Signed copy recorded');
  const doVoid = () => act('void', async () => {
    const r = await rpc<LetterDetail>('practice_letter_void', { p_letter: lid, p_reason: voidReason });
    setVoiding(false); setVoidReason('');
    return r;
  }, 'Letter voided');

  if (q.isLoading) return <SkeletonRows n={6} />;
  if (q.isError || !l) return <Alert kind="red" icon="alert">{q.isError ? cleanError(q.error) : 'That letter was not found.'}</Alert>;
  const [statusWord, statusTone] = LETTER_STATUS[l.status];
  const s = l.signers[0];
  const back = l.intake_id ? `/practice/${pid}/intake/${l.intake_id}` : `/practice/${pid}`;

  return (
    <>
      <div><Link to={back} className="btn btn-ghost btn-sm" onClick={(e) => { if (dirty && !window.confirm('Leave without saving your changes?')) e.preventDefault(); }}>← {l.intake_name || 'Back'}</Link></div>
      <PageHead title={l.title} sub={<span className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        <span className={'chip ' + statusTone} data-testid="letter-status">{statusWord}</span>
        <span className="muted">{l.variant === 'full' ? 'Full mandate letter' : 'Involved letter'}{l.template_name ? ` · from ${l.template_name}` : ''}</span>
      </span>} />
      {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
      {l.status === 'void' && <Alert kind="grey" icon="info">Voided{l.void_reason ? `: ${l.void_reason}` : ''}. Draft a new letter from the intake if the client still needs one.</Alert>}

      {(l.doc_path || l.final_path) && (
        <Card title="Documents">
          <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
            {l.final_path && <button className="btn btn-primary" onClick={() => openDoc(l.final_path!).catch((e) => setErr(cleanError(e)))}><Icon name="file" size={16} />Open the signed letter</button>}
            {l.doc_path && <button className="btn btn-secondary" onClick={() => openDoc(l.doc_path!).catch((e) => setErr(cleanError(e)))}><Icon name="file" size={16} />{l.status === 'draft' ? 'Open the PDF' : 'Open the letter the firm signed'}</button>}
          </div>
          {l.partner_signed_at && <p className="muted" style={{ fontSize: 13, marginTop: 10 }}>Signed for the firm by {l.partner_name} on {fmtDay(l.partner_signed_at)}.</p>}
        </Card>
      )}

      {draft && (
        <Card title="Details in the letter" sub="Filled in from the intake. Change anything the letter should say differently, then save.">
          <div className="stack" style={{ gap: 12 }} data-testid="letter-merge-form">
            <Field label="Title of the letter" req><input className="input" value={title} maxLength={160} onChange={(e) => { setTitle(e.target.value); setDirty(true); }} /></Field>
            <div className="grid-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 12 }}>
              {fields.map((f) => YES_NO.has(f) ? (
                <label key={f} className="row" style={{ gap: 10, minHeight: 44 }}>
                  <input type="checkbox" checked={merge[f] === true} onChange={(e) => { setMerge({ ...merge, [f]: e.target.checked }); setDirty(true); }} />
                  <span>{FIELD_LABEL[f] || f}</span>
                </label>
              ) : f === 'liability.cap_basis' ? (
                <Field key={f} label={FIELD_LABEL[f]}>
                  <select className="input" value={String(merge[f] ?? 'lower')} onChange={(e) => { setMerge({ ...merge, [f]: e.target.value }); setDirty(true); }}>
                    <option value="lower">Whichever is lower</option><option value="higher">Whichever is higher</option>
                  </select>
                </Field>
              ) : (
                <Field key={f} label={FIELD_LABEL[f] || f}>
                  <input className="input" value={merge[f] == null ? '' : String(merge[f])} inputMode={/amount|deposit|days|years|day$/.test(f) ? 'decimal' : undefined}
                    onChange={(e) => {
                      const v = e.target.value;
                      const numeric = /^(fees\.(amount|deposit|billing_day|payment_days|suspend_days)|service\.days|retention\.years|termination\.(notice_days|handover_days))$/.test(f);
                      setMerge({ ...merge, [f]: v === '' ? null : numeric && /^\d+(\.\d+)?$/.test(v) ? Number(v) : v }); setDirty(true);
                    }} />
                </Field>
              ))}
            </div>
          </div>
        </Card>
      )}

      {l.source !== 'pdf' && blocks && (l.status === 'draft' || l.status !== 'void') && (
        <Card title="Clauses" sub={draft ? (partner && l.source === 'template' ? 'Edit any clause. Only this letter changes, not the template.' : 'Only a partner changes the clauses.') : 'The letter as the firm signed it.'}>
          <LetterEditor body={blocks} merge={merge} variant={l.variant} editable={draft && partner && l.source === 'template'} onChange={(b) => { setBlocks(b); setDirty(true); }} />
        </Card>
      )}

      {draft && (
        <div className="row" style={{ gap: 8, justifyContent: 'flex-end' }}>
          {dirty && <span className="muted" style={{ alignSelf: 'center' }}>Changes not saved yet</span>}
          <button className="btn btn-primary" disabled={busy === 'save' || !dirty} onClick={saveDraft} data-testid="letter-save"><Busy on={busy === 'save'}>{null}</Busy>Save the letter</button>
        </div>
      )}

      {draft && (
        <Card title="Sign for the firm" sub="The letter is turned into a PDF and fingerprinted. After this it cannot be changed: void it and draft again to change it.">
          {partner ? (
            <div className="row" style={{ gap: 12, flexWrap: 'wrap', alignItems: 'flex-end' }}>
              <Field label="Your name, as your signature" style={{ flex: '1 1 260px' }}>
                <input className="input" value={sigName} maxLength={120} onChange={(e) => setSigName(e.target.value)} />
              </Field>
              <button className="btn btn-primary" disabled={busy === 'sign' || dirty || sigName.trim().length < 2} onClick={signForFirm} data-testid="letter-partner-sign">
                <Busy on={busy === 'sign'}>{null}</Busy>Sign for the firm
              </button>
            </div>
          ) : <p className="muted">A partner signs letters for the firm.</p>}
        </Card>
      )}

      {(l.status === 'partner_signed' || l.status === 'sent') && (
        <Card title={l.status === 'sent' ? 'Sent for signing' : 'Send to the client'} sub="The signer gets a link by email, reads the letter, and signs after confirming a code sent to the same address.">
          {s && l.status === 'sent' && (
            <div className="muted" style={{ fontSize: 13, marginBottom: 12 }}>
              Sent to {s.name} ({s.email}){s.token_expires ? `; the link works until ${fmtDay(s.token_expires)}` : ''}.
              {s.locked ? ' Too many wrong codes were entered: send the link again to let them try again.' : ''}
              {s.code_verified_at ? ' They confirmed their code.' : ''}
            </div>
          )}
          {partner ? (
            <div className="stack" style={{ gap: 12 }}>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 12 }}>
                <Field label="Signer's name" req><input className="input" value={signer.name} maxLength={120} onChange={(e) => setSigner({ ...signer, name: e.target.value })} data-testid="letter-signer-name" /></Field>
                <Field label="Signer's email" req><input className="input" type="email" value={signer.email} maxLength={254} onChange={(e) => setSigner({ ...signer, email: e.target.value })} data-testid="letter-signer-email" /></Field>
                <Field label="Signer's title"><input className="input" value={signer.title} maxLength={80} onChange={(e) => setSigner({ ...signer, title: e.target.value })} data-testid="letter-signer-title" /></Field>
              </div>
              <div className="row" style={{ justifyContent: 'flex-end' }}>
                <button className="btn btn-primary" disabled={busy === 'send' || signer.name.trim().length < 2 || !signer.email.includes('@')} onClick={send} data-testid="letter-send">
                  <Busy on={busy === 'send'}>{null}</Busy>{l.status === 'sent' ? 'Send again' : 'Send for signing'}
                </button>
              </div>
            </div>
          ) : <p className="muted">A partner sends letters for signing.</p>}
        </Card>
      )}

      {partner && ['draft', 'partner_signed', 'sent'].includes(l.status) && (
        <Card title="Signed on paper?" sub="Upload the letter signed by both sides as a PDF instead. It is fingerprinted and kept as the record.">
          <button className="btn btn-secondary" disabled={busy === 'upload'} onClick={() => upload.current?.click()} data-testid="letter-upload-signed">
            <Busy on={busy === 'upload'}><Icon name="upload" size={16} /></Busy>Upload the signed copy
          </button>
          <input ref={upload} type="file" accept="application/pdf,.pdf" hidden onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) uploadSigned(f); }} />
        </Card>
      )}

      <Card title="What happened" pad={false}>
        <div data-testid="letter-events">
          {l.events.length === 0 ? <p className="muted" style={{ padding: 16 }}>Nothing yet.</p> : l.events.slice().reverse().map((e) => (
            <div key={e.id} className="tr" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', gap: 12, padding: '10px 16px' }}>
              <span>{EVENT_WORD[e.kind] || e.kind}{e.actor ? <span className="muted"> · {e.actor}</span> : null}</span>
              <span className="muted" style={{ fontSize: 13 }}>{when(e.at)}</span>
            </div>
          ))}
        </div>
      </Card>

      {partner && !['completed', 'uploaded', 'void'].includes(l.status) && (
        <div className="row" style={{ justifyContent: 'flex-end' }}>
          <button className="btn btn-ghost" style={{ color: '#B42318' }} onClick={() => setVoiding(true)} data-testid="letter-void">Void this letter</button>
        </div>
      )}
      {voiding && (
        <Modal onClose={() => setVoiding(false)}>
          <ModalHead title="Void this letter?" sub="A void letter cannot be signed. The client's link stops working." onClose={() => setVoiding(false)} />
          <div className="stack" style={{ gap: 12, padding: '0 20px 20px' }}>
            <Field label="Why" req hint="5 to 500 characters, kept on the letter's record.">
              <textarea className="input" rows={3} value={voidReason} maxLength={500} onChange={(e) => setVoidReason(e.target.value)} />
            </Field>
            <div className="row" style={{ justifyContent: 'flex-end', gap: 8 }}>
              <button className="btn btn-secondary" onClick={() => setVoiding(false)}>Keep it</button>
              <button className="btn btn-primary" disabled={busy === 'void' || voidReason.trim().length < 5} onClick={doVoid}><Busy on={busy === 'void'}>{null}</Busy>Void the letter</button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}
