#!/usr/bin/env bash
# Shared constants and helpers for FRP binary lifecycle management.
# Source this file; do not execute it.

if [[ -n "${FRP_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_COMMON_LOADED=1

# Defaults match VERSION. A sibling VERSION file overrides project/FRP versions.
PROJECT_VERSION="${PROJECT_VERSION:-1.3.1}"
FRP_VERSION="${FRP_VERSION:-0.70.1}"
FRP_SHA256_AMD64="${FRP_SHA256_AMD64:-333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6}"
FRP_SHA256_ARM64="${FRP_SHA256_ARM64:-3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d}"

_FRP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_FRP_COMMON_DIR}/../VERSION" ]]; then
  # shellcheck disable=SC1091
  . "${_FRP_COMMON_DIR}/../VERSION"
fi

FRP_TEST_HARNESS_MAGIC="frp-auto-deploy-test-harness"

frp_test_harness_enabled() {
  [[ "${FRP_UPDATE_TEST_HARNESS:-}" == "1" ]] || return 1
  local marker="${FRP_UPDATE_TEST_MARKER:-}"
  [[ -n "$marker" && -f "$marker" ]] || return 1
  [[ "$(tr -d '\n' <"$marker")" == "$FRP_TEST_HARNESS_MAGIC" ]] || return 1
  return 0
}

frp_path() {
  local p="$1"
  local root="${FRP_DEPLOY_TEST_ROOT:-${FRP_UPDATE_ROOT:-}}"
  if frp_test_harness_enabled && [[ -n "$root" ]]; then
    printf '%s' "${root}${p}"
  else
    printf '%s' "$p"
  fi
}

frp_detect_arch() {
  case "$(uname -m)" in
    x86_64) FRP_ARCH=amd64 ;;
    aarch64|arm64) FRP_ARCH=arm64 ;;
    *)
      echo "ERROR: unsupported architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
}

frp_checksum_for() {
  local version="$1" arch="$2"
  if [[ "$version" != "$FRP_VERSION" ]]; then
    echo "ERROR: FRP ${version} is not the tested version (${FRP_VERSION})" >&2
    return 1
  fi
  case "$arch" in
    amd64) printf '%s' "$FRP_SHA256_AMD64" ;;
    arm64) printf '%s' "$FRP_SHA256_ARM64" ;;
    *)
      echo "ERROR: unsupported architecture: ${arch}" >&2
      return 1
      ;;
  esac
}

frp_release_url() {
  local version="$1" arch="$2"
  printf 'https://github.com/fatedier/frp/releases/download/v%s/frp_%s_linux_%s.tar.gz' \
    "$version" "$version" "$arch"
}

frp_parse_binary_version() {
  local bin="$1" out
  if [[ ! -x "$bin" ]]; then
    printf '%s' "unknown"
    return 0
  fi
  out="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  printf '%s' "$out" | python3 -c '
import re,sys
text=sys.stdin.read()
m=re.search(r"([0-9]+\.[0-9]+\.[0-9]+)", text)
sys.stdout.write(m.group(1) if m else "unknown")
'
}

frp_file_sha256() {
  local file="$1"
  python3 - "$file" <<'PY'
import hashlib, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    sys.stdout.write("")
else:
    sys.stdout.write(hashlib.sha256(p.read_bytes()).hexdigest())
PY
}

frp_verify_sha256() {
  local expected="$1" file="$2"
  python3 - "$expected" "$file" <<'PY'
import hashlib, sys
from pathlib import Path
expected, path = sys.argv[1], sys.argv[2]
actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
if actual.lower() != expected.lower():
    sys.stderr.write("ERROR: SHA256 checksum mismatch\n")
    sys.exit(1)
print(path + ": OK")
PY
}

frp_atomic_install() {
  local src="$1" dest="$2" mode="${3:-0755}"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.frp-install.XXXXXX")"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest"
}

frp_write_version_file() {
  local dest="$1"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.version.XXXXXX")"
  cat >"$tmp" <<EOF
PROJECT_VERSION=${PROJECT_VERSION}
FRP_VERSION=${FRP_VERSION}
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
}

frp_read_kv_file() {
  local file="$1" key="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$file"
}

frp_bind_port() {
  local config="$1"
  if [[ ! -f "$config" ]]; then
    return 0
  fi
  python3 - "$config" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"^\s*bindPort\s*=\s*(\d+)", text, re.M)
sys.stdout.write(m.group(1) if m else "")
PY
}

frp_port_listening() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(1)
try:
    sys.exit(0 if s.connect_ex(("127.0.0.1", port)) == 0 else 1)
finally:
    s.close()
PY
}

frp_registry_identity() {
  local registry="$1"
  python3 - "$registry" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("{}")
    raise SystemExit(0)
state = json.loads(p.read_text(encoding="utf-8"))
clients = {}
for mid, client in sorted((state.get("clients") or {}).items()):
    services = {}
    raw = client.get("services") or {}
    if isinstance(raw, dict):
        for sid, svc in sorted(raw.items()):
            if not isinstance(svc, dict):
                continue
            services[sid] = {
                "enabled": svc.get("enabled", True),
                "local_ip": svc.get("local_ip"),
                "local_port": svc.get("local_port"),
                "preset": svc.get("preset"),
                "remote_port": svc.get("remote_port"),
            }
    clients[mid] = {
        "hostname": client.get("hostname"),
        "services": services,
    }
print(json.dumps({
    "clients": clients,
    "reserved": sorted(state.get("reserved") or []),
    "schema_version": state.get("schema_version"),
}, sort_keys=True))
PY
}

frp_registry_readiness() {
  local registry="$1"
  python3 - "$registry" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("none")
    print("missing")
    raise SystemExit(0)
try:
    state = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print("unknown")
    print("invalid")
    raise SystemExit(0)
if not isinstance(state, dict):
    print("unknown")
    print("invalid")
    raise SystemExit(0)
version = state.get("schema_version")
if version is None:
    print("1")
    print("incompatible")
    raise SystemExit(0)
print(str(version))
if version != 2:
    print("incompatible")
    raise SystemExit(0)
clients = state.get("clients", {}) or {}
if not isinstance(clients, dict):
    print("incompatible")
    raise SystemExit(0)
for client in clients.values():
    if not isinstance(client, dict) or "ssh_port" in client or "https_port" in client:
        print("incompatible")
        raise SystemExit(0)
print("ready")
PY
}

frp_registry_counts() {
  local registry="$1"
  python3 - "$registry" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("0 0")
    raise SystemExit(0)
state = json.loads(p.read_text(encoding="utf-8"))
clients = state.get("clients") or {}
used = set()
for item in state.get("reserved") or []:
    try:
        used.add(int(item))
    except Exception:
        pass
for client in clients.values():
    if not isinstance(client, dict):
        continue
    services = client.get("services") or {}
    if not isinstance(services, dict):
        continue
    for svc in services.values():
        if not isinstance(svc, dict):
            continue
        value = svc.get("remote_port")
        if value:
            try:
                used.add(int(value))
            except Exception:
                pass
print(f"{len(clients)} {len(used)}")
PY
}

frp_valid_version() {
  local v="$1"
  printf '%s' "$v" | python3 -c '
import re,sys
sys.exit(0 if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", sys.stdin.read().strip()) else 1)
'
}

frp_upstream_latest() {
  if [[ "${FRP_STATUS_SKIP_UPSTREAM:-}" == "1" ]]; then
    printf '%s' "unavailable"
    return 0
  fi
  python3 - <<'PY'
import json, sys, urllib.request
url = "https://api.github.com/repos/fatedier/frp/releases/latest"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "frp-auto-deploy"})
try:
    with urllib.request.urlopen(req, timeout=3) as resp:
        data = json.loads(resp.read().decode())
    tag = str(data.get("tag_name") or "").strip()
    if tag.startswith("v"):
        tag = tag[1:]
    sys.stdout.write(tag if tag else "unavailable")
except Exception:
    sys.stdout.write("unavailable")
PY
}

frp_has_disk_kb() {
  local path="$1" need_kb="$2" avail check="$1"
  while [[ ! -d "$check" && "$check" != "/" && -n "$check" ]]; do
    check="$(dirname "$check")"
  done
  avail="$(df -Pk "$check" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "$avail" ]]; then
    return 0
  fi
  [[ "$avail" -ge "$need_kb" ]]
}
