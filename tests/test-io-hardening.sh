#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
import frp_client_registry as creg

assert creg.sanitize_display('정상\x1b[31mRED\x9b31m', 64) == '정상 [31mRED 31m'
assert creg.validate_text_field('서울 서비스', 'name', 64) == '서울 서비스'
for value in ('bad\nline', 'bad\rline', 'bad\x00nul', 'bad\x1besc', 'bad\x9bcsi'):
    try:
        creg.validate_text_field(value, 'field', 64)
    except ValueError:
        pass
    else:
        raise AssertionError('control character accepted: %r' % value)
try:
    creg.validate_hostname('h' * 254)
except ValueError:
    pass
else:
    raise AssertionError('overlong hostname accepted')

spec = importlib.util.spec_from_file_location('allocator', root / 'server/frp-port-allocator.py')
allocator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(allocator)
base = {
    'id': 'web', 'protocol': 'tcp', 'preset': 'custom',
    'local_ip': '127.0.0.1', 'local_port': 8080,
}
for name in ('bad\x1bname', 'bad\nname', 'x' * 65):
    try:
        allocator.normalize_service(dict(base, name=name))
    except allocator.ServiceValidationError:
        pass
    else:
        raise AssertionError('unsafe service name accepted: %r' % name)
PY

echo "IO_HARDENING_TEST=PASS"
