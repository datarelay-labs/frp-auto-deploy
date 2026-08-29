#!/usr/bin/env bash
# Explicit maintainer bump of the pinned FRP version after compatibility PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
APPLY=0
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  cat <<'EOF'
Usage: ./scripts/bump-frp-version.sh <frp-version> --apply

Refuses to run unless:
  1) ./scripts/check-frp-compatibility.sh <version> already staged a PASS, or
     FRP_COMPAT_REPORT is provided
  2) --apply is passed

This never installs GitHub "latest" automatically.
EOF
  exit 2
fi

if [[ "$APPLY" != "1" ]]; then
  echo "ERROR: refusing to bump VERSION without --apply" >&2
  echo "Run ./scripts/check-frp-compatibility.sh ${VERSION} first." >&2
  exit 2
fi

REPORT="${FRP_COMPAT_REPORT:-$ROOT/.frp-compat-stage/$VERSION/report.status}"
if [[ ! -f "$REPORT" ]] && [[ "${FRP_COMPAT_FORCE:-}" != "1" ]]; then
  echo "ERROR: no compatibility report at $REPORT" >&2
  echo "Run ./scripts/check-frp-compatibility.sh ${VERSION} first." >&2
  echo "Set FRP_COMPAT_FORCE=1 only if you have external PASS evidence." >&2
  exit 2
fi

AMD="${FRP_NEW_SHA256_AMD64:-}"
ARM="${FRP_NEW_SHA256_ARM64:-}"
if [[ -z "$AMD" || -z "$ARM" ]]; then
  echo "ERROR: set FRP_NEW_SHA256_AMD64 and FRP_NEW_SHA256_ARM64 from the compatibility report" >&2
  exit 2
fi

python3 - "$ROOT" "$VERSION" "$AMD" "$ARM" <<'PY'
from pathlib import Path
import re, sys
root, version, amd, arm = sys.argv[1:]
ver = Path(root) / "VERSION"
text = ver.read_text()
text = re.sub(r"^FRP_VERSION=.*$", f"FRP_VERSION={version}", text, flags=re.M)
ver.write_text(text)
common = Path(root) / "lib" / "frp-common.sh"
ct = common.read_text()
ct = re.sub(r'FRP_VERSION="\$\{FRP_VERSION:-[^}]+\}"', f'FRP_VERSION="${{FRP_VERSION:-{version}}}"', ct, count=1)
ct = re.sub(r'FRP_SHA256_AMD64="\$\{FRP_SHA256_AMD64:-[^}]+\}"', f'FRP_SHA256_AMD64="${{FRP_SHA256_AMD64:-{amd}}}"', ct, count=1)
ct = re.sub(r'FRP_SHA256_ARM64="\$\{FRP_SHA256_ARM64:-[^}]+\}"', f'FRP_SHA256_ARM64="${{FRP_SHA256_ARM64:-{arm}}}"', ct, count=1)
common.write_text(ct)
print(f"Updated VERSION and lib/frp-common.sh to FRP {version}")
print("Now run tests, ./scripts/build-bundles.sh, ./scripts/update-sha256sums.sh")
print("Do not tag until OCI acceptance.")
PY
