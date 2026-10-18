// Where something is in Nigeria: a state, then one of its local government areas, as the NRS VAT return lists them.
// Used for branches and customers (the place of consumption on the VAT return).
import { useNgPlaces, useNrsLabels } from '../lib/tax';
import { Field } from './ui';

export function StateLga({ state, lga, onChange, required, compact }: {
  state: string; lga: string; onChange: (state: string, lga: string) => void; required?: boolean; compact?: boolean;
}) {
  const places = useNgPlaces();
  const states = places.data?.states || [];
  const lgas = (state && places.data?.lgas?.[state]) || [];
  const known = !state || states.includes(state);
  const stateSel = (
    <select className={'input' + (compact ? ' input-sm' : '')} style={compact ? { width: 170 } : undefined} value={known ? state : ''} aria-label="State" onChange={(e) => onChange(e.target.value, '')}>
      <option value="">{known ? 'Choose the state' : `${state} (choose from the list)`}</option>
      {states.map((s) => <option key={s} value={s}>{s === 'FCT' ? 'FCT (Abuja)' : s}</option>)}
    </select>
  );
  const lgaSel = (
    <select className={'input' + (compact ? ' input-sm' : '')} style={compact ? { width: 210 } : undefined} value={lga} aria-label="Local government area" disabled={!state || !known} onChange={(e) => onChange(state, e.target.value)}>
      <option value="">{state ? 'Choose the LGA' : 'Choose the state first'}</option>
      {lgas.map((l) => <option key={l} value={l}>{l}</option>)}
    </select>
  );
  if (compact) return <div className="row" style={{ gap: 6, flexWrap: 'wrap', maxWidth: '100%' }}>{stateSel}{lgaSel}</div>;
  return (
    <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
      <Field label="State" req={required}>{stateSel}</Field>
      <Field label="Local government area" hint="For the place of consumption on the VAT return.">{lgaSel}</Field>
    </div>
  );
}

// The NRS description of a zero-rated or exempt supply.
export function NrsLabelSelect({ treatment, value, onChange, compact }: { treatment: 'zero' | 'exempt'; value: string; onChange: (v: string) => void; compact?: boolean }) {
  const labels = (useNrsLabels().data || []).filter((l) => l.treatment === treatment);
  return (
    <select className={'input' + (compact ? ' input-sm' : '')} value={value} aria-label="NRS description" onChange={(e) => onChange(e.target.value)} style={{ maxWidth: '100%' }}>
      <option value="">Choose the NRS description</option>
      {labels.map((l) => <option key={l.label} value={l.label} title={l.label}>{l.label.trim().replace(/;$/, '').replace(/\s{2,}/g, ' ')}</option>)}
    </select>
  );
}
