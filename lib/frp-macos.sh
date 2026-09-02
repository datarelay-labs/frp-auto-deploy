#!/usr/bin/env bash
# Apple Silicon macOS support: filesystem layout, Homebrew prefix discovery,
# launchd service control, and stable machine identity.
#
# Source this file; do not execute it. lib/frp-common.sh loads it on every
# platform so that path mapping resolves the same way regardless of source
# order. Every function here is inert unless frp_is_darwin reports true, which
# keeps Linux behavior unchanged and lets a Linux host run the portable macOS
# unit tests with FRP_TEST_UNAME_S=Darwin.

if [[ -n "${FRP_MACOS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_MACOS_LOADED=1

# Reverse-DNS label shared by the LaunchDaemon plist, launchctl, and the
# Homebrew formula. Changing it orphans daemons on already-installed hosts.
FRP_MACOS_LAUNCHD_LABEL="${FRP_MACOS_LAUNCHD_LABEL:-com.datarelay.frp-auto-deploy.frpc}"
FRP_MACOS_STATE_ROOT_DEFAULT='/Library/Application Support/frp-auto-deploy'
FRP_MACOS_LAUNCHDAEMON_DIR='/Library/LaunchDaemons'
FRP_MACOS_MIN_PRODUCT_VERSION="${FRP_MACOS_MIN_PRODUCT_VERSION:-11}"

# ---------------------------------------------------------------------------
# Filesystem layout
# ---------------------------------------------------------------------------

frp_macos_state_root() {
  printf '%s' "${FRP_MACOS_STATE_ROOT:-$FRP_MACOS_STATE_ROOT_DEFAULT}"
}

frp_macos_plist_path() {
  printf '%s/%s.plist' "$FRP_MACOS_LAUNCHDAEMON_DIR" "$FRP_MACOS_LAUNCHD_LABEL"
}

frp_macos_log_dir() {
  printf '%s/logs' "$(frp_macos_state_root)"
}

# Absolute path of the pinned frpc runtime binary.
#
# frpc is deliberately NOT installed into the Homebrew prefix. The LaunchDaemon
# runs it as root at boot, and a Homebrew prefix is writable by any admin user,
# which would turn a root daemon into a local privilege-escalation path. The
# state root is created root:wheel 0755 by the installer, so the daemon only
# ever executes a root-owned binary. User-facing CLI entry points (frpctl,
# frp-client) still land in the Homebrew prefix so they are on PATH.
frp_macos_frpc_path() {
  printf '%s/bin/frpc' "$(frp_macos_state_root)"
}

# Homebrew prefix, or /usr/local when Homebrew is absent.
#
# /opt/homebrew is never hardcoded: it is discovered from `brew --prefix`, or
# from the location of the brew executable when Homebrew refuses to answer
# (it declines to run as root, which is the normal case under sudo).
frp_macos_brew_prefix() {
  local prefix="" brew_bin="" brew_dir=""
  if [[ -n "${FRP_MACOS_PREFIX:-}" ]]; then
    printf '%s' "${FRP_MACOS_PREFIX}"
    return 0
  fi
  if frp_command_exists brew; then
    prefix="$(frp_invoke brew --prefix 2>/dev/null || true)"
    prefix="${prefix%%$'\n'*}"
    if [[ -z "$prefix" && -n "${SUDO_USER:-}" ]] && frp_command_exists sudo; then
      # Homebrew refuses to run as root; ask as the invoking user instead.
      prefix="$(frp_invoke sudo -n -u "${SUDO_USER}" brew --prefix 2>/dev/null || true)"
      prefix="${prefix%%$'\n'*}"
    fi
    if [[ -z "$prefix" ]]; then
      brew_bin="$(frp_invoke command -v brew 2>/dev/null || true)"
      if [[ -n "$brew_bin" ]]; then
        brew_dir="$(dirname "$brew_bin")"
        prefix="$(dirname "$brew_dir")"
      fi
    fi
  fi
  case "$prefix" in
    /*) ;;
    *) prefix="" ;;
  esac
  if [[ -z "$prefix" || ! -d "$prefix" ]]; then
    prefix=/usr/local
  fi
  # Strip a trailing slash so joins never produce a doubled separator.
  while [[ "$prefix" != "/" && "$prefix" == */ ]]; do
    prefix="${prefix%/}"
  done
  printf '%s' "$prefix"
}

frp_macos_bin_dir() {
  printf '%s/bin' "$(frp_macos_brew_prefix)"
}

# Rewrite a canonical Linux FHS path onto the macOS layout.
#
#   /etc/frp/...                     -> <state>/...
#   /etc/frp-auto-deploy/...         -> <state>/...
#   /var/lib/frp-auto-deploy/...     -> <state>/state/...
#   /usr/local/lib/frp-auto-deploy/. -> <state>/lib/...
#   /usr/local/bin/frpc              -> <state>/bin/frpc
#   /usr/local/bin/...               -> <brew prefix>/bin/...
#   /usr/local/sbin/...              -> <brew prefix>/sbin/...
#   /etc/systemd/system/frpc.service -> /Library/LaunchDaemons/<label>.plist
#
# Unknown paths pass through unchanged.
frp_macos_map_path() {
  local p="${1:-}" state prefix
  if ! frp_is_darwin; then
    printf '%s' "$p"
    return 0
  fi
  state="$(frp_macos_state_root)"
  case "$p" in
    /etc/frp|/etc/frp-auto-deploy)
      printf '%s' "$state"
      return 0
      ;;
    /etc/frp/*)
      printf '%s/%s' "$state" "${p#/etc/frp/}"
      return 0
      ;;
    /etc/frp-auto-deploy/*)
      printf '%s/%s' "$state" "${p#/etc/frp-auto-deploy/}"
      return 0
      ;;
    /var/lib/frp-auto-deploy)
      printf '%s/state' "$state"
      return 0
      ;;
    /var/lib/frp-auto-deploy/*)
      printf '%s/state/%s' "$state" "${p#/var/lib/frp-auto-deploy/}"
      return 0
      ;;
    /etc/systemd/system/frpc.service)
      frp_macos_plist_path
      return 0
      ;;
    /usr/local/lib/frp-auto-deploy)
      printf '%s/lib' "$state"
      return 0
      ;;
    /usr/local/lib/frp-auto-deploy/*)
      printf '%s/lib/%s' "$state" "${p#/usr/local/lib/frp-auto-deploy/}"
      return 0
      ;;
    /usr/local/bin/frpc)
      frp_macos_frpc_path
      return 0
      ;;
  esac
  prefix="$(frp_macos_brew_prefix)"
  case "$p" in
    /usr/local/bin/*)
      printf '%s/bin/%s' "$prefix" "${p#/usr/local/bin/}"
      return 0
      ;;
    /usr/local/sbin/*)
      printf '%s/sbin/%s' "$prefix" "${p#/usr/local/sbin/}"
      return 0
      ;;
  esac
  printf '%s' "$p"
}

# Map a canonical path and apply the active client test root. Self-contained so
# that frp-macos.sh stays usable from uninstall-client.sh and from tests that
# have not sourced lib/frp-client-common.sh.
frp_macos_fs() {
  local p root
  p="$(frp_macos_map_path "$1")"
  root="${FRP_CLIENT_TEST_ROOT:-${FRP_CTL_TEST_ROOT:-${FRP_UNINSTALL_TEST_ROOT:-${FRP_DEPLOY_TEST_ROOT:-}}}}"
  if [[ -n "$root" ]]; then
    printf '%s' "${root}${p}"
  else
    printf '%s' "$p"
  fi
}

# Create the root-owned directory skeleton the daemon depends on.
frp_macos_ensure_dirs() {
  local state logs dir
  frp_is_darwin || return 0
  state="$(frp_macos_fs /etc/frp)"
  logs="${state}/logs"
  for dir in "$state" "$state/bin" "$state/lib" "$state/state" "$logs"; do
    mkdir -p "$dir" || return 1
    chmod 0755 "$dir" 2>/dev/null || true
    if [[ ${EUID} -eq 0 ]]; then
      chown root:wheel "$dir" 2>/dev/null || true
    fi
  done
  # Logs may contain endpoint metadata; keep them out of reach of local users.
  chmod 0750 "$logs" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Host identity
# ---------------------------------------------------------------------------

frp_macos_platform_uuid() {
  local uuid="${FRP_TEST_IOPLATFORM_UUID:-}"
  if [[ -z "$uuid" ]] && frp_command_exists ioreg; then
    uuid="$(frp_invoke ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
      awk -F'"' '/IOPlatformUUID/ { print $4; exit }')"
  fi
  uuid="$(printf '%s' "$uuid" | tr -d '[:space:]')"
  if [[ ! "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    return 1
  fi
  printf '%s' "$uuid" | tr '[:lower:]' '[:upper:]'
}

# Stable immutable client identity: 32 lowercase hex, same shape as a Linux
# /etc/machine-id. Derived from IOPlatformUUID, which survives renames, user
# changes, and OS upgrades. Hashed with a domain separator so the raw hardware
# UUID is never transmitted or stored in the registry. The hostname stays
# mutable metadata and is never part of this value.
frp_macos_machine_id() {
  local uuid
  uuid="$(frp_macos_platform_uuid)" || {
    echo "ERROR: could not read IOPlatformUUID from ioreg." >&2
    echo "A stable machine identity is required to enroll this Mac." >&2
    return 1
  }
  printf '%s' "$uuid" | python3 -c '
import hashlib, sys
uuid = sys.stdin.read().strip()
digest = hashlib.sha256(("frp-auto-deploy:macos:" + uuid).encode("utf-8")).hexdigest()
sys.stdout.write(digest[:32])
'
}

frp_macos_product_version() {
  local v="${FRP_TEST_MACOS_PRODUCT_VERSION:-}"
  if [[ -z "$v" ]] && frp_command_exists sw_vers; then
    v="$(frp_invoke sw_vers -productVersion 2>/dev/null || true)"
  fi
  printf '%s' "$v"
}

frp_macos_require_supported_release() {
  local v major
  v="$(frp_macos_product_version)"
  if [[ -z "$v" ]]; then
    return 0
  fi
  major="${v%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if (( major < FRP_MACOS_MIN_PRODUCT_VERSION )); then
    echo "ERROR: macOS ${v} is older than the supported minimum (macOS ${FRP_MACOS_MIN_PRODUCT_VERSION})." >&2
    return 1
  fi
  return 0
}

frp_macos_print_detected() {
  local version prefix init="none"
  version="$(frp_macos_product_version)"
  prefix="$(frp_macos_brew_prefix)"
  if frp_launchd_usable; then
    init="launchd"
  fi
  echo "Detected macOS:"
  echo "  Version      : ${version:-unknown}"
  echo "  Architecture : ${FRP_ARCH:-unknown} (Apple Silicon)"
  echo "  Service mgr  : ${init}"
  echo "  Software     : ${prefix}"
  echo "  State        : $(frp_macos_state_root)"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

frp_macos_required_commands() {
  # macOS ships curl, python3 (Command Line Tools), openssl (LibreSSL), tar,
  # and shasum. There is no unattended system package manager to fall back on,
  # so a missing tool is reported, never auto-installed.
  printf '%s\n' curl openssl python3 tar shasum launchctl
}

frp_macos_missing_commands() {
  local cmd
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    frp_command_exists "$cmd" || printf '%s\n' "$cmd"
  done < <(frp_macos_required_commands)
}

frp_macos_require_dependencies() {
  local missing cmd
  missing="$(frp_macos_missing_commands)"
  if [[ -z "$missing" ]]; then
    return 0
  fi
  echo "ERROR: required tools are missing:" >&2
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    echo "  ${cmd}" >&2
  done <<<"$missing"
  echo >&2
  echo "This installer does not modify system packages on macOS." >&2
  echo "Install the Command Line Tools, then run the installer again:" >&2
  echo "  xcode-select --install" >&2
  echo "Homebrew can also provide them, for example: brew install curl python3" >&2
  return 1
}

# macOS ships BSD coreutils, so sha256sum does not exist. Both tools accept the
# same "<digest>  <path>" check format.
frp_macos_sha256_check() {
  local expected="$1" file="$2"
  printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c - >/dev/null
}

# ---------------------------------------------------------------------------
# launchd
# ---------------------------------------------------------------------------

# Defined here rather than in frp-common.sh so that uninstall-client.sh, which
# sources only this module, can still gate its launchd teardown.
frp_launchd_usable() {
  frp_command_exists launchctl
}

frp_macos_launchd_template() {
  # Locate the plist template shipped with the project tree or the install.
  local candidate here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "${FRP_MACOS_PLIST_TEMPLATE:-}" \
    "${here}/../client/${FRP_MACOS_LAUNCHD_LABEL}.plist" \
    "$(frp_macos_fs "/usr/local/lib/frp-auto-deploy/${FRP_MACOS_LAUNCHD_LABEL}.plist")"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Render the LaunchDaemon plist for the resolved runtime paths.
frp_macos_render_plist() {
  local dest="$1"
  local template frpc config out_log err_log
  frpc="$(frp_macos_fs /usr/local/bin/frpc)"
  config="$(frp_macos_fs /etc/frp/frpc.toml)"
  out_log="$(frp_macos_fs /etc/frp)/logs/frpc.out.log"
  err_log="$(frp_macos_fs /etc/frp)/logs/frpc.err.log"
  if ! template="$(frp_macos_launchd_template)"; then
    echo "ERROR: launchd plist template not found" >&2
    return 1
  fi
  FRP_PLIST_LABEL="$FRP_MACOS_LAUNCHD_LABEL" \
  FRP_PLIST_FRPC="$frpc" \
  FRP_PLIST_CONFIG="$config" \
  FRP_PLIST_STDOUT="$out_log" \
  FRP_PLIST_STDERR="$err_log" \
    python3 - "$template" "$dest" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

template, dest = sys.argv[1], sys.argv[2]
with open(template, 'rb') as fh:
    data = plistlib.load(fh)

subs = {
    '@LABEL@': os.environ['FRP_PLIST_LABEL'],
    '@FRPC@': os.environ['FRP_PLIST_FRPC'],
    '@CONFIG@': os.environ['FRP_PLIST_CONFIG'],
    '@STDOUT@': os.environ['FRP_PLIST_STDOUT'],
    '@STDERR@': os.environ['FRP_PLIST_STDERR'],
}


def expand(value):
    if isinstance(value, str):
        for key, replacement in subs.items():
            value = value.replace(key, replacement)
        return value
    if isinstance(value, list):
        return [expand(item) for item in value]
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    return value


rendered = expand(data)
# Fail closed rather than shipping a daemon that would exec a placeholder.
for token in subs:
    if token in repr(rendered):
        sys.stderr.write('ERROR: unresolved placeholder %s in launchd plist\n' % token)
        raise SystemExit(1)
if rendered.get('Label') != subs['@LABEL@']:
    sys.stderr.write('ERROR: launchd plist Label does not match the project label\n')
    raise SystemExit(1)
args = rendered.get('ProgramArguments') or []
if len(args) < 3 or args[0] != subs['@FRPC@'] or args[-1] != subs['@CONFIG@']:
    sys.stderr.write('ERROR: launchd plist ProgramArguments are not the pinned frpc invocation\n')
    raise SystemExit(1)

out = Path(dest)
out.parent.mkdir(parents=True, exist_ok=True)
tmp = out.with_name(out.name + '.tmp')
with open(tmp, 'wb') as fh:
    plistlib.dump(rendered, fh)
os.chmod(tmp, 0o644)
tmp.replace(out)
PY
}

frp_macos_launchd_install() {
  local dest
  dest="$(frp_macos_fs /etc/systemd/system/frpc.service)"
  frp_require_safe_write_path "$dest" || return 1
  frp_macos_render_plist "$dest" || return 1
  if [[ ${EUID} -eq 0 ]]; then
    chown root:wheel "$dest" 2>/dev/null || true
  fi
  return 0
}

frp_macos_launchd_bootout() {
  local plist
  plist="$(frp_macos_fs /etc/systemd/system/frpc.service)"
  frp_launchd_usable || return 0
  # bootout is the modern spelling; unload covers older releases. Both are
  # best-effort: "not loaded" is a success for our purposes.
  frp_invoke launchctl bootout "system/${FRP_MACOS_LAUNCHD_LABEL}" >/dev/null 2>&1 ||
    frp_invoke launchctl unload -w "$plist" >/dev/null 2>&1 || true
  return 0
}

frp_macos_launchd_bootstrap() {
  local plist
  plist="$(frp_macos_fs /etc/systemd/system/frpc.service)"
  frp_launchd_usable || {
    echo "ERROR: launchctl is not available" >&2
    return 1
  }
  [[ -f "$plist" ]] || {
    echo "ERROR: launchd plist is missing: ${plist}" >&2
    return 1
  }
  if frp_invoke launchctl bootstrap system "$plist" >/dev/null 2>&1; then
    return 0
  fi
  if frp_invoke launchctl load -w "$plist" >/dev/null 2>&1; then
    return 0
  fi
  echo "ERROR: launchctl could not load ${FRP_MACOS_LAUNCHD_LABEL}" >&2
  return 1
}

# launchctl enable/disable persists across reboots in the service database, so
# a paused Mac stays paused after a restart. This is the launchd counterpart of
# `systemctl enable` / `systemctl disable`; RunAtLoad alone is not enough.
frp_macos_launchd_set_enabled() {
  local want="$1"
  frp_launchd_usable || return 0
  case "$want" in
    enable|disable) ;;
    *) return 1 ;;
  esac
  frp_invoke launchctl "$want" "system/${FRP_MACOS_LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  return 0
}

frp_macos_launchd_kickstart() {
  frp_launchd_usable || return 1
  if frp_invoke launchctl kickstart -k "system/${FRP_MACOS_LAUNCHD_LABEL}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

frp_macos_launchd_loaded() {
  frp_launchd_usable || return 1
  frp_invoke launchctl print "system/${FRP_MACOS_LAUNCHD_LABEL}" >/dev/null 2>&1 && return 0
  frp_invoke launchctl list "${FRP_MACOS_LAUNCHD_LABEL}" >/dev/null 2>&1
}

# PID of the running daemon, or empty. launchd is authoritative here; /proc
# does not exist on macOS so the Linux cmdline inspection cannot be used.
frp_macos_launchd_pid() {
  local pid=""
  frp_launchd_usable || return 0
  pid="$(frp_invoke launchctl print "system/${FRP_MACOS_LAUNCHD_LABEL}" 2>/dev/null |
    awk '/^[[:space:]]*pid[[:space:]]*=/ { print $3; exit }')"
  if [[ -z "$pid" ]]; then
    pid="$(frp_invoke launchctl list "${FRP_MACOS_LAUNCHD_LABEL}" 2>/dev/null |
      awk -F'"' '/"PID"[[:space:]]*=/ { next } /PID/ { gsub(/[^0-9]/, "", $0); print; exit }')"
  fi
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != "0" ]] || return 0
  printf '%s' "$pid"
}

frp_macos_launchd_running() {
  local pid
  pid="$(frp_macos_launchd_pid)"
  [[ -n "$pid" ]]
}

# Project-owned frpc PIDs without /proc: match the pinned binary path and the
# project config in the pgrep full command line, so unrelated frpc processes
# on the same Mac are never signalled.
frp_macos_project_frpc_pids() {
  local cfg bin pid cmdline
  cfg="$(frp_macos_fs /etc/frp/frpc.toml)"
  bin="$(frp_macos_fs /usr/local/bin/frpc)"
  frp_command_exists pgrep || return 0
  for pid in $(frp_invoke pgrep -x frpc 2>/dev/null || true); do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    cmdline="$(frp_invoke ps -o command= -p "$pid" 2>/dev/null || true)"
    [[ -n "$cmdline" ]] || continue
    if [[ "$cmdline" == *"$bin"* && "$cmdline" == *"$cfg"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

frp_macos_launchd_uninstall() {
  local plist
  plist="$(frp_macos_fs /etc/systemd/system/frpc.service)"
  frp_macos_launchd_bootout
  if [[ -f "$plist" && ! -L "$plist" ]]; then
    rm -f "$plist"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Compact join descriptor (shared wire format with the Windows launcher)
# ---------------------------------------------------------------------------
# frpj1.<urlsafe-b64("allocator|ca|ticket|channel|source_ref")>
#
# The descriptor is an opaque short-lived credential, not obfuscation: it is
# base64 only so that a single copy-paste token carries the allocator URL, the
# pinned CA fingerprint, and the one-time bootstrap ticket without shell
# quoting hazards. Decoding is deliberately strict and fails closed.
frp_macos_decode_join_descriptor() {
  local descriptor="${1:-}"
  python3 - "$descriptor" <<'PY'
import base64
import re
import sys
from urllib.parse import urlsplit

raw = sys.argv[1].strip()
if not raw.startswith('frpj1.'):
    sys.stderr.write('ERROR: join descriptor must start with frpj1.\n')
    raise SystemExit(1)
body = raw[len('frpj1.'):]
if not re.fullmatch(r'[A-Za-z0-9_-]+', body or ''):
    sys.stderr.write('ERROR: join descriptor is not valid base64url\n')
    raise SystemExit(1)
try:
    decoded = base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)).decode('utf-8')
except Exception:
    sys.stderr.write('ERROR: join descriptor could not be decoded\n')
    raise SystemExit(1)
fields = decoded.split('|')
if len(fields) != 5:
    sys.stderr.write('ERROR: join descriptor has an unexpected field count\n')
    raise SystemExit(1)
allocator, ca, ticket, channel, source_ref = fields
for value in fields:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        sys.stderr.write('ERROR: join descriptor contains control characters\n')
        raise SystemExit(1)
parsed = urlsplit(allocator)
if parsed.scheme != 'https' or not parsed.hostname:
    sys.stderr.write('ERROR: join descriptor allocator URL must be https\n')
    raise SystemExit(1)
if parsed.username is not None or parsed.password is not None:
    sys.stderr.write('ERROR: join descriptor allocator URL must not carry credentials\n')
    raise SystemExit(1)
if not re.fullmatch(r'[0-9a-f]{64}', ca.lower()):
    sys.stderr.write('ERROR: join descriptor CA fingerprint must be 64 hex characters\n')
    raise SystemExit(1)
if not ticket:
    sys.stderr.write('ERROR: join descriptor is missing the bootstrap ticket\n')
    raise SystemExit(1)
if channel and channel not in ('stable', 'dev', 'candidate'):
    sys.stderr.write('ERROR: join descriptor has an unknown release channel\n')
    raise SystemExit(1)
if channel == 'candidate' and not re.fullmatch(r'[0-9a-f]{40}', source_ref or ''):
    sys.stderr.write('ERROR: candidate join descriptor needs an exact commit source ref\n')
    raise SystemExit(1)

print('FRP_ALLOCATOR_URL=%s' % allocator)
print('FRP_ALLOCATOR_CA_SHA256=%s' % ca.lower())
print('FRP_BOOTSTRAP_TICKET=%s' % ticket)
print('FRP_RELEASE_CHANNEL=%s' % channel)
print('FRP_SOURCE_REF=%s' % source_ref)
PY
}
