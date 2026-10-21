// The accountant portal: /practice. A practice (a firm, or a sole practitioner) sees every business it works for in one
// place: what needs doing in each set of books, every tax deadline, requests to the clients, the returns it changed, its
// own people and who pays for Counta. The portal reads and changes nothing in a business except through the accountant's
// own place in it, so the business's role settings and the database's checks still apply.
import { useEffect, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSession } from '../state/session';
import { cleanError } from '../lib/supabase';
import { Icon } from '../components/Icon';
import { Alert, Spinner } from '../components/ui';
import { savedPractice, savePractice, usePracticeClient, usePracticeHome, usePracticesMine } from './api';
import Setup from './pages/Setup';
import Overview from './pages/Overview';
import ClientPage from './pages/Client';
import Deadlines from './pages/Deadlines';
import TeamPage from './pages/Team';
import BillingPage from './pages/Billing';
import SettingsPage from './pages/Settings';

const NAV: [string, string, string][] = [
  ['', 'Clients', 'building'], ['deadlines', 'Deadlines', 'cal'], ['team', 'Team', 'users'], ['billing', 'Billing', 'card'], ['settings', 'Practice', 'settings'],
];

function Centre({ children }: { children: ReactNode }) {
  return <div style={{ minHeight: '100vh', display: 'grid', placeItems: 'center', padding: 16, background: 'var(--canvas)' }}>{children}</div>;
}

function Layout({ pid, children }: { pid: string; children: ReactNode }) {
  const { session, signOut, memberships } = useSession();
  const mine = usePracticesMine();
  const home = usePracticeHome(pid);
  const nav = useNavigate();
  const lead = home.data?.me.role === 'partner' || home.data?.me.role === 'manager';
  const items = NAV.filter(([p]) => lead || !['billing'].includes(p));
  const many = (mine.data?.practices.length || 0) > 1;
  return (
    <div className="adm">
      <header className="adm-top">
        <img src="/logo-brand.svg" alt="TaxStreem" style={{ height: 20 }} />
        <span className="chip t-blue">Accountant portal</span>
        {many ? (
          <select className="input input-sm" style={{ width: 'auto', maxWidth: 220 }} value={pid} aria-label="Practice"
            onChange={(e) => { savePractice(e.target.value); nav(`/practice/${e.target.value}`); }}>
            {mine.data!.practices.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        ) : <b className="ellipsis hide-xs" style={{ fontSize: 14, maxWidth: 260 }}>{home.data?.practice.name}</b>}
        <span className="grow" />
        <span className="faint hide-xs ellipsis" style={{ fontSize: 13, maxWidth: 240 }}>{session?.user.email}</span>
        {memberships.length > 0 && <Link to="/" className="btn btn-secondary btn-sm"><Icon name="house" size={14} /><span className="hide-xs">Counta</span></Link>}
        <button className="btn btn-ghost btn-sm" onClick={signOut} aria-label="Sign out"><Icon name="logout" size={14} /></button>
      </header>
      <div className="adm-body">
        <nav className="adm-nav" aria-label="Accountant portal">
          {items.map(([p, label, icon]) => (
            <NavLink key={p} to={p ? `/practice/${pid}/${p}` : `/practice/${pid}`} end={!p} className={({ isActive }) => 'nav-item' + (isActive ? ' active' : '')}>
              <Icon name={icon} size={18} color="#6B7280" /><span>{label}</span>
            </NavLink>
          ))}
        </nav>
        <main className="adm-main stack" style={{ gap: 20, minWidth: 0 }}>
          {home.isError ? <Alert kind="red" icon="alert">{cleanError(home.error)}</Alert> : !home.data ? <div className="row" style={{ justifyContent: 'center', padding: 40 }}><Spinner /></div> : children}
        </main>
      </div>
    </div>
  );
}

// /practice: the practice last used, the only one, or setting one up.
function Pick() {
  const mine = usePracticesMine();
  const list = mine.data?.practices || [];
  if (mine.isLoading) return <Centre><Spinner /></Centre>;
  if (mine.isError) return <Centre><Alert kind="red" icon="alert">{cleanError(mine.error)}</Alert></Centre>;
  if (!list.length) return <Setup invitations={mine.data?.business_invitations || []} />;
  const saved = savedPractice();
  const id = list.find((p) => p.id === saved)?.id || list[0].id;
  return <Navigate to={`/practice/${id}`} replace />;
}

function InPractice() {
  const { pid = '' } = useParams();
  const qc = useQueryClient();
  useEffect(() => { if (pid) savePractice(pid); }, [pid]);
  useEffect(() => () => { qc.removeQueries({ queryKey: ['practice-home'] }); }, [qc]);
  return (
    <Layout pid={pid}>
      <Routes>
        <Route index element={<Overview pid={pid} />} />
        <Route path="clients/:cid" element={<ClientPage pid={pid} />} />
        <Route path="deadlines" element={<Deadlines pid={pid} />} />
        <Route path="team" element={<TeamPage pid={pid} />} />
        <Route path="billing" element={<BillingPage pid={pid} />} />
        <Route path="settings" element={<SettingsPage pid={pid} />} />
        <Route path="*" element={<Navigate to={`/practice/${pid}`} replace />} />
      </Routes>
    </Layout>
  );
}

// Links in emails and notifications name a page, not the practice: they open it in the practice last used (or the client's own).
function ToPage({ page }: { page: string }) {
  const mine = usePracticesMine();
  if (mine.isLoading) return <Centre><Spinner /></Centre>;
  const list = mine.data?.practices || [];
  const id = list.find((p) => p.id === savedPractice())?.id || list[0]?.id;
  if (!id) return <Navigate to="/practice" replace />;
  return <Navigate to={`/practice/${id}/${page}${window.location.search}`} replace />;
}
function ToClient() {
  const { cid = '' } = useParams();
  const c = usePracticeClient(cid);
  if (c.isLoading) return <Centre><Spinner /></Centre>;
  if (c.isError || !c.data) return <Centre><Alert kind="amber" icon="alert">{c.isError ? cleanError(c.error) : 'That client was not found.'}</Alert></Centre>;
  return <Navigate to={`/practice/${c.data.client.practice_id}/clients/${cid}`} replace />;
}

export default function PracticeApp() {
  return (
    <Routes>
      <Route index element={<Pick />} />
      <Route path="new" element={<Setup invitations={[]} again />} />
      {['billing', 'team', 'settings', 'deadlines'].map((p) => <Route key={p} path={p} element={<ToPage page={p} />} />)}
      <Route path="clients/:cid" element={<ToClient />} />
      <Route path=":pid/*" element={<InPractice />} />
    </Routes>
  );
}
