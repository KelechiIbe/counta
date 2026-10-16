import { lazy, Suspense, type ReactNode } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { useSession } from './state/session';
import { Spinner } from './components/ui';
import AppShell from './shell/AppShell';
import { AuthPage, UpdatePasswordPage } from './pages/auth/Auth';
import Onboarding from './pages/Onboarding';
import Overview from './pages/inventory/Overview';

const Items = lazy(() => import('./pages/inventory/Items'));
const Receive = lazy(() => import('./pages/inventory/Receive'));
const Counts = lazy(() => import('./pages/inventory/Counts'));
const Reorder = lazy(() => import('./pages/inventory/Reorder'));
const Pricing = lazy(() => import('./pages/inventory/Pricing'));
const Insights = lazy(() => import('./pages/inventory/Insights'));
const Locations = lazy(() => import('./pages/inventory/Locations'));
const Assistant = lazy(() => import('./pages/Assistant'));
const Settings = lazy(() => import('./pages/Settings'));

const MobileApp = lazy(() => import('./mobile/MobileApp'));

function Loading() {
  return <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center' }}><Spinner /></div>;
}

function RequireAuth({ children, needOrg = true }: { children: ReactNode; needOrg?: boolean }) {
  const { session, ready, memberships, orgId } = useSession();
  const loc = useLocation();
  if (!ready) return <Loading />;
  if (!session) return <Navigate to={'/login?next=' + encodeURIComponent(loc.pathname + loc.search)} replace />;
  if (needOrg && (!memberships.length || !orgId)) return <Navigate to="/onboarding" replace />;
  return <>{children}</>;
}

function Home() {
  const phone = typeof window !== 'undefined' && window.matchMedia('(max-width: 700px)').matches;
  return <Navigate to={phone ? '/m' : '/inventory'} replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<AuthPage mode="login" />} />
      <Route path="/signup" element={<AuthPage mode="signup" />} />
      <Route path="/reset" element={<AuthPage mode="reset" />} />
      <Route path="/update-password" element={<UpdatePasswordPage />} />
      <Route path="/onboarding" element={<RequireAuth needOrg={false}><Onboarding /></RequireAuth>} />
      <Route path="/m/*" element={<RequireAuth><Suspense fallback={<Loading />}><MobileApp /></Suspense></RequireAuth>} />
      <Route element={<RequireAuth><AppShell /></RequireAuth>}>
        <Route path="/inventory" element={<Overview />} />
        <Route path="/inventory/items" element={<Items />} />
        <Route path="/inventory/receive" element={<Receive />} />
        <Route path="/inventory/counts" element={<Counts />} />
        <Route path="/inventory/reorder" element={<Reorder />} />
        <Route path="/inventory/pricing" element={<Pricing />} />
        <Route path="/inventory/insights" element={<Insights />} />
        <Route path="/inventory/locations" element={<Locations />} />
        <Route path="/assistant" element={<Assistant />} />
        <Route path="/settings" element={<Settings />} />
      </Route>
      <Route path="/" element={<RequireAuth><Home /></RequireAuth>} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
