// The client's signer signs an engagement letter: /sign/<token> (the token then lives in this tab only, at /sign). They
// read the letter, type their name and type or draw a signature, confirm a 6-digit code sent to the email the letter was
// sent to, and sign. The practice function adds the signature page and a completion certificate and keeps the result.
// A full-mandate client sees only the firm: no Counta name on this page.
import { useCallback, useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { edge } from '../../lib/api';
import { Alert, Spinner } from '../../components/ui';
import { useLinkToken } from './linkToken';

type Open = { ok: boolean; reason?: string; error?: string; title?: string; firm_name?: string; signer_name?: string; status?: string; white_label?: boolean; doc_url?: string | null };

// A typed signature drawn as an image, in a handwriting-like face.
function typedPng(name: string): string {
  const c = document.createElement('canvas');
  c.width = 900; c.height = 240;
  const g = c.getContext('2d')!;
  g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = '#111827';
  let size = 96;
  g.font = `italic ${size}px "Segoe Script", "Brush Script MT", "Snell Roundhand", cursive`;
  while (g.measureText(name).width > c.width - 60 && size > 28) { size -= 4; g.font = `italic ${size}px "Segoe Script", "Brush Script MT", "Snell Roundhand", cursive`; }
  g.textBaseline = 'middle';
  g.fillText(name, 30, c.height / 2);
  return c.toDataURL('image/png');
}

function Pad({ onChange }: { onChange: (png: string | null) => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const drawing = useRef(false);
  const inked = useRef(false);
  useEffect(() => {
    const c = ref.current!;
    c.width = 900; c.height = 270;
    const g = c.getContext('2d')!;
    g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
    g.lineWidth = 4; g.lineCap = 'round'; g.lineJoin = 'round'; g.strokeStyle = '#111827';
  }, []);
  const at = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    return [((e.clientX - r.left) / r.width) * e.currentTarget.width, ((e.clientY - r.top) / r.height) * e.currentTarget.height];
  };
  function clear() {
    const c = ref.current!, g = c.getContext('2d')!;
    g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
    inked.current = false; onChange(null);
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <canvas ref={ref} className="sign-pad" aria-label="Draw your signature here" role="img" data-testid="sign-canvas"
        onPointerDown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); drawing.current = true; const g = e.currentTarget.getContext('2d')!; const [x, y] = at(e); g.beginPath(); g.moveTo(x, y); }}
        onPointerMove={(e) => { if (!drawing.current) return; const g = e.currentTarget.getContext('2d')!; const [x, y] = at(e); g.lineTo(x, y); g.stroke(); inked.current = true; }}
        onPointerUp={(e) => { drawing.current = false; if (inked.current) onChange(e.currentTarget.toDataURL('image/png')); }}
        onPointerCancel={() => { drawing.current = false; }} />
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className="muted" style={{ fontSize: 13 }}>Sign with your finger, a pen or the mouse.</span>
        <button type="button" className="btn btn-ghost btn-sm" onClick={clear}>Clear</button>
      </div>
    </div>
  );
}

export default function SignPage() {
  const { token: param } = useParams();
  const token = useLinkToken(param, 'counta.sign', '/sign');
  const [open, setOpen] = useState<Open | null>(null);
  const [read, setRead] = useState(false);
  const [mode, setMode] = useState<'type' | 'draw'>('type');
  const [typed, setTyped] = useState('');
  const [drawn, setDrawn] = useState<string | null>(null);
  const [codeSent, setCodeSent] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<{ doc_url: string | null } | null>(null);

  const load = useCallback(async () => {
    if (!token) { setOpen({ ok: false, error: 'This link is not valid. Ask the firm to send it again.' }); return; }
    const r = await edge<Open>('practice', { action: 'sign_open', token });
    setOpen(r);
  }, [token]);
  useEffect(() => { load(); }, [load]);
  // The link to the letter lasts five minutes: renew it while the page is open.
  useEffect(() => {
    if (!open?.ok || done) return;
    const t = window.setInterval(load, 4 * 60_000);
    return () => window.clearInterval(t);
  }, [open?.ok, done, load]);
  useEffect(() => { if (open?.ok && open.firm_name && open.white_label) document.title = open.firm_name; }, [open?.ok, open?.firm_name, open?.white_label]);
  useEffect(() => { if (open?.signer_name && !typed) setTyped(open.signer_name); }, [open?.signer_name]); // eslint-disable-line react-hooks/exhaustive-deps

  async function sendCode() {
    setBusy('code'); setErr(null);
    const r = await edge<any>('practice', { action: 'sign_code', token });
    setBusy(null);
    if (r?.ok === false) { setErr(r.error || 'The code could not be sent just now.'); return; }
    setCodeSent(`We sent a 6-digit code to the email address this letter was sent to.${typeof r?.sends_left === 'number' ? ` You can ask for ${r.sends_left} more today.` : ''}`);
  }
  async function submit() {
    setErr(null);
    const name = typed.replace(/\s+/g, ' ').trim();
    if (name.length < 2) { setErr('Type your full name.'); return; }
    const png = mode === 'type' ? typedPng(name) : drawn;
    if (!png) { setErr('Draw your signature, or choose to type it.'); return; }
    setBusy('sign');
    const r = await edge<any>('practice', { action: 'sign_submit', token, typed_name: name, signature_png: png, code: code.replace(/\s/g, '') });
    setBusy(null);
    if (r?.ok === false) {
      setErr(`${r.error || 'The letter could not be signed just now.'}${r.tries_left ? ` ${r.tries_left} tries left for this code.` : ''}`);
      return;
    }
    setDone({ doc_url: r?.doc_url ?? null });
  }

  const wl = open?.white_label !== false;
  return (
    <div className="sign-wrap">
      <div className="sign-card stack" style={{ gap: 16 }}>
        {!open ? <div className="row" style={{ justifyContent: 'center', padding: 32 }}><Spinner /></div> : !open.ok ? (
          <Alert kind="amber" icon="alert"><span role="alert">{open.error || 'This link cannot be used now.'}</span></Alert>
        ) : done || open.status === 'completed' ? (
          <div className="stack" style={{ gap: 12 }} data-testid="sign-done">
            <h1 style={{ fontSize: 22, margin: 0 }}>Thank you, the letter is signed</h1>
            <p className="muted" style={{ margin: 0 }}>{open.firm_name} has the signed letter with its completion certificate.</p>
            {(done?.doc_url || open.doc_url) && <a className="btn btn-primary" href={(done?.doc_url || open.doc_url)!} target="_blank" rel="noopener noreferrer">Download the signed letter</a>}
            <p className="faint" style={{ fontSize: 12, margin: 0 }}>The download link works for five minutes. Open this page again for a new one.</p>
          </div>
        ) : (
          <>
            <div>
              <div className="muted" style={{ fontSize: 13 }} data-testid="sign-firm">{open.firm_name} asks you to sign</div>
              <h1 style={{ fontSize: 22, margin: '4px 0 0' }}>{open.title}</h1>
            </div>
            <div className="stack" style={{ gap: 8 }}>
              <a className="btn btn-secondary" href={open.doc_url || '#'} target="_blank" rel="noopener noreferrer" data-testid="sign-doc"
                aria-disabled={!open.doc_url} onClick={(e) => { if (!open.doc_url) e.preventDefault(); }}>Read the letter (PDF)</a>
              <label className="row" style={{ gap: 10, minHeight: 44 }}>
                <input type="checkbox" checked={read} onChange={(e) => setRead(e.target.checked)} data-testid="sign-read" />
                <span>I have read the letter and agree to its terms for the client.</span>
              </label>
            </div>
            <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} disabled={!read}>
              <legend style={{ fontWeight: 600, marginBottom: 6 }}>Your signature</legend>
              <label className="stack" style={{ gap: 4 }}>
                <span>Your full name</span>
                <input className="input" value={typed} maxLength={120} autoComplete="name" onChange={(e) => setTyped(e.target.value)} data-testid="sign-typed" />
              </label>
              <div className="row" role="radiogroup" aria-label="How to sign" style={{ gap: 8 }}>
                <button type="button" role="radio" aria-checked={mode === 'type'} className={'btn ' + (mode === 'type' ? 'btn-primary' : 'btn-secondary')} onClick={() => setMode('type')} data-testid="sign-mode-type">Type it</button>
                <button type="button" role="radio" aria-checked={mode === 'draw'} className={'btn ' + (mode === 'draw' ? 'btn-primary' : 'btn-secondary')} onClick={() => setMode('draw')} data-testid="sign-mode-draw">Draw it</button>
              </div>
              {mode === 'type' ? (
                <div className="sign-pad" style={{ display: 'grid', placeItems: 'center', fontFamily: '"Segoe Script","Brush Script MT","Snell Roundhand",cursive', fontStyle: 'italic', fontSize: 34, color: '#111827', overflow: 'hidden' }}>
                  {typed.trim() || 'Your name'}
                </div>
              ) : <Pad onChange={setDrawn} />}
            </fieldset>
            <fieldset className="stack" style={{ gap: 10, border: 0, padding: 0, margin: 0 }} disabled={!read}>
              <legend style={{ fontWeight: 600, marginBottom: 6 }}>Confirm it is you</legend>
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <button type="button" className="btn btn-secondary" disabled={busy === 'code'} onClick={sendCode} data-testid="sign-send-code">
                  {busy === 'code' ? <Spinner small /> : null}{codeSent ? 'Send another code' : 'Email me a code'}
                </button>
                <input className="input sign-code" inputMode="numeric" autoComplete="one-time-code" maxLength={7} placeholder="000000" aria-label="6-digit code"
                  value={code} onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))} data-testid="sign-code" />
              </div>
              {codeSent && <p className="muted" style={{ margin: 0, fontSize: 13 }} role="status">{codeSent}</p>}
            </fieldset>
            {err && <Alert kind="red" icon="alert"><span role="alert">{err}</span></Alert>}
            <button className="btn btn-primary" disabled={!read || busy === 'sign' || code.replace(/\s/g, '').length !== 6} onClick={submit} data-testid="sign-submit">
              {busy === 'sign' ? <Spinner small /> : null}Sign the letter
            </button>
          </>
        )}
      </div>
      {open && !wl && <div className="faint" data-testid="sign-powered-by" style={{ fontSize: 11, textAlign: 'center', marginTop: 24 }}>Powered by Counta · TaxStreem</div>}
    </div>
  );
}
