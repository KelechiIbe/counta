#!/usr/bin/env bash
# Usage: bash supabase/tests/harness/run.sh [migrations_dir]
# Fresh local Postgres 16 cluster (UTF8, port 54329, socket and data under $PGH_DIR), Supabase stubs, then every
# migration in name order. Stops at the first failure. Leaves the cluster running.
# Just before the first migration named >= 20261124 (or after the last one) it snapshots every private function
# into harness.private_baseline, so tests can tell which private functions this plan's migrations created or redefined.
# Run as root: initdb refuses root, so every initdb / pg_ctl / psql goes through `runuser -u postgres --`.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$H/../../.." && pwd)"
MIG="${1:-$ROOT/supabase/migrations}"
PGH_DIR=${PGH_DIR:-/var/tmp/counta-pgh}
D="$PGH_DIR/data"; P=54329; BIN=/usr/lib/postgresql/16/bin
as_pg() { runuser -u postgres -- "$@"; }
pg() { as_pg env PGOPTIONS='-c client_min_messages=warning' "$BIN/psql" -h "$PGH_DIR" -p "$P" -U postgres -qX -v ON_ERROR_STOP=1 -d postgres "$@"; }

mkdir -p "$PGH_DIR"; chown postgres "$PGH_DIR"
if [ -d "$D" ]; then as_pg "$BIN/pg_ctl" -D "$D" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$D"; fi
as_pg "$BIN/initdb" -D "$D" -U postgres -A trust -E UTF8 --locale=C.UTF-8 >/dev/null
as_pg "$BIN/pg_ctl" -D "$D" -w -o "-p $P -k $PGH_DIR -c listen_addresses='' -c timezone=UTC" -l "$PGH_DIR/pg.log" start >/dev/null

pg < "$H/stubs.sql" >/dev/null

baseline() {
  pg >/dev/null <<'SQL'
create schema if not exists harness;
create table harness.private_baseline (sig text primary key, def_md5 text);
insert into harness.private_baseline (sig, def_md5)
select p.oid::regprocedure::text, md5(pg_get_functiondef(p.oid))
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private' and p.prokind <> 'a';
SQL
}

n=0; snapped=0
for f in "$MIG"/*.sql; do
  name=$(basename "$f")
  if [ $snapped = 0 ] && [[ ! "$name" < "20261124" ]]; then baseline; snapped=1; fi
  sed -E '/create extension if not exists (pg_cron|pg_net)/Id' "$f" | pg >/dev/null 2>"$PGH_DIR/last.err" \
    || { echo "FAIL: $name"; head -5 "$PGH_DIR/last.err"; exit 1; }
  n=$((n+1))
done
[ $snapped = 1 ] || baseline
echo "OK: $n migrations applied"
