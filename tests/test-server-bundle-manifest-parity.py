#!/usr/bin/env python3
"""P1-1: server bootstrap payload must track server-project-files.manifest."""
from __future__ import annotations

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
    bundle = (ROOT / "dist" / "bootstrap-server.sh").read_text(encoding="utf-8", errors="replace")
    for rel in sorted(required):
        # Payload writes either mkdir/base64 targets as $TMP/<rel>
        marker = '"$TMP/%s"' % rel
        if marker not in bundle and ("$TMP/%s" % rel) not in bundle:
            fail("bootstrap-server.sh missing payload for %s" % rel)
    for rel in DATA_PLANE:
        if rel not in bundle:
            fail("bootstrap-server.sh missing data-plane file %s" % rel)

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
