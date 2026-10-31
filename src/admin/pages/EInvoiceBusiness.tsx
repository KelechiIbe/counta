// A business's e-invoicing as TaxStreem's admins see it: whether it has started, which of its own keys are saved (never
// what they are), its last NRS test, and the switch that runs it on TaxStreem's provider keys while NRS is in test mode.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { rpc } from '../../lib/supabase';
import { when } from '../../lib/format';
import { useToast } from '../../state/session';
import { Alert, SkeletonRows } from '../../components/ui';
import { tidyError } from '../api';
import { Card } from '../ui';

type AdminEinv = {
  started: boolean; enabled: boolean; enabled_at: string | null; platform_keys: boolean; platform_keys_note: string | null;
  own: { business_id: boolean; service_id: boolean; api_key: boolean; api_secret: boolean; crypto_keys: boolean };
  check: { at: string; ok: boolean; note: string; current: boolean } | null; ready: boolean;
  readiness: { id: string; ok: boolean; blocking: boolean; title: string; counts?: { items: number; coded: number; waiting: number; review: number } }[];
};
const OWN: [keyof AdminEinv['own'], string][] = [['business_id', 'Business ID'], ['service_id', 'Service ID'], ['api_key', 'API key'], ['api_secret', 'API secret'], ['crypto_keys', 'crypto_keys.txt']];

export function EInvoiceBusiness({ orgId }: { orgId: string }) {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['admin-einvoice', orgId], queryFn: () => rpc<AdminEinv>('admin_einvoice_business', { p_org: orgId }) });
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const d = q.data;
  async function choose(on: boolean) {
    setBusy(true);
    try {
      await rpc('admin_einvoice_platform_keys', { p_org: orgId, p_on: on, p_note: (note ?? d?.platform_keys_note) || null });
      await qc.invalidateQueries({ queryKey: ['admin-einvoice', orgId] });
      toast(on ? 'This business now runs on TaxStreem\'s keys' : 'This business is back on its own keys');
      setNote(null);
    } catch (e) { toast(tidyError(e), 'err'); }
    setBusy(false);
  }
  const items = d?.readiness.find((r) => r.id === 'items')?.counts;
  return (
    <Card title="E-invoicing (NRS)" sub="While NRS is in test mode, a business can run on TaxStreem's provider keys, as the QA business does for the sandbox demo. In production each business uses its own. Switching either way needs a new NRS test, so e-invoicing goes off until the business passes one.">
      {q.isLoading ? <SkeletonRows n={3} /> : q.isError || !d ? <Alert kind="red" icon="alert">{tidyError(q.error) || 'Could not load.'}</Alert> : (
        <div className="stack" style={{ gap: 12, fontSize: 14 }} data-testid="admin-einv">
          <div className="row wrap" style={{ gap: 6 }}>
            <span className={'chip ' + (!d.started ? 't-grey' : d.enabled ? 't-green' : d.ready ? 't-blue' : 't-amber')}>
              {!d.started ? 'Not started' : d.enabled ? 'On' : d.ready ? 'Ready, not on' : 'Getting ready'}</span>
            {d.platform_keys && <span className="chip t-blue">On TaxStreem's keys</span>}
            {d.enabled_at && <span className="faint" style={{ fontSize: 12 }}>switched on {when(d.enabled_at)}</span>}
          </div>
          {d.started && (
            <>
              <div className="row wrap" style={{ gap: 6 }}>
                {OWN.map(([k, l]) => <span key={k} className={'chip ' + (d.own[k] ? 't-green' : 't-grey')}>{l} {d.own[k] ? 'saved' : 'missing'}</span>)}
              </div>
              <div className="muted" style={{ fontSize: 13 }}>
                {d.readiness.filter((r) => r.blocking && !r.ok).length ? `Still to do: ${d.readiness.filter((r) => r.blocking && !r.ok).map((r) => r.title.toLowerCase()).join('; ')}.` : 'Nothing required is missing.'}
                {items && items.items > 0 && ` ${items.coded} of ${items.items} items have an HS code${items.review ? `, ${items.review} to confirm` : ''}.`}
              </div>
              {d.check && <div style={{ fontSize: 13 }}><span className={'chip ' + (!d.check.current ? 't-grey' : d.check.ok ? 't-green' : 't-red')}>{d.check.ok ? 'Last test passed' : 'Last test failed'}</span>
                <span className="faint"> {when(d.check.at)}{!d.check.current && ' (keys changed since)'}</span><div className="muted" style={{ marginTop: 4, wordBreak: 'break-word' }}>{d.check.note}</div></div>}
            </>
          )}
          <div className="adm-row" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', padding: 0, border: 0 }}>
            <input className="input" style={{ height: 32, fontSize: 13 }} placeholder="Note (why), shown to admins only" maxLength={300}
              value={note ?? d.platform_keys_note ?? ''} onChange={(e) => setNote(e.target.value)} aria-label="Note on the keys switch" />
            <div className="row" style={{ gap: 4 }} role="radiogroup" aria-label="Which NRS keys this business uses">
              <button role="radio" aria-checked={!d.platform_keys} disabled={busy} className={'pill' + (!d.platform_keys ? ' on' : '')} onClick={() => d.platform_keys && choose(false)}>Its own keys</button>
              <button role="radio" aria-checked={d.platform_keys} disabled={busy} className={'pill' + (d.platform_keys ? ' on' : '')} onClick={() => !d.platform_keys && choose(true)}>TaxStreem's keys</button>
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}
