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
assert creg.sanitize_display('서울 서비스', 64) == '서울 서비스'
assert creg.validate_text_field('서울 서비스', 'name', 64) == '서울 서비스'
assert creg.validate_label('seoul-office') == 'seoul-office'
assert creg.validate_note('현장 설명') == '현장 설명'
assert creg.validate_tag_key('site') == 'site'
assert creg.validate_tag_value('seoul/office') == 'seoul/office'
for value in ('bad\nline', 'bad\rline', 'bad\x00nul', 'bad\x1besc'):
    try:
        creg.validate_text_field(value, 'field', 64)
    except ValueError:
        pass
    else:
        raise AssertionError('C0 control character accepted: %r' % value)
    try:
        creg.validate_label('x' + value)
    except ValueError:
        pass
    else:
        raise AssertionError('C0 label accepted: %r' % value)
for value in ('bad\x9bcsi', 'bad\x7fdel', 'bad\x80c1'):
    try:
        creg.validate_text_field(value, 'field', 64)
    except ValueError:
        pass
    else:
        raise AssertionError('C1 control character accepted: %r' % value)
    try:
        creg.validate_tag_key('site')
        creg.validate_tag_value(value)
    except ValueError:
        pass
    else:
        raise AssertionError('C1 tag value accepted: %r' % value)
try:
    creg.validate_hostname('h' * 254)
except ValueError:
    pass
else:
    raise AssertionError('overlong hostname accepted')
print('C0_CONTROL_CHAR_REJECTED=PASS')
print('C1_CONTROL_CHAR_REJECTED=PASS')
print('ANSI_ESCAPE_SAFE=PASS')
print('UNICODE_NORMAL_TEXT=PASS')

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
