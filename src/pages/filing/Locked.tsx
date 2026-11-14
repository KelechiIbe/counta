// What a screen shows instead of a filing-only business's books or return before the year is paid for.
import { Link } from 'react-router-dom';
import { Alert } from '../../components/ui';

export function FilingLocked({ message }: { message?: string | null }) {
  return (
    <Alert kind="blue" icon="lock">
      <span data-testid="filing-locked">{message || 'Pay the filing fee on the Filing page to see the books and the return.'}</span>{' '}
      <Link to="/filing">Go to Filing</Link>
    </Alert>
  );
}
