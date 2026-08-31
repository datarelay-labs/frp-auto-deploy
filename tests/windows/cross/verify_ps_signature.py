#!/usr/bin/env python3
"""Verify a PowerShell-produced ECDSA signature using frp_mgmt_auth."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'lib'))

import frp_mgmt_auth as MGMT  # noqa: E402


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--pubkey-pem', required=True)
    # Prefer --vectors-json on Windows PowerShell 5.1: native argv mangles JSON quotes.
    p.add_argument('--vectors-json')
    p.add_argument('--body')
    p.add_argument('--ts', type=int)
    p.add_argument('--nonce')
    p.add_argument('--machine-id')
    # Prefer --sig-file: native argv also mangles '+' in base64.
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument('--sig-b64')
    g.add_argument('--sig-file')
    p.add_argument('--op', default='enroll')
    args = p.parse_args(argv)

    if args.vectors_json:
        vectors = json.loads(Path(args.vectors_json).read_text(encoding='utf-8-sig'))
        body = vectors['body']
        ts = int(vectors['ts'])
        nonce = vectors['nonce']
        machine_id = vectors['machine_id']
    else:
        missing = [n for n in ('body', 'ts', 'nonce', 'machine_id') if getattr(args, n.replace('-', '_')) is None]
        # argparse converts dashes; check explicitly
        if args.body is None or args.ts is None or args.nonce is None or args.machine_id is None:
            print('ERROR: provide --vectors-json or all of --body/--ts/--nonce/--machine-id', file=sys.stderr)
            return 2
        body = args.body
        ts = args.ts
        nonce = args.nonce
        machine_id = args.machine_id

    if args.sig_file:
        sig_b64 = Path(args.sig_file).read_text(encoding='utf-8-sig').strip()
    else:
        sig_b64 = args.sig_b64

    pub = Path(args.pubkey_pem).read_text(encoding='utf-8-sig')
    message = MGMT.signed_message(machine_id, body, ts, nonce, op=args.op)
    ok = MGMT.verify_signature(pub, message, sig_b64)
    if not ok:
        print('VERIFY_FAIL', file=sys.stderr)
        return 1
    print('VERIFY_OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
