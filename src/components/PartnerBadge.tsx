// "Counta Partner · Gold": the tier an accountant's practice has reached, shown wherever businesses see it.
import { Icon } from './Icon';
import { tierTone } from '../lib/partners';

export function PartnerBadge({ tier, small }: { tier: { code: string; name: string }; small?: boolean }) {
  const t = tierTone(tier.code);
  return (
    <span className="chip" data-testid="partner-badge" style={{ background: t.bg, color: t.fg, boxShadow: `inset 0 0 0 1px ${t.ring}`, gap: 4, fontSize: small ? 11 : 12, whiteSpace: 'nowrap' }}>
      <Icon name="award" size={small ? 12 : 13} color={t.fg} />Counta Partner · {tier.name}
    </span>
  );
}
