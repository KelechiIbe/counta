#!/usr/bin/env bash
# Usage: bash supabase/tests/golden/run.sh record|check|coverage|sweep [pattern]
#   record    runs every cases/*<pattern>*.sql and writes expected/<case>.out
#   check     runs them and compares with expected/<case>.out: "golden OK (<n> cases)" or a unified diff and exit 1
#   coverage  every line of owner_functions.txt has cases/<line>.sql, and no case is vacuous (every caller's output only
#             "ERROR 42501: permission denied..." or empty): "coverage OK (<n> functions)"
#   sweep     every owner comparison (the owner enumeration regexes) in the latest definition of a public or private
#             function is listed in sweep_manifest.tsv as keep, unless it already counts acting owners (a positive test, with
#             no <>, != or not, immediately followed by `or [alias.]acts_as_owner` or `or ([alias.]acts_as_owner and ...`;
#             a built-in self-check proves negated forms are not accepted); no keep line is stale; every owner_functions.txt
#             function has a line: "sweep OK (<n> kept)". A manifest line is <schema.function> TAB
#             <perm_of|acts_as_owner|org_contact|keep> TAB <the line holding the comparison, whitespace collapsed>; '#' starts
#             a comment line.
# Each run starts a fresh harness cluster. Each case runs in one transaction: sequences reset, fixture.sql, then per caller
# savepoint -> setup (as postgres) -> act as the caller -> each "-- exec" through tests.error_of -> tests.capture per
# "-- call" -> back to postgres -> rollback to savepoint. Case format:
#   -- callers: owner admin accountant staff        (optional; defaults below)
#   -- setup                                        (optional SQL run as postgres before the caller acts)
#   -- exec                                         (optional statements run as the caller, one per line)
#   -- call                                         (SELECTs run as the caller, one per line; golden.readback(sql)
#                                                    reads back rows the call wrote, whatever the caller may see)
# Callers: owner admin accountant staff partner platform (aal2) service anon, and definer:<caller> (the caller's claims
# while staying postgres). Default: svc_* -> service; private.* -> definer:owner..staff; others -> owner admin accountant staff.
set -euo pipefail
G="$(cd "$(dirname "$0")" && pwd)"
T="$(cd "$G/.." && pwd)"
PGH_DIR=${PGH_DIR:-/var/tmp/counta-pgh}
mode=${1:-}; pattern=${2:-}
case "$mode" in record|check|coverage|sweep) ;; *) echo "usage: golden/run.sh record|check|coverage|sweep [pattern]" >&2; exit 2;; esac
pg() { runuser -u postgres -- env PGOPTIONS='-c client_min_messages=error' /usr/lib/postgresql/16/bin/psql \
  -h "$PGH_DIR" -p 54329 -U postgres -qAtX -v ON_ERROR_STOP=1 -d postgres "$@"; }

if [ "$mode" = sweep ]; then
  M="$G/sweep_manifest.tsv"
  bad=$(awk -F'\t' '/^#/ || /^[[:space:]]*$/ { next }
    !(NF == 3 && $1 ~ /^(public|private)\.[a-z0-9_]+$/ && $2 ~ /^(perm_of|acts_as_owner|org_contact|keep)$/ && $3 != "") { print NR ": " $0 }' "$M")
  [ -z "$bad" ] || { echo "sweep_manifest.tsv: malformed lines (want <schema.function> TAB <perm_of|acts_as_owner|org_contact|keep> TAB <line>):"; echo "$bad"; exit 1; }
  out=$(bash "$T/harness/run.sh" 2>&1) || { echo "$out"; exit 1; }
  # Each result line is "<kind> TAB <manifest line>"; kind "kept" is a comparison the manifest keeps.
  res=$( {
    echo "create temp table manifest (fn text, category text, snippet text); create temp table owner_list (fn text);"
    echo "copy manifest from stdin with (format csv, delimiter E'\t', quote E'\x01');"
    grep -v -e '^#' -e '^[[:space:]]*$' "$M"; echo '\.'
    echo "copy owner_list from stdin with (format csv, quote E'\x01');"
    cat "$G/owner_functions.txt"; echo '\.'
    cat <<'SQL'
-- Every owner comparison in a public or private function. A comparison is resolved (it already counts acting owners) when it
-- is a positive test, `role = 'owner'` or `role in (... 'owner' ...)` (no <>, != or not in it), immediately followed by
-- `or [alias.]acts_as_owner` or `or ([alias.]acts_as_owner and ...`; a negated test before acting owners would let every
-- non-owner through, so it is never resolved.
create temp view owner_matches as
with defs as (
  select n.nspname || '.' || p.proname as fn, pg_get_functiondef(p.oid) as src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and p.prokind = 'f'),
hits as (
  select d.fn, d.src, regexp_instr(d.src, x.pat, 1, k) as a, regexp_instr(d.src, x.pat, 1, k, 1) as b
  from defs d
  cross join (select $r$role\s*(<>|!=|=)\s*'owner'|role\s+(not\s+)?in\s*\([^)]*'owner'[^)]*\)$r$ as pat) x
  cross join lateral generate_series(1, regexp_count(d.src, x.pat)) k),
spans as (
  select fn, src, a, b,
    case when strpos(reverse(substr(src, 1, a - 1)), E'\n') = 0 then 1 else a - strpos(reverse(substr(src, 1, a - 1)), E'\n') + 1 end as s,
    case when strpos(substr(src, b), E'\n') = 0 then length(src) + 1 else b + strpos(substr(src, b), E'\n') - 1 end as e
  from hits)
select fn, btrim(regexp_replace(substr(src, s, e - s), '\s+', ' ', 'g')) as snippet,
  substr(src, a, b - a) !~ $r$(<>|!=|\mnot\M)$r$
    and substr(src, b) ~ $r$^\s*or\s+((\w+\.)?acts_as_owner\M|\(\s*(\w+\.)?acts_as_owner\s+and\M)$r$ as resolved
from spans;

-- Self-check of the rule above on a throwaway function: each line says whether it may count as resolved.
begin;
set local check_function_bodies = off;
create function private.sweep_selfcheck(m public.members) returns boolean language sql as $f$
  select (m.role = 'owner' or m.acts_as_owner)                                   -- resolved
    and (m.role in ('owner', 'manager') or m.acts_as_owner)                      -- resolved
    and (m.role = 'owner' or (m.acts_as_owner and m.status = 'active'))          -- resolved
    and (role in ('owner', 'manager') or (acts_as_owner and status = 'active'))  -- resolved
    and (m.role <> 'owner' or m.acts_as_owner)                                   -- not resolved
    and (m.role != 'owner' or m.acts_as_owner)                                   -- not resolved
    and (m.role not in ('owner', 'manager') or m.acts_as_owner)                  -- not resolved
    and (m.role <> 'owner' or (m.acts_as_owner and m.status = 'active'))         -- not resolved
    and (m.role = 'owner' or (m.acts_as_owner or m.role = 'staff'))              -- not resolved
    and (m.role = 'owner' or m.acts_as_owner_x)                                  -- not resolved
    and (m.role = 'owner')                                                       -- not resolved
$f$;
do $$
declare v_wrong text;
begin
  select string_agg(snippet, E'\n') into v_wrong from owner_matches
  where fn = 'private.sweep_selfcheck' and resolved is distinct from (snippet like '%-- resolved');
  if v_wrong is not null or (select count(*) from owner_matches where fn = 'private.sweep_selfcheck') <> 11 then
    raise exception E'sweep self-check: the resolved-comparison rule is wrong for:\n%', coalesce(v_wrong, '(a line was not found)');
  end if;
end $$;
rollback;

create temp table hits_now as select * from owner_matches;
with keyed as (
  select fn, snippet, bool_or(category = 'keep') as kept, string_agg(distinct category, ',') as categories, count(distinct category) as n
  from manifest group by fn, snippet)
select 'kept' || E'\t' || f.fn || E'\tkeep\t' || f.snippet from hits_now f join keyed k using (fn, snippet) where not f.resolved and k.kept
union all
select 'missing' || E'\t' || f.fn || E'\tkeep\t' || f.snippet from hits_now f left join keyed k using (fn, snippet) where not f.resolved and k.fn is null
union all
select 'swept' || E'\t' || f.fn || E'\t' || k.categories || E'\t' || f.snippet from hits_now f join keyed k using (fn, snippet) where not f.resolved and not k.kept
union all
select 'conflict' || E'\t' || fn || E'\t' || categories || E'\t' || snippet from keyed where n > 1
union all
select 'stale' || E'\t' || m.fn || E'\tkeep\t' || m.snippet from manifest m
where m.category = 'keep' and not exists (select 1 from hits_now f where f.fn = m.fn and f.snippet = m.snippet)
union all
select 'unlisted' || E'\t' || o.fn from owner_list o where not exists (select 1 from manifest m where m.fn = o.fn);
SQL
  } | pg 2>&1) || { echo "$res"; exit 1; }
  failed=0
  report() {
    local lines; lines=$(printf '%s\n' "$res" | awk -F'\t' -v k="$1" '$1 == k' | cut -f2-)
    [ -n "$lines" ] || return 0
    echo "$2"; printf '%s\n' "$lines"; failed=1
  }
  report missing "Owner comparisons not in sweep_manifest.tsv (sweep each onto the resolver, or append it as it stands here if it stays):"
  report swept "Owner comparisons the manifest lists as swept that are still in place (sweep them, or list them as keep):"
  report stale "Keep lines whose comparison is no longer there (remove or replace them):"
  report conflict "Manifest lines listed under more than one category:"
  report unlisted "owner_functions.txt functions with no line in sweep_manifest.tsv:"
  [ $failed = 0 ] || exit 1
  echo "sweep OK ($(printf '%s\n' "$res" | awk -F'\t' '$1 == "kept"' | grep -c .) kept)"
  exit 0
fi

# The entries of added_keys.txt, one per line ('#' starts a comment).
added_keys() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$G/added_keys.txt" | { grep -v '^$' || true; } | sort -u; }

# A bare entry of added_keys.txt may not name a key that the recorded outputs already carry.
check_added_keys() {
  local bad=0 key
  for key in $(added_keys); do
    case "$key" in *.*) continue;; esac
    if grep -lF "\"$key\": " "$G"/expected/*.out >/dev/null 2>&1; then
      echo "added_keys.txt: bare key '$key' occurs in $(grep -lF "\"$key\": " "$G"/expected/*.out | head -3 | xargs -n1 basename | tr '\n' ' ')- scope it as parent.key or parent[].key"
      bad=1
    fi
  done
  return $bad
}

if [ "$mode" = coverage ]; then
  missing=0
  while IFS= read -r fn; do
    [ -f "$G/cases/$fn.sql" ] || { echo "missing case: cases/$fn.sql"; missing=1; }
  done < "$G/owner_functions.txt"
  [ $missing = 0 ] || exit 1
else
  check_added_keys || exit 1
fi

out=$(bash "$T/harness/run.sh" 2>&1) || { echo "$out"; exit 1; }
pg < "$T/harness/helpers.sql" >/dev/null

# Golden support: sequence states (so every case and caller sees the same serial ids), the vacuity test, ignored keys.
pg >/dev/null <<'SQL'
create schema golden;
create table golden.seqs (tag text, seq regclass, last_value bigint, is_called boolean);
create function golden.seq_save(p_tag text) returns void language plpgsql as $$
declare r record; v bigint; c boolean;
begin
  delete from golden.seqs where tag = p_tag;
  for r in select k.oid::regclass as seq from pg_class k where k.relkind = 'S' loop
    execute format('select last_value, is_called from %s', r.seq) into v, c;
    insert into golden.seqs values (p_tag, r.seq, v, c);
  end loop;
end $$;
create function golden.seq_restore(p_tag text) returns void language plpgsql as $$
declare r record;
begin
  for r in select * from golden.seqs where tag = p_tag loop perform setval(r.seq, r.last_value, r.is_called); end loop;
end $$;
-- Empty: null, "", or an array/object holding only empty values.
create function golden.empty_json(p jsonb) returns boolean language sql immutable as $$
  select case jsonb_typeof(p)
    when 'null' then true
    when 'string' then p #>> '{}' = ''
    when 'array' then not exists (select 1 from jsonb_array_elements(p) e where not golden.empty_json(e))
    when 'object' then not exists (select 1 from jsonb_each(p) e where not golden.empty_json(e.value))
    else false end
$$;
create function golden.vacuous(p_line text) returns boolean language plpgsql immutable as $$
begin
  if p_line = 'ok' or p_line like 'ERROR 42501: permission denied%' then return true; end if;
  if p_line like 'ERROR %' then return false; end if;
  return golden.empty_json(p_line::jsonb);
exception when others then
  return false;
end $$;
-- One physical line per result: a newline (or carriage return) inside an error message is written as \n (\r).
create function golden.line(p_line text) returns text language sql immutable as $$
  select case when golden.vacuous(p_line) then '0' else '1' end
    || replace(replace(coalesce(p_line, '<null>'), E'\r', '\r'), E'\n', '\n')
$$;
-- Reads back what a call wrote, whatever the caller may see: a "-- call" line such as
--   select golden.readback($r$select m.* from members m where m.org_id = tests.id('org') order by m.display_name$r$)
create function golden.readback(p_sql text) returns setof jsonb language plpgsql security definer set search_path = public as $$
begin
  return query execute format('select to_jsonb(q) from (%s) q', regexp_replace(p_sql, ';\s*$', ''));
end $$;
grant usage on schema golden to anon, authenticated, service_role;
grant execute on all functions in schema golden to anon, authenticated, service_role;
select golden.seq_save('base');
SQL
added_keys | pg -c "copy tests.golden_ignore (path) from stdin" >/dev/null

# Turns one case file into the psql script that runs it. Every output line starts with one marker character:
# '#' a caller heading, '0' a vacuous result, '1' any other result; each result is one line (see golden.line).
case_sql() {
  local file=$1 name=$2 default
  case "$name" in
    public.svc_*) default="service";;
    private.*) default="definer:owner definer:admin definer:accountant definer:staff";;
    *) default="owner admin accountant staff";;
  esac
  awk -v default_callers="$default" -v fixture="$G/fixture.sql" -v sq="'" '
    function q(s) { return "$golden_q$" s "$golden_q$" }
    /^-- callers:/ { callers = substr($0, 12); next }
    /^-- setup[ \t]*$/ { sec = "setup"; next }
    /^-- exec[ \t]*$/ { sec = "exec"; next }
    /^-- call[ \t]*$/ { sec = "call"; next }
    sec == "setup" { setup = setup $0 "\n"; next }
    sec == "exec" && $0 !~ /^[ \t]*(--.*)?$/ { ne++; ex[ne] = $0; next }
    sec == "call" && $0 !~ /^[ \t]*(--.*)?$/ { nc++; ca[nc] = $0; next }
    END {
      if (callers ~ /^[ \t]*$/) callers = default_callers
      print "\\o /dev/null"
      print "begin;"
      print "select golden.seq_restore(" sq "base" sq ");"
      while ((getline l < fixture) > 0) print l
      print "select golden.seq_save(" sq "fixture" sq ");"
      n = split(callers, cs, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        c = cs[i]; if (c == "") continue
        who = c; sub(/^definer:/, "", who)
        aal = (who == "platform") ? "aal2" : "aal1"
        if (c ~ /^definer:/) sw = "tests.as_definer(tests.id(" sq who sq "), " sq aal sq ")"
        else if (c == "service") sw = "tests.as_service()"
        else if (c == "anon") sw = "tests.as_anon()"
        else sw = "tests.as_user(tests.id(" sq who sq "), " sq aal sq ")"
        print "\\o /dev/null"
        print "savepoint golden_caller;"
        print "select golden.seq_restore(" sq "fixture" sq ");"
        printf "%s", setup
        print ";"
        print "select " sw ";"
        print "\\o"
        print "\\echo " sq "#== " c sq
        for (j = 1; j <= ne; j++)
          print "select golden.line(coalesce(" sq "ERROR " sq " || tests.error_of(" q(ex[j]) "), " sq "ok" sq "));"
        for (j = 1; j <= nc; j++)
          print "select golden.line(tests.capture(" q(ca[j]) "));"
        print "\\o /dev/null"
        print "select tests.as_postgres();"
        print "rollback to savepoint golden_caller;"
      }
      print "rollback;"
    }' "$file"
}

normalise() {
  sed -E \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([+-][0-9]{2}(:[0-9]{2})?|Z)?/<ts>/g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<date>/g' \
    -e 's/[0-9a-f]{48,}/<hex>/g'
}

shopt -s nullglob
cases=("$G"/cases/*${pattern}*.sql)
[ ${#cases[@]} -gt 0 ] || { echo "No golden cases match '$pattern'"; exit 1; }
failed=0; vacuous=0
for f in "${cases[@]}"; do
  name=$(basename "$f" .sql)
  grep -q '^-- call[[:space:]]*$' "$f" || { echo "case $name has no -- call"; failed=1; continue; }
  if ! raw=$(case_sql "$f" "$name" | pg 2>&1); then
    echo "case $name did not run: $(echo "$raw" | grep -m1 -E 'ERROR|case has' || echo "$raw" | tail -1)"; failed=1; continue
  fi
  body=$(printf '%s\n' "$raw" | cut -c2- | normalise)
  case "$mode" in
    record) printf '%s\n' "$body" > "$G/expected/$name.out" ;;
    check)
      if [ ! -f "$G/expected/$name.out" ]; then echo "no expected output for $name"; failed=1
      elif ! d=$(diff -u --label "expected/$name.out" --label "actual/$name.out" "$G/expected/$name.out" <(printf '%s\n' "$body")); then
        printf '%s\n' "$d"; failed=1
      fi ;;
    coverage)
      if ! grep -q '^1' <<< "$raw"; then echo "vacuous case: $name (every caller only gets permission denied or empty results)"; vacuous=1; fi ;;
  esac
done

case "$mode" in
  record) [ $failed = 0 ] || exit 1; check_added_keys || exit 1; echo "recorded ${#cases[@]} cases" ;;
  check) [ $failed = 0 ] || exit 1; echo "golden OK (${#cases[@]} cases)" ;;
  coverage) [ $failed = 0 ] && [ $vacuous = 0 ] || exit 1; echo "coverage OK ($(grep -c . "$G/owner_functions.txt") functions)" ;;
esac
