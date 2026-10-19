// Tax returns, a section of its own: VAT by month, withholding tax and withholding VAT by month and tax authority, and
// companies income tax by accounting year (2023 accounts onwards, filed on Rev360 through TaxStreem Flux).
import { useSearchParams } from 'react-router-dom';
import { useInventory } from '../../state/session';
import CitTab from './tax/CitTab';
import VatTab from './tax/VatTab';
import WhtTab from './tax/WhtTab';

export type TaxTab = 'cit' | 'vat' | 'wht';

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
  return (
    <div className="container stack" style={{ gap: 16 }}>
      {tab === 'cit' && <CitTab year={year} setYear={setYear} />}
      {tab === 'vat' && <VatTab />}
      {tab === 'wht' && <WhtTab />}
    </div>
  );
}
