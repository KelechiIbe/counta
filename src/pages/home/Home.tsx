// Home: the day's numbers from the books, what needs a person, and shortcuts into the work.
import { Link, useNavigate } from 'react-router-dom';
import { can, useInventory } from '../../state/session';
import { useInbox, useOverview, useSales } from '../../lib/api';
import { K, N2, fmtDay, kpiFont, when } from '../../lib/format';
import { useNeedsAction } from '../../shell/needsAction';
import { Icon } from '../../components/Icon';
import { Empty, SkeletonRows } from '../../components/ui';
import { StatusChip } from '../sell/common';

export default function Home() {
  const { data: inv } = useInventory();
  const nav = useNavigate();
  const money = can(inv, 'keep_books') || can(inv, 'make_payments') || can(inv, 'see_margins');
  const ov = useOverview(money);
  const inbox = useInbox(money);
  const sales = useSales({ limit: 8 });
  const { rows } = useNeedsAction();
  if (!inv) return null;
  const o = ov.data || {};
  const ib = inbox.data;
  const first = inv.me.display_name.split(' ')[0];
  const hour = Number(new Date().toLocaleString('en-GB', { hour: '2-digit', hour12: false, timeZone: 'Africa/Lagos' }));
  const actions = [
    ...(ib?.questions?.length ? [{ key: 'q', t: `${ib.questions.length} question${ib.questions.length === 1 ? '' : 's'} from Atlas`, d: 'Bank lines it was not sure about. Each answer can teach it a rule.', to: '/accounting/inbox', icon: 'sparkles', color: '#7C3AED', bg: '#F5F3FF', cta: 'Answer' }] : []),
    ...(Number(ib?.payments_to_confirm) ? [{ key: 'p', t: `${ib.payments_to_confirm} payment${Number(ib.payments_to_confirm) === 1 ? '' : 's'} to confirm`, d: 'Transfers and POS taken at the till or on invoices.', to: '/sell/sales?tab=confirm', icon: 'card', color: '#0072F5', bg: '#F0F7FF', cta: 'Confirm' }] : []),
    ...(Number(ib?.bills_to_approve) ? [{ key: 'b', t: `${ib.bills_to_approve} bill${Number(ib.bills_to_approve) === 1 ? '' : 's'} to approve`, d: 'From stock receipts, Prism or typed in.', to: '/purchases/bills', icon: 'file', color: '#C2410C', bg: '#FFF7ED', cta: 'Review' }] : []),
    ...(Number(ib?.payouts_to_approve) ? [{ key: 'po', t: `${ib.payouts_to_approve} payout${Number(ib.payouts_to_approve) === 1 ? '' : 's'} to approve`, d: 'Above the amount that needs a second person.', to: '/payments', icon: 'send', color: '#DC2626', bg: '#FEF2F2', cta: 'Approve' }] : []),
    ...rows.map((r) => ({ key: r.key, t: r.t, d: r.d, to: r.to, icon: r.icon, color: r.color, bg: r.bg, cta: r.cta })),
  ];
  const tiles: [string, string, string, string?][] = [
    ['Sales this month', N2(o.revenue_mtd), '/accounting/cfo', o.revenue_last_month != null ? `${K(o.revenue_last_month)} last month` : undefined],
    ['Profit this month', N2(o.profit_mtd), '/accounting/statements', o.gross_profit_mtd != null ? `gross profit ${K(o.gross_profit_mtd)}` : undefined],
    ['Cash and bank', N2(o.cash), '/accounting/banking', o.runway_months != null ? (Number(o.runway_months) > 0 ? `${o.runway_months} months at this rate` : 'Spending more than coming in') : undefined],
    ['Customers owe', N2(o.receivables), '/sell/customers', Number(o.receivables_overdue) ? `${K(o.receivables_overdue)} overdue` : 'none overdue'],
    ['We owe suppliers', N2(o.payables), '/purchases/bills', o.bills_to_pay ? `${o.bills_to_pay} bills to pay` : undefined],
    Number(o.vat_payable) >= 0 ? ['VAT to pay', N2(o.vat_payable), '/accounting/ledgers', 'due by the 21st of next month']
      : ['VAT credit', N2(-o.vat_payable), '/accounting/ledgers', 'input VAT to carry forward'],
  ];
  return (
    <div className="container">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}>
        <div><div style={{ fontSize: 22, fontWeight: 600 }}>Good {hour < 12 ? 'morning' : hour < 17 ? 'afternoon' : 'evening'}, {first}</div>
          <div className="muted" style={{ fontSize: 13 }}>{inv.org.name}{o.closed_through ? ` · books closed to ${fmtDay(o.closed_through)}` : ''}</div></div>
        <div className="row wrap">
          {can(inv, 'record_sales') && <button className="btn btn-primary btn-sm" onClick={() => nav('/sell/till')}><Icon name="receipt" size={14} color="#fff" />Sell</button>}
          {can(inv, 'record_sales') && <button className="btn btn-secondary btn-sm" onClick={() => nav('/sell/sales')}><Icon name="file" size={14} />Invoice</button>}
          {(can(inv, 'keep_books') || can(inv, 'approve_pos')) && <button className="btn btn-secondary btn-sm" onClick={() => nav('/purchases/bills')}><Icon name="paperclip" size={14} />Bill</button>}
          {can(inv, 'keep_books') && <button className="btn btn-secondary btn-sm" onClick={() => nav('/accounting/banking')}><Icon name="upload" size={14} />Bank statement</button>}
        </div>
      </div>
      {money && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(210px,1fr))', gap: 12 }}>
          {ov.isLoading ? <SkeletonRows n={3} /> : tiles.map(([l, v, to, s]) => (
            <Link key={l} to={to} className="card card-pad entry-card" style={{ color: 'inherit' }}>
              <div className="label">{l}</div><div className="num kpi-val" title={v} style={{ fontSize: kpiFont(v) }}>{v}</div>{s && <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>{s}</div>}
            </Link>
          ))}
        </div>
      )}
      <div className="m-stack" style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1.2fr) minmax(0,1fr)', gap: 16, alignItems: 'start' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>Needs you</b><span className="faint" style={{ fontSize: 12 }}>{actions.length ? `${actions.length} thing${actions.length === 1 ? '' : 's'}` : 'All clear'}</span></div>
          {!actions.length ? <div style={{ padding: 20 }}><Empty>Nothing waiting. Atlas keeps the books; it asks here when it needs you.</Empty></div> : actions.map((a) => (
            <Link key={a.key} to={a.to} className="tr click" style={{ gridTemplateColumns: '36px minmax(0,1fr) auto', color: 'inherit' }}>
              <span style={{ width: 32, height: 32, borderRadius: 8, background: a.bg, display: 'grid', placeItems: 'center' }}><Icon name={a.icon} size={16} color={a.color} /></span>
              <span style={{ minWidth: 0 }}><b>{a.t}</b><span className="faint ellipsis" style={{ display: 'block', fontSize: 12 }}>{a.d}</span></span>
              <span className="btn btn-secondary btn-xs">{a.cta}</span>
            </Link>
          ))}
        </div>
        <div className="card" style={{ overflow: 'hidden' }}>
          <div className="card-hd"><b>Latest sales</b><Link to="/sell/sales" className="btn btn-ghost btn-xs">All</Link></div>
          {sales.isLoading ? <SkeletonRows n={4} /> : !(sales.data?.rows || []).length ? <div style={{ padding: 20 }}><Empty>No sales yet. Open the till to start.</Empty></div> : sales.data!.rows.map((s) => (
            <Link key={s.id} to={`/sell/sales?open=${s.id}`} className="tr click" style={{ gridTemplateColumns: 'minmax(0,1fr) auto', color: 'inherit' }}>
              <span style={{ minWidth: 0 }}><b>{s.number}</b> <span className="muted">{s.customer_name}</span><span className="faint" style={{ display: 'block', fontSize: 11 }}>{when(s.created_at)}</span></span>
              <span className="row" style={{ gap: 8 }}><StatusChip s={s.status} /><b className="num">{N2(s.total)}</b></span>
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}
