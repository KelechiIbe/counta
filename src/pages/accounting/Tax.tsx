// Tax returns: companies income tax by accounting year (2023 accounts onwards, filed on Rev360 through TaxStreem Flux), VAT
// by month, and withholding tax and withholding VAT by month and tax authority.
import { useSearchParams } from 'react-router-dom';
import { useInventory } from '../../state/session';
import { Pills } from '../../components/ui';
import CitTab from './tax/CitTab';
import VatTab from './tax/VatTab';
import WhtTab from './tax/WhtTab';

type Tab = 'cit' | 'vat' | 'wht';

export default function Tax() {
  const { data: inv } = useInventory();
  const [params, setParams] = useSearchParams();
  const tab = (['cit', 'vat', 'wht'].includes(params.get('tab') || '') ? params.get('tab') : 'cit') as Tab;
  const year = Number(params.get('year')) || null;
  const set = (p: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(p)) { if (v == null) next.delete(k); else next.set(k, v); }
    setParams(next, { replace: true });
  };
  if (!inv) return null;
  return (
    <div className="container stack" style={{ gap: 16 }}>
      <Pills value={tab} onChange={(t) => set({ tab: t === 'cit' ? null : t })}
        options={[{ id: 'cit', label: 'Companies income tax' }, { id: 'vat', label: 'VAT' }, { id: 'wht', label: 'Withholding' }]} />
      {tab === 'cit' && <CitTab year={year} setYear={(y) => set({ year: String(y) })} />}
      {tab === 'vat' && <VatTab />}
      {tab === 'wht' && <WhtTab />}
    </div>
  );
}
