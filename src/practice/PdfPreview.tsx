// A letter shown as the PDF it will be, before anyone signs it: the practice function draws it (on the firm's letterhead,
// or one a partner is trying), marks every page as a preview and stores nothing. The pages are drawn here with pdf.js, as
// pictures, because a phone's browser will not show a PDF inside the page; the PDF itself opens on its own or downloads.
import { useEffect, useState } from 'react';
import { edge } from '../lib/api';
import { pdfjs } from '../lib/statement';
import { Icon } from '../components/Icon';
import { Alert, Modal, ModalHead, Spinner } from '../components/ui';

export type PreviewAsk = { practice_id: string } & ({ letter_id: string } | { blocks: unknown; merge?: unknown; variant?: string; title?: string }) & { letterhead?: unknown };

const FAILED = 'The preview could not be made just now. Try again.';

export function PdfPreview({ ask, title, onClose }: { ask: PreviewAsk; title?: string; onClose: () => void }) {
  const [url, setUrl] = useState<string | null>(null);
  const [pages, setPages] = useState<string[]>([]);
  const [count, setCount] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let gone = false;
    const made: string[] = [];
    const keep = (u: string) => { made.push(u); return u; };
    (async () => {
      const r = await edge<{ pdf: string; pages: number }>('practice', { action: 'letter_preview', ...ask });
      if (gone) return;
      if (!r || r.ok === false || !r.pdf) { setErr(r?.error || FAILED); return; }
      const bytes = Uint8Array.from(atob(r.pdf), (c) => c.charCodeAt(0));
      setUrl(keep(URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }))));
      // Each page as a picture about 1,400 pixels wide, one after another as they are drawn.
      const lib = await pdfjs();
      const doc = await lib.getDocument({ data: bytes.slice(), isEvalSupported: false }).promise;
      if (gone) return;
      setCount(doc.numPages);
      for (let i = 1; i <= doc.numPages && !gone; i++) {
        const page = await doc.getPage(i);
        const v = page.getViewport({ scale: 1400 / page.getViewport({ scale: 1 }).width });
        const c = document.createElement('canvas');
        c.width = Math.round(v.width); c.height = Math.round(v.height);
        await page.render({ canvas: c, viewport: v }).promise;
        const blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, 'image/png'));
        if (!blob || gone) break;
        const u = keep(URL.createObjectURL(blob));
        setPages((p) => [...p, u]);
      }
      doc.destroy();
    })().catch(() => { if (!gone) setErr(FAILED); });
    return () => { gone = true; made.forEach((u) => URL.revokeObjectURL(u)); };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const name = `${(title || 'letter').replace(/[^A-Za-z0-9 _-]+/g, '').trim() || 'letter'} (preview).pdf`;
  return (
    <Modal onClose={onClose} width={900} z={70}>
      <ModalHead title={title || 'Preview'} sub={count ? `${count} page${count === 1 ? '' : 's'}, marked as a preview. Nothing is signed or kept.` : 'Marked as a preview. Nothing is signed or kept.'}
        onClose={onClose} />
      <div className="stack" style={{ gap: 10, padding: '0 20px 20px' }} data-testid="pdf-preview">
        {err ? <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert> : !url ? (
          <div className="row" style={{ gap: 10, minHeight: 120, justifyContent: 'center' }}><Spinner small />Preparing the PDF…</div>
        ) : (
          <>
            <div className="pdf-pages" data-testid="pdf-preview-pages" tabIndex={0} aria-label={title || 'Letter preview'}>
              {pages.map((u, i) => <img key={u} src={u} alt={`Page ${i + 1} of ${count}`} data-testid="pdf-preview-page" />)}
              {pages.length < count && <div className="row" style={{ gap: 10, justifyContent: 'center', padding: 16 }}><Spinner small />Drawing page {pages.length + 1} of {count}…</div>}
            </div>
            <div className="row" style={{ gap: 8, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
              <a className="btn btn-secondary" href={url} target="_blank" rel="noreferrer" data-testid="pdf-preview-open"><Icon name="external" size={16} />Open the PDF</a>
              <a className="btn btn-ghost" href={url} download={name}><Icon name="download" size={16} />Download</a>
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}
