import { lazy, Suspense, useEffect, type ReactNode } from 'react';
import { Link, Navigate, Outlet, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from './state/session';
import type { Inventory } from './lib/types';
import { refreshPushSubscription, store } from './lib/pwa';
import { Spinner } from './components/ui';
import AppShell from './shell/AppShell';
import { AuthPage, UpdatePasswordPage } from './pages/auth/Auth';
import { GuideProvider } from './guide/GuideProvider';
import { GuideDock } from './guide/GuideDock';
import Overview from './pages/inventory/Overview';

const Items = lazy(() => import('./pages/inventory/Items'));
const Receive = lazy(() => import('./pages/inventory/Receive'));
const Counts = lazy(() => import('./pages/inventory/Counts'));
const Reorder = lazy(() => import('./pages/inventory/Reorder'));
const Pricing = lazy(() => import('./pages/inventory/Pricing'));
const Insights = lazy(() => import('./pages/inventory/Insights'));
const Locations = lazy(() => import('./pages/inventory/Locations'));
const Reports = lazy(() => import('./pages/inventory/Reports'));
const Production = lazy(() => import('./pages/inventory/Production'));
const MonthEnd = lazy(() => import('./pages/inventory/MonthEnd'));
const Migrate = lazy(() => import('./pages/inventory/Migrate'));
const Assistant = lazy(() => import('./pages/Assistant'));
const Onboard = lazy(() => import('./pages/onboarding/Onboard'));
const Settings = lazy(() => import('./pages/Settings'));
const Subscription = lazy(() => import('./pages/settings/Subscription'));
const Join = lazy(() => import('./pages/auth/Join'));
const AdminApp = lazy(() => import('./admin/AdminApp'));

const MobileApp = lazy(() => import('./mobile/MobileApp'));
const HomePage = lazy(() => import('./pages/home/Home'));
const Till = lazy(() => import('./pages/sell/Till'));
const Sales = lazy(() => import('./pages/sell/Sales'));
const Customers = lazy(() => import('./pages/sell/Customers'));
const Orders = lazy(() => import('./pages/sell/Orders'));
const PriceLists = lazy(() => import('./pages/sell/PriceLists'));
const Shop = lazy(() => import('./pages/sell/Shop'));
const Payments = lazy(() => import('./pages/payments/Payments'));
const Bills = lazy(() => import('./pages/purchases/Bills'));
const Vendors = lazy(() => import('./pages/purchases/Vendors'));
const Inbox = lazy(() => import('./pages/accounting/Inbox'));
const Banking = lazy(() => import('./pages/accounting/Banking'));
const Statements = lazy(() => import('./pages/accounting/Statements'));
const MoveBooks = lazy(() => import('./pages/accounting/MoveBooks'));
const Ledgers = lazy(() => import('./pages/accounting/Ledgers'));
const Cfo = lazy(() => import('./pages/accounting/Cfo'));
const Journals = lazy(() => import('./pages/accounting/Journals'));
const Assets = lazy(() => import('./pages/accounting/Assets'));
const Close = lazy(() => import('./pages/accounting/Close'));
const Tax = lazy(() => import('./pages/accounting/Tax'));
const PublicDoc = lazy(() => import('./pages/public/Public').then((m) => ({ default: m.PublicDoc })));
const ShopPage = lazy(() => import('./pages/public/Public').then((m) => ({ default: m.ShopPage })));
const Sso = lazy(() => import('./pages/public/Sso'));
const InvoicePortal = lazy(() => import('./pages/public/InvoicePortal'));

function Loading() {
  return <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center' }}><Spinner /></div>;
}

function RequireAuth({ children, needOrg = true }: { children: ReactNode; needOrg?: boolean }) {
  const { session, ready, memberships, orgId, loadingMemberships } = useSession();
  const loc = useLocation();
  // Right after sign-in the businesses are still loading: wait for them instead of sending the person to set up a new one.
  if (!ready || (loadingMemberships && !memberships.length)) return <Loading />;
  if (!session) return <Navigate to={'/login?next=' + encodeURIComponent(loc.pathname + loc.search)} replace />;
  if (needOrg && (!memberships.length || !orgId)) return <Navigate to="/onboarding" replace />;
  return <>{children}</>;
}

// A page someone's role does not cover says so plainly instead of asking the server and showing its refusal.
const money = (i: Inventory) => can(i, 'keep_books') || can(i, 'make_payments') || can(i, 'see_margins');
const RULES: { prefix: string; ok: (i: Inventory) => boolean; who: string }[] = [
  { prefix: '/accounting', ok: money, who: 'people who keep the books, make payments or see margins' },
  { prefix: '/tax/', ok: (i) => money(i) || can(i, 'file_tax'), who: 'people who keep the books or file tax returns' },
  { prefix: '/purchases', ok: (i) => money(i) || can(i, 'approve_pos'), who: 'people who keep the books, make payments or approve purchase orders' },
  { prefix: '/sell', ok: (i) => can(i, 'record_sales') || money(i), who: 'people who record sales' },
  { prefix: '/payments', ok: (i) => can(i, 'record_sales') || money(i), who: 'people who record sales or make payments' },
];
function Gate({ children }: { children: ReactNode }) {
  const { data: inv } = useInventory();
  const loc = useLocation();
  const rule = RULES.find((r) => loc.pathname.startsWith(r.prefix));
  if (!rule || !inv || rule.ok(inv)) return <>{children}</>;
  return (
    <div className="container" style={{ maxWidth: 560, paddingTop: 48 }}>
      <div className="card card-pad stack" style={{ gap: 10, textAlign: 'center' }}>
        <b style={{ fontSize: 18 }}>This part of Counta is not on your role</b>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.5 }}>It is for {rule.who}. The owner can change what you can do under Inventory, Locations &amp; staff.</div>
        <div><Link className="btn btn-secondary btn-sm" to="/home">Go to Home</Link></div>
      </div>
    </div>
  );
}

// Tax returns used to live under Accounting with ?tab=; old links and notifications still land on the right page.
function OldTaxLink() {
  const q = new URLSearchParams(useLocation().search);
  const tab = ['vat', 'wht', 'cit'].includes(q.get('tab') || '') ? q.get('tab') : 'cit';
  q.delete('tab');
  const rest = q.toString();
  return <Navigate to={`/tax/${tab}${rest ? '?' + rest : ''}`} replace />;
}

// Phones open the phone app unless the person chose the full app on this device.
function Home() {
  const phone = typeof window !== 'undefined' && window.matchMedia('(max-width: 700px)').matches;
  const pref = store.get('counta-view');
  return <Navigate to={pref === 'full' ? '/home' : pref === 'phone' || phone ? '/m' : '/home'} replace />;
}

// A tapped notification asks an open window to go to its page (see public/push-sw.js).
function DeviceHooks() {
  const nav = useNavigate();
  const { session } = useSession();
  const uid = session?.user.id;
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    const onMsg = (e: MessageEvent) => {
      if (e.data?.type !== 'counta:navigate' || typeof e.data.url !== 'string') return;
      const u = new URL(e.data.url, window.location.origin);
      if (u.origin === window.location.origin) nav(u.pathname + u.search + u.hash);
    };
    navigator.serviceWorker.addEventListener('message', onMsg);
    return () => navigator.serviceWorker.removeEventListener('message', onMsg);
  }, [nav]);
  useEffect(() => { if (uid) refreshPushSubscription(); }, [uid]);
  return null;
}

export default function App() {
  return (
    <GuideProvider>
    <DeviceHooks />
    <GuideDock />
    <Routes>
      <Route path="/login" element={<AuthPage mode="login" />} />
      <Route path="/signup" element={<AuthPage mode="signup" />} />
      <Route path="/reset" element={<AuthPage mode="reset" />} />
      <Route path="/update-password" element={<UpdatePasswordPage />} />
      <Route path="/join" element={<Suspense fallback={<Loading />}><Join /></Suspense>} />
      <Route path="/admin/*" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><AdminApp /></Suspense></RequireAuth>} />
      <Route path="/review" element={<Navigate to="/admin/reviews" replace />} />
      <Route path="/onboarding" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><Onboard /></Suspense></RequireAuth>} />
      <Route path="/p/:token" element={<Suspense fallback={<Loading />}><PublicDoc /></Suspense>} />
      <Route path="/shop/:slug" element={<Suspense fallback={<Loading />}><ShopPage /></Suspense>} />
      <Route path="/v/:token" element={<Suspense fallback={<Loading />}><InvoicePortal /></Suspense>} />
      <Route path="/sso" element={<Suspense fallback={<Loading />}><Sso /></Suspense>} />
      <Route path="/m/*" element={<RequireAuth><Suspense fallback={<Loading />}><MobileApp /></Suspense></RequireAuth>} />
      <Route element={<RequireAuth><AppShell /></RequireAuth>}>
        <Route element={<Gate><Outlet /></Gate>}>
        <Route path="/home" element={<HomePage />} />
        <Route path="/sell/till" element={<Till />} />
        <Route path="/sell/sales" element={<Sales />} />
        <Route path="/sell/customers" element={<Customers />} />
        <Route path="/sell/orders" element={<Orders />} />
        <Route path="/sell/price-lists" element={<PriceLists />} />
        <Route path="/sell/shop" element={<Shop />} />
        <Route path="/payments" element={<Payments />} />
        <Route path="/purchases/bills" element={<Bills />} />
        <Route path="/purchases/vendors" element={<Vendors />} />
        <Route path="/accounting" element={<Navigate to="/accounting/inbox" replace />} />
        <Route path="/accounting/inbox" element={<Inbox />} />
        <Route path="/accounting/banking" element={<Banking />} />
        <Route path="/accounting/statements" element={<Statements />} />
        <Route path="/accounting/migrate" element={<MoveBooks />} />
        <Route path="/accounting/ledgers" element={<Ledgers />} />
        <Route path="/accounting/cfo" element={<Cfo />} />
        <Route path="/accounting/journals" element={<Journals />} />
        <Route path="/accounting/assets" element={<Assets />} />
        <Route path="/accounting/close" element={<Close />} />
        <Route path="/accounting/tax" element={<OldTaxLink />} />
        <Route path="/tax" element={<Navigate to="/tax/vat" replace />} />
        <Route path="/tax/vat" element={<Tax tab="vat" />} />
        <Route path="/tax/wht" element={<Tax tab="wht" />} />
        <Route path="/tax/cit" element={<Tax tab="cit" />} />
        <Route path="/inventory" element={<Overview />} />
        <Route path="/inventory/items" element={<Items />} />
        <Route path="/inventory/receive" element={<Receive />} />
        <Route path="/inventory/counts" element={<Counts />} />
        <Route path="/inventory/reorder" element={<Reorder />} />
        <Route path="/inventory/pricing" element={<Pricing />} />
        <Route path="/inventory/insights" element={<Insights />} />
        <Route path="/inventory/locations" element={<Locations />} />
        <Route path="/inventory/reports" element={<Reports />} />
        <Route path="/inventory/production" element={<Production />} />
        <Route path="/inventory/month-end" element={<MonthEnd />} />
        <Route path="/inventory/migrate" element={<Migrate />} />
        <Route path="/assistant" element={<Assistant />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/settings/subscription" element={<Subscription />} />
        </Route>
      </Route>
      <Route path="/" element={<RequireAuth><Home /></RequireAuth>} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
    </GuideProvider>
  );
}
