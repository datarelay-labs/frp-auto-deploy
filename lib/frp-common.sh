#!/usr/bin/env bash
# Shared constants and helpers for FRP binary lifecycle management.
# Source this file; do not execute it.

if [[ -n "${FRP_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_COMMON_LOADED=1

# Defaults match VERSION. A sibling VERSION file overrides project/FRP versions.
PROJECT_VERSION="${PROJECT_VERSION:-1.5.0}"
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
