import { cloneElement, isValidElement, useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactElement, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from './Icon';
import { tone } from '../lib/domain';
import { photoUrl } from '../lib/supabase';
import { initials } from '../lib/format';

export function Chip({ label, t, style }: { label: string; t?: string; style?: CSSProperties }) {
  return <span className={'chip ' + (t || tone(label))} style={style}>{label}</span>;
}

export function Label({ children, style }: { children: ReactNode; style?: CSSProperties }) {
  return <div className="label" style={style}>{children}</div>;
}

export function Spinner({ small }: { small?: boolean }) { return <div className={'spinner' + (small ? ' spinner-sm' : '')} />; }

export function Thumb({ name, path, size = 40, radius = 8 }: { name: string; path?: string | null; size?: number; radius?: number }) {
  const url = photoUrl(path);
  return (
    <span className="thumb" style={{ width: size, height: size, borderRadius: radius, fontSize: size >= 60 ? 13 : 11 }}>
      {url ? <img src={url} alt="" loading="lazy" /> : initials(name).slice(0, 2)}
    </span>
  );
}

function useEsc(onClose: () => void) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', h); return () => window.removeEventListener('keydown', h);
  }, [onClose]);
}

export function Drawer({ onClose, width = 560, children }: { onClose: () => void; width?: number; children: ReactNode }) {
  useEsc(onClose);
  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className="drawer" style={{ width }} role="dialog" aria-modal="true">{children}</div>
    </>
  );
}

export function Modal({ onClose, width = 480, children, z, fixed }: { onClose: () => void; width?: number; children: ReactNode; z?: number; fixed?: boolean }) {
  useEsc(onClose);
  return (
    <div className="modal-wrap" style={z ? { zIndex: z } : undefined}>
      <div className="scrim dark" onClick={onClose} style={z ? { zIndex: z - 1 } : undefined} />
      <div className="modal" style={{ width, ...(fixed ? { overflow: 'hidden' } : {}) }} role="dialog" aria-modal="true">{children}</div>
    </div>
  );
}

export function XButton({ onClick, size = 18 }: { onClick: () => void; size?: number }) {
  return <button className="x-btn" onClick={onClick} aria-label="Close"><Icon name="x" size={size} color="#6B7280" /></button>;
}

export function ModalHead({ title, sub, onClose, extra }: { title: ReactNode; sub?: ReactNode; onClose: () => void; extra?: ReactNode }) {
  return (
    <div className="modal-hd">
      <div style={{ minWidth: 0 }}>
        <div className="drawer-title">{title}</div>
        {sub && <div style={{ fontSize: 13, color: '#6B7280', marginTop: 2, lineHeight: 1.45 }}>{sub}</div>}
      </div>
      <div className="row">{extra}<XButton onClick={onClose} /></div>
    </div>
  );
}

export function Field({ label, req, error, children, hint, style }: { label: ReactNode; req?: boolean; error?: string | null; children: ReactNode; hint?: ReactNode; style?: CSSProperties }) {
  // Tie the label to a lone input, select or textarea so screen readers announce it and a click on it focuses the control.
  const autoId = useId();
  let id: string | undefined;
  let body = children;
  if (isValidElement(children) && typeof children.type === 'string' && ['input', 'select', 'textarea'].includes(children.type)) {
    const props = children.props as { id?: string };
    id = props.id || autoId;
    if (!props.id) body = cloneElement(children as ReactElement<{ id?: string }>, { id });
  }
  return (
    <div style={style}>
      <label className="field-label" htmlFor={id}>{label}{req && <span className="req"> *</span>}</label>
      {body}
      {error ? <div className="err-text">{error}</div> : hint ? <div className="hint" style={{ marginTop: 6 }}>{hint}</div> : null}
    </div>
  );
}

export function Empty({ children, style }: { children: ReactNode; style?: CSSProperties }) {
  return <div className="empty" style={style}>{children}</div>;
}

export function Alert({ kind, children, icon, style }: { kind: 'red' | 'amber' | 'yellow' | 'blue' | 'green' | 'grey'; children: ReactNode; icon?: string; style?: CSSProperties }) {
  const colors: Record<string, string> = { red: '#DC2626', amber: '#C2410C', yellow: '#A16207', blue: '#0072F5', green: '#15803D', grey: '#4B5563' };
  return (
    <div className={'alert alert-' + kind} style={style}>
      {icon && <Icon name={icon} size={16} color={colors[kind]} style={{ marginTop: 1 }} />}
      <div style={{ minWidth: 0 }}>{children}</div>
    </div>
  );
}

export function Kpi({ label, value, sub, color }: { label: string; value: ReactNode; sub: ReactNode; color: string }) {
  return (
    <div className="kpi" style={{ minWidth: 0, borderLeft: '1px solid #E6E6E6', paddingLeft: 20, marginLeft: -20 }}>
      <div className="label">{label}</div>
      <div className="kpi-v" style={{ fontFamily: 'var(--font-brand)', fontSize: 30, fontWeight: 600, letterSpacing: '-.02em', color, marginTop: 8, lineHeight: 1.1 }}>{value}</div>
      <div style={{ fontSize: 12, color: '#6B7280', marginTop: 6, lineHeight: 1.4 }}>{sub}</div>
    </div>
  );
}

export function Stat({ label, value, color, sub }: { label: ReactNode; value: ReactNode; color?: string; sub?: ReactNode }) {
  return (
    <div style={{ background: '#FAFAFA', borderRadius: 12, padding: '10px 12px', minWidth: 0 }}>
      <div className="mini-label">{label}</div>
      <div style={{ fontSize: 15, fontWeight: 600, color: color || '#111827', marginTop: 4, lineHeight: 1.3 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: '#6B7280', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

export function SkeletonRows({ n = 5, h = 18 }: { n?: number; h?: number }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: 20 }}>
      {Array.from({ length: n }).map((_, i) => <div key={i} className="skel" style={{ height: h, width: `${90 - i * 7}%` }} />)}
    </div>
  );
}

export function Seg<T extends string>({ value, options, onChange }: { value: T; options: { id: T; label: string }[]; onChange: (v: T) => void }) {
  return (
    <div className="seg" role="tablist">
      {options.map((o) => (
        <button key={o.id} role="tab" aria-selected={value === o.id} className={value === o.id ? 'on' : ''} onClick={() => onChange(o.id)}>{o.label}</button>
      ))}
    </div>
  );
}

export function Pills<T extends string>({ value, options, onChange }: { value: T; options: { id: T; label: string; count?: number }[]; onChange: (v: T) => void }) {
  return (
    <div className="row wrap" style={{ gap: 6 }}>
      {options.map((o) => (
        <button key={o.id} className={'pill' + (value === o.id ? ' on' : '')} onClick={() => onChange(o.id)}>
          {o.label}{o.count != null && <span className="count">{o.count}</span>}
        </button>
      ))}
    </div>
  );
}

export function Annot({ children }: { children: ReactNode }) {
  return <span style={{ fontSize: 12, color: '#A16207', background: '#FEFCE8', borderRadius: 8, padding: '8px 10px', whiteSpace: 'nowrap', display: 'inline-block' }}>{children}</span>;
}

// A menu or flyout drawn on top of the page, next to the button that opened it, and kept inside the screen:
// it never sits under the navigation or gets cut off by a card.
export function Popover({ anchor, onClose, children, width = 210, side = 'bottom-end', label }: {
  anchor: HTMLElement | null; onClose: () => void; children: ReactNode; width?: number; side?: 'bottom-end' | 'bottom-start' | 'right-start'; label?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  const [pos, setPos] = useState<{ top: number; left: number; maxH: number } | null>(null);
  useLayoutEffect(() => {
    function place() {
      if (!anchor) return;
      const r = anchor.getBoundingClientRect();
      const vw = window.innerWidth, vh = window.innerHeight, pad = 8;
      const w = Math.min(width, vw - pad * 2);
      const h = Math.min(ref.current?.scrollHeight || 0, vh - pad * 2);
      let left = side === 'right-start' ? r.right + 6 : side === 'bottom-end' ? r.right - w : r.left;
      let top = side === 'right-start' ? r.top : r.bottom + 6;
      if (side === 'right-start' && left + w > vw - pad) { left = r.left; top = r.bottom + 6; }
      left = Math.max(pad, Math.min(left, vw - w - pad));
      if (top + h > vh - pad) {
        const above = (side === 'right-start' ? r.bottom : r.top - 6) - h;
        top = above >= pad ? above : Math.max(pad, vh - pad - h);
      }
      setPos({ top, left, maxH: vh - pad * 2 });
    }
    place();
    window.addEventListener('resize', place);
    window.addEventListener('scroll', place, true);
    return () => { window.removeEventListener('resize', place); window.removeEventListener('scroll', place, true); };
  }, [anchor, side, width]);
  useEffect(() => {
    const down = (e: Event) => {
      const t = e.target as Node;
      if (ref.current?.contains(t) || anchor?.contains(t)) return;
      close.current();
    };
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') { close.current(); anchor?.focus(); } };
    document.addEventListener('mousedown', down);
    document.addEventListener('touchstart', down, { passive: true });
    document.addEventListener('keydown', key);
    return () => { document.removeEventListener('mousedown', down); document.removeEventListener('touchstart', down); document.removeEventListener('keydown', key); };
  }, [anchor]);
  return createPortal(
    <div ref={ref} className="card popover" role="menu" aria-label={label}
      style={{ position: 'fixed', top: pos?.top ?? 0, left: pos?.left ?? 0, width: `min(${width}px, calc(100vw - 16px))`, maxHeight: pos?.maxH, overflowY: 'auto',
        zIndex: 90, padding: 6, boxShadow: 'var(--shadow-drawer)', visibility: pos ? 'visible' : 'hidden' }}>
      {children}
    </div>,
    document.body,
  );
}

export type MenuItem = { key: string; label: ReactNode; hint?: ReactNode; icon?: string; disabled?: boolean; onClick: () => void };
// A button that opens a short menu of actions.
export function MenuButton({ label, icon, items, disabled, busy, className = 'btn btn-secondary btn-sm', width = 230, title }: {
  label: ReactNode; icon?: string; items: MenuItem[]; disabled?: boolean; busy?: ReactNode; className?: string; width?: number; title?: string;
}) {
  const [btn, setBtn] = useState<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  return (
    <>
      <button ref={setBtn} className={className} disabled={disabled || !!busy} onClick={() => setOpen((o) => !o)} aria-haspopup="menu" aria-expanded={open} title={title}>
        {icon && <Icon name={icon} size={14} />}{busy || label}<Icon name="chevD" size={14} />
      </button>
      {open && (
        <Popover anchor={btn} onClose={() => setOpen(false)} width={width}>
          {items.map((it) => (
            <button key={it.key} role="menuitem" className="nav-item" disabled={it.disabled} style={{ fontSize: 14, padding: '8px 10px', alignItems: 'flex-start', opacity: it.disabled ? 0.5 : 1 }}
              onClick={() => { setOpen(false); it.onClick(); }}>
              {it.icon && <Icon name={it.icon} size={16} color="#6B7280" />}
              <span style={{ display: 'flex', flexDirection: 'column', gap: 1, minWidth: 0 }}>
                <span>{it.label}</span>
                {it.hint && <span className="faint" style={{ fontSize: 12, fontWeight: 400 }}>{it.hint}</span>}
              </span>
            </button>
          ))}
        </Popover>
      )}
    </>
  );
}
