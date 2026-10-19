import { useNavigate } from 'react-router-dom';
import { num } from '../../lib/format';
import { Alert, SkeletonRows } from '../../components/ui';
import { featureLabel, GROUPS, useKeys, useOverview } from '../api';
import { Card, grid, PageHead, Tile } from '../ui';

export default function Overview() {
  const nav = useNavigate();
  const o = useOverview();
  const keys = useKeys();
  const d = o.data;
  // A service counts as set up when every secret in its group is set somewhere (here, or as an Edge Function secret).
  const groups = GROUPS.filter((g) => g.id !== 'counta').map((g) => {
    const ks = (keys.data?.keys || []).filter((k) => k.group === g.id && k.secret && !/fallback|optional/i.test(k.label));
    return { ...g, ready: ks.length > 0 && ks.every((k) => k.set || k.env) };
  });
  return (
    <>
      <PageHead title="Overview" sub="Counta across every business: who is signing up, what needs a person, and what is switched on." />
      {o.isError && <Alert kind="red" icon="alert">{(o.error as Error).message}</Alert>}
      {!d ? <SkeletonRows n={4} /> : (
        <div style={grid(190)}>
          <Tile label="Businesses" value={num(d.businesses?.total)} sub={`${num(d.businesses?.week)} new this week`} onClick={() => nav('/admin/businesses')} />
          <Tile label="People" value={num(d.people?.total)} sub={`${num(d.people?.week)} signed up this week`} onClick={() => nav('/admin/people')} />
          <Tile label="Identity reviews" value={num(d.reviews)} tone={d.reviews ? 'var(--amber)' : undefined} sub={d.reviews ? 'NIN slips waiting for a decision' : 'Nothing waiting'}
            onClick={() => nav('/admin/reviews')} />
          <Tile label="Failures, last 24 hours" value={num(d.failures_day)} tone={d.failures_day ? 'var(--red)' : undefined} sub="Messages, calls, payments and AI reads"
            onClick={() => nav('/admin/activity')} />
          <Tile label="Payments locked" value={num(d.businesses?.locked)} sub="Waiting for a director's NIN check" onClick={() => nav('/admin/businesses?filter=locked')} />
        </div>
      )}
      <Card title="Services" sub="Green when Counta has every key it needs. Open Keys and services to change one or test it."
        right={<button className="btn btn-secondary btn-sm" onClick={() => nav('/admin/keys')}>Keys and services</button>}>
        {keys.isLoading ? <SkeletonRows n={3} /> : keys.data?.ok === false ? <Alert kind="red" icon="alert">{keys.data.error}</Alert> : (
          <div className="row wrap" style={{ gap: 8 }}>
            {groups.map((g) => <span key={g.id} className={'chip ' + (g.ready ? 't-green' : 't-amber')}>{g.title} · {g.ready ? 'set up' : 'missing a key'}</span>)}
          </div>
        )}
      </Card>
      {d && (
        <Card title="Switched off" sub="Features TaxStreem has paused for everyone, and the businesses with their own setting."
          right={<button className="btn btn-secondary btn-sm" onClick={() => nav('/admin/limits')}>Limits and switches</button>}>
          {d.paused?.length ? (
            <div className="row wrap" style={{ gap: 8 }}>{d.paused.map((p) => <span key={p} className="chip t-red">{featureLabel(p)} · off for everyone</span>)}</div>
          ) : <div className="muted" style={{ fontSize: 14 }}>Everything is switched on for everyone.</div>}
          {!!d.business_overrides && <div className="faint" style={{ fontSize: 13 }}>{num(d.business_overrides)} business setting{d.business_overrides === 1 ? '' : 's'} differ from everyone else's.</div>}
        </Card>
      )}
    </>
  );
}
