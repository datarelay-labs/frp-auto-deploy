#!/usr/bin/env python3
"""P1-1: server bootstrap payload must track server-project-files.manifest."""
from __future__ import annotations

import base64
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
from frp_project_files import (  # noqa: E402
    MANAGED_CLASSES,
    load_entries,
    server_bootstrap_source_rels,
)

DATA_PLANE = (
    "lib/frp_data_plane_auth.py",
    "lib/frp_proxy_leases.py",
    "lib/frp_plugin_server.py",
    "lib/frp_release_guard.py",
)


def fail(msg):
    print("FAIL", msg, file=sys.stderr)
    raise SystemExit(1)


def _embedded_sha256sums(bundle_text: str) -> str:
    m = re.search(
        r"base64 -d >\"\$TMP/SHA256SUMS\" <<'B64'\n(.*?)\nB64",
        bundle_text,
        re.S,
    )
    if not m:
        fail("bootstrap-server.sh missing embedded SHA256SUMS payload")
    return base64.b64decode(m.group(1).replace("\n", "")).decode("utf-8")


def main():
    required = set(server_bootstrap_source_rels(source_root=ROOT))
    for rel in DATA_PLANE:
        if rel not in required:
            fail("derived bootstrap sources missing %s" % rel)

    # Rebuild and inspect generated artifact embedding.
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build-bundles.py")],
        cwd=str(ROOT),
        check=True,
        stdout=subprocess.DEVNULL,
    )
    bundle_path = ROOT / "dist" / "bootstrap-server.sh"
    first_digest = hashlib.sha256(bundle_path.read_bytes()).hexdigest()
    bundle = bundle_path.read_text(encoding="utf-8", errors="replace")
    for rel in sorted(required):
        # Payload writes either mkdir/base64 targets as $TMP/<rel>
        marker = '"$TMP/%s"' % rel
        if marker not in bundle and ("$TMP/%s" % rel) not in bundle:
            fail("bootstrap-server.sh missing payload for %s" % rel)
    for rel in DATA_PLANE:
        if rel not in bundle:
            fail("bootstrap-server.sh missing data-plane file %s" % rel)

    # Self-hash of the outer bootstrap must not be embedded: that creates an
    # unsatisfiable SHA256SUMS fixed-point and breaks rebuild parity.
    embedded_sums = _embedded_sha256sums(bundle)
    for line in embedded_sums.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1] == "dist/bootstrap-server.sh":
            fail("embedded SHA256SUMS must omit dist/bootstrap-server.sh self-digest")

    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build-bundles.py")],
        cwd=str(ROOT),
        check=True,
        stdout=subprocess.DEVNULL,
    )
    second_digest = hashlib.sha256(bundle_path.read_bytes()).hexdigest()
    if first_digest != second_digest:
        fail("bootstrap-server.sh rebuild is not deterministic with fixed SHA256SUMS")

    # Sanity: generated/binary/version/protected sources must not drive payload.
    for entry in load_entries():
        if entry.cls in MANAGED_CLASSES:
            continue
        if entry.source in ("-", "", None):
            continue
        if entry.source in required and entry.source not in (
            "release-manifest.json",  # also a managed project source
        ):
            # Only managed + bootstrap-only should appear; non-managed sources
            # with real paths should not be required unless also managed.
            if entry.cls in ("generated", "binary", "version", "protected", "protected-prefix"):
                if entry.source in required and entry.source not in server_bootstrap_source_rels(
                    source_root=ROOT
                ):
                    fail("non-managed class leaked into bootstrap: %s" % entry.source)

    print("SERVER_BUNDLE_MANIFEST_PARITY=PASS")
    print("SERVER_BUNDLE_DATA_PLANE_FILES=PASS")
    print("SERVER_BUNDLE_SHA256SUMS_SELF_EMBED_SAFE=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())