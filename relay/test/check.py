# Reads the stand-ins' log (stdin) for relay/test/audits_e2e.sh and checks one scenario.
# argv: expected Flutterwave calls ("via METHOD path" joined by "; "), expected saved status, text the saved ref or error holds.
import json
import sys

d = json.load(sys.stdin)
calls, status, want = sys.argv[1], sys.argv[2], sys.argv[3]
got = '; '.join('%s %s %s' % (f['via'], f['method'], f['path']) for f in d['flw'])
saves = d['saves']
ok = (got == calls and all(f['auth'] == 'Bearer FLWSECK_TEST-abc123' for f in d['flw']) and len(saves) == 1
      and saves[0]['status'] == status and want in (saves[0].get('ref') or saves[0].get('error') or ''))
if not ok:
    print('   got calls:', got, '| saved:', json.dumps(saves))
sys.exit(0 if ok else 1)
