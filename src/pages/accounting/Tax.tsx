// Tax returns, a section of its own: VAT by month, withholding tax and withholding VAT by month and tax authority, and
// income tax by accounting year: companies income tax for a company (2023 accounts onwards, filed on Rev360 through
// TaxStreem Flux), personal income tax for a business name or partnership (2025 accounts onwards, filed with the states),
// and an NGO's exemption.
import { Navigate, useSearchParams } from 'react-router-dom';
import { useInventory } from '../../state/session';
import { incomeTaxKind } from '../../lib/tax';
import CitTab from './tax/CitTab';
import PitTab from './tax/PitTab';
import VatTab from './tax/VatTab';
import WhtTab from './tax/WhtTab';

export type TaxTab = 'cit' | 'pit' | 'vat' | 'wht';

export default function Tax({ tab }: { tab: TaxTab }) {
  const { data: inv } = useInventory();
  const [params, setParams] = useSearchParams();
  const year = Number(params.get('year')) || null;
  const setYear = (y: number) => {
    const next = new URLSearchParams(params);
    next.set('year', String(y));
    setParams(next, { replace: true });
  };
  if (!inv) return null;
  // Income tax follows what the business is: the wrong one for it sends the person to the right one.
  const kind = incomeTaxKind(inv.org as any);
  const q = params.toString() ? `?${params.toString()}` : '';
  if (tab === 'cit' && kind !== 'cit') return <Navigate to={`/tax/pit${q}`} replace />;
  if (tab === 'pit' && kind === 'cit') return <Navigate to={`/tax/cit${q}`} replace />;
  return (
    <div className="container stack" style={{ gap: 16 }}>
      {tab === 'cit' && <CitTab year={year} setYear={setYear} />}
      {tab === 'pit' && <PitTab year={year} setYear={setYear} />}
      {tab === 'vat' && <VatTab />}
      {tab === 'wht' && <WhtTab />}
    </div>
  );
}
