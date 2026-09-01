#!/usr/bin/env python3
"""Canonical allocator / https URL validation cases."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import frp_url  # noqa: E402


def load_common_validate():
    """Exercise bash frp_validate_https_url via a tiny wrapper."""
    script = r"""
set -euo pipefail
. "%s/lib/frp-common.sh"
if frp_validate_https_url "$1"; then exit 0; else exit 1; fi
""" % ROOT
    def check(url: str) -> bool:
        proc = subprocess.run(
            ["bash", "-c", script, "bash", url],
            capture_output=True,
            text=True,
        )
        return proc.returncode == 0
    return check


bash_validate = load_common_validate()

MALICIOUS = [
    "https://user:pass@example.com/enroll",
    "https://example.com:99999/enroll",
    "https://example.com%0aevil/enroll",
    "https:// example.com/enroll",
    "http://example.com/enroll",
]

VALID = [
    "https://example.com/enroll",
    "https://example.com:8443/enroll",
    "https://203.0.113.10/enroll;extra",
]


def main() -> int:
    failed = 0
    for url in MALICIOUS:
        if frp_url.validate_https_allocator_url(url):
            print("FAIL python accepted:", url)
            failed += 1
        if bash_validate(url):
            print("FAIL bash accepted:", url)
            failed += 1
    for url in VALID:
        if not frp_url.validate_https_allocator_url(url):
            print("FAIL python rejected:", url)
            failed += 1
        if not bash_validate(url):
            print("FAIL bash rejected:", url)
            failed += 1
    # Control char / DEL
    for url in ("https://example.com/\x01x", "https://example.com/\x7fx"):
        if frp_url.validate_https_allocator_url(url):
            print("FAIL python accepted control:", repr(url))
            failed += 1
    if failed:
        print("ALLOCATOR_URL_VALIDATION_TEST=FAIL")
        return 1
    print("PASS allocator url validation")
    print("ALLOCATOR_URL_VALIDATION_TEST=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
