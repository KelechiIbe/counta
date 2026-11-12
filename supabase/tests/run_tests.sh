#!/usr/bin/env bash
# Usage: bash supabase/tests/run_tests.sh [pattern]
# Fresh harness (harness/run.sh), the tests helpers, then every supabase/tests/sql/*<pattern>*.sql in name order.
# Each file runs as postgres with ON_ERROR_STOP; it prints PASS <file> or FAIL <file>: <first ERROR line>.
set -uo pipefail
T="$(cd "$(dirname "$0")" && pwd)"
PGH_DIR=${PGH_DIR:-/var/tmp/counta-pgh}
pg() { runuser -u postgres -- env PGOPTIONS='-c client_min_messages=warning' /usr/lib/postgresql/16/bin/psql \
  -h "$PGH_DIR" -p 54329 -U postgres -qX -v ON_ERROR_STOP=1 -d postgres "$@"; }

bash "$T/harness/run.sh" || exit 1
pg < "$T/harness/helpers.sql" >/dev/null 2>"$PGH_DIR/helpers.err" || { echo "FAIL helpers.sql: $(grep -m1 ERROR "$PGH_DIR/helpers.err")"; exit 1; }

shopt -s nullglob
files=("$T"/sql/*${1:-}*.sql)
[ ${#files[@]} -gt 0 ] || { echo "No test files match '${1:-}'"; exit 1; }
failed=0
for f in "${files[@]}"; do
  name=$(basename "$f")
  if pg < "$f" >/dev/null 2>"$PGH_DIR/test.err"; then
    echo "PASS $name"
  else
    echo "FAIL $name: $(grep -m1 'ERROR' "$PGH_DIR/test.err" || head -1 "$PGH_DIR/test.err")"
    failed=$((failed+1))
  fi
done
[ $failed = 0 ] || { echo "FAILED ($failed of ${#files[@]} files)"; exit 1; }
echo "ALL PASS (${#files[@]} files)"
