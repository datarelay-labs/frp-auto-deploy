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
    # Prefer --sig-file on Windows PowerShell 5.1: native argv mangles '+' in base64.
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument('--sig-b64')
    g.add_argument('--sig-file')
    p.add_argument('--op', default='enroll')
    args = p.parse_args(argv)

    if args.sig_file:
        sig_b64 = Path(args.sig_file).read_text(encoding='utf-8-sig').strip()
    else:
        sig_b64 = args.sig_b64

    pub = Path(args.pubkey_pem).read_text(encoding='utf-8-sig')
    message = MGMT.signed_message(args.machine_id, args.body, args.ts, args.nonce, op=args.op)
    ok = MGMT.verify_signature(pub, message, sig_b64)
    if not ok:
        print('VERIFY_FAIL', file=sys.stderr)
        return 1
    print('VERIFY_OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
