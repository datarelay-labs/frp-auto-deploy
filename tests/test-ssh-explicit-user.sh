#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('allocator', root / 'server/frp-port-allocator.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

base = {
    'id': 'ssh', 'name': 'SSH', 'protocol': 'tcp', 'preset': 'ssh',
    'local_ip': '127.0.0.1', 'local_port': 22,
}
try:
    mod.normalize_service(base)
except mod.ServiceValidationError as exc:
    assert 'ssh_user is required' in str(exc)
else:
    raise AssertionError('missing ssh_user was accepted')

item = dict(base, ssh_user='deploy.user')
assert mod.normalize_service(item)['ssh_user'] == 'deploy.user'
for bad in ('root\nx', '\x1broot', 'bad user'):
    try:
        mod.normalize_service(dict(base, ssh_user=bad))
    except mod.ServiceValidationError:
        pass
    else:
        raise AssertionError('invalid ssh_user was accepted: %r' % bad)
PY

if rg -n "ssh_user.*(or 'root'|else 'root'|get\\('ssh_user'.*root)" \
  "$ROOT/lib/frp-client-common.sh" "$ROOT/server/frp-port-allocator.py" \
  "$ROOT/install-client.sh" >/dev/null; then
  echo "FAIL implicit SSH root fallback remains" >&2
  exit 1
fi

echo "SSH_EXPLICIT_USER_TEST=PASS"
