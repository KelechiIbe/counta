// The guide across the app: a launcher, then a small panel with Martina's orb, what was said, a box to type in and the
// controls. Also the confetti and the voice chooser the guide can open from anywhere.
import { useEffect, useRef, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useSession } from '../state/session';
import { useGuide } from '../lib/onboard';
import { Icon } from '../components/Icon';
import { Spinner } from '../components/ui';
import { useGuideTalk } from './GuideProvider';
import { VoicePickerModal } from './VoicePicker';
import './guide.css';

// The orb grows with the voice: Martina's when she speaks, the person's while she listens.
export function Orb({ size = 56, live = false }: { size?: number; live?: boolean }) {
  const g = useGuideTalk();
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!live) return;
    let raf = 0, smooth = 0;
    const tick = () => {
      const v = g.volumes();
      const level = g.speaking ? v.output : v.input * 0.7;
      smooth = smooth * 0.8 + Math.min(1, level * 1.6) * 0.2;
      if (ref.current) ref.current.style.transform = `scale(${1 + smooth * 0.22})`;
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [live, g]);
  const cls = !live ? 'idle off' : g.speaking ? 'speaking' : 'idle';
  return (
    <div className={'g-orb ' + cls} style={{ width: size, height: size }} aria-hidden>
      <span className="ring" /><span className="ring r2" />
      <div ref={ref} className="core" style={{ transition: 'transform .08s linear' }} />
    </div>
  );
}

// Light confetti: a burst of paper in TaxStreem colours, drawn on a canvas for two seconds.
export function Confetti({ fire }: { fire: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (!fire || !ref.current) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const c = ref.current, ctx = c.getContext('2d');
    if (!ctx) return;
    c.width = window.innerWidth; c.height = window.innerHeight;
    const colours = ['#0072F5', '#3E88FF', '#22C55E', '#F59E0B', '#7C3AED', '#EF4444'];
    const bits = Array.from({ length: 140 }, () => ({
      x: c.width / 2 + (Math.random() - 0.5) * 160, y: c.height * 0.38, vx: (Math.random() - 0.5) * 15, vy: -Math.random() * 15 - 4,
      r: Math.random() * Math.PI, vr: (Math.random() - 0.5) * 0.3, w: 6 + Math.random() * 6, h: 8 + Math.random() * 8, col: colours[Math.floor(Math.random() * colours.length)],
    }));
    const t0 = performance.now();
    let raf = 0;
    const draw = (t: number) => {
      ctx.clearRect(0, 0, c.width, c.height);
      for (const b of bits) {
        b.vy += 0.38; b.vx *= 0.99; b.x += b.vx; b.y += b.vy; b.r += b.vr;
        ctx.save(); ctx.translate(b.x, b.y); ctx.rotate(b.r); ctx.fillStyle = b.col; ctx.globalAlpha = Math.max(0, 1 - (t - t0) / 2400);
        ctx.fillRect(-b.w / 2, -b.h / 2, b.w, b.h); ctx.restore();
      }
      if (t - t0 < 2400) raf = requestAnimationFrame(draw); else ctx.clearRect(0, 0, c.width, c.height);
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, [fire]);
  return <canvas ref={ref} className="g-confetti" />;
}

const HIDDEN = /^\/(p|shop|sso|login|signup|reset|update-password|join|review)(\/|$)/;

export function GuideDock() {
  const g = useGuideTalk();
  const { session, orgId } = useSession();
  const loc = useLocation();
  const guide = useGuide(Boolean(session), loc.pathname.startsWith('/onboarding') ? null : orgId);
  const [text, setText] = useState('');
  const body = useRef<HTMLDivElement>(null);
  useEffect(() => { body.current?.scrollTo({ top: body.current.scrollHeight, behavior: 'smooth' }); }, [g.lines.length]);
  // The phone app and the Martina page show the conversation themselves.
  // On the phone app the launcher stays out of the way; a conversation already going shows everywhere but the chat screen.
  const phone = /^\/m(\/|$)/.test(loc.pathname);
  const hidden = !session || HIDDEN.test(loc.pathname) || (phone && (g.status === 'idle' || loc.pathname.startsWith('/m/chat')))
    || (loc.pathname === '/assistant' && g.agent === 'assistant');
  const gs = guide.data;
  // For the owner of a business set up in the last 30 days that is still getting going, the launcher picks up the setup
  // (Home's checklist has its own button for it). Everyone else, and every other page, gets Martina the assistant.
  const recent = gs?.org?.created_at ? Date.now() - Date.parse(gs.org.created_at) < 30 * 86400_000 : false;
  const setup = !!(gs && !gs.completed && !gs.dismissed && gs.org?.is_owner && recent);
  // Home's checklist and the onboarding page start the setup guide themselves, and the Martina page is the conversation.
  const where = loc.pathname.startsWith('/onboarding') || loc.pathname === '/assistant' || !orgId ? 'none'
    : setup && loc.pathname !== '/home' ? 'guide' : 'assistant';
  const offer = !hidden && g.status === 'idle' && where !== 'none';
  // While a drawer or a dialog is open, the panel moves to the left so it never covers their buttons.
  const [overlay, setOverlay] = useState(false);
  useEffect(() => {
    if (g.status === 'idle') return;
    const t = window.setInterval(() => setOverlay(Boolean(document.querySelector('.drawer, .modal-wrap:not(.g-own)'))), 500);
    return () => window.clearInterval(t);
  }, [g.status]);
  const extras = <><Confetti fire={g.confetti} />{g.voicePicker && <VoicePickerModal onClose={() => g.setVoicePicker(false)} />}</>;
  if (hidden) return extras;
  if (g.status === 'idle') {
    return (
      <>
        {extras}
        {offer && (where === 'guide' ? (
          <button className="g-launch" onClick={() => g.start({ agent: 'guide' })} aria-label="Talk to Martina, your Counta guide">
            <Orb size={34} />
            <span>Talk to Martina<span className="faint" style={{ display: 'block', fontSize: 11, fontWeight: 500 }}>{gs!.done} of {gs!.total} done · your guide</span></span>
          </button>
        ) : (
          <div className="g-launch g-launch-2" role="group" aria-label="Martina">
            <button className="g-launch-main" onClick={() => g.start({ agent: 'assistant' })} aria-label="Talk to Martina">
              <Orb size={34} /><span>Ask Martina<span className="faint" style={{ display: 'block', fontSize: 11, fontWeight: 500 }}>talk or type</span></span>
            </button>
            <button className="g-launch-type" onClick={() => g.start({ agent: 'assistant', text: true })} aria-label="Type to Martina" title="Type instead"><Icon name="chat" size={16} /></button>
          </div>
        ))}
      </>
    );
  }
  // On a phone an open drawer or dialog keeps the whole screen; Martina waits as the small orb.
  if (g.minimized || (overlay && window.innerWidth < 700)) {
    return <>{extras}<button className={'g-mini' + (overlay ? ' left' : '')} onClick={() => g.setMinimized(false)} aria-label="Open Martina"><Orb size={62} live={g.status === 'live'} /></button></>;
  }
  const last = g.lines.slice(-6);
  return (
    <>
      {extras}
      <div className={'g-dock' + (overlay ? ' left' : '')} role="dialog" aria-label="Martina, your Counta guide">
        <div className="g-dock-hd">
          <Orb size={38} live={g.status === 'live'} />
          <div className="grow" style={{ minWidth: 0 }}>
            <b style={{ fontSize: 15 }}>Martina<span className="faint" style={{ fontWeight: 500, fontSize: 12 }}>{g.agent === 'guide' ? ' · setting up' : ''}</span></b>
            <div className="row" style={{ gap: 6, fontSize: 12, color: 'var(--muted)' }}>
              <span className={'g-dot' + (g.status === 'live' ? '' : ' wait')} />
              {g.status === 'connecting' ? 'Connecting…' : g.status === 'ending' ? 'Saying bye…' : g.textOnly ? 'Typing' : g.speaking ? 'Speaking' : g.muted ? 'Muted' : 'Listening'}
            </div>
          </div>
          <button className="icon-btn" onClick={() => g.setMinimized(true)} aria-label="Make smaller" title="Make smaller"><Icon name="minus" size={16} /></button>
          <button className="icon-btn" onClick={() => g.end()} aria-label="End the conversation" title="End"><Icon name="x" size={16} /></button>
        </div>
        <div className="g-dock-body" ref={body} aria-live="polite">
          {g.status === 'connecting' && <div className="row" style={{ gap: 8, color: 'var(--muted)', fontSize: 14 }}><Spinner small />Getting Martina…</div>}
          {g.error && <div className="g-line agent" style={{ background: '#FFF7ED' }}>{g.error}</div>}
          {last.map((l) => <div key={l.at + l.role} className={'g-line ' + l.role}>{l.text}</div>)}
          {g.status === 'live' && g.speaking && !last.length && <div className="g-typing"><span /><span /><span /></div>}
        </div>
        <form className="g-dock-ft" onSubmit={(e) => { e.preventDefault(); g.send(text); setText(''); }}>
          {!g.textOnly && (
            <button type="button" className="icon-btn" onClick={g.toggleMute} aria-label={g.muted ? 'Unmute the microphone' : 'Mute the microphone'}
              title={g.muted ? 'Unmute' : 'Mute'} style={{ background: g.muted ? 'var(--red-bg)' : undefined }}>
              <Icon name="mic" size={16} color={g.muted ? 'var(--red)' : undefined} />
            </button>
          )}
          <input className="input input-sm grow" value={text} onChange={(e) => setText(e.target.value)} placeholder={g.textOnly ? 'Type to Martina…' : 'Or type here…'}
            aria-label="Message to Martina" disabled={g.status !== 'live'} />
          <button className="btn btn-primary btn-sm" disabled={!text.trim() || g.status !== 'live'} aria-label="Send"><Icon name="send" size={14} color="#fff" /></button>
        </form>
      </div>
    </>
  );
}
