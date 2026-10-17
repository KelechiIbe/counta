import { Suspense, createContext, useContext, useEffect, useMemo, useState } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from '../state/session';
import { Icon } from '../components/Icon';
import { Popover, Seg, Spinner } from '../components/ui';
import { initials } from '../lib/format';
import { useNeedsAction } from './needsAction';
import { InstallBanner } from '../components/InstallBanner';
import { store } from '../lib/pwa';
import { useInbox } from '../lib/api';

// ---------- location picker state shared by Overview, Items and Insights ----------
const LocCtx = createContext<{ loc: string; setLoc: (l: string) => void }>({ loc: 'ALL', setLoc: () => {} });
export const useLoc = () => useContext(LocCtx);

const TITLES: Record<string, string> = {
  '/home': 'Home',
  '/inventory': 'Inventory', '/inventory/items': 'Items', '/inventory/receive': 'Receive stock', '/inventory/counts': 'Stock counts',
  '/inventory/reorder': 'Reorder', '/inventory/pricing': 'Pricing', '/inventory/insights': 'Insights', '/inventory/locations': 'Locations & staff', '/inventory/reports': 'Reports',
  '/inventory/production': 'Production & jobs', '/inventory/month-end': 'Stock close', '/inventory/migrate': 'Move to Counta',
  '/sell/till': 'Till', '/sell/sales': 'Sales', '/sell/customers': 'Customers', '/sell/orders': 'Orders & deliveries', '/sell/price-lists': 'Price lists', '/sell/shop': 'Online shop',
  '/payments': 'Payments', '/purchases/bills': 'Bills', '/purchases/vendors': 'Vendors',
  '/accounting/inbox': 'Books inbox', '/accounting/banking': 'Banking & reconciliation', '/accounting/statements': 'Financial statements',
  '/accounting/ledgers': 'Ledgers & reports', '/accounting/cfo': 'CFO pack', '/accounting/assets': 'Fixed assets', '/accounting/close': 'Period close',
  '/accounting/journals': 'Journals', '/assistant': 'AI Assistant', '/settings': 'Settings',
};
export const titleFor = (path: string) => TITLES[path] || TITLES[Object.keys(TITLES).filter((k) => path.startsWith(k + '/')).sort((x, y) => y.length - x.length)[0]] || 'Counta';
const PICKER = new Set(['/inventory', '/inventory/items', '/inventory/insights']);
const MAIN_APP: string = import.meta.env.VITE_MAIN_APP_URL || 'https://app.taxstreem.com';
const SUPPORT_URL: string = import.meta.env.VITE_SUPPORT_URL || 'https://www.taxstreem.com';

type Sub = [string, string, number?];
function useMedia(q: string) {
  const [m, setM] = useState(() => typeof window !== 'undefined' && window.matchMedia(q).matches);
  useEffect(() => {
    const mq = window.matchMedia(q);
    const on = () => setM(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, [q]);
  return m;
}
function Group({ to, label, icon, subs, active, onClose, show = true, rail }: { to: string; label: string; icon: string; subs?: Sub[]; active: boolean; onClose: () => void; show?: boolean; rail?: boolean }) {
  const [fly, setFly] = useState<HTMLElement | null>(null);
  if (!show) return null;
  const count = subs?.reduce((a, x) => a + (x[2] || 0), 0) || 0;
  if (rail) {
    // Icons only: the pages of a section open in a small panel beside it.
    const hasSubs = (subs?.length || 0) > 1;
    return (
      <>
        {hasSubs ? (
          <button className={'nav-item rail-item' + (active ? ' active' : '')} title={label} aria-label={label} aria-haspopup="menu" aria-expanded={!!fly}
            onClick={(e) => setFly(fly ? null : e.currentTarget)}>
            <Icon name={icon} size={20} color={active ? '#111827' : '#6B7280'} />{count > 0 && <span className="rail-dot" />}
          </button>
        ) : (
          <NavLink to={to} className={() => 'nav-item rail-item' + (active ? ' active' : '')} title={label} aria-label={label} onClick={onClose}>
            <Icon name={icon} size={20} color={active ? '#111827' : '#6B7280'} />{count > 0 && <span className="rail-dot" />}
          </NavLink>
        )}
        {fly && subs && (
          <Popover anchor={fly} onClose={() => setFly(null)} side="right-start" width={230} label={label}>
            <div className="mini-label" style={{ padding: '6px 10px 4px' }}>{label}</div>
            <div className="nav-sub fly">
              {subs.map(([path, l, badge]) => (
                <NavLink key={path} to={path} end className={({ isActive }) => (isActive ? 'active' : '')} onClick={() => { setFly(null); onClose(); }}>
                  <span style={{ flex: 1 }}>{l}</span>
                  {(badge || 0) > 0 && <span className="nav-badge">{badge}</span>}
                </NavLink>
              ))}
            </div>
          </Popover>
        )}
      </>
    );
  }
  return (
    <>
      <NavLink to={to} className={() => 'nav-item' + (active ? ' active' : '')} onClick={onClose}>
        <Icon name={icon} size={20} color={active ? '#111827' : '#6B7280'} /><span style={{ flex: 1 }}>{label}</span>
        {!active && count > 0 && <span className="nav-badge">{count}</span>}
      </NavLink>
      {active && subs && (
        <div className="nav-sub">
          {subs.map(([path, l, badge]) => (
            <NavLink key={path} to={path} end className={({ isActive }) => (isActive ? 'active' : '')} onClick={onClose}>
              <span style={{ flex: 1 }}>{l}</span>
              {(badge || 0) > 0 && <span className="nav-badge">{badge}</span>}
            </NavLink>
          ))}
        </div>
      )}
    </>
  );
}

function Sidebar({ open, onClose, rail, onRail }: { open: boolean; onClose: () => void; rail: boolean; onRail: () => void }) {
  const { data: inv } = useInventory();
  const { memberships, orgId, setOrgId, signOut } = useSession();
  const nav = useNavigate();
  const loc = useLocation();
  const badges = useNeedsAction().badges;
  const [menu, setMenu] = useState(false);
  const populated = (inv?.items.length ?? 0) > 0;
  const current = memberships.find((m) => m.org_id === orgId);
  const p = loc.pathname;
  const money = can(inv, 'keep_books') || can(inv, 'make_payments') || can(inv, 'see_margins');
  const inbox = useInbox(money);
  const ib = inbox.data;
  const external = (label: string, icon: string) => (
    <a className={'nav-item' + (rail ? ' rail-item' : '')} href={MAIN_APP} target="_blank" rel="noreferrer" title={label + ' opens in the main TaxStreem app'} aria-label={rail ? label : undefined}>
      <Icon name={icon} size={20} color="#6B7280" />{!rail && <><span style={{ flex: 1 }}>{label}</span><Icon name="external" size={14} color="#9CA3AF" /></>}
    </a>
  );
  const link = (to: string, label: string, icon: string, extra?: () => void) => (
    <NavLink to={to} className={({ isActive }) => 'nav-item' + (rail ? ' rail-item' : '') + (isActive && to !== '/m' ? ' active' : '')} title={rail ? label : undefined} aria-label={rail ? label : undefined}
      onClick={() => { extra?.(); onClose(); }}>
      {({ isActive }) => (<><Icon name={icon} size={20} color={isActive && to !== '/m' ? '#111827' : '#6B7280'} />{!rail && <span>{label}</span>}</>)}
    </NavLink>
  );
  const invSubs: Sub[] = populated ? [
    ['/inventory', 'Overview'], ['/inventory/items', 'Items'], ['/inventory/receive', 'Receive stock', badges.receive],
    ['/inventory/counts', 'Stock counts', badges.counts], ['/inventory/reorder', 'Reorder', badges.reorder], ['/inventory/pricing', 'Pricing', badges.pricing],
    ['/inventory/production', 'Production & jobs'], ['/inventory/insights', 'Insights'], ['/inventory/reports', 'Reports'],
    ['/inventory/month-end', 'Stock close'], ['/inventory/locations', 'Locations & staff', badges.locations],
  ] : [];
  const questions = (ib?.questions?.length || 0) + Number(ib?.payments_to_confirm || 0);
  return (
    <aside className={'sidebar' + (open ? ' open' : '') + (rail ? ' rail' : '')} aria-label="Main navigation">
      <div className="sidebar-head">
        {!rail && <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 24 }} />}
        <button className="x-btn nav-close" onClick={onClose} aria-label="Close menu"><Icon name="panel" size={18} color="#9CA3AF" /></button>
        <button className="x-btn nav-rail" onClick={onRail} aria-label={rail ? 'Expand the menu' : 'Collapse the menu'} title={rail ? 'Expand the menu' : 'Collapse the menu'} aria-pressed={rail}>
          <Icon name="panel" size={18} color="#6B7280" />
        </button>
      </div>
      <div className="sidebar-section">{rail ? '' : 'MENU'}</div>
      <nav className="nav">
        <Group to="/home" label="Home" icon="house" active={p === '/home'} onClose={onClose} rail={rail} />
        <Group to="/sell/till" label="Sell" icon="receipt" active={p.startsWith('/sell')} onClose={onClose} rail={rail} show={can(inv, 'record_sales') || money}
          subs={[['/sell/till', 'Till'], ['/sell/sales', 'Sales & invoices'], ['/sell/customers', 'Customers'], ['/sell/orders', 'Orders & deliveries'],
            ['/sell/price-lists', 'Price lists'], ['/sell/shop', 'Online shop']]} />
        <Group to="/payments" label="Payments" icon="card" active={p.startsWith('/payments')} onClose={onClose} rail={rail} show={can(inv, 'record_sales') || money}
          subs={[['/payments', 'Wallet & payments', Number(ib?.payouts_to_approve || 0)]]} />
        <Group to="/purchases/bills" label="Purchases" icon="file" active={p.startsWith('/purchases')} onClose={onClose} rail={rail} show={money || can(inv, 'approve_pos')}
          subs={[['/purchases/bills', 'Bills', Number(ib?.bills_to_approve || 0)], ['/purchases/vendors', 'Vendors']]} />
        <Group to="/inventory" label="Inventory" icon="package" active={p.startsWith('/inventory')} onClose={onClose} rail={rail} subs={invSubs} />
        <Group to="/accounting/inbox" label="Accounting" icon="book" active={p.startsWith('/accounting')} onClose={onClose} rail={rail} show={money}
          subs={[['/accounting/inbox', 'Books inbox', questions], ['/accounting/banking', 'Banking'], ['/accounting/statements', 'Financial statements'],
            ['/accounting/ledgers', 'Ledgers & reports'], ['/accounting/cfo', 'CFO pack'], ['/accounting/journals', 'Journals'], ['/accounting/assets', 'Fixed assets', Number(ib?.assets_to_confirm || 0)],
            ['/accounting/close', 'Period close']]} />
        {external('Taxes', 'landmark')}
        {link('/assistant', 'AI Assistant', 'sparkles')}
      </nav>
      <div className="sidebar-section" style={{ paddingTop: 24 }}>{rail ? '' : 'MORE'}</div>
      <nav className="nav">
        {external('Integrations', 'blocks')}
        {external('Subscriptions', 'card')}
        {link('/settings', 'Settings', 'settings')}
        {link('/m', 'Phone app', 'phone', () => store.set('counta-view', 'phone'))}
      </nav>
      <div style={{ marginTop: 'auto', padding: '16px 0 12px', flex: 'none', position: 'relative' }}>
        {menu && (
          <div className="card rise" style={{ position: 'absolute', bottom: rail ? 64 : 76, left: 0, right: rail ? 'auto' : 0, width: rail ? 240 : undefined, boxShadow: 'var(--shadow-drawer)', padding: 6, zIndex: 5 }}>
            <div className="mini-label" style={{ padding: '8px 10px 4px' }}>Businesses</div>
            {memberships.map((m) => (
              <button key={m.org_id} className="nav-item" style={{ fontSize: 14, padding: '8px 10px' }} onClick={() => { setOrgId(m.org_id); setMenu(false); nav('/home'); }}>
                <span className="org-ini" style={{ width: 28, height: 28, fontSize: 10, borderRadius: 7 }}>{initials(m.name)}</span>
                <span className="grow ellipsis">{m.name}{m.is_sample ? ' · sample' : ''}</span>
                {m.org_id === orgId && <Icon name="check" size={16} color="#0072F5" />}
              </button>
            ))}
            <button className="nav-item" style={{ fontSize: 14, padding: '8px 10px' }} onClick={() => { setMenu(false); nav('/onboarding'); }}><Icon name="plus" size={16} color="#6B7280" />Add a business</button>
            <div style={{ height: 1, background: '#F3F4F6', margin: '4px 0' }} />
            <button className="nav-item" style={{ fontSize: 14, padding: '8px 10px' }} onClick={() => { setMenu(false); nav('/settings'); }}><Icon name="settings" size={16} color="#6B7280" />Settings</button>
            <button className="nav-item" style={{ fontSize: 14, padding: '8px 10px' }} onClick={signOut}><Icon name="logout" size={16} color="#6B7280" />Sign out</button>
          </div>
        )}
        <button className="org-card" onClick={() => setMenu(!menu)} aria-expanded={menu} title={rail ? current?.name || inv?.org.name : undefined}>
          <span className="org-ini">{initials(current?.name || inv?.org.name || 'TS').slice(0, 3)}</span>
          {!rail && <><span style={{ flex: 1, minWidth: 0 }}>
            <span style={{ display: 'block', fontSize: 13, fontWeight: 600, color: '#111827', lineHeight: 1.25 }}>{current?.name || inv?.org.name || '…'}</span>
            <span style={{ display: 'block', fontSize: 11, color: '#9CA3AF', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{current?.is_sample ? 'Sample business' : current?.email || inv?.org.email || ''}</span>
          </span>
          <Icon name="more" size={18} color="#6B7280" /></>}
        </button>
      </div>
    </aside>
  );
}

function Header({ onMenu }: { onMenu: () => void }) {
  const { data: inv } = useInventory();
  const { loc, setLoc } = useLoc();
  const path = useLocation().pathname;
  const nav = useNavigate();
  const { total } = useNeedsAction();
  const populated = (inv?.items.length ?? 0) > 0;
  const title = titleFor(path);
  const owner = inv?.me.role === 'owner';
  const roleLabel = !inv ? '' : owner ? 'Owner view' : `${({ manager: 'Manager', cashier: 'Cashier', accountant: 'Accountant' } as Record<string, string>)[inv.me.role] || 'Staff'} view · ${inv.me.display_name.split(' ')[0]}`;
  return (
    <header className="header">
      <div className="row hdr-left" style={{ gap: 14, minWidth: 0, flex: '1 1 360px', flexWrap: 'wrap' }}>
        <button className="icon-btn hamburger" onClick={onMenu} aria-label="Open menu"><Icon name="menu" size={22} color="#4B5563" /></button>
        <h1 className="page-title">{title}</h1>
        {populated && PICKER.has(path) && inv && inv.locations.length > 1 && (
          <div className="hdr-seg hide-sm"><Seg value={loc} onChange={setLoc} options={[{ id: 'ALL', label: 'All locations' }, ...inv.locations.map((l) => ({ id: l.id, label: l.name }))]} /></div>
        )}
      </div>
      <div className="row hdr-right" style={{ gap: 12, flex: 'none', marginLeft: 'auto' }}>
        {inv && (
          <div className="role-pill hide-sm" style={{ background: owner ? '#F0F7FF' : '#FEFCE8', color: owner ? '#0072F5' : '#A16207' }} title="Your role decides which numbers and approvals you see">
            <Icon name="shield" size={14} />{roleLabel}
          </div>
        )}
        <a className="btn btn-secondary hide-sm" style={{ color: '#111827', fontSize: 15 }} href={SUPPORT_URL} target="_blank" rel="noreferrer">
          <Icon name="chat" size={18} color="#0072F5" /><span>Get Help</span>
        </a>
        <a className="icon-btn show-sm" href={SUPPORT_URL} target="_blank" rel="noreferrer" aria-label="Get help"><Icon name="chat" size={21} color="#0072F5" /></a>
        <button className="icon-btn" onClick={() => nav('/home')} aria-label={`${total} things need your attention`}>
          <Icon name="bell" size={22} color="#4B5563" />
          {total > 0 && <span className="dot-badge">{total}</span>}
        </button>
      </div>
      {populated && PICKER.has(path) && inv && inv.locations.length > 1 && (
        <div className="hdr-seg show-sm"><Seg value={loc} onChange={setLoc} options={[{ id: 'ALL', label: 'All locations' }, ...inv.locations.map((l) => ({ id: l.id, label: l.name }))]} /></div>
      )}
    </header>
  );
}

export default function AppShell() {
  const { data: inv, isLoading, error } = useInventory();
  const [open, setOpen] = useState(false);
  const narrow = useMedia('(max-width: 1080px)');
  const [railPref, setRailPref] = useState<boolean>(() => { try { return localStorage.getItem('counta.nav.rail') === '1'; } catch { return false; } });
  const toggleRail = () => { const v = !railPref; setRailPref(v); try { localStorage.setItem('counta.nav.rail', v ? '1' : '0'); } catch { /* ignore */ } };
  const { orgId } = useSession();
  const key = 'counta.loc.' + orgId;
  const [loc, setLocState] = useState<string>(() => { try { return localStorage.getItem(key) || 'ALL'; } catch { return 'ALL'; } });
  useEffect(() => { try { setLocState(localStorage.getItem(key) || 'ALL'); } catch { /* ignore */ } }, [key]);
  const setLoc = (l: string) => { setLocState(l); try { localStorage.setItem(key, l); } catch { /* ignore */ } };
  const safeLoc = inv && loc !== 'ALL' && !inv.locations.some((l) => l.id === loc) ? 'ALL' : loc;
  const value = useMemo(() => ({ loc: safeLoc, setLoc }), [safeLoc]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <LocCtx.Provider value={value}>
      <div className="shell">
        {open && <div className="scrim" style={{ zIndex: 45 }} onClick={() => setOpen(false)} />}
        <Sidebar open={open} onClose={() => setOpen(false)} rail={railPref && !narrow} onRail={toggleRail} />
        <main className="main">
          <Header onMenu={() => setOpen(true)} />
          <div className="content" id="content">
            {isLoading && !inv ? (
              <div style={{ display: 'grid', placeItems: 'center', minHeight: 320 }}><Spinner /></div>
            ) : error && !inv ? (
              <div className="empty">Could not load this business. {(error as Error).message}</div>
            ) : (
              <>
                <InstallBanner />
                <Suspense fallback={<div style={{ display: 'grid', placeItems: 'center', minHeight: 320 }}><Spinner /></div>}><Outlet /></Suspense>
              </>
            )}
          </div>
        </main>
      </div>
    </LocCtx.Provider>
  );
}

export { can };
