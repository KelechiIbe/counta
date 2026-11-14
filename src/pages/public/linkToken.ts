// One-time links (/sign/<token>, /confirm/<token>, /approve/<token>) keep their token out of the address bar, the browser history and any
// Referer header: it is moved into this tab's sessionStorage on arrival and the address becomes /sign or /confirm, so a
// reload still works and nothing else sees it.
import { useEffect, useState } from 'react';

export function useLinkToken(param: string | undefined, key: 'counta.sign' | 'counta.confirm' | 'counta.approve', bare: '/sign' | '/confirm' | '/approve'): string {
  const [token] = useState(() => {
    let t = param || '';
    try {
      if (t) sessionStorage.setItem(key, t);
      else t = sessionStorage.getItem(key) || '';
    } catch { /* storage blocked: the token stays in memory only */ }
    if (param) window.history.replaceState(window.history.state, '', bare);
    return t;
  });
  useEffect(() => {
    let meta = document.querySelector('meta[name="referrer"]') as HTMLMetaElement | null;
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'referrer';
      document.head.appendChild(meta);
    }
    meta.content = 'no-referrer';
  }, []);
  return token;
}
