#!/usr/bin/env python3
"""Legacy P1-L reproducer — superseded by tests/test-frp-data-plane-auth.py.

The original test documented the shared-token + allowPorts architectural gap.
P1-L remediation adds server-authoritative NewProxy authorization; run the
focused suite for current acceptance coverage.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOCUSED = ROOT / 'tests' / 'test-frp-data-plane-auth.py'


def main():
    if not FOCUSED.is_file():
        print('FAIL missing %s' % FOCUSED, file=sys.stderr)
        return 1
    print('NOTE: superseded by tests/test-frp-data-plane-auth.py')
    proc = subprocess.run([sys.executable, str(FOCUSED)], cwd=str(ROOT))
    if proc.returncode == 0:
        print('P1_L_STATUS=FIXED')
    return proc.returncode


if __name__ == '__main__':
    raise SystemExit(main())
