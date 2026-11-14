import { lazy, Suspense, useEffect, type ReactNode } from 'react';
import { Link, Navigate, Outlet, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { can, useInventory, useSession } from './state/session';
import type { Inventory } from './lib/types';
import { planOff, useFeatures, type Feature } from './lib/features';
import { refreshPushSubscription, store } from './lib/pwa';
import { Spinner } from './components/ui';
import { UpdateNotice } from './components/UpdateNotice';
import AppShell from './shell/AppShell';
import { AuthPage, UpdatePasswordPage } from './pages/auth/Auth';
import { GuideProvider } from './guide/GuideProvider';
import { GuideDock } from './guide/GuideDock';
import { TwoStepGate } from './components/TwoStep';
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
const Integrations = lazy(() => import('./pages/integrations/Integrations'));
const Documents = lazy(() => import('./pages/documents/Documents'));
const Join = lazy(() => import('./pages/auth/Join'));
const AdminApp = lazy(() => import('./admin/AdminApp'));
const PracticeApp = lazy(() => import('./practice/PracticeApp'));
const PracticeJoin = lazy(() => import('./practice/Join'));
const AdminJoin = lazy(() => import('./admin/Join'));

const MobileApp = lazy(() => import('./mobile/MobileApp'));
const HomePage = lazy(() => import('./pages/home/Home'));
const Till = lazy(() => import('./pages/sell/Till'));
const Sales = lazy(() => import('./pages/sell/Sales'));
const Customers = lazy(() => import('./pages/sell/Customers'));
const Orders = lazy(() => import('./pages/sell/Orders'));
const PriceLists = lazy(() => import('./pages/sell/PriceLists'));
const Shop = lazy(() => import('./pages/sell/Shop'));
const Recurring = lazy(() => import('./pages/sell/Recurring'));
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
const Filing = lazy(() => import('./pages/filing/Filing'));
const PublicDoc = lazy(() => import('./pages/public/Public').then((m) => ({ default: m.PublicDoc })));
const ShopPage = lazy(() => import('./pages/public/Public').then((m) => ({ default: m.ShopPage })));
const Sso = lazy(() => import('./pages/public/Sso'));
const LegalPage = lazy(() => import('./pages/public/Legal'));
const Referral = lazy(() => import('./pages/public/Referral'));
const InvoicePortal = lazy(() => import('./pages/public/InvoicePortal'));
const SignPage = lazy(() => import('./pages/public/Sign'));
const DirectorConfirm = lazy(() => import('./pages/public/DirectorConfirm'));
const ApprovePage = lazy(() => import('./pages/public/Approve'));
const Approvals = lazy(() => import('./pages/approvals/Approvals'));
const RecoverStart = lazy(() => import('./pages/recover/Recover').then((m) => ({ default: m.RecoverStart })));
const RecoverPage = lazy(() => import('./pages/recover/Recover').then((m) => ({ default: m.RecoverPage })));
const RecoverAccept = lazy(() => import('./pages/recover/Recover').then((m) => ({ default: m.RecoverAccept })));

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
  // In a business, the code from the authenticator app first (the admin portal and the practice app ask in their own way).
  return needOrg ? <TwoStepGate>{children}</TwoStepGate> : <>{children}</>;
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
// Parts of the app a plan can leave out (the Annual filing package keeps only the books and the income tax return).
const AREAS: { prefix: string; feature: Feature; what: string }[] = [
  { prefix: '/sell', feature: 'selling', what: 'Selling' }, { prefix: '/payments', feature: 'payments', what: 'Payments' },
  { prefix: '/purchases', feature: 'purchases', what: 'Bills and vendors' }, { prefix: '/inventory', feature: 'inventory', what: 'Inventory' },
  { prefix: '/tax/vat', feature: 'vat_wht', what: 'The monthly VAT return' }, { prefix: '/tax/wht', feature: 'vat_wht', what: 'Withholding tax schedules' },
];
function Gate({ children }: { children: ReactNode }) {
  const { data: inv } = useInventory();
  const feats = useFeatures().data;
  const loc = useLocation();
  // A filing-only business starts on its Filing page.
  if (inv?.org.filing_only && loc.pathname === '/home') return <Navigate to="/filing" replace />;
  // Who works where (Locations & staff) stays open whatever the plan.
  const area = loc.pathname.startsWith('/inventory/locations') ? undefined : AREAS.find((a) => loc.pathname === a.prefix || loc.pathname.startsWith(a.prefix + '/'));
  if (area && inv && planOff(feats, area.feature)) {
    const filing = !!inv.org.filing_only;
    return (
      <div className="container" style={{ maxWidth: 560, paddingTop: 48 }}>
        <div className="card card-pad stack" style={{ gap: 10, textAlign: 'center' }} data-testid="plan-off">
          <b style={{ fontSize: 18 }}>{area.what} {filing ? 'is not part of filing-only' : 'is not in your plan'}</b>
          <div className="muted" style={{ fontSize: 14, lineHeight: 1.5 }}>{filing
            ? `${inv.org.name} is on Annual filing: Counta prepares its yearly income tax return from its bank statements. ${area.what} comes with a Counta plan.`
            : 'The owner or an admin can move the business to a plan that includes it.'}</div>
          <div className="row" style={{ gap: 8, justifyContent: 'center' }}>
            {filing && <Link className="btn btn-primary btn-sm" to="/filing">Go to Filing</Link>}
            <Link className="btn btn-secondary btn-sm" to="/settings/subscription">See the plans</Link>
          </div>
        </div>
      </div>
    );
  }
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
    <UpdateNotice />
    <GuideDock />
    <Routes>
      <Route path="/login" element={<AuthPage mode="login" />} />
      <Route path="/signup" element={<AuthPage mode="signup" />} />
      <Route path="/reset" element={<AuthPage mode="reset" />} />
      <Route path="/update-password" element={<UpdatePasswordPage />} />
      <Route path="/join" element={<Suspense fallback={<Loading />}><Join /></Suspense>} />
      <Route path="/admin/join" element={<Suspense fallback={<Loading />}><AdminJoin /></Suspense>} />
      <Route path="/admin/*" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><AdminApp /></Suspense></RequireAuth>} />
      <Route path="/practice/join" element={<Suspense fallback={<Loading />}><PracticeJoin /></Suspense>} />
      <Route path="/practice/*" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><PracticeApp /></Suspense></RequireAuth>} />
      <Route path="/review" element={<Navigate to="/admin/reviews" replace />} />
      <Route path="/onboarding" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><Onboard /></Suspense></RequireAuth>} />
      <Route path="/p/:token" element={<Suspense fallback={<Loading />}><PublicDoc /></Suspense>} />
      <Route path="/r/:code" element={<Suspense fallback={<Loading />}><Referral /></Suspense>} />
      <Route path="/shop/:slug" element={<Suspense fallback={<Loading />}><ShopPage /></Suspense>} />
      <Route path="/v/:token" element={<Suspense fallback={<Loading />}><InvoicePortal /></Suspense>} />
      <Route path="/sign/:token" element={<Suspense fallback={<Loading />}><SignPage /></Suspense>} />
      <Route path="/sign" element={<Suspense fallback={<Loading />}><SignPage /></Suspense>} />
      <Route path="/confirm/:token" element={<Suspense fallback={<Loading />}><DirectorConfirm /></Suspense>} />
      <Route path="/confirm" element={<Suspense fallback={<Loading />}><DirectorConfirm /></Suspense>} />
      <Route path="/approve/:token" element={<Suspense fallback={<Loading />}><ApprovePage /></Suspense>} />
      <Route path="/approve" element={<Suspense fallback={<Loading />}><ApprovePage /></Suspense>} />
      <Route path="/recover" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><RecoverStart /></Suspense></RequireAuth>} />
      <Route path="/recover/accept/:token" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><RecoverAccept /></Suspense></RequireAuth>} />
      <Route path="/recover/:id" element={<RequireAuth needOrg={false}><Suspense fallback={<Loading />}><RecoverPage /></Suspense></RequireAuth>} />
      <Route path="/sso" element={<Suspense fallback={<Loading />}><Sso /></Suspense>} />
      <Route path="/sla" element={<Suspense fallback={<Loading />}><LegalPage page="/sla" /></Suspense>} />
      <Route path="/developers" element={<Suspense fallback={<Loading />}><LegalPage page="/developers" /></Suspense>} />
      <Route path="/privacy" element={<Suspense fallback={<Loading />}><LegalPage page="/privacy" /></Suspense>} />
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
        <Route path="/sell/recurring" element={<Recurring />} />
        <Route path="/payments" element={<Payments />} />
        <Route path="/approvals" element={<Approvals />} />
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
        <Route path="/tax/pit" element={<Tax tab="pit" />} />
        <Route path="/filing" element={<Filing />} />
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
        <Route path="/integrations" element={<Integrations />} />
        <Route path="/documents" element={<Documents />} />
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
