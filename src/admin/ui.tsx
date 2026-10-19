// Small pieces the admin portal's screens share.
import type { ReactNode } from 'react';

export function PageHead({ title, sub, right }: { title: string; sub?: ReactNode; right?: ReactNode }) {
  return (
    <div className="row wrap" style={{ gap: 12, alignItems: 'flex-end', justifyContent: 'space-between' }}>
      <div style={{ minWidth: 0, flex: '1 1 320px' }}>
        <h1 style={{ fontFamily: 'var(--font-brand)', fontSize: 26, fontWeight: 600, margin: 0, letterSpacing: '-.01em' }}>{title}</h1>
        {sub && <div className="muted" style={{ fontSize: 14, marginTop: 6, lineHeight: 1.5, maxWidth: 760 }}>{sub}</div>}
      </div>
      {right}
    </div>
  );
}

export function Card({ title, sub, right, children, pad = true }: { title?: ReactNode; sub?: ReactNode; right?: ReactNode; children: ReactNode; pad?: boolean }) {
  return (
    <section className="card" style={{ overflow: 'hidden', minWidth: 0 }}>
      {(title || right) && (
        <div className="card-hd" style={{ alignItems: 'flex-start' }}>
          <div style={{ minWidth: 0, flex: '1 1 260px' }}>
            {title && <div style={{ fontWeight: 700, fontSize: 15 }}>{title}</div>}
            {sub && <div className="muted" style={{ fontSize: 13, marginTop: 4, lineHeight: 1.5 }}>{sub}</div>}
          </div>
          {right}
        </div>
      )}
      <div className={pad ? 'card-pad stack' : 'stack'} style={{ gap: 14, minWidth: 0 }}>{children}</div>
    </section>
  );
}

export function Toggle({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label: string }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} className={'tgl' + (on ? ' on' : '')} onClick={() => onChange(!on)}>
      <span />
    </button>
  );
}

export function Tile({ label, value, sub, tone, onClick }: { label: string; value: ReactNode; sub?: ReactNode; tone?: string; onClick?: () => void }) {
  return (
    <button type="button" className="card card-pad" onClick={onClick} disabled={!onClick}
      style={{ textAlign: 'left', cursor: onClick ? 'pointer' : 'default', background: '#fff', display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
      <span className="mini-label">{label}</span>
      <span className="num" style={{ fontSize: 26, fontWeight: 700, color: tone || 'var(--ink)' }}>{value}</span>
      {sub && <span className="faint" style={{ fontSize: 12, lineHeight: 1.4 }}>{sub}</span>}
    </button>
  );
}

export const grid = (min: number) => ({ display: 'grid', gridTemplateColumns: `repeat(auto-fit, minmax(min(${min}px, 100%), 1fr))`, gap: 12 });
