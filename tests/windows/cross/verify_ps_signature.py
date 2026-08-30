#!/usr/bin/env python3
"""Verify a PowerShell-produced ECDSA signature using frp_mgmt_auth."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'lib'))

import frp_mgmt_auth as MGMT  # noqa: E402


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--pubkey-pem', required=True)
    p.add_argument('--body', required=True)
    p.add_argument('--ts', required=True, type=int)
    p.add_argument('--nonce', required=True)
    p.add_argument('--machine-id', required=True)
    p.add_argument('--sig-b64', required=True)
    p.add_argument('--op', default='enroll')
    args = p.parse_args(argv)

    pub = Path(args.pubkey_pem).read_text(encoding='utf-8')
    message = MGMT.signed_message(args.machine_id, args.body, args.ts, args.nonce, op=args.op)
    ok = MGMT.verify_signature(pub, message, args.sig_b64)
    if not ok:
        print('VERIFY_FAIL', file=sys.stderr)
        return 1
    print('VERIFY_OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
