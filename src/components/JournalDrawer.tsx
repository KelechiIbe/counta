import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { rpc, signedDoc } from '../lib/supabase';
import { useSession } from '../state/session';
import { Drawer, Spinner, XButton, Empty } from './ui';
import { Icon } from './Icon';
import { N2, fmtDay } from '../lib/format';

export default function JournalDrawer({ journalRef, onClose }: { journalRef: string; onClose: () => void }) {
  const { orgId } = useSession();
  const q = useQuery({ queryKey: ['journal', orgId, journalRef], queryFn: () => rpc<any>('get_journal', { p_journal_ref: journalRef, p_org: orgId }) });
  const [doc, setDoc] = useState<string | null>(null);
  useEffect(() => { if (q.data?.document_path) signedDoc(q.data.document_path).then(setDoc); }, [q.data?.document_path]);
  const j = q.data?.journal;
  const lines: any[] = q.data?.lines || [];
  const dr = lines.reduce((a, l) => a + Number(l.debit), 0);
  const cr = lines.reduce((a, l) => a + Number(l.credit), 0);
  const isPdf = q.data?.document_path?.toLowerCase().endsWith('.pdf');
  return (
    <Drawer onClose={onClose} width={560}>
      <div className="drawer-hd">
        <span style={{ width: 44, height: 44, borderRadius: 12, background: '#F0F7FF', display: 'grid', placeItems: 'center', flex: 'none' }}><Icon name="book" size={20} color="#0072F5" /></span>
        <div className="grow">
          <div className="drawer-title">{journalRef}</div>
          <div className="muted" style={{ fontSize: 13, marginTop: 2 }}>{j ? `${fmtDay(j.entry_date)} · ${j.memo}` : 'Loading…'}</div>
        </div>
        <XButton onClick={onClose} />
      </div>
      <div className="drawer-body" style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {q.isLoading ? <div style={{ display: 'grid', placeItems: 'center', padding: 40 }}><Spinner /></div> : q.error ? (
          <Empty>{(q.error as Error).message}</Empty>
        ) : !j ? <Empty>Journal not found.</Empty> : (
          <>
            <div className="card" style={{ overflow: 'hidden', borderRadius: 12 }}>
              <div className="tr head shade th" style={{ gridTemplateColumns: '60px 1fr 110px 110px', padding: '8px 14px' }}><span>Acct</span><span>Account</span><span className="right">Debit</span><span className="right">Credit</span></div>
              {lines.map((l, i) => (
                <div key={i} className="tr" style={{ gridTemplateColumns: '60px 1fr 110px 110px', padding: '10px 14px' }}>
                  <span className="mono ink3">{l.code}</span>
                  <span><span className="ink">{l.name}</span>{(l.location || l.memo) && <span className="faint" style={{ display: 'block', fontSize: 11 }}>{[l.location, l.memo].filter(Boolean).join(' · ')}</span>}</span>
                  <span className="right num" style={{ fontWeight: 600 }}>{Number(l.debit) ? N2(l.debit) : ''}</span>
                  <span className="right num" style={{ fontWeight: 600 }}>{Number(l.credit) ? N2(l.credit) : ''}</span>
                </div>
              ))}
              <div className="tr" style={{ gridTemplateColumns: '60px 1fr 110px 110px', padding: '10px 14px', background: '#FAFAFA' }}>
                <span /><span className="muted">Totals</span><span className="right num" style={{ fontWeight: 700 }}>{N2(dr)}</span><span className="right num" style={{ fontWeight: 700 }}>{N2(cr)}</span>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, fontSize: 13 }}>
              <div className="card" style={{ padding: 12, borderRadius: 12 }}><div className="muted">Posted by</div><div style={{ fontWeight: 600, marginTop: 2 }}>{j.posted_by_name || 'System'}</div></div>
              <div className="card" style={{ padding: 12, borderRadius: 12 }}><div className="muted">Approved by</div><div style={{ fontWeight: 600, marginTop: 2 }}>{j.approved_by_name || '—'}</div></div>
            </div>
            {q.data?.document_path && (
              <div>
                <div className="label" style={{ marginBottom: 8 }}>Source document</div>
                {!doc ? <div className="skel" style={{ height: 180 }} /> : isPdf ? (
                  <a className="btn btn-secondary btn-sm" href={doc} target="_blank" rel="noreferrer"><Icon name="file" size={16} />Open the invoice PDF</a>
                ) : (
                  <a href={doc} target="_blank" rel="noreferrer"><img src={doc} alt="Source invoice" style={{ width: '100%', borderRadius: 12, border: '1px solid #E6E6E6' }} /></a>
                )}
              </div>
            )}
            <div className="hint">Posted journals cannot be edited. Corrections post as new entries so the trail stays intact.</div>
          </>
        )}
      </div>
    </Drawer>
  );
}
