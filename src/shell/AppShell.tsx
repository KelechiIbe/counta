import { Suspense, createContext, useContext, useEffect, useMemo, useState } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from '../state/session';
import { Icon } from '../components/Icon';
import { Seg, Spinner } from '../components/ui';
import { initials } from '../lib/format';
import { useNeedsAction } from './needsAction';

// ---------- location picker state shared by Overview, Items and Insights ----------
const LocCtx = createContext<{ loc: string; setLoc: (l: string) => void }>({ loc: 'ALL', setLoc: () => {} });
export const useLoc = () => useContext(LocCtx);

const TITLES: Record<string, string> = {
  '/inventory': 'Inventory', '/inventory/items': 'Items', '/inventory/receive': 'Receive stock', '/inventory/counts': 'Stock counts',
  '/inventory/reorder': 'Reorder', '/inventory/pricing': 'Pricing', '/inventory/insights': 'Insights', '/inventory/locations': 'Locations & staff',
  '/assistant': 'AI Assistant', '/settings': 'Settings',
};
const PICKER = new Set(['/inventory', '/inventory/items', '/inventory/insights']);
const MAIN_APP: string = import.meta.env.VITE_MAIN_APP_URL || 'https://app.taxstreem.com';
const SUPPORT_URL: string = import.meta.env.VITE_SUPPORT_URL || 'https://www.taxstreem.com';

function Sidebar({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { data: inv } = useInventory();
  const { memberships, orgId, setOrgId, signOut } = useSession();
  const nav = useNavigate();
  const loc = useLocation();
  const badges = useNeedsAction().badges;
  const [menu, setMenu] = useState(false);
  const populated = (inv?.items.length ?? 0) > 0;
  const current = memberships.find((m) => m.org_id === orgId);
  const inInventory = loc.pathname.startsWith('/inventory');

  const external = (label: string, icon: string, chev = false) => (
    <a className="nav-item" href={MAIN_APP} target="_blank" rel="noreferrer" title={label + ' opens in the main TaxStreem app'}>
      <Icon name={icon} size={20} color="#6B7280" /><span style={{ flex: 1 }}>{label}</span>
      {chev && <Icon name="chevR" size={16} color="#9CA3AF" />}
    </a>
  );
  const subs: [string, string, number][] = [
    ['/inventory', 'Overview', 0], ['/inventory/items', 'Items', 0], ['/inventory/receive', 'Receive stock', badges.receive],
    ['/inventory/counts', 'Stock counts', badges.counts], ['/inventory/reorder', 'Reorder', badges.reorder], ['/inventory/pricing', 'Pricing', badges.pricing],
    ['/inventory/insights', 'Insights', 0], ['/inventory/locations', 'Locations & staff', badges.locations],
  ];
  return (
    <aside className={'sidebar' + (open ? ' open' : '')} aria-label="Main navigation">
      <div className="sidebar-head">
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 24 }} />
        <button className="x-btn" onClick={onClose} aria-label="Close menu"><Icon name="panel" size={18} color="#9CA3AF" /></button>
      </div>
      <div className="sidebar-section">MENU</div>
      <nav className="nav">
        {external('Dashboard', 'house')}
        {external('Transactions', 'receipt')}
        {external('Accounting', 'book', true)}
        {external('Invoices', 'file')}
        {external('My Invoices', 'file')}
        {external('Vendors', 'users')}
        {external('Taxes', 'landmark')}
        {external('Filed Taxes', 'archive')}
        <NavLink to="/inventory" end={false} className={() => 'nav-item' + (inInventory ? ' active' : '')} onClick={onClose}>
          <Icon name="package" size={20} color={inInventory ? '#111827' : '#6B7280'} /><span style={{ flex: 1 }}>Inventory</span>
        </NavLink>
        {populated && (
          <div className="nav-sub">
            {subs.map(([to, label, badge]) => (
              <NavLink key={to} to={to} end className={({ isActive }) => (isActive ? 'active' : '')} onClick={onClose}>
                <span style={{ flex: 1 }}>{label}</span>
                {badge > 0 && <span className="nav-badge">{badge}</span>}
              </NavLink>
            ))}
          </div>
        )}
        <NavLink to="/assistant" className={({ isActive }) => 'nav-item' + (isActive ? ' active' : '')} onClick={onClose}>
          {({ isActive }) => (<><Icon name="sparkles" size={20} color={isActive ? '#111827' : '#6B7280'} /><span>AI Assistant</span></>)}
        </NavLink>
      </nav>
      <div className="sidebar-section" style={{ paddingTop: 24 }}>MORE</div>
      <nav className="nav">
        {external('Integrations', 'blocks')}
        {external('Subscriptions', 'card')}
        <NavLink to="/settings" className={({ isActive }) => 'nav-item' + (isActive ? ' active' : '')} onClick={onClose}>
          {({ isActive }) => (<><Icon name="settings" size={20} color={isActive ? '#111827' : '#6B7280'} /><span>Settings</span></>)}
        </NavLink>
        <NavLink to="/m" className="nav-item" onClick={onClose}>
          <Icon name="phone" size={20} color="#6B7280" /><span>Phone app</span>
        </NavLink>
      </nav>
      <div style={{ marginTop: 'auto', padding: '16px 0 12px', flex: 'none', position: 'relative' }}>
        {menu && (
          <div className="card rise" style={{ position: 'absolute', bottom: 76, left: 0, right: 0, boxShadow: 'var(--shadow-drawer)', padding: 6, zIndex: 5 }}>
            <div className="mini-label" style={{ padding: '8px 10px 4px' }}>Businesses</div>
            {memberships.map((m) => (
              <button key={m.org_id} className="nav-item" style={{ fontSize: 14, padding: '8px 10px' }} onClick={() => { setOrgId(m.org_id); setMenu(false); nav('/inventory'); }}>
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
        <button className="org-card" onClick={() => setMenu(!menu)} aria-expanded={menu}>
          <span className="org-ini">{initials(current?.name || inv?.org.name || 'TS').slice(0, 3)}</span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={{ display: 'block', fontSize: 13, fontWeight: 600, color: '#111827', lineHeight: 1.25 }}>{current?.name || inv?.org.name || '…'}</span>
            <span style={{ display: 'block', fontSize: 11, color: '#9CA3AF', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{current?.is_sample ? 'Sample business' : current?.email || inv?.org.email || ''}</span>
          </span>
          <Icon name="more" size={18} color="#6B7280" />
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
  const title = path === '/inventory' ? 'Inventory' : TITLES[path] || 'Inventory';
  const owner = inv?.me.role === 'owner';
  const roleLabel = !inv ? '' : owner ? 'Owner view' : `${inv.me.role === 'manager' ? 'Manager' : inv.me.role === 'cashier' ? 'Cashier' : 'Staff'} view · ${inv.me.display_name.split(' ')[0]}`;
  return (
    <header className="header">
      <div className="row" style={{ gap: 14, minWidth: 0, flex: '1 1 360px', flexWrap: 'wrap' }}>
        <button className="icon-btn hamburger" onClick={onMenu} aria-label="Open menu"><Icon name="menu" size={22} color="#4B5563" /></button>
        <h1 className="page-title">{title}</h1>
        {populated && PICKER.has(path) && inv && inv.locations.length > 1 && (
          <Seg value={loc} onChange={setLoc} options={[{ id: 'ALL', label: 'All locations' }, ...inv.locations.map((l) => ({ id: l.id, label: l.name }))]} />
        )}
      </div>
      <div className="row" style={{ gap: 12, flex: 'none', marginLeft: 'auto' }}>
        {inv && (
          <div className="role-pill hide-sm" style={{ background: owner ? '#F0F7FF' : '#FEFCE8', color: owner ? '#0072F5' : '#A16207' }} title="Your role decides which numbers and approvals you see">
            <Icon name="shield" size={14} />{roleLabel}
          </div>
        )}
        <a className="btn btn-secondary" style={{ color: '#111827', fontSize: 15 }} href={SUPPORT_URL} target="_blank" rel="noreferrer">
          <Icon name="chat" size={18} color="#0072F5" /><span className="hide-sm">Get Help</span>
        </a>
        <button className="icon-btn" onClick={() => nav('/inventory#needs-action')} aria-label={`${total} things need your attention`}>
          <Icon name="bell" size={22} color="#4B5563" />
          {total > 0 && <span className="dot-badge">{total}</span>}
        </button>
      </div>
    </header>
  );
}

export default function AppShell() {
  const { data: inv, isLoading, error } = useInventory();
  const [open, setOpen] = useState(false);
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
        <Sidebar open={open} onClose={() => setOpen(false)} />
        <main className="main">
          <Header onMenu={() => setOpen(true)} />
          <div className="content" id="content">
            {isLoading && !inv ? (
              <div style={{ display: 'grid', placeItems: 'center', minHeight: 320 }}><Spinner /></div>
            ) : error && !inv ? (
              <div className="empty">Could not load this business. {(error as Error).message}</div>
            ) : (
              <Suspense fallback={<div style={{ display: 'grid', placeItems: 'center', minHeight: 320 }}><Spinner /></div>}><Outlet /></Suspense>
            )}
          </div>
        </main>
      </div>
    </LocCtx.Provider>
  );
}

export { can };
