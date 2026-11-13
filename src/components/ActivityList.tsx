// A business's activity log as a list, newest first, with a button for the page before. Used by the accountant portal (a
// client the firm runs) and by the business itself (Settings, Your accountant).
import type { InfiniteData, UseInfiniteQueryResult } from '@tanstack/react-query';
import { activityText, type ActivityPage } from '../lib/api';
import { cleanError } from '../lib/supabase';
import { when } from '../lib/format';
import { Alert, SkeletonRows, Spinner } from './ui';

export function ActivityList({ q, empty = 'Nothing has been done yet.' }: { q: UseInfiniteQueryResult<InfiniteData<ActivityPage>>; empty?: string }) {
  if (q.isLoading) return <SkeletonRows n={4} />;
  if (q.isError) return <Alert kind="red" icon="alert">{cleanError(q.error)}</Alert>;
  const rows = (q.data?.pages || []).flatMap((p) => p.rows);
  if (!rows.length) return <div className="faint" style={{ fontSize: 14 }}>{empty}</div>;
  return (
    <div className="stack" style={{ gap: 0 }}>
      <ol className="act-list">
        {rows.map((r) => (
          <li key={r.id} className="act-row" data-testid="activity-row">
            <span className="act-what">{activityText(r)}</span>
            <span className="faint act-who">{r.actor_name || 'Counta'} · <time dateTime={r.at} title={new Date(r.at).toLocaleString('en-GB', { timeZone: 'Africa/Lagos' })}>{when(r.at)}</time></span>
          </li>
        ))}
      </ol>
      {q.hasNextPage && (
        <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start', minHeight: 44, marginTop: 4 }} disabled={q.isFetchingNextPage}
          onClick={() => q.fetchNextPage()} data-testid="activity-more">
          {q.isFetchingNextPage ? <Spinner small /> : null}Show earlier entries
        </button>
      )}
    </div>
  );
}
