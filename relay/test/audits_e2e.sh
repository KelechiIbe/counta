#!/bin/bash
# The audits function's Flutterwave subaccount calls, end to end: the function (Deno) -> the real relay (relay/server.mjs) ->
# a stand-in for Flutterwave, with stand-ins for Supabase. Checks the relay route, the fallback to a direct call when the
# relay does not forward subaccounts yet or cannot be reached, a wrong secret, an existing split and a moved bank account,
# and that the relay still refuses every other path. Needs node, deno and curl; uses ports 8000 and 54401-54403.
# Run: bash relay/test/audits_e2e.sh
set -u
R=$(cd "$(dirname "$0")/../.." && pwd); T=$R/relay/test; D=${DENO:-deno}; L=$(mktemp -d)
GOOD=$(printf 'b%.0s' $(seq 64)); BAD=$(printf 'c%.0s' $(seq 64)); FAILS=0; RELAY=
node $T/fake.mjs > $L/fake.log 2>&1 & FAKE=$!
SUPABASE_URL=http://127.0.0.1:54401 SUPABASE_ANON_KEY=anon SUPABASE_SERVICE_ROLE_KEY=svc FLW_BASE_URL=http://127.0.0.1:54402/v3 \
  $D run --allow-all --node-modules-dir=none --no-lock $R/supabase/functions/audits/index.ts > $L/fn.log 2>&1 & FN=$!
trap 'kill $RELAY $FN $FAKE 2>/dev/null; wait 2>/dev/null; rm -rf $L' EXIT
relay() { # $1: secret, or "down"; $2: RELAY_ALLOW (empty: the default)
  if [ -n "$RELAY" ]; then kill $RELAY 2>/dev/null; wait $RELAY 2>/dev/null; RELAY=; fi
  [ "$1" = down ] && return
  env ${2:+RELAY_ALLOW="$2"} RELAY_SECRET=$1 PORT=54403 RELAY_UPSTREAM=http://127.0.0.1:54402/v3 node $R/relay/server.mjs >> $L/relay.log 2>&1 &
  RELAY=$!; for i in $(seq 50); do curl -s http://127.0.0.1:54403/health > /dev/null && break; sleep 0.1; done
}
for i in $(seq 150); do curl -s -o /dev/null http://127.0.0.1:8000 && break; sleep 0.2; done
# $1 name, $2 scenario, $3 expected Flutterwave calls ("via METHOD path" joined by "; "), $4 expected saved status, $5 expected ref or error text
check() {
  sleep 1  # the relay refuses the same signed request twice, and the signature counts whole seconds
  curl -s -X POST http://127.0.0.1:54401/__scenario -d "$2" > /dev/null
  curl -s -X POST http://127.0.0.1:8000 -H 'Authorization: Bearer x' -H 'Content-Type: application/json' \
    -d '{"action":"subaccount","practice_id":"11111111-1111-1111-1111-111111111111"}' > $L/answer.json
  if curl -s http://127.0.0.1:54401/__log | python3 $T/check.py "$3" "$4" "$5"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS+1)); fi
}
S='{"sub":"new","flwDirect":"blocked","flwPost":"ok"}'
relay $GOOD
check 'updated relay forwards the new split' "$S" 'relay POST /v3/subaccounts' ready RS_NEW
check 'an existing split is found through the relay' '{"sub":"new","flwDirect":"blocked","flwPost":"exists"}' \
  'relay POST /v3/subaccounts; relay GET /v3/subaccounts?account_bank=058&account_number=0011223344' ready RS_EARLIER
check 'a moved bank account updates the split' '{"sub":"move","flwDirect":"blocked","flwPost":"ok"}' 'relay PUT /v3/subaccounts/2181' ready RS_OLD
# Two identical requests in the same second (two tabs): the relay passes one on and refuses the repeat, which saves nothing.
sleep 1; curl -s -X POST http://127.0.0.1:54401/__scenario -d "$S" > /dev/null
python3 -c 'import time; time.sleep(1.05 - time.time() % 1)'
for n in 1 2; do curl -s -X POST http://127.0.0.1:8000 -H 'Authorization: Bearer x' -H 'Content-Type: application/json' \
  -d '{"action":"subaccount","practice_id":"11111111-1111-1111-1111-111111111111"}' > $L/twice$n.json & done; wait $(jobs -p | grep -v -e $FAKE -e $FN -e $RELAY)
if curl -s http://127.0.0.1:54401/__log | python3 -c '
import json, sys
d = json.load(sys.stdin); a = [open(f).read() for f in sys.argv[1:]]
sys.exit(0 if len(d["flw"]) == 1 and [x["status"] for x in d["saves"]] == ["ready"] and sum("went twice" in x for x in a) == 1 else 1)' \
  $L/twice1.json $L/twice2.json; then echo "ok   a repeat in the same second is refused and saves nothing"
else echo "FAIL a repeat in the same second"; cat $L/twice1.json $L/twice2.json; FAILS=$((FAILS+1)); fi
relay $GOOD '^/(transfers|bulk-transfers)(/|\?|$)'
check 'old relay, Flutterwave refuses direct: says to update the relay' "$S" 'direct POST /v3/subaccounts' failed 'Update the relay'
check 'old relay, Flutterwave takes direct: goes direct' '{"sub":"new","flwDirect":"open","flwPost":"ok"}' 'direct POST /v3/subaccounts' ready RS_NEW
relay down
check 'relay down, Flutterwave takes direct: goes direct' '{"sub":"new","flwDirect":"open","flwPost":"ok"}' 'direct POST /v3/subaccounts' ready RS_NEW
check 'relay down, Flutterwave refuses direct' "$S" 'direct POST /v3/subaccounts' failed 'whitelisted address'
relay $BAD
check 'relay with another secret sends nothing' "$S" '' failed 'FLW_RELAY_SECRET'
for p in /payments '/transactions/verify_by_reference?tx_ref=AUD-1' /subaccountsx /transfers/../payments; do
  if curl -s -X POST "http://127.0.0.1:54403/forward$p" -d '{}' | grep -q 'this path is not forwarded'; then echo "ok   relay refuses $p"
  else echo "FAIL relay refuses $p"; FAILS=$((FAILS+1)); fi
done
if curl -s http://127.0.0.1:54403/health | grep -q '"version":"2"'; then echo "ok   relay version 2"; else echo "FAIL relay version"; FAILS=$((FAILS+1)); fi
[ $FAILS = 0 ] && echo "all passed" || { echo "$FAILS failed"; cat $L/fn.log; exit 1; }
