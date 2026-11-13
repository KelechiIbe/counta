#!/usr/bin/env bash
# Usage: bash supabase/tests/harness/fn_dump.sh <schema.name>...   latest definition of each function (every overload),
#                                                                  each followed by ';' and a blank line
#        bash supabase/tests/harness/fn_dump.sh --owner-list        every public/private function comparing a role to 'owner'
# Needs the running harness cluster (harness/run.sh).
set -euo pipefail
PGH_DIR=${PGH_DIR:-/var/tmp/counta-pgh}
pg() { runuser -u postgres -- /usr/lib/postgresql/16/bin/psql -h "$PGH_DIR" -p 54329 -U postgres -qXAt -v ON_ERROR_STOP=1 -d postgres "$@"; }

if [ "${1:-}" = "--owner-list" ]; then
  pg <<'SQL'
select n.nspname || '.' || p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private') and p.prokind = 'f'
  and (pg_get_functiondef(p.oid) ~ $r$role\s*(<>|!=|=)\s*'owner'$r$
    or pg_get_functiondef(p.oid) ~ $r$role\s+(not\s+)?in\s*\([^)]*'owner'[^)]*\)$r$)
order by 1;
SQL
  exit 0
fi

[ $# -gt 0 ] || { echo "usage: fn_dump.sh <schema.name>... | --owner-list" >&2; exit 2; }
for f in "$@"; do
  out=$(pg -v fn="$f" <<'SQL'
select string_agg(rtrim(pg_get_functiondef(p.oid), E'\n') || ';', E'\n\n' order by p.oid::regprocedure::text)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname || '.' || p.proname = :'fn' and p.prokind in ('f', 'p');
SQL
)
  [ -n "$out" ] || { echo "fn_dump: no function $f" >&2; exit 1; }
  printf '%s\n\n' "$out"
done
