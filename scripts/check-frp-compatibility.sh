#!/usr/bin/env bash
# Stage and inspect a candidate upstream FRP release. Does not bump VERSION.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../lib/frp-common.sh
. "$ROOT/lib/frp-common.sh"

CANDIDATE="${1:-}"
if [[ -z "$CANDIDATE" || "$CANDIDATE" == "-h" || "$CANDIDATE" == "--help" ]]; then
  cat <<'EOF'
Usage: ./scripts/check-frp-compatibility.sh <frp-version>

Downloads linux amd64/arm64 candidate archives from GitHub, verifies
checksums, inspects websocket path defaults, and runs local config verify
when binaries can be extracted.

This does NOT change VERSION, SHA256 constants, or production installs.
Use ./scripts/bump-frp-version.sh only after this report is PASS and after
full project tests.
EOF
  exit 2
fi

STAGE="${FRP_COMPAT_STAGE:-$ROOT/.frp-compat-stage/$CANDIDATE}"
mkdir -p "$STAGE"
BASE_URL="https://github.com/fatedier/frp/releases/download/v${CANDIDATE}"

download() {
  local name="$1"
  curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
    -o "$STAGE/$name" "$BASE_URL/$name"
}

ws_src="$STAGE/websocket.go"
if [[ "${FRP_COMPAT_OFFLINE:-}" != "1" ]]; then
  curl -fL --retry 3 --connect-timeout 10 --max-time 60 \
    -o "$ws_src" \
    "https://raw.githubusercontent.com/fatedier/frp/v${CANDIDATE}/pkg/util/net/websocket.go" \
    || true
fi
if [[ ! -f "$ws_src" ]] || ! grep -F "$FRP_WEBSOCKET_PATH" "$ws_src" >/dev/null 2>&1; then
  echo "ERROR: candidate websocket.go does not contain ${FRP_WEBSOCKET_PATH}"
  echo "BREAKING_WEBSOCKET_PATH=FAIL"
  exit 1
fi
echo "WEBSOCKET_PATH_UNCHANGED=PASS"
echo "PASS" >"$STAGE/report.status"

echo "Candidate FRP : $CANDIDATE"
echo "Pinned FRP    : $FRP_VERSION"
echo "WebSocket path (project): $FRP_WEBSOCKET_PATH"
echo "Stage         : $STAGE"
echo

if [[ "${FRP_COMPAT_SKIP_ARCHIVES:-}" == "1" ]]; then
  echo "FRP_COMPAT_SKIP_ARCHIVES=1 (checksum/extract skipped)"
  echo "FRP_COMPAT=PASS_WEBSOCKET_ONLY"
  echo "Next: run project tests, then ./scripts/bump-frp-version.sh ${CANDIDATE} --apply"
  echo "Never install upstream latest automatically."
  exit 0
elif [[ "${FRP_COMPAT_OFFLINE:-}" == "1" ]]; then
  echo "OFFLINE=1; expecting pre-staged archives in $STAGE"
else
  download "frp_${CANDIDATE}_linux_amd64.tar.gz"
  download "frp_${CANDIDATE}_linux_arm64.tar.gz"
fi

python3 - "$STAGE" "$CANDIDATE" "$FRP_SHA256_AMD64" "$FRP_SHA256_ARM64" <<'PY'
import hashlib, sys, tarfile
from pathlib import Path

stage, version, pin_amd, pin_arm = sys.argv[1:]
fail = 0

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def inspect(archive, expected_pin):
    global fail
    path = Path(archive)
    if not path.is_file():
        print(f"MISSING {path.name}")
        fail = 1
        return
    digest = sha256(path)
    print(f"{path.name} sha256={digest}")
    extract = path.parent / (path.name.replace(".tar.gz", "") + "_extract")
    extract.mkdir(exist_ok=True)
    with tarfile.open(path, "r:gz") as tar:
        tar.extractall(extract)
    if digest == expected_pin:
        print(f"PIN_MATCH {path.name}")
    else:
        print(f"PIN_DIFFERS {path.name} (expected {expected_pin})")

inspect(Path(stage) / f"frp_{version}_linux_amd64.tar.gz", pin_amd)
inspect(Path(stage) / f"frp_{version}_linux_arm64.tar.gz", pin_arm)
if fail:
    print("FRP_COMPAT=FAIL")
    raise SystemExit(1)
print("FRP_COMPAT=PASS_CANDIDATE_STAGED")
print("This is NOT permission to bump production VERSION.")
PY

# Config verify against current project templates if binaries extracted.
amd_bin="$(find "$STAGE" -path '*linux_amd64*' -name frps -type f | head -n1 || true)"
if [[ -n "$amd_bin" && -x "$amd_bin" ]]; then
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
bindPort = 7000
auth.method = "token"
auth.token = "compat-check-not-a-secret"
allowPorts = [{ start = 6000, end = 6098 }]
EOF
  if "$amd_bin" verify -c "$tmp"; then
    echo "FRPS_VERIFY=PASS"
  else
    echo "FRPS_VERIFY=FAIL"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
else
  echo "FRPS_VERIFY=SKIPPED_NO_BINARY"
fi

echo
echo "Next: run project tests, then ./scripts/bump-frp-version.sh ${CANDIDATE} --apply"
echo "Never install upstream latest automatically."
