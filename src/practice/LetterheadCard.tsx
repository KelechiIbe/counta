// The firm's letterhead on its engagement letters (Practice settings). Plain: the firm's name heads the first page, as
// before. Our own letterhead: the firm uploads its blank letterhead page (a PDF, or a picture of the whole page), and
// the letter is printed on it, inside the space it keeps clear; the following pages can carry the same page, another, or
// none. Build one here: the firm's logo, name and details in its colour, with a footer line. A partner changes it; letters
// signed from then on carry it, and letters already signed never change. Files go to practice/<pid>/letterhead/ and the
// database checks every setting (practice_set_letterhead). A sample letter can be seen as a PDF before saving.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useLocation } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { cleanError, rpc, supabase } from '../lib/supabase';
import { pdfjs } from '../lib/statement';
import { fmtDay } from '../lib/format';
import { useToast } from '../state/session';
import { Icon } from '../components/Icon';
import { Alert, Field, Pills, Spinner } from '../components/ui';
import { Card } from '../admin/ui';
import { ColorPicker } from '../pages/SettingsBranding';
import { type Home, type Letterhead, type LetterheadFile, type LetterheadMargins, type LetterheadShow, useLetterTemplates } from './api';
import { PREVIEW_MERGE } from './letterSample';
import { PdfPreview, type PreviewAsk } from './PdfPreview';

type Mode = 'plain' | 'upload' | 'built';
type Form = {
  mode: Mode; font: 'helvetica' | 'times'; color: string; first: LetterheadFile | null; next: LetterheadFile | null; next_mode: 'same' | 'upload' | 'none';
  margins: LetterheadMargins; logo: LetterheadFile | null; layout: 'left' | 'center'; show: LetterheadShow; website: string; footer: string;
};
const A4: [number, number] = [595.28, 841.89];
const MM = 72 / 25.4;
const mm = (pt: number) => Math.round(pt / MM);
const pt = (v: number) => Math.round(v * MM * 10) / 10;
const DEFAULT_MARGINS: LetterheadMargins = { first_top: 150, first_bottom: 90, next_top: 150, next_bottom: 90, left: 56, right: 56 };
// A colour still at one mode's default follows the mode; one the partner picked stays.
const DEFAULT_COLOURS = ['#111827', '#0B3B75'];
const DEFAULT_SHOW: LetterheadShow = { address: true, phone: true, email: true, firm_reg: true, website: false };

function formOf(lh: Letterhead | null): Form {
  return {
    mode: lh?.mode ?? 'plain', font: lh?.font ?? 'helvetica', color: lh?.color ?? (lh?.mode === 'upload' ? '#111827' : '#0B3B75'),
    first: lh?.first ?? null, next: lh?.next ?? null, next_mode: lh?.next_mode ?? 'same', margins: lh?.margins ?? DEFAULT_MARGINS,
    logo: lh?.logo ?? null, layout: lh?.layout ?? 'left', show: lh?.show ?? DEFAULT_SHOW, website: lh?.website ?? '', footer: lh?.footer ?? '',
  };
}
// What practice_set_letterhead takes.
function payload(f: Form): Record<string, unknown> {
  if (f.mode === 'plain') return { mode: 'plain' };
  if (f.mode === 'upload') {
    const m = f.margins;
    return { mode: 'upload', font: f.font, color: f.color, first: f.first, next_mode: f.next_mode, ...(f.next_mode === 'upload' ? { next: f.next } : {}),
      margins: f.next_mode === 'same' ? { first_top: m.first_top, first_bottom: m.first_bottom, left: m.left, right: m.right } : m };
  }
  return { mode: 'built', font: f.font, color: f.color, logo: f.logo, layout: f.layout, show: f.show, website: f.website.trim() || null, footer: f.footer.trim() || null };
}
// The page a letterhead file makes, in points (a picture: A4 or US Letter by its shape).
const pageOf = (f: LetterheadFile | null): [number, number] =>
  !f ? A4 : f.kind === 'pdf' ? [f.w, f.h] : Math.abs(f.h / f.w - 1.2941) < Math.abs(f.h / f.w - 1.4142) ? [612, 792] : A4;

async function sha256(b: Blob) {
  const d = await crypto.subtle.digest('SHA-256', await b.arrayBuffer());
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('');
}
async function store(pid: string, blob: Blob, name: string, type: string): Promise<string> {
  const path = `practice/${pid}/letterhead/${Date.now()}-${name}`;
  const { error } = await supabase.storage.from('documents').upload(path, blob, { contentType: type, upsert: false });
  if (error) throw new Error('The file could not be uploaded just now. Try again.');
  return path;
}
async function decode(f: Blob): Promise<{ img: CanvasImageSource; w: number; h: number; done: () => void }> {
  try {
    const b = await createImageBitmap(f);
    return { img: b, w: b.width, h: b.height, done: () => b.close() };
  } catch {
    throw new Error('That picture could not be read. Choose a PNG or JPG.');
  }
}
function canvasBlob(c: HTMLCanvasElement, type: string, q?: number) {
  return new Promise<Blob>((ok, ko) => c.toBlob((b) => (b ? ok(b) : ko(new Error('The picture could not be prepared. Try another file.'))), type, q));
}
// The first page of a PDF: its size in points and a picture of it for the preview.
async function pdfFirstPage(data: ArrayBuffer): Promise<{ w: number; h: number; img: string }> {
  const lib = await pdfjs();
  let doc: any;
  try { doc = await lib.getDocument({ data: new Uint8Array(data), isEvalSupported: false }).promise; }
  catch (e: any) {
    throw new Error(e?.name === 'PasswordException' ? 'That PDF is protected by a password. Save it again without one.' : 'That PDF could not be opened. Save it again from Word as a PDF.');
  }
  const page = await doc.getPage(1);
  const v1 = page.getViewport({ scale: 1 });
  const v = page.getViewport({ scale: 640 / v1.width });
  const c = document.createElement('canvas');
  c.width = Math.round(v.width); c.height = Math.round(v.height);
  await page.render({ canvas: c, viewport: v }).promise;
  return { w: Math.round(v1.width * 100) / 100, h: Math.round(v1.height * 100) / 100, img: c.toDataURL('image/png') };
}
// A letterhead page from a file: a PDF as it is (5 MB at most), or a picture of the whole page redrawn as a JPG no wider
// than 2,480 pixels (A4 at 300 dpi).
async function letterheadPage(pid: string, f: File): Promise<{ file: LetterheadFile; img: string }> {
  if (/pdf$/i.test(f.type) || /\.pdf$/i.test(f.name)) {
    if (f.size > 5 * 1048576) throw new Error('That PDF is larger than 5 MB. Save it again with smaller pictures.');
    const page = await pdfFirstPage(await f.arrayBuffer());
    if (page.w < 400 || page.w > 700 || page.h < 500 || page.h > 1000 || page.h <= page.w) throw new Error('The letterhead must be an upright A4 or US Letter page.');
    const path = await store(pid, f, 'page.pdf', 'application/pdf');
    return { file: { path, sha256: await sha256(f), kind: 'pdf', w: page.w, h: page.h }, img: page.img };
  }
  if (!/^image\/(png|jpe?g|webp)$/i.test(f.type)) throw new Error('Choose a PDF, or a PNG or JPG picture of the whole page.');
  const d = await decode(f);
  try {
    const r = d.h / d.w;
    if (Math.abs(r - 1.4142) > 0.045 && Math.abs(r - 1.2941) > 0.04) throw new Error('The picture must be a whole upright A4 or US Letter page, not just the header.');
    if (d.w < 1000) throw new Error('The picture is too small to print well. Save it at 150 dpi or more (at least 1,000 pixels wide), or use a PDF.');
    const s = Math.min(1, 2480 / d.w);
    const c = document.createElement('canvas');
    c.width = Math.round(d.w * s); c.height = Math.round(d.h * s);
    const ctx = c.getContext('2d')!;
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, c.width, c.height);
    ctx.drawImage(d.img, 0, 0, c.width, c.height);
    const blob = await canvasBlob(c, 'image/jpeg', 0.9);
    if (blob.size > 5 * 1048576) throw new Error('The picture is still larger than 5 MB. Use a PDF instead.');
    const path = await store(pid, blob, 'page.jpg', 'image/jpeg');
    return { file: { path, sha256: await sha256(blob), kind: 'jpg', w: c.width, h: c.height }, img: URL.createObjectURL(blob) };
  } finally { d.done(); }
}
// A logo, redrawn as a PNG (keeping its transparency) no larger than 1,000 pixels on its long side.
async function logoFile(pid: string, f: File): Promise<{ file: LetterheadFile; img: string }> {
  if (!/^image\/(png|jpe?g|webp)$/i.test(f.type)) throw new Error('Choose the logo as a PNG or JPG picture.');
  if (f.size > 15 * 1048576) throw new Error('Choose a picture under 15 MB.');
  const d = await decode(f);
  try {
    if (d.w < 16 || d.h < 16) throw new Error('That logo is too small.');
    const s = Math.min(1, 1000 / Math.max(d.w, d.h));
    const c = document.createElement('canvas');
    c.width = Math.max(16, Math.round(d.w * s)); c.height = Math.max(16, Math.round(d.h * s));
    c.getContext('2d')!.drawImage(d.img, 0, 0, c.width, c.height);
    const blob = await canvasBlob(c, 'image/png');
    if (blob.size > 2 * 1048576) throw new Error('The logo is larger than 2 MB even after resizing. Choose a simpler picture.');
    const path = await store(pid, blob, 'logo.png', 'image/png');
    return { file: { path, sha256: await sha256(blob), kind: 'png', w: c.width, h: c.height }, img: URL.createObjectURL(blob) };
  } finally { d.done(); }
}
// A saved file's picture for the preview (a PDF's first page drawn, a picture as it is).
async function savedArt(f: LetterheadFile): Promise<string | null> {
  const { data, error } = await supabase.storage.from('documents').download(f.path);
  if (error || !data) return null;
  if (f.kind === 'pdf') return (await pdfFirstPage(await data.arrayBuffer())).img;
  return URL.createObjectURL(data);
}

// The firm's details as a built letterhead shows them (the same as the PDF: practice function firmLines).
function firmLines(h: Home, f: Form): string[] {
  const p = h.practice, s = f.show;
  const address = s.address ? [p.address, p.state].map((x) => String(x || '').trim()).filter(Boolean).join(', ') : '';
  const contact = [s.phone && p.phone ? `Tel ${p.phone}` : '', s.email && p.email ? p.email : '', s.website && f.website.trim() ? f.website.trim() : ''].filter(Boolean).join(' · ');
  const reg = s.firm_reg && p.firm_reg ? `Registration no. ${p.firm_reg}` : '';
  return [address, contact, reg].filter(Boolean);
}
const FONT_CSS = { helvetica: 'Helvetica, Arial, sans-serif', times: '"Times New Roman", Times, serif' };

// Grey bars standing for the letter's text.
function TextBars({ n = 14 }: { n?: number }) {
  const widths = [92, 100, 86, 97, 64, 100, 94, 78, 100, 88, 70, 96, 100, 58, 90, 82];
  return <>{widths.slice(0, n).map((w, i) => <span key={i} className="lh-bar" style={{ width: `${w}%`, marginTop: i === 4 || i === 9 ? 8 : undefined }} />)}</>;
}
// One page as the letter will sit on it: the letterhead under it, the space kept clear tinted, the text area in between.
function PagePreview({ label, art, page, top, bottom, left, right, children, testid }: {
  label: string; art: string | null; page: [number, number]; top: number; bottom: number; left: number; right: number; children?: ReactNode; testid?: string;
}) {
  const [w, h] = page;
  return (
    <figure className="lh-fig" data-testid={testid}>
      <div className="lh-page" style={{ aspectRatio: `${w} / ${h}` }}>
        {art && <img src={art} alt="" />}
        <div className="lh-clear" style={{ top: 0, height: `${(top / h) * 100}%` }} />
        <div className="lh-clear" style={{ bottom: 0, height: `${(bottom / h) * 100}%` }} />
        <div className="lh-area" style={{ top: `${(top / h) * 100}%`, bottom: `${(bottom / h) * 100}%`, left: `${(left / w) * 100}%`, right: `${(right / w) * 100}%` }}>
          {children ?? <TextBars />}
          <span className="lh-num" />
        </div>
      </div>
      <figcaption>{label}</figcaption>
    </figure>
  );
}

// The page a built letterhead makes: the logo, name and details in its colour, a rule, and the footer.
function BuiltPreview({ h, f, logo, next }: { h: Home; f: Form; logo: string | null; next?: boolean }) {
  const lines = firmLines(h, f);
  const centre = f.layout === 'center';
  return (
    <figure className="lh-fig" data-testid={next ? 'lh-built-next' : 'lh-built-first'}>
      <div className="lh-page lh-built" style={{ aspectRatio: '595.28 / 841.89', fontFamily: FONT_CSS[f.font] }}>
        {next ? (
          <div className="lh-built-slim" style={{ color: f.color, borderColor: f.color }}>{h.practice.name}</div>
        ) : (
          <div className={'lh-built-head' + (centre ? ' centre' : '')} style={{ borderColor: f.color }}>
            {logo && <img src={logo} alt="" className="lh-logo" />}
            <div className="lh-built-text">
              <div className="lh-built-name" style={{ color: f.color }}>{h.practice.name}</div>
              {lines.map((l) => <div key={l} className="lh-built-line">{l}</div>)}
            </div>
          </div>
        )}
        <div className="lh-built-body"><TextBars n={next ? 16 : 11} /></div>
        {f.footer.trim() && <div className="lh-built-foot">{f.footer.trim().split('\n').slice(0, 2).map((l) => <div key={l}>{l}</div>)}</div>}
      </div>
      <figcaption>{next ? 'Following pages' : 'First page'}</figcaption>
    </figure>
  );
}

function Slider({ label, value, min, max, onChange, disabled, testid }: { label: string; value: number; min: number; max: number; onChange: (v: number) => void;
  disabled?: boolean; testid?: string }) {
  return (
    <label className="lh-slider">
      <span className="row" style={{ justifyContent: 'space-between' }}><span>{label}</span><b className="num">{value} mm</b></span>
      <input type="range" min={min} max={max} value={value} disabled={disabled} onChange={(e) => onChange(Number(e.target.value))} data-testid={testid}
        aria-valuetext={`${value} millimetres`} />
    </label>
  );
}

export function LetterheadCard({ pid, h }: { pid: string; h: Home }) {
  const qc = useQueryClient();
  const toast = useToast();
  const partner = h.me.role === 'partner';
  const saved = h.practice.letterhead;
  const [f, setF] = useState<Form>(() => formOf(saved));
  const [art, setArt] = useState<{ first: string | null; next: string | null; logo: string | null }>({ first: null, next: null, logo: null });
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);
  const [preview, setPreview] = useState<PreviewAsk | null>(null);
  const templates = useLetterTemplates(pid);
  const sample = (templates.data || []).find((t) => t.is_default && t.kind === 'blocks')?.body || (templates.data || []).find((t) => t.kind === 'blocks')?.body;
  const pick = { first: useRef<HTMLInputElement>(null), next: useRef<HTMLInputElement>(null), logo: useRef<HTMLInputElement>(null) };
  const savedAt = h.practice.letterhead_set_at;
  const savedBy = h.members.find((m) => m.id === h.practice.letterhead_set_by)?.display_name;

  // Opened from a letter's link (…/settings#letterhead): bring the card into view.
  const loc = useLocation();
  useEffect(() => {
    if (loc.hash === '#letterhead') document.getElementById('letterhead')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, [loc.hash]);
  // The saved files' pictures, once.
  useEffect(() => {
    let gone = false;
    (async () => {
      const lh = saved;
      if (!lh) return;
      const [first, next, logo] = await Promise.all([lh.first ? savedArt(lh.first) : null, lh.next ? savedArt(lh.next) : null, lh.logo ? savedArt(lh.logo) : null]
        .map((p) => Promise.resolve(p).catch(() => null)));
      if (!gone) setArt({ first, next, logo });
    })();
    return () => { gone = true; };
  }, [h.practice.letterhead_set_at]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setF(formOf(saved)); setDirty(false); }, [h.practice.letterhead_set_at]); // eslint-disable-line react-hooks/exhaustive-deps

  const set = (p: Partial<Form>) => { setF((x) => ({ ...x, ...p })); setDirty(true); };
  const setM = (p: Partial<LetterheadMargins>) => { setF((x) => ({ ...x, margins: { ...x.margins, ...p } })); setDirty(true); };
  async function choose(kind: 'first' | 'next' | 'logo', file: File) {
    setBusy(kind); setErr(null);
    try {
      const r = kind === 'logo' ? await logoFile(pid, file) : await letterheadPage(pid, file);
      setArt((a) => ({ ...a, [kind]: r.img }));
      set({ [kind]: r.file } as Partial<Form>);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  }
  async function save() {
    if (f.mode === 'upload' && !f.first) { setErr('Upload your letterhead page first.'); return; }
    if (f.mode === 'upload' && f.next_mode === 'upload' && !f.next) { setErr('Upload the page for the following pages, or choose the same letterhead.'); return; }
    setBusy('save'); setErr(null);
    try {
      await rpc('practice_set_letterhead', { p_practice: pid, p: payload(f) });
      await qc.invalidateQueries({ queryKey: ['practice-home', pid] });
      setDirty(false);
      toast(f.mode === 'plain' ? 'Letters are printed plain from now on' : 'Letterhead saved. Letters signed from now on carry it.');
    } catch (e) {
      setErr(cleanError(e));
    } finally {
      setBusy(null);
    }
  }
  function showSample() {
    if (!sample) { setErr('The sample letter is still loading. Try again in a moment.'); return; }
    if (f.mode === 'upload' && !f.first) { setErr('Upload your letterhead page first.'); return; }
    setErr(null);
    setPreview({ practice_id: pid, blocks: sample, merge: { ...PREVIEW_MERGE, 'firm.name': h.practice.name, 'mode.full_mandate': false }, variant: 'involved',
      title: 'Letter of engagement: Client Name Limited', ...(partner ? { letterhead: payload(f) } : {}) });
  }

  const page = f.mode === 'upload' ? pageOf(f.first) : A4;
  const m = f.margins;
  const nextTop = f.next_mode === 'same' ? m.first_top : m.next_top, nextBottom = f.next_mode === 'same' ? m.first_bottom : m.next_bottom;
  const nextArt = f.next_mode === 'same' ? art.first : f.next_mode === 'upload' ? art.next : null;
  const off = !partner || busy !== null;

  return (
    <div id="letterhead">
      <Card title="Letterhead" sub={`How your engagement letters look. Letters signed from now on carry it; letters already signed keep the look they were signed with, and a letter you use as a finished PDF is never changed.${partner ? '' : ' A partner changes this.'}`}>
        {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
        <Pills value={f.mode} onChange={(v) => partner && set({ mode: v as Mode, color: DEFAULT_COLOURS.includes(f.color) ? (v === 'upload' ? '#111827' : '#0B3B75') : f.color })}
          options={[{ id: 'plain', label: 'Plain' }, { id: 'upload', label: 'Our own letterhead' }, { id: 'built', label: 'Build one here' }]} />

        {f.mode === 'plain' && <p className="muted" style={{ margin: 0 }}>The firm's name heads the first page, and the letter is set in Helvetica on A4.</p>}

        {f.mode === 'upload' && (
          <div className="stack" style={{ gap: 14 }} data-testid="lh-upload">
            <div className="stack" style={{ gap: 6 }}>
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <button className="btn btn-secondary" disabled={off} onClick={() => pick.first.current?.click()} data-testid="lh-first-pick">
                  {busy === 'first' ? <Spinner small /> : <Icon name="upload" size={16} />}{f.first ? 'Replace the letterhead page' : 'Upload your letterhead page'}
                </button>
                {f.first && <span className="chip t-green">{f.first.kind === 'pdf' ? 'PDF' : 'Picture'}, {page[0] === 612 ? 'US Letter' : 'A4'}</span>}
              </div>
              <span className="muted" style={{ fontSize: 13 }}>A PDF, or a PNG or JPG of the whole page. In Word, open your letterhead with nothing typed on it and save it as a PDF.</span>
              <input ref={pick.first} type="file" accept="application/pdf,.pdf,image/png,image/jpeg" hidden
                onChange={(e) => { const x = e.target.files?.[0]; e.target.value = ''; if (x) choose('first', x); }} data-testid="lh-first-file" />
            </div>

            <Field label="The following pages">
              <select className="input" value={f.next_mode} disabled={off} data-testid="lh-next-mode" onChange={(e) => {
                // A plain following page starts with 20 mm at the top and bottom; another letterhead page starts as the first.
                const v = e.target.value as Form['next_mode'];
                set({ next_mode: v, margins: { ...f.margins, ...(v === 'none' ? { next_top: 56, next_bottom: 56 } : { next_top: f.margins.first_top, next_bottom: f.margins.first_bottom }) } });
              }}>
                <option value="same">The same letterhead</option>
                <option value="upload">A different page (often a lighter one)</option>
                <option value="none">No letterhead</option>
              </select>
            </Field>
            {f.next_mode === 'upload' && (
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <button className="btn btn-secondary" disabled={off} onClick={() => pick.next.current?.click()} data-testid="lh-next-pick">
                  {busy === 'next' ? <Spinner small /> : <Icon name="upload" size={16} />}{f.next ? 'Replace the page for the following pages' : 'Upload the page for the following pages'}
                </button>
                <input ref={pick.next} type="file" accept="application/pdf,.pdf,image/png,image/jpeg" hidden
                  onChange={(e) => { const x = e.target.files?.[0]; e.target.value = ''; if (x) choose('next', x); }} data-testid="lh-next-file" />
              </div>
            )}

            <div className="lh-grid">
              <div className="stack" style={{ gap: 10 }}>
                <div className="label">Space to keep clear for your letterhead</div>
                <Slider label="Top of the first page" value={mm(m.first_top)} min={13} max={148} disabled={off} onChange={(v) => setM({ first_top: pt(v) })} testid="lh-first-top" />
                <Slider label="Bottom of the first page" value={mm(m.first_bottom)} min={11} max={105} disabled={off} onChange={(v) => setM({ first_bottom: pt(v) })} testid="lh-first-bottom" />
                {f.next_mode !== 'same' && <>
                  <Slider label="Top of the following pages" value={mm(m.next_top)} min={13} max={148} disabled={off} onChange={(v) => setM({ next_top: pt(v) })} />
                  <Slider label="Bottom of the following pages" value={mm(m.next_bottom)} min={11} max={105} disabled={off} onChange={(v) => setM({ next_bottom: pt(v) })} />
                </>}
                <Slider label="Left side" value={mm(m.left)} min={13} max={70} disabled={off} onChange={(v) => setM({ left: pt(v) })} />
                <Slider label="Right side" value={mm(m.right)} min={13} max={70} disabled={off} onChange={(v) => setM({ right: pt(v) })} />
                <Field label="Typeface">
                  <select className="input" value={f.font} disabled={off} onChange={(e) => set({ font: e.target.value as Form['font'] })}>
                    <option value="helvetica">Helvetica (clean, modern)</option><option value="times">Times (traditional)</option>
                  </select>
                </Field>
                <div className="stack" style={{ gap: 4 }}><span className="label">Colour of the headings</span><ColorPicker value={f.color} disabled={off} onChange={(v) => set({ color: v })} /></div>
              </div>
              <div className="lh-pages">
                <PagePreview label="First page" art={art.first} page={page} top={m.first_top} bottom={m.first_bottom + 18} left={m.left} right={m.right} testid="lh-preview-first" />
                <PagePreview label="Following pages" art={nextArt} page={page} top={nextTop} bottom={nextBottom + 18} left={m.left} right={m.right} testid="lh-preview-next" />
              </div>
            </div>
          </div>
        )}

        {f.mode === 'built' && (
          <div className="lh-grid" data-testid="lh-built">
            <div className="stack" style={{ gap: 12 }}>
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <button className="btn btn-secondary" disabled={off} onClick={() => pick.logo.current?.click()} data-testid="lh-logo-pick">
                  {busy === 'logo' ? <Spinner small /> : <Icon name="image" size={16} />}{f.logo ? 'Replace the logo' : 'Upload your logo'}
                </button>
                {f.logo && <button className="btn btn-ghost btn-sm" disabled={off} onClick={() => { set({ logo: null }); setArt((a) => ({ ...a, logo: null })); }}>Remove the logo</button>}
                <input ref={pick.logo} type="file" accept="image/png,image/jpeg,image/webp" hidden
                  onChange={(e) => { const x = e.target.files?.[0]; e.target.value = ''; if (x) choose('logo', x); }} data-testid="lh-logo-file" />
              </div>
              <Field label="Layout">
                <select className="input" value={f.layout} disabled={off} onChange={(e) => set({ layout: e.target.value as Form['layout'] })} data-testid="lh-layout">
                  <option value="left">Logo on the left, details on the right</option><option value="center">Centred</option>
                </select>
              </Field>
              <div className="stack" style={{ gap: 4 }}><span className="label">Colour</span><ColorPicker value={f.color} disabled={off} onChange={(v) => set({ color: v })} /></div>
              <Field label="Typeface">
                <select className="input" value={f.font} disabled={off} onChange={(e) => set({ font: e.target.value as Form['font'] })} data-testid="lh-font">
                  <option value="helvetica">Helvetica (clean, modern)</option><option value="times">Times (traditional)</option>
                </select>
              </Field>
              <div className="stack" style={{ gap: 2 }}>
                <span className="label">Under the firm's name</span>
                {([['address', 'Address'], ['phone', 'Phone'], ['email', 'Email'], ['firm_reg', 'Registration number'], ['website', 'Website']] as [keyof LetterheadShow, string][]).map(([k, l]) => (
                  <label key={k} className="check" style={{ minHeight: 36 }}>
                    <input type="checkbox" checked={f.show[k]} disabled={off} onChange={(e) => set({ show: { ...f.show, [k]: e.target.checked } })} data-testid={`lh-show-${k}`} />
                    <span>{l}</span>
                  </label>
                ))}
                {f.show.website && <input className="input" value={f.website} disabled={off} maxLength={100} placeholder="www.yourfirm.ng" aria-label="Website"
                  onChange={(e) => set({ website: e.target.value })} data-testid="lh-website" />}
                <span className="muted" style={{ fontSize: 13 }}>The name, address, phone, email and registration number come from The practice above.</span>
              </div>
              <Field label="Footer (optional, up to two lines)" hint="For example your partners' names, or the body that regulates the firm.">
                <textarea className="input" rows={2} value={f.footer} disabled={off} maxLength={300}
                  onChange={(e) => set({ footer: e.target.value.split('\n').slice(0, 2).join('\n') })} data-testid="lh-footer" />
              </Field>
            </div>
            <div className="lh-pages">
              <BuiltPreview h={h} f={f} logo={art.logo} />
              <BuiltPreview h={h} f={f} logo={art.logo} next />
            </div>
          </div>
        )}

        <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <button className="btn btn-secondary" onClick={showSample} disabled={busy !== null} data-testid="lh-sample"><Icon name="eye" size={16} />See a sample letter</button>
          {partner && <button className="btn btn-primary" disabled={busy !== null || !dirty} onClick={save} data-testid="lh-save">
            {busy === 'save' ? <Spinner small /> : <Icon name="check" size={14} color="#fff" />}Save letterhead
          </button>}
          {dirty && <span className="muted" style={{ fontSize: 13 }}>Not saved yet</span>}
          {!dirty && savedAt && <span className="faint" style={{ fontSize: 13 }}>Changed {savedBy ? `by ${savedBy} ` : ''}on {fmtDay(savedAt)}</span>}
        </div>
      </Card>
      {preview && <PdfPreview ask={preview} title="Sample letter" onClose={() => setPreview(null)} />}
    </div>
  );
}
