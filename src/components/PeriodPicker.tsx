// One control for choosing a period on any data screen: a button showing the period, opening ready-made choices and
// two dates. Compact on phones; the screen remembers the choice (see lib/period).
import { useState } from 'react';
import { useInventory } from '../state/session';
import { Icon } from './Icon';
import { Popover } from './ui';
import { BOOKS_FLOOR, PRESET_ORDER, periodText, presetLabel, presetRange, type PeriodValue, type PresetId } from '../lib/period';

export function PeriodPicker({ value, onChange, presets = PRESET_ORDER, label = 'Period', align = 'start' }: {
  value: PeriodValue; onChange: (v: PeriodValue) => void; presets?: PresetId[]; label?: string; align?: 'start' | 'end';
}) {
  const { data: inv } = useInventory();
  const fy = inv?.org.fiscal_year_start || 1;
  const [at, setAt] = useState<HTMLButtonElement | null>(null);
  const [from, setFrom] = useState(value.from);
  const [to, setTo] = useState(value.to);
  const text = periodText(value, fy);
  const open = (el: HTMLButtonElement) => { setFrom(value.preset === 'all' ? BOOKS_FLOOR : value.from); setTo(value.to); setAt(el); };
  const pick = (p: PresetId) => { onChange({ ...presetRange(p, fy), preset: p }); setAt(null); };
  const bad = !from || !to || from > to;
  const apply = () => { if (bad) return; onChange({ from, to, preset: null }); setAt(null); };
  return (
    <>
      <button type="button" className="btn btn-secondary btn-sm period-btn" aria-haspopup="dialog" aria-expanded={!!at} aria-label={`${label}: ${text}`}
        onClick={(e) => (at ? setAt(null) : open(e.currentTarget))}>
        <Icon name="cal" size={14} /><span className="ellipsis">{text}</span><Icon name="chevron" size={14} color="#9CA3AF" />
      </button>
      {at && (
        <Popover anchor={at} onClose={() => setAt(null)} side={align === 'end' ? 'bottom-end' : 'bottom-start'} width={300} label={label}>
          <div className="period-pop" role="dialog" aria-label={label}>
            <div className="period-presets">
              {presets.map((p) => (
                <button key={p} type="button" className={'period-preset' + (value.preset === p ? ' on' : '')} aria-pressed={value.preset === p} onClick={() => pick(p)}>
                  {presetLabel(p, fy)}{value.preset === p && <Icon name="check" size={14} color="#0072F5" />}
                </button>
              ))}
            </div>
            <div className="period-custom">
              <div className="mini-label">Choose dates</div>
              <div className="row" style={{ gap: 6, flexWrap: 'nowrap' }}>
                <input className="input input-sm" type="date" value={from} max={to || undefined} onChange={(e) => setFrom(e.target.value)} aria-label="From" />
                <span className="faint">to</span>
                <input className="input input-sm" type="date" value={to} min={from || undefined} onChange={(e) => setTo(e.target.value)} aria-label="To" />
              </div>
              {from && to && from > to && <div className="faint" style={{ fontSize: 12, color: '#DC2626' }}>The start comes after the end.</div>}
              <button type="button" className="btn btn-primary btn-sm" disabled={bad} onClick={apply}>Show these dates</button>
            </div>
          </div>
        </Popover>
      )}
    </>
  );
}
