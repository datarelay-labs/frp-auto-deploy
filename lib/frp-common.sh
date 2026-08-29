#!/usr/bin/env bash
# Shared constants and helpers for FRP binary lifecycle management.
# Source this file; do not execute it.

if [[ -n "${FRP_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_COMMON_LOADED=1

# Defaults match VERSION. A sibling VERSION file overrides project/FRP versions.
PROJECT_VERSION="${PROJECT_VERSION:-2.1.0}"
FRP_VERSION="${FRP_VERSION:-0.70.1}"
# FRP 0.70.1 pkg/util/net/websocket.go FrpWebsocketPath. Not configurable.
FRP_WEBSOCKET_PATH="${FRP_WEBSOCKET_PATH:-/~!frp}"
FRP_SINGLE443_BACKEND_PORT="${FRP_SINGLE443_BACKEND_PORT:-7000}"
FRP_SHA256_AMD64="${FRP_SHA256_AMD64:-333da23d1b9009d7c01638e9ba38cf4600f7d37d393f854e96ee1396adefa9a6}"
FRP_SHA256_ARM64="${FRP_SHA256_ARM64:-3990f396a9a490ee7f0e5f355287750ed41520064ed999eab443b5e9a78d773d}"

_FRP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_FRP_COMMON_DIR}/../VERSION" ]]; then
  # shellcheck disable=SC1091
  . "${_FRP_COMMON_DIR}/../VERSION"
fi

FRP_GITHUB_OWNER="${FRP_GITHUB_OWNER:-datarelay-labs}"
FRP_GITHUB_REPO="${FRP_GITHUB_REPO:-frp-auto-deploy}"
FRP_GITHUB_RAW_HOST="${FRP_GITHUB_RAW_HOST:-raw.githubusercontent.com}"

frp_normalize_release_channel() {
  local ch
  ch="$(printf '%s' "${1:-stable}" | tr '[:upper:]' '[:lower:]')"
  case "$ch" in
    dev|main|development) printf 'dev' ;;
    *) printf 'stable' ;;
  esac
}

frp_version_state_file() {
  local root="${FRP_DEPLOY_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-${FRP_CTL_TEST_ROOT:-${FRP_UPDATE_ROOT:-}}}}"
  if [[ -n "$root" ]]; then
    printf '%s' "${root}/etc/frp-auto-deploy/version"
  else
    printf '%s' '/etc/frp-auto-deploy/version'
  fi
}

frp_persisted_release_channel() {
  local file ch
  file="$(frp_version_state_file)"
  ch="$(frp_read_kv_file "$file" RELEASE_CHANNEL)"
  if [[ -z "$ch" ]]; then
    return 0
  fi
  frp_normalize_release_channel "$ch"
}

frp_release_channel() {
  local ch
  if [[ -n "${FRP_RELEASE_CHANNEL:-}" ]]; then
    frp_normalize_release_channel "$FRP_RELEASE_CHANNEL"
    return 0
  fi
  ch="$(frp_persisted_release_channel)"
  if [[ -n "$ch" ]]; then
    printf '%s' "$ch"
    return 0
  fi
  printf 'stable'
}

frp_release_git_ref() {
  if [[ "$(frp_release_channel)" == "dev" ]]; then
    printf 'main'
  else
    printf 'v%s' "${PROJECT_VERSION}"
  fi
}

frp_github_raw_url() {
  local rel="${1:-}"
  rel="${rel#/}"
  printf 'https://%s/%s/%s/%s/%s' \
    "$FRP_GITHUB_RAW_HOST" "$FRP_GITHUB_OWNER" "$FRP_GITHUB_REPO" \
    "$(frp_release_git_ref)" "$rel"
}

frp_default_client_installer_url() {
  frp_github_raw_url dist/bootstrap-client.sh
}

frp_default_client_update_url() {
  frp_github_raw_url dist/bootstrap-client.sh
}

frp_default_client_update_metadata_url() {
  frp_github_raw_url SHA256SUMS
}

frp_default_server_project_update_url() {
  frp_github_raw_url dist/bootstrap-server.sh
}

frp_default_release_sha256sums_url() {
  frp_github_raw_url SHA256SUMS
}

frp_sha256sum_entry() {
  local sums_file="$1" artifact="$2"
  [[ -f "$sums_file" ]] || return 1
  awk -v name="$artifact" '
    $2 == name && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      if (found) exit 2
      digest=tolower($1)
      found=1
    }
    END {
      if (found == 1) print digest
      else exit 1
    }
  ' "$sums_file"
}

frp_validate_https_url() {
  local url="${1:-}"
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    port = parsed.port
except (TypeError, ValueError):
    raise SystemExit(1)
if (
    parsed.scheme != "https"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or port is not None and not (1 <= port <= 65535)
):
    raise SystemExit(1)
PY
}

frp_url_has_source_ref() {
  local url="${1:-}" ref="${2:-}"
  python3 - "$url" "$ref" <<'PY'
import sys
from urllib.parse import unquote, urlsplit

parts = [unquote(part) for part in urlsplit(sys.argv[1]).path.split("/") if part]
raise SystemExit(0 if sys.argv[2] in parts else 1)
PY
}

frp_is_official_main_installer_url() {
  local url="${1:-}"
  [[ "$url" == "https://${FRP_GITHUB_RAW_HOST}/${FRP_GITHUB_OWNER}/${FRP_GITHUB_REPO}/main/dist/bootstrap-client.sh" ]]
}

frp_release_manifest_path() {
  if [[ -n "${FRP_RELEASE_MANIFEST:-}" && -f "${FRP_RELEASE_MANIFEST}" ]]; then
    printf '%s' "$FRP_RELEASE_MANIFEST"
    return 0
  fi
  if [[ -f "${_FRP_COMMON_DIR}/../release-manifest.json" ]]; then
    printf '%s' "${_FRP_COMMON_DIR}/../release-manifest.json"
    return 0
  fi
  if [[ -f /usr/local/lib/frp-auto-deploy/release-manifest.json ]]; then
    printf '%s' /usr/local/lib/frp-auto-deploy/release-manifest.json
    return 0
  fi
  return 1
}

frp_release_artifact_sha256() {
  local name="${1:-bootstrap-client.sh}" path
  path="$(frp_release_manifest_path)" || return 1
  python3 - "$path" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    data = json.loads(open(path, encoding='utf-8').read())
except Exception:
    raise SystemExit(1)
art = (data.get('artifacts') or {}).get(name) or {}
digest = str(art.get('sha256') or '').strip().lower()
if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
    raise SystemExit(1)
print(digest)
PY
}

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
  local machine
  machine="${FRP_TEST_UNAME_M:-$(uname -m)}"
  case "$machine" in
    x86_64)
      FRP_ARCH=amd64
      EXPECTED_SHA="${FRP_SHA256_AMD64}"
      ;;
    aarch64|arm64)
      FRP_ARCH=arm64
      EXPECTED_SHA="${FRP_SHA256_ARM64}"
      ;;
    *)
      echo "ERROR: unsupported architecture: ${machine}" >&2
      return 1
      ;;
  esac
}

frp_detect_architecture() {
  frp_detect_arch
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
  frp_require_safe_write_path "$dest" || return 1
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
  local dir tmp channel source_ref bundle existing
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  if [[ -n "${FRP_RELEASE_CHANNEL:-}" ]]; then
    channel="$(frp_normalize_release_channel "$FRP_RELEASE_CHANNEL")"
  else
    existing="$(frp_read_kv_file "$dest" RELEASE_CHANNEL)"
    if [[ -n "$existing" ]]; then
      channel="$(frp_normalize_release_channel "$existing")"
    else
      channel="$(frp_release_channel)"
    fi
  fi
  if [[ "$channel" == "dev" ]]; then
    source_ref="main"
  else
    source_ref="v${PROJECT_VERSION}"
  fi
  bundle="${FRP_BUNDLE_SHA256:-}"
  if [[ -z "$bundle" && -n "${FRP_BUNDLE_FILE:-}" && -f "${FRP_BUNDLE_FILE}" ]]; then
    bundle="$(sha256sum "${FRP_BUNDLE_FILE}" | awk '{print $1}')"
  fi
  if [[ -z "$bundle" ]]; then
    bundle="$(frp_read_kv_file "$dest" BUNDLE_SHA256)"
  fi
  if [[ -z "$bundle" ]]; then
    local cand=""
    if [[ "${2:-}" == "client" ]]; then
      cand="${_FRP_COMMON_DIR}/../dist/bootstrap-client.sh"
    else
      cand="${_FRP_COMMON_DIR}/../dist/bootstrap-server.sh"
    fi
    if [[ -f "$cand" ]]; then
      bundle="$(sha256sum "$cand" | awk '{print $1}')"
    fi
  fi
  tmp="$(mktemp "${dir}/.version.XXXXXX")"
  {
    printf 'PROJECT_VERSION=%s\n' "${PROJECT_VERSION}"
    printf 'FRP_VERSION=%s\n' "${FRP_VERSION}"
    printf 'RELEASE_CHANNEL=%s\n' "${channel}"
    printf 'SOURCE_REF=%s\n' "${source_ref}"
    if [[ -n "$bundle" ]]; then
      printf 'BUNDLE_SHA256=%s\n' "$bundle"
    fi
  } >"$tmp"
  chmod 0644 "$tmp"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
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
  local raw=""
  if ! frp_command_exists ss; then
    return 2
  fi
  if raw="$(frp_invoke ss -H -lnt 2>/dev/null)"; then
    :
  elif raw="$(frp_invoke ss -lnt 2>/dev/null)"; then
    :
  else
    return 2
  fi
  if printf '%s\n' "$raw" | awk -v wanted="$port" '
    $1 ~ /^(State|Netid)$/ { next }
    {
      p=$4
      gsub(/\]$/, "", p)
      sub(/^.*:/, "", p)
      if (p == wanted) found=1
    }
    END { exit(found ? 0 : 1) }
  '; then
    return 0
  fi
  return 1
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

# ---------------------------------------------------------------------------
# Cross-distro host detection (capability-based; not distro-id switches)
# ---------------------------------------------------------------------------

FRP_PYTHON_MIN_MAJOR=3
FRP_PYTHON_MIN_MINOR=7
FRP_BASH_MIN_MAJOR=4
FRP_BASH_MIN_MINOR=2
# systemd 232 introduced ProtectSystem=strict and ReadWritePaths.
FRP_SYSTEMD_HARDENING_MIN=232

frp_os_release_file() {
  printf '%s' "${FRP_OS_RELEASE_FILE:-/etc/os-release}"
}

frp_os_release_value() {
  local key="$1" file="$2" line value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        value="${line#*=}"
        if [[ "$value" == \"*\" ]]; then
          value="${value#\"}"
          value="${value%\"}"
        elif [[ "$value" == \'*\' ]]; then
          value="${value#\'}"
          value="${value%\'}"
        fi
        printf '%s' "$value"
        return 0
        ;;
    esac
  done <"$file"
}

frp_detect_platform() {
  local file pretty name
  DISTRO_ID="unknown"
  DISTRO_NAME="Linux"
  DISTRO_VERSION=""
  file="$(frp_os_release_file)"
  if [[ -r "$file" ]]; then
    DISTRO_ID="$(frp_os_release_value ID "$file")"
    DISTRO_ID="${DISTRO_ID:-unknown}"
    pretty="$(frp_os_release_value PRETTY_NAME "$file")"
    name="$(frp_os_release_value NAME "$file")"
    DISTRO_NAME="${pretty:-${name:-Linux}}"
    DISTRO_VERSION="$(frp_os_release_value VERSION_ID "$file")"
  fi
}

frp_command_exists() {
  local cmd="$1"
  if [[ -n "${FRP_TEST_CMD_PATH:-}" ]]; then
    PATH="${FRP_TEST_CMD_PATH}" command -v "$cmd" >/dev/null 2>&1
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

frp_invoke() {
  local cmd="$1"
  shift
  if [[ -n "${FRP_TEST_CMD_PATH:-}" ]]; then
    PATH="${FRP_TEST_CMD_PATH}${PATH:+:$PATH}" command "$cmd" "$@"
  else
    command "$cmd" "$@"
  fi
}

frp_package_manager_exists() {
  local cmd="$1"
  if [[ -n "${FRP_TEST_PM_PATH:-}" ]]; then
    PATH="${FRP_TEST_PM_PATH}" command -v "$cmd" >/dev/null 2>&1
  else
    command -v "$cmd" >/dev/null 2>&1
  fi
}

frp_package_manager_bin() {
  local cmd="$1"
  if [[ -n "${FRP_TEST_PM_PATH:-}" ]]; then
    PATH="${FRP_TEST_PM_PATH}" command -v "$cmd"
  else
    command -v "$cmd"
  fi
}

frp_detect_package_manager() {
  PACKAGE_MANAGER=""
  if frp_package_manager_exists dnf; then
    PACKAGE_MANAGER=dnf
  elif frp_package_manager_exists yum; then
    PACKAGE_MANAGER=yum
  elif frp_package_manager_exists apt-get; then
    PACKAGE_MANAGER=apt
  fi
}

frp_systemd_runtime_dir() {
  printf '%s' "${FRP_TEST_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
}

frp_systemd_usable() {
  [[ -d "$(frp_systemd_runtime_dir)" ]]
}

frp_require_systemd() {
  if ! frp_command_exists systemctl; then
    echo "ERROR: this release requires a systemd-based Linux distribution." >&2
    return 1
  fi
  if ! frp_systemd_usable; then
    echo "ERROR: this release requires a systemd-based Linux distribution." >&2
    return 1
  fi
}

frp_systemd_version() {
  local v="${FRP_TEST_SYSTEMD_VERSION:-}"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
    return 0
  fi
  if ! frp_command_exists systemctl; then
    return 0
  fi
  frp_invoke systemctl --version 2>/dev/null | awk 'NR==1 {print $2; exit}'
}

frp_systemd_supports_service_hardening() {
  local v
  v="$(frp_systemd_version)"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  [[ "$v" -ge "$FRP_SYSTEMD_HARDENING_MIN" ]]
}

# Strip directives that systemd 219 (Amazon Linux 2) cannot honor.
# Unknown ProtectSystem=strict values can fail unit load on old systemd.
frp_write_compatible_systemd_unit() {
  local src="$1" dest="$2"
  local tmp
  if frp_systemd_supports_service_hardening; then
    install -m 0644 "$src" "$dest"
    return 0
  fi
  tmp="$(mktemp)"
  grep -vE '^(NoNewPrivileges|ProtectSystem|ReadWritePaths)=' "$src" >"$tmp"
  install -m 0644 "$tmp" "$dest"
  rm -f "$tmp"
}

frp_print_detected_linux() {
  local pm="${PACKAGE_MANAGER:-none}"
  local init="unknown"
  if frp_command_exists systemctl && frp_systemd_usable; then
    init="systemd"
  fi
  echo "Detected Linux:"
  echo "  Distribution : ${DISTRO_NAME}"
  echo "  Package mgr  : ${pm}"
  echo "  Architecture : ${FRP_ARCH:-unknown}"
  echo "  Init system  : ${init}"
}

frp_require_bash() {
  if (( BASH_VERSINFO[0] < FRP_BASH_MIN_MAJOR || \
        (BASH_VERSINFO[0] == FRP_BASH_MIN_MAJOR && BASH_VERSINFO[1] < FRP_BASH_MIN_MINOR) )); then
    echo "ERROR: Bash ${FRP_BASH_MIN_MAJOR}.${FRP_BASH_MIN_MINOR} or newer is required (found ${BASH_VERSION})." >&2
    return 1
  fi
}

frp_require_python() {
  if ! frp_command_exists python3; then
    echo "ERROR: python3 ${FRP_PYTHON_MIN_MAJOR}.${FRP_PYTHON_MIN_MINOR} or newer is required." >&2
    return 1
  fi
  if ! frp_invoke python3 -c "import sys; raise SystemExit(0 if sys.version_info >= (${FRP_PYTHON_MIN_MAJOR}, ${FRP_PYTHON_MIN_MINOR}) else 1)"; then
    echo "ERROR: python3 ${FRP_PYTHON_MIN_MAJOR}.${FRP_PYTHON_MIN_MINOR} or newer is required." >&2
    echo "This host's python3 is too old for frp-auto-deploy." >&2
    return 1
  fi
}

frp_required_commands() {
  local role="${FRP_DEPENDENCY_ROLE:-client}"
  printf '%s\n' curl openssl python3 tar sha256sum timeout hostname install
  if [[ "$role" == server ]]; then
    printf '%s\n' ss
  fi
}

frp_collect_missing_commands() {
  local cmd
  MISSING_COMMANDS=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    if ! frp_command_exists "$cmd"; then
      MISSING_COMMANDS+=("$cmd")
    fi
  done < <(frp_required_commands)
}

frp_package_for_command() {
  local cmd="$1" pm="$2"
  case "$cmd" in
    curl) printf 'curl' ;;
    openssl) printf 'openssl' ;;
    python3) printf 'python3' ;;
    tar) printf 'tar' ;;
    sha256sum|timeout|install) printf 'coreutils' ;;
    hostname) printf 'hostname' ;;
    ss|ip)
      if [[ "$pm" == apt ]]; then
        printf 'iproute2'
      else
        printf 'iproute'
      fi
      ;;
    nginx) printf 'nginx' ;;
    *)
      echo "ERROR: no package mapping for command: ${cmd}" >&2
      return 1
      ;;
  esac
}

frp_packages_for_missing() {
  local pm="$1" cmd pkg existing existing_pkg
  PACKAGES=(ca-certificates)
  for cmd in "${MISSING_COMMANDS[@]}"; do
    pkg="$(frp_package_for_command "$cmd" "$pm")"
    existing=0
    for existing_pkg in "${PACKAGES[@]}"; do
      if [[ "$existing_pkg" == "$pkg" ]]; then
        existing=1
        break
      fi
    done
    if (( existing == 0 )); then
      PACKAGES+=("$pkg")
    fi
  done
}

install_dependencies_apt() {
  local bin
  bin="$(frp_package_manager_bin apt-get)"
  export DEBIAN_FRONTEND=noninteractive
  "$bin" update
  "$bin" install -y --no-install-recommends "$@"
}

install_dependencies_dnf() {
  local bin
  bin="$(frp_package_manager_bin dnf)"
  "$bin" install -y "$@"
}

install_dependencies_yum() {
  local bin
  bin="$(frp_package_manager_bin yum)"
  "$bin" install -y "$@"
}

frp_print_missing_tools_error() {
  local cmd
  echo "ERROR: required tools are missing:" >&2
  for cmd in "${MISSING_COMMANDS[@]}"; do
    echo "  ${cmd}" >&2
  done
  echo >&2
  echo "Automatic dependency installation supports apt, dnf, and yum." >&2
  echo "Install the missing tools manually and run the installer again." >&2
}

ensure_dependencies() {
  frp_collect_missing_commands
  if ((${#MISSING_COMMANDS[@]} == 0)); then
    return 0
  fi
  if [[ -z "${PACKAGE_MANAGER:-}" ]]; then
    frp_detect_package_manager
  fi
  if [[ -z "${PACKAGE_MANAGER:-}" ]]; then
    frp_print_missing_tools_error
    return 1
  fi
  frp_packages_for_missing "$PACKAGE_MANAGER"
  case "$PACKAGE_MANAGER" in
    apt) install_dependencies_apt "${PACKAGES[@]}" ;;
    dnf) install_dependencies_dnf "${PACKAGES[@]}" ;;
    yum) install_dependencies_yum "${PACKAGES[@]}" ;;
    *)
      echo "ERROR: unsupported package manager: ${PACKAGE_MANAGER}" >&2
      return 1
      ;;
  esac
  frp_collect_missing_commands
  if ((${#MISSING_COMMANDS[@]} > 0)); then
    echo "ERROR: missing required command after dependency installation:" >&2
    local cmd
    for cmd in "${MISSING_COMMANDS[@]}"; do
      echo "  ${cmd}" >&2
    done
    return 1
  fi
}

frp_detect_internal_ip() {
  local ip=""
  if frp_command_exists hostname; then
    ip="$(frp_invoke hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$ip" ]] && frp_command_exists ip; then
    ip="$(frp_invoke ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
  printf '%s' "$ip"
}

frp_short_hostname() {
  local h=""
  if [[ -n "${FRP_TEST_HOSTNAME:-}" ]]; then
    printf '%s' "$FRP_TEST_HOSTNAME"
    return 0
  fi
  if frp_command_exists hostname; then
    h="$(frp_invoke hostname -s 2>/dev/null || frp_invoke hostname 2>/dev/null || true)"
  fi
  if [[ -z "$h" ]]; then
    h="$(uname -n 2>/dev/null || true)"
  fi
  h="${h%%.*}"
  printf '%s' "$h"
}

# Parse `ss -lnt` with or without -H (Amazon Linux 2 iproute may lack --no-header).
frp_listening_tcp_ports_in_range() {
  local start="$1" end="$2" raw=""
  if ! frp_command_exists ss; then
    return 0
  fi
  raw="$(frp_invoke ss -H -lnt 2>/dev/null || frp_invoke ss -lnt 2>/dev/null || true)"
  printf '%s\n' "$raw" | awk -v s="$start" -v e="$end" '
    $1 ~ /^(State|Netid)$/ { next }
    {
      p=$4
      gsub(/\]$/, "", p)
      sub(/^.*:/, "", p)
      if (p ~ /^[0-9]+$/ && p+0>=s && p+0<=e) print p
    }
  ' | sort -nu | paste -sd, - 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Software-lifecycle helpers (install / update / uninstall)
# ---------------------------------------------------------------------------

FRP_BACKUP_KEEP="${FRP_BACKUP_KEEP:-5}"

if ! declare -F frp_emit_failure_class >/dev/null 2>&1; then
  frp_emit_failure_class() {
    local class="$1"
    printf 'FAILURE_CLASS=%s\n' "$class"
    printf 'FAILURE_CLASS=%s\n' "$class" >&2
  }
fi

frp_is_unsafe_delete_path() {
  local path="${1:-}"
  if [[ -z "$path" || "$path" == "/" || "$path" == "." || "$path" == ".." || "$path" == "//" ]]; then
    return 0
  fi
  case "$path" in
    /*) ;;
    *) return 0 ;;
  esac
  return 1
}

frp_path_has_symlink_component() {
  local path="${1:-}"
  local parent
  if [[ -L "$path" ]]; then
    return 0
  fi
  parent="${path%/*}"
  if [[ -n "$parent" && "$parent" != "$path" && -L "$parent" ]]; then
    return 0
  fi
  return 1
}

frp_require_safe_write_path() {
  local path="${1:-}"
  if frp_is_unsafe_delete_path "$path"; then
    echo "ERROR: refusing unsafe installation path" >&2
    frp_emit_failure_class PATH_DELETION_REFUSED
    return 1
  fi
  if [[ -e "$path" || -L "$path" ]] && frp_path_has_symlink_component "$path"; then
    echo "ERROR: refusing to write through a symlink: ${path}" >&2
    frp_emit_failure_class SYMLINK_REFUSED
    return 1
  fi
  local parent
  parent="${path%/*}"
  if [[ -n "$parent" && "$parent" != "$path" && ( -e "$parent" || -L "$parent" ) ]]; then
    if frp_path_has_symlink_component "$parent"; then
      echo "ERROR: refusing to write through a symlink parent: ${path}" >&2
      frp_emit_failure_class SYMLINK_REFUSED
      return 1
    fi
  fi
  return 0
}

frp_safe_rm_rf() {
  local path="${1:-}"
  if frp_is_unsafe_delete_path "$path"; then
    echo "ERROR: refusing unsafe recursive deletion" >&2
    frp_emit_failure_class PATH_DELETION_REFUSED
    return 1
  fi
  if [[ -L "$path" ]]; then
    echo "ERROR: refusing to recursively delete through a symlink" >&2
    frp_emit_failure_class SYMLINK_REFUSED
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ ! -d "$path" ]]; then
    echo "ERROR: refusing recursive deletion of a non-directory" >&2
    frp_emit_failure_class PATH_DELETION_REFUSED
    return 1
  fi
  rm -rf "$path"
}

frp_atomic_write() {
  local dest="$1" mode="${2:-0600}"
  local dir tmp
  frp_require_safe_write_path "$dest" || return 1
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.frp-write.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest"
}

frp_secure_mktemp_dir() {
  local dir
  dir="$(mktemp -d)"
  chmod 700 "$dir"
  printf '%s' "$dir"
}

frp_version_compare() {
  python3 - "$1" "$2" <<'PY'
import re, sys
def parse(v):
    text = (v or "").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text):
        return None
    return tuple(int(x) for x in text.split("."))
a, b = parse(sys.argv[1]), parse(sys.argv[2])
if a is None or b is None:
    print("invalid")
    raise SystemExit(0)
if a > b:
    print("gt")
elif a < b:
    print("lt")
else:
    print("eq")
PY
}

frp_elf_arch_label() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if not path.is_file():
    print("missing")
    raise SystemExit(0)
data = path.read_bytes()
if len(data) < 20 or data[:4] != b"\x7fELF":
    print("non-elf")
    raise SystemExit(0)
endian = "little" if data[5] == 1 else "big"
machine = int.from_bytes(data[18:20], endian)
if machine == 62:
    print("amd64")
elif machine == 183:
    print("arm64")
else:
    print("other")
PY
}

frp_extract_frp_member() {
  local archive="$1" dest_dir="$2" member="$3"
  python3 - "$archive" "$dest_dir" "$member" <<'PY'
import os, sys, tarfile
from pathlib import Path

archive, dest_dir, member = sys.argv[1], sys.argv[2], sys.argv[3]
dest = Path(dest_dir)
dest.mkdir(parents=True, exist_ok=True)
out = dest / member

def unsafe(name):
    name = name.replace("\\", "/")
    if name.startswith("/") or name.startswith("../") or name == ".." or "/../" in name:
        return True
    if name.endswith("/.."):
        return True
    return False

found = None
try:
    tf = tarfile.open(archive, "r:*")
except tarfile.TarError:
    sys.stderr.write("ERROR: archive is not a valid tar file\n")
    raise SystemExit(1)
with tf:
    for info in tf.getmembers():
        name = info.name.replace("\\", "/")
        if unsafe(name):
            sys.stderr.write("ERROR: archive contains an unsafe path\n")
            raise SystemExit(1)
        if Path(name).name != member:
            continue
        if info.issym() or info.islnk():
            sys.stderr.write("ERROR: archive member %s is a link\n" % member)
            raise SystemExit(1)
        if not info.isfile():
            continue
        found = info
        break
    if found is None:
        sys.stderr.write("ERROR: archive did not contain expected file %s\n" % member)
        raise SystemExit(1)
    src = tf.extractfile(found)
    if src is None:
        sys.stderr.write("ERROR: failed to read archive member %s\n" % member)
        raise SystemExit(1)
    data = src.read()
tmp = dest / (".%s.extract" % member)
tmp.write_bytes(data)
os.chmod(str(tmp), 0o755)
tmp.replace(out)
print(str(out))
PY
}

frp_validate_frp_binary() {
  local bin="$1" expected_ver="$2" expected_arch="${3:-}"
  local elf ver
  [[ -f "$bin" ]] || {
    echo "ERROR: candidate binary is missing" >&2
    return 1
  }
  [[ -x "$bin" ]] || {
    echo "ERROR: candidate is not executable" >&2
    return 1
  }
  elf="$(frp_elf_arch_label "$bin")"
  if [[ "$elf" != "non-elf" && "$elf" != "missing" && -n "$expected_arch" && "$elf" != "$expected_arch" ]]; then
    echo "ERROR: candidate architecture (${elf}) does not match this host (${expected_arch})" >&2
    return 1
  fi
  ver="$(frp_parse_binary_version "$bin")"
  if [[ "$ver" != "$expected_ver" ]]; then
    echo "ERROR: candidate FRP version (${ver}) is not the pinned version (${expected_ver})" >&2
    return 1
  fi
  return 0
}

frp_prune_backup_dirs() {
  local root="$1" keep="${2:-$FRP_BACKUP_KEEP}"
  python3 - "$root" "$keep" <<'PY'
import shutil, sys
from pathlib import Path
root = Path(sys.argv[1])
keep = int(sys.argv[2])
if not root.is_dir():
    raise SystemExit(0)
dirs = sorted([p for p in root.iterdir() if p.is_dir()], key=lambda p: p.name)
for extra in dirs[: max(0, len(dirs) - keep)]:
    shutil.rmtree(extra, ignore_errors=True)
PY
}

frp_txn_marker_path() {
  local root="${FRP_UPDATE_ROOT:-${FRP_DEPLOY_TEST_ROOT:-${FRP_SERVER_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-${FRP_UNINSTALL_TEST_ROOT:-}}}}}"
  if [[ -n "$root" ]]; then
    printf '%s' "${root}/var/lib/frp-auto-deploy/update-pending.json"
  else
    printf '%s' /var/lib/frp-auto-deploy/update-pending.json
  fi
}

frp_txn_write() {
  local operation="$1" phase="$2" previous="${3:-}" candidate="${4:-}"
  local marker dir tmp
  marker="$(frp_txn_marker_path)"
  dir="$(dirname "$marker")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${dir}/.update-pending.XXXXXX")"
  python3 - "$tmp" "$operation" "$phase" "$previous" "$candidate" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "operation": sys.argv[2],
    "phase": sys.argv[3],
    "previous_version": sys.argv[4],
    "candidate_version": sys.argv[5],
}, sort_keys=True) + "\n", encoding="utf-8")
PY
  chmod 0644 "$tmp"
  mv -f "$tmp" "$marker"
}

frp_txn_clear() {
  local marker
  marker="$(frp_txn_marker_path)"
  rm -f "$marker"
}

frp_role_fs() {
  local p="$1"
  local root="${FRP_ROLE_TEST_ROOT:-${FRP_SERVER_TEST_ROOT:-${FRP_CLIENT_TEST_ROOT:-${FRP_UNINSTALL_TEST_ROOT:-${FRP_DEPLOY_TEST_ROOT:-${FRP_UPDATE_ROOT:-}}}}}}"
  if [[ -n "$root" ]]; then
    printf '%s' "${root}${p}"
  else
    printf '%s' "$p"
  fi
}

frp_detect_host_role() {
  local server_signals=0 client_signals=0
  local has_server_config=0 has_client_state=0
  FRP_HOST_ROLE=absent
  [[ -f "$(frp_role_fs /etc/frp-auto-deploy/config.json)" ]] && { has_server_config=1; server_signals=$((server_signals + 1)); }
  [[ -f "$(frp_role_fs /etc/frp/server_token)" ]] && server_signals=$((server_signals + 1))
  [[ -f "$(frp_role_fs /var/lib/frp-auto-deploy/registry.json)" ]] && server_signals=$((server_signals + 1))
  [[ -f "$(frp_role_fs /etc/frp/frps.toml)" ]] && server_signals=$((server_signals + 1))
  [[ -x "$(frp_role_fs /usr/local/bin/frps)" ]] && server_signals=$((server_signals + 1))
  [[ -x "$(frp_role_fs /usr/local/sbin/frp-create-client)" ]] && server_signals=$((server_signals + 1))
  [[ -f "$(frp_role_fs /etc/frp/client-state.json)" ]] && { has_client_state=1; client_signals=$((client_signals + 1)); }
  [[ -f "$(frp_role_fs /etc/frp/frpc.toml)" ]] && client_signals=$((client_signals + 1))
  [[ -f "$(frp_role_fs /etc/frp/client-identity.key)" ]] && client_signals=$((client_signals + 1))
  [[ -x "$(frp_role_fs /usr/local/bin/frpc)" ]] && client_signals=$((client_signals + 1))
  [[ -x "$(frp_role_fs /usr/local/bin/frp-client)" ]] && client_signals=$((client_signals + 1))
  if (( server_signals >= 2 && client_signals >= 2 )); then
    FRP_HOST_ROLE=both
  elif (( server_signals >= 2 )); then
    FRP_HOST_ROLE=server
  elif (( client_signals >= 2 )); then
    FRP_HOST_ROLE=client
  elif [[ "$has_server_config" == "1" ]]; then
    FRP_HOST_ROLE=server
  elif [[ "$has_client_state" == "1" ]]; then
    FRP_HOST_ROLE=client
  elif (( server_signals == 1 )); then
    FRP_HOST_ROLE=partial-server
  elif (( client_signals == 1 )); then
    FRP_HOST_ROLE=partial-client
  else
    FRP_HOST_ROLE=absent
  fi
}
