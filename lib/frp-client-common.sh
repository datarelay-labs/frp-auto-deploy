#!/usr/bin/env bash
# Shared client-side helpers for install-client.sh and tools/frp-client.
# Source this file; do not execute it.

if [[ -n "${FRP_CLIENT_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
FRP_CLIENT_COMMON_LOADED=1

FRP_CLIENT_STATE_SCHEMA=1
FRP_CLIENT_BACKUP_KEEP="${FRP_CLIENT_BACKUP_KEEP:-5}"
FRP_CLIENT_UPGRADE_BACKUP_KEEP="${FRP_CLIENT_UPGRADE_BACKUP_KEEP:-5}"
FRP_CLIENT_UPDATE_URL="${FRP_CLIENT_UPDATE_URL:-https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh}"

# Defaults match VERSION. A sibling VERSION file overrides project/FRP versions.
PROJECT_VERSION="${PROJECT_VERSION:-1.3.1}"
FRP_VERSION="${FRP_VERSION:-0.70.1}"
_FRP_CLIENT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_FRP_CLIENT_COMMON_DIR}/../VERSION" ]]; then
  # shellcheck disable=SC1091
  . "${_FRP_CLIENT_COMMON_DIR}/../VERSION"
fi

frp_client_path() {
  local p="$1"
  if [[ -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    printf '%s' "${FRP_CLIENT_TEST_ROOT}${p}"
  else
    printf '%s' "$p"
  fi
}

frp_client_state_path() {
  frp_client_path /etc/frp/client-state.json
}

frp_client_toml_path() {
  frp_client_path /etc/frp/frpc.toml
}

frp_client_access_path() {
  frp_client_path /etc/frp/access-info.txt
}

frp_client_backup_dir() {
  frp_client_path /etc/frp/backups
}

frp_client_lock_dir() {
  frp_client_path /etc/frp/client-manage.lock
}

frp_client_identity_key_path() {
  frp_client_path /etc/frp/client-identity.key
}

frp_client_identity_pub_path() {
  frp_client_path /etc/frp/client-identity.pub
}

frp_client_identity_mac_path() {
  frp_client_path /etc/frp/client-identity.mac
}

frp_mgmt_auth_py() {
  local cand libdir here
  if [[ -n "${FRP_MGMT_AUTH_PY:-}" && -f "${FRP_MGMT_AUTH_PY}" ]]; then
    printf '%s' "$FRP_MGMT_AUTH_PY"
    return 0
  fi
  libdir="$(frp_client_lib_dir)"
  for cand in \
    "${libdir}/frp_mgmt_auth.py" \
    "${FRP_CLIENT_LIB:-}/frp_mgmt_auth.py"
  do
    if [[ -f "$cand" ]]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  if [[ -n "${FRP_CLIENT_LIB:-}" && -f "${FRP_CLIENT_LIB}" ]]; then
    cand="$(dirname "$FRP_CLIENT_LIB")/frp_mgmt_auth.py"
    if [[ -f "$cand" ]]; then
      printf '%s' "$cand"
      return 0
    fi
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for cand in \
    "$here/frp_mgmt_auth.py" \
    "$here/../lib/frp_mgmt_auth.py" \
    /usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py
  do
    if [[ -f "$cand" ]]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  echo "ERROR: missing frp_mgmt_auth.py" >&2
  return 1
}

frp_identity_status() {
  local key pub mac macval
  key="$(frp_client_identity_key_path)"
  pub="$(frp_client_identity_pub_path)"
  mac="$(frp_client_identity_mac_path)"
  if [[ ! -e "$key" && ! -e "$pub" && ! -e "$mac" ]]; then
    printf 'missing'
    return 0
  fi
  if [[ ! -f "$key" ]]; then
    printf 'corrupt'
    return 0
  fi
  if ! python3 "$(frp_mgmt_auth_py)" check-key "$key" >/dev/null 2>&1; then
    printf 'corrupt'
    return 0
  fi
  # A local key without a confirmed response key is not enrolled. This avoids
  # treating a half-finished first enrollment as a usable identity.
  if [[ ! -f "$mac" ]]; then
    printf 'pending'
    return 0
  fi
  macval="$(tr -d '\n' <"$mac" 2>/dev/null || true)"
  if [[ ${#macval} -ne 64 ]]; then
    printf 'pending'
    return 0
  fi
  printf 'enrolled'
}

frp_identity_label() {
  case "$(frp_identity_status)" in
    enrolled) printf 'enrolled' ;;
    corrupt) printf 'unusable' ;;
    *) printf 'not established' ;;
  esac
}

frp_identity_ensure() {
  local key pub status py
  key="$(frp_client_identity_key_path)"
  pub="$(frp_client_identity_pub_path)"
  py="$(frp_mgmt_auth_py)" || return 1
  mkdir -p "$(dirname "$key")"
  chmod 700 "$(dirname "$key")" 2>/dev/null || true
  status="$(frp_identity_status)"
  if [[ "$status" == corrupt ]]; then
    echo "ERROR: this client's management identity is unusable." >&2
    echo "The local identity file exists but cannot be used." >&2
    echo "Create a new Enrollment Code on the FRP server with sudo frp-create-client," >&2
    echo "move the damaged identity aside, then re-enroll this client." >&2
    echo "Do not overwrite ${key} automatically." >&2
    return 1
  fi
  if [[ "$status" == enrolled || "$status" == pending ]]; then
    if [[ ! -f "$pub" ]]; then
      python3 "$py" pub "$key" >"${pub}.tmp"
      chmod 644 "${pub}.tmp"
      mv "${pub}.tmp" "$pub"
    fi
    return 0
  fi
  python3 "$py" gen-key "$key" "$pub"
  chmod 600 "$key"
  chmod 644 "$pub" 2>/dev/null || true
}

frp_identity_public_pem() {
  local key pub py
  py="$(frp_mgmt_auth_py)" || return 1
  key="$(frp_client_identity_key_path)"
  pub="$(frp_client_identity_pub_path)"
  if [[ -f "$pub" ]]; then
    python3 "$py" pub "$key"
    return 0
  fi
  python3 "$py" pub "$key"
}

frp_identity_store_mac() {
  local dest value="${1:-}"
  dest="$(frp_client_identity_mac_path)"
  MGMT_MAC_VALUE="$value" python3 - "$dest" <<'PY'
import os, sys, tempfile
from pathlib import Path
dest = Path(sys.argv[1])
text = os.environ.get('MGMT_MAC_VALUE', '').strip() + '\n'
if len(text.strip()) != 64:
    raise SystemExit('ERROR: invalid management response key')
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
  unset MGMT_MAC_VALUE
}

frp_identity_load_mac() {
  local path
  path="$(frp_client_identity_mac_path)"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: management identity is missing a response key; re-enroll this client." >&2
    return 1
  fi
  tr -d '\n' <"$path"
}

frp_identity_derive_and_store_mac() {
  local machine_id="$1" secret="$2" mac py
  py="$(frp_mgmt_auth_py)" || return 1
  mac="$(MGMT_ENROLL_SECRET="$secret" python3 "$py" derive-mac "$machine_id")" || return 1
  unset MGMT_ENROLL_SECRET
  if [[ ${#mac} -ne 64 ]]; then
    echo "ERROR: failed to derive management response key" >&2
    return 1
  fi
  frp_identity_store_mac "$mac"
}

frp_read_existing_token() {
  python3 - "$(frp_client_toml_path)" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit('ERROR: existing FRP client configuration is missing; re-enroll this client.')
text = path.read_text(encoding='utf-8')
for line in text.splitlines():
    m = re.match(r'^\s*auth\.token\s*=\s*"(.*)"\s*$', line)
    if m:
        sys.stdout.write(m.group(1))
        raise SystemExit(0)
raise SystemExit('ERROR: existing FRP client configuration is missing the FRP token; re-enroll this client.')
PY
}

frp_client_lib_dir() {
  frp_client_path /usr/local/lib/frp-auto-deploy
}

frp_client_version_file() {
  frp_client_path /etc/frp-auto-deploy/version
}

frp_client_upgrade_backup_root() {
  frp_client_path /var/lib/frp-auto-deploy/client-upgrades
}

frp_client_write_version_file() {
  local dest dir tmp
  dest="$(frp_client_version_file)"
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.version.XXXXXX")"
  cat >"$tmp" <<EOF
PROJECT_VERSION=${PROJECT_VERSION}
FRP_VERSION=${FRP_VERSION}
EOF
  chmod 0644 "$tmp"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest"
}

frp_client_read_kv() {
  local file="$1" key="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,"=")+1); exit}' "$file"
}

frp_client_installed_project_version() {
  local pv
  pv="$(frp_client_read_kv "$(frp_client_version_file)" PROJECT_VERSION)"
  if [[ -z "$pv" ]]; then
    printf '%s' "legacy / unknown"
    return 0
  fi
  printf '%s' "$pv"
}

frp_client_installed_frp_version() {
  local fv
  fv="$(frp_client_read_kv "$(frp_client_version_file)" FRP_VERSION)"
  if [[ -n "$fv" ]]; then
    printf '%s' "$fv"
    return 0
  fi
  printf '%s' "${FRP_VERSION:-0.70.1}"
}

frp_client_has_existing_install() {
  [[ -f "$(frp_client_state_path)" ]]
}

frp_client_hook_log() {
  if [[ -n "${FRP_CLIENT_HOOK_LOG:-}" ]]; then
    printf '%s\n' "$1" >>"$FRP_CLIENT_HOOK_LOG"
  fi
}

_FRP_TEST_INPUT_READY=0

frp_test_input_path() {
  printf '%s' "${FRP_CLIENT_TEST_INPUT_FILE:-${TMPDIR:-/tmp}/frp-client-test-input.$$}"
}

frp_reset_test_input() {
  _FRP_TEST_INPUT_READY=0
  rm -f "$(frp_test_input_path)"
}

frp_using_test_input() {
  [[ -n "${FRP_CLIENT_TEST_INPUT+x}" ]]
}

frp_open_test_input() {
  local file
  file="$(frp_test_input_path)"
  if [[ -f "$file" ]]; then
    return 0
  fi
  printf '%s' "${FRP_CLIENT_TEST_INPUT}" >"$file"
  if [[ -n "${FRP_CLIENT_TEST_INPUT:-}" && "${FRP_CLIENT_TEST_INPUT}" != *$'\n' ]]; then
    printf '\n' >>"$file"
  fi
}

frp_read_test_line() {
  local file first
  frp_open_test_input
  file="$(frp_test_input_path)"
  first="$(python3 - "$file" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8') if path.is_file() else ''
if not text:
    sys.stdout.write('')
    raise SystemExit(0)
if text.endswith('\n') and text.count('\n') == 1 and text[:-1] == '':
    first, rest = '', ''
elif '\n' in text:
    first, rest = text.split('\n', 1)
else:
    first, rest = text, ''
path.write_text(rest, encoding='utf-8')
sys.stdout.write(first)
PY
)"
  printf '%s' "$first"
}

prompt_secret() {
  local prompt="$1" var="$2"
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if frp_using_test_input; then
    printf '%s\n' "$prompt" >&2
    printf -v "$var" '%s' "$(frp_read_test_line)"
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    read -r -s -p "$prompt" "$var" </dev/tty
    echo >/dev/tty
  else
    echo "ERROR: no TTY and $var is not set" >&2
    exit 1
  fi
}

read_tty() {
  local prompt="$1" default="${2:-}"
  local value=""
  if frp_using_test_input; then
    printf '%s\n' "$prompt" >&2
    value="$(frp_read_test_line)"
    printf '%s' "${value:-$default}"
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" value </dev/tty || true
  else
    echo "ERROR: no TTY for interactive setup; set FRP_SERVICES_JSON or FRP_CLIENT_TEST_INPUT" >&2
    exit 1
  fi
  printf '%s' "${value:-$default}"
}

infer_ssh_user() {
  local user="${FRP_SSH_USER:-${SUDO_USER:-root}}"
  if [[ "$user" == "root" && -n "${LOGNAME:-}" && "$LOGNAME" != root ]]; then
    user="$LOGNAME"
  fi
  printf '%s' "$user"
}

probe_tcp() {
  local host="$1" port="$2"
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

maybe_warn_connectivity() {
  local host="$1" port="$2" label="$3"
  if [[ "${FRP_SKIP_CONNECTIVITY_CHECK:-}" == "1" ]]; then
    return 0
  fi
  if probe_tcp "$host" "$port"; then
    return 0
  fi
  echo "WARNING: cannot connect to ${label} ${host}:${port} (continuing; target may be remote or not yet listening)"
}

frp_confirm_yes() {
  local prompt="${1:-Continue? [Y/n]: }"
  local answer
  answer="$(read_tty "$prompt" "Y")"
  case "$answer" in
    ''|Y|y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

frp_preset_type_label() {
  case "$1" in
    ssh) printf 'SSH / TCP' ;;
    http) printf 'HTTP / TCP' ;;
    https) printf 'HTTPS / TCP' ;;
    *) printf 'Custom TCP' ;;
  esac
}

service_payload() {
  python3 - "$@" <<'PY'
import json, sys
preset = sys.argv[1]
sid = sys.argv[2]
name = sys.argv[3]
host = sys.argv[4]
port = sys.argv[5]
payload = {
  'id': sid,
  'name': name,
  'protocol': 'tcp',
  'local_ip': host,
  'local_port': port,
  'preset': preset,
}
if preset == 'ssh':
    payload['ssh_user'] = sys.argv[6] if len(sys.argv) > 6 else 'root'
print(json.dumps(payload))
PY
}

frp_ux_intro() {
  cat <<'EOF'

=========================================
 FRP Client Setup
=========================================

This installer publishes services on this Linux system
through your FRP server.

Before continuing, you need an Enrollment Code.

Generate one on the FRP server with:

  sudo frp-create-client

The Enrollment Code is short-lived. Enter it only here.
It authorizes this first enrollment (or a later recovery).
It is not stored on this client and it is not the FRP token.
After enrollment, this client uses a local management identity
for ordinary configuration changes.

Tip:
  Values shown in [brackets] are defaults.
  Press Enter to accept the default value.

EOF
}

frp_ux_enrollment_help() {
  cat <<'EOF'
Enrollment Code
  Generated on the FRP server with: sudo frp-create-client
  Short-lived bootstrap/recovery credential. Entered interactively.
  Not stored. Not the FRP token.
  Needed for first enrollment, recovering a lost local identity,
  or after an administrator revokes this client's management access.
  Ordinary later changes use this client's local management identity.

EOF
}

frp_ux_defaults_help() {
  cat <<'EOF'
Tip:
  Values shown in [brackets] are defaults.
  Press Enter to accept the default value.

EOF
}

frp_ux_service_id_help() {
  local default="${1:-}"
  cat <<EOF
Service ID
  A short unique name for this service.
  Service IDs are lowercase and case-insensitive.
  SSH, ssh, and Ssh are the same ID.

  The Service ID is used together with this machine's identity
  to keep the same public port after reinstall or later changes.

  Usually you can keep the default.

  Examples:
    ssh
    grafana
    admin-web
    api
EOF
  if [[ -n "$default" ]]; then
    echo
  fi
}

frp_ux_target_host_help() {
  cat <<'EOF'
Target host
  The IP address or hostname where the actual service runs.

  Use 127.0.0.1 if the service is running on this machine.
  Enter another reachable internal IP if it runs on another server.

  Examples:
    127.0.0.1
    192.168.10.20
    internal-api.example.local

EOF
}

frp_ux_target_port_help() {
  local preset="${1:-custom}"
  case "$preset" in
    ssh)
      cat <<'EOF'
Target port
  TCP port used by the SSH service on the target host.

  Standard SSH uses port 22.
  Press Enter if this is a normal SSH installation.

EOF
      ;;
    http)
      cat <<'EOF'
Target port
  TCP port used by the web application.

  Standard HTTP uses port 80.
  Examples of alternate ports: 8080, 3000.

EOF
      ;;
    https)
      cat <<'EOF'
Target port
  TCP port used by the HTTPS application.

  Standard HTTPS uses port 443.

EOF
      ;;
    *)
      cat <<'EOF'
Target port
  TCP port used by the application on the target host.

  Examples:
    Grafana      3000
    API          8080
    PostgreSQL   5432

EOF
      ;;
  esac
}

frp_ux_ssh_user_help() {
  cat <<'EOF'
SSH user
  Linux username shown in the generated SSH command.

  This does NOT create an operating-system account,
  change a password, or configure SSH authentication.

EOF
}

frp_ux_add_service_menu() {
  cat <<'EOF'
Add a service
=============

Select the type of service you want to publish.

1) SSH
   Remote shell access.
   Default target: 127.0.0.1:22

2) HTTP
   Web application using plain HTTP.
   Default target: 127.0.0.1:80

3) HTTPS
   Web application using HTTPS.
   Default target: 127.0.0.1:443
   FRP forwards the TCP connection without terminating TLS.

4) Custom TCP
   Any other TCP service.
   Examples: Grafana :3000, API :8080, PostgreSQL :5432

5) Back

For normal remote SSH access, choose 1.

You may publish one or more services.
SSH is optional.

EOF
}

frp_ux_empty_services_help() {
  cat <<'EOF'
No services have been configured yet.

Choose "Add service" to select what you want to access
through the FRP server.

Examples:
  SSH        - remote shell access
  HTTP       - web application using HTTP
  HTTPS      - web application using HTTPS
  Custom TCP - any other TCP service such as Grafana,
               APIs, databases, or appliance management ports

You may publish one or more services.
SSH is optional.

EOF
}

frp_ux_configured_services_help() {
  cat <<'EOF'
The public port will be assigned automatically by the FRP server.

You can add more services now, or install when finished.

You may publish one or more services.
SSH is optional.

EOF
}

frp_ux_print_all_guidance() {
  frp_ux_intro
  frp_ux_enrollment_help
  frp_ux_defaults_help
  frp_ux_service_id_help ssh
  echo
  frp_ux_target_host_help
  frp_ux_target_port_help ssh
  frp_ux_target_port_help http
  frp_ux_target_port_help https
  frp_ux_target_port_help custom
  frp_ux_ssh_user_help
  frp_ux_add_service_menu
  frp_ux_empty_services_help
  frp_ux_configured_services_help
}

frp_prompt_service_id() {
  local default="$1"
  local -n _frp_sid_out="$2"
  frp_ux_service_id_help "$default"
  echo
  _frp_sid_out="$(read_tty "Service ID [${default}]: " "$default")"
}

frp_prompt_target_host() {
  local default="${1:-127.0.0.1}"
  local -n _frp_host_out="$2"
  frp_ux_target_host_help
  _frp_host_out="$(read_tty "Target host [${default}]: " "$default")"
}

frp_prompt_target_port() {
  local preset="$1" default="${2:-}"
  local -n _frp_port_out="$3"
  frp_ux_target_port_help "$preset"
  if [[ -n "$default" ]]; then
    _frp_port_out="$(read_tty "Target port [${default}]: " "$default")"
  else
    _frp_port_out="$(read_tty "Target port: " "")"
  fi
}

frp_prompt_ssh_user() {
  local -n _frp_user_out="$1"
  local default
  default="${2:-$(infer_ssh_user)}"
  frp_ux_ssh_user_help
  _frp_user_out="$(read_tty "SSH user [${default}]: " "$default")"
}

frp_ux_prompt_new_service() {
  local dest="${1:-}"
  local choice sid host port user name _frp_new_payload
  while true; do
    echo
    frp_ux_add_service_menu
    choice="$(read_tty "Select: " "")"
    case "$choice" in
      1)
        frp_prompt_service_id ssh sid
        frp_prompt_target_host 127.0.0.1 host
        frp_prompt_target_port ssh 22 port
        frp_prompt_ssh_user user
        maybe_warn_connectivity "$host" "$port" "SSH"
        _frp_new_payload="$(service_payload ssh "$sid" SSH "$host" "$port" "$user")"
        ;;
      2)
        frp_prompt_service_id http sid
        frp_prompt_target_host 127.0.0.1 host
        frp_prompt_target_port http 80 port
        maybe_warn_connectivity "$host" "$port" "HTTP"
        _frp_new_payload="$(service_payload http "$sid" HTTP "$host" "$port")"
        ;;
      3)
        frp_prompt_service_id https sid
        frp_prompt_target_host 127.0.0.1 host
        frp_prompt_target_port https 443 port
        maybe_warn_connectivity "$host" "$port" "HTTPS"
        _frp_new_payload="$(service_payload https "$sid" HTTPS "$host" "$port")"
        ;;
      4)
        frp_ux_service_id_help
        echo
        sid="$(read_tty "Service ID: " "")"
        name="$(read_tty "Display name [${sid}]: " "$sid")"
        frp_prompt_target_host 127.0.0.1 host
        frp_prompt_target_port custom "" port
        maybe_warn_connectivity "$host" "$port" "TCP"
        _frp_new_payload="$(service_payload custom "$sid" "$name" "$host" "$port")"
        ;;
      5)
        if [[ -n "$dest" ]]; then
          local -n _frp_payload_back="$dest"
          _frp_payload_back=""
        fi
        return 0
        ;;
      *) echo "ERROR: select 1-5" >&2; continue ;;
    esac
    if [[ -n "$dest" ]]; then
      local -n _frp_payload_out="$dest"
      _frp_payload_out="$_frp_new_payload"
    else
      printf '%s\n' "$_frp_new_payload"
    fi
    return 0
  done
}

frp_ux_print_install_summary() {
  local services_file="$1" version="${2:-0.70.1}"
  python3 - "$services_file" "$version" <<'PY'
import json, sys
from pathlib import Path
services = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
version = sys.argv[2]
labels = {'ssh': 'SSH / TCP', 'http': 'HTTP / TCP', 'https': 'HTTPS / TCP'}
print()
print('Ready to install')
print('================')
print()
print('The following services will be published:')
print()
for item in services:
    name = item.get('name') or item.get('id')
    preset = item.get('preset') or 'custom'
    kind = labels.get(preset, 'Custom TCP')
    print(name)
    print(f"  Type        : {kind}")
    print(f"  Target      : {item.get('local_ip')}:{item.get('local_port')}")
    print('  Public port : assigned automatically')
    print()
print('The public port is assigned automatically by the FRP server.')
print('You do not enter an external/public port here.')
print()
print('The installer will:')
print()
print(f'  - install FRP v{version}')
print('  - create /etc/frp/frpc.toml')
print('  - write /etc/frp/client-state.json')
print('  - install the frpc systemd service')
print('  - enable frpc at boot')
print('  - start the FRP client')
print()
PY
}

frp_ux_print_apply_summary() {
  frp_state_diff_engine summary "$1" "$2"
}

frp_atomic_write_text() {
  local dest="$1" mode="$2"
  python3 - "$dest" "$mode" <<'PY'
import os, sys, tempfile
from pathlib import Path
dest = Path(sys.argv[1])
mode = int(sys.argv[2], 8)
text = sys.stdin.read()
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

frp_atomic_write_json_file() {
  local dest="$1" src="$2" mode="${3:-0600}"
  python3 - "$dest" "$src" "$mode" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
dest = Path(sys.argv[1])
src = Path(sys.argv[2])
mode = int(sys.argv[3], 8)
data = json.loads(src.read_text(encoding='utf-8'))
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

frp_state_has_secrets() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
forbidden = {
    'token', 'auth.token', 'token_ciphertext', 'frp_token', 'server_token',
    'enrollment_code', 'enrollment_secret', 'enroll_secret', 'secret',
    'password', 'private_key', 'mgmt_mac_key', 'mac_key',
}
def walk(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = str(k).lower()
            loc = f'{path}.{k}' if path else str(k)
            if key in forbidden or 'token' in key or 'secret' in key or 'password' in key:
                raise SystemExit(f'secret field: {loc}')
            walk(v, loc)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk(v, f'{path}[{i}]')
raw = Path(sys.argv[1]).read_text(encoding='utf-8')
lower = raw.lower()
if 'begin ' in lower and 'private key' in lower:
    raise SystemExit('private key material')
walk(json.loads(raw))
PY
}

frp_services_to_list() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(data, list):
    json.dump(data, sys.stdout)
    sys.stdout.write('\n')
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit('ERROR: invalid services document')
services = data.get('services', data)
if isinstance(services, list):
    json.dump(services, sys.stdout)
    sys.stdout.write('\n')
    raise SystemExit(0)
out = []
for sid, item in services.items():
    rec = dict(item)
    rec['id'] = rec.get('id') or sid
    out.append(rec)
json.dump(out, sys.stdout)
sys.stdout.write('\n')
PY
}

frp_enabled_services_list() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(data, dict) and 'services' in data:
    services = data['services']
    if isinstance(services, dict):
        items = []
        for sid, item in services.items():
            rec = dict(item)
            rec['id'] = rec.get('id') or sid
            items.append(rec)
        services = items
else:
    services = data
out = []
for item in services:
    if item.get('enabled', True) is False:
        continue
    out.append(item)
json.dump(out, sys.stdout)
sys.stdout.write('\n')
PY
}

frp_count_enabled_services() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
services = data.get('services', {}) if isinstance(data, dict) else data
n = 0
if isinstance(services, dict):
    for item in services.values():
        if item.get('enabled', True) is not False:
            n += 1
elif isinstance(services, list):
    for item in services:
        if item.get('enabled', True) is not False:
            n += 1
print(n)
PY
}

frp_load_client_state() {
  local path="$1"
  python3 - "$path" "$FRP_CLIENT_STATE_SCHEMA" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
want = int(sys.argv[2])
if not path.is_file():
    raise SystemExit(
        'ERROR: This client predates local management state.\n'
        'Re-enroll once with the current bootstrap installer to initialize frp-client management.'
    )
try:
    data = json.loads(path.read_text(encoding='utf-8'))
except Exception:
    raise SystemExit('ERROR: client-state.json is not valid JSON')
if not isinstance(data, dict) or data.get('schema_version') != want:
    raise SystemExit(
        f'ERROR: unsupported client-state schema version {data.get("schema_version")!r}.\n'
        'Re-enroll once with the current bootstrap installer to initialize frp-client management.'
    )
if not isinstance(data.get('services'), dict):
    raise SystemExit('ERROR: client-state.json services must be a map')
PY
}

frp_write_client_state() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$FRP_CLIENT_STATE_SCHEMA" "$8" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
dest, allocator_url, server, server_port, hostname, machine_id, host_id = sys.argv[1:8]
schema = int(sys.argv[8])
services_raw = json.loads(Path(sys.argv[9]).read_text(encoding='utf-8'))
services = {}
if isinstance(services_raw, list):
    items = services_raw
elif isinstance(services_raw, dict):
    items = []
    for sid, item in services_raw.items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        items.append(rec)
else:
    raise SystemExit('ERROR: invalid services for client-state')
for item in items:
    rec = {
        'id': item['id'],
        'name': item.get('name') or item['id'],
        'preset': item.get('preset') or 'custom',
        'protocol': 'tcp',
        'local_ip': item['local_ip'],
        'local_port': int(item['local_port']),
        'enabled': item.get('enabled', True) is not False,
    }
    if 'remote_port' in item and item['remote_port'] is not None:
        rec['remote_port'] = int(item['remote_port'])
    if rec['preset'] == 'ssh':
        rec['ssh_user'] = item.get('ssh_user') or 'root'
    services[rec['id']] = rec
state = {
    'schema_version': schema,
    'allocator_url': allocator_url,
    'frp_server': server,
    'frp_server_port': int(server_port),
    'hostname': hostname,
    'machine_id': machine_id,
    'host_id': host_id,
    'services': services,
}
dest = Path(dest)
dest.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=dest.name + '.', suffix='.tmp', dir=str(dest.parent))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
        fh.write('\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

services_init() {
  printf '%s\n' '[]' >"$SERVICES_FILE"
}

services_count() {
  python3 - "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
print(len(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))))
PY
}

services_add_json() {
  python3 - "$SERVICES_FILE" "$1" <<'PY'
import json, re, sys
from pathlib import Path
path = Path(sys.argv[1])
raw = json.loads(sys.argv[2])
data = json.loads(path.read_text(encoding='utf-8'))
sid = str(raw.get('id', '')).strip().lower()
if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,31}', sid or ''):
    raise SystemExit('ERROR: invalid service id; use [a-z0-9][a-z0-9._-]{0,31}')
if any(item.get('id') == sid for item in data):
    raise SystemExit(
        f'ERROR: duplicate service id: {sid}\n\n'
        'A service with this ID already exists.\n'
        'Service IDs are lowercase and case-insensitive.'
    )
protocol = str(raw.get('protocol', 'tcp') or 'tcp').strip().lower()
if protocol != 'tcp':
    raise SystemExit('ERROR: only tcp services are supported')
preset = str(raw.get('preset', 'custom') or 'custom').strip().lower()
if preset not in ('ssh', 'http', 'https', 'custom'):
    raise SystemExit('ERROR: invalid service preset')
name = str(raw.get('name', '') or sid).strip() or sid
if len(name) > 64 or '\n' in name or '\r' in name:
    raise SystemExit('ERROR: invalid service display name')
local_ip = str(raw.get('local_ip', '')).strip()
if not local_ip or any(c in local_ip for c in ' \t\r\n/\\;|&$`\'"<>'):
    raise SystemExit('ERROR: invalid target host')
try:
    local_port = int(str(raw.get('local_port', '')).strip())
except Exception:
    raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
if local_port < 1 or local_port > 65535:
    raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
item = {
    'id': sid,
    'name': name,
    'protocol': 'tcp',
    'local_ip': local_ip,
    'local_port': local_port,
    'preset': preset,
}
if preset == 'ssh':
    ssh_user = str(raw.get('ssh_user', '') or 'root').strip() or 'root'
    if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
        raise SystemExit('ERROR: invalid ssh_user')
    item['ssh_user'] = ssh_user
if len(data) >= 32:
    raise SystemExit('ERROR: too many services')
data.append(item)
path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY
}

services_load_from_env() {
  python3 - "$SERVICES_FILE" <<'PY'
import json, os, re, sys
from pathlib import Path

def add(path, raw):
    data = json.loads(path.read_text(encoding='utf-8'))
    sid = str(raw.get('id', '')).strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,31}', sid or ''):
        raise SystemExit('ERROR: invalid service id; use [a-z0-9][a-z0-9._-]{0,31}')
    if any(item.get('id') == sid for item in data):
        raise SystemExit(
            f'ERROR: duplicate service id: {sid}\n\n'
            'A service with this ID already exists.\n'
            'Service IDs are lowercase and case-insensitive.'
        )
    protocol = str(raw.get('protocol', 'tcp') or 'tcp').strip().lower()
    if protocol != 'tcp':
        raise SystemExit('ERROR: only tcp services are supported')
    preset = str(raw.get('preset', 'custom') or 'custom').strip().lower()
    if preset not in ('ssh', 'http', 'https', 'custom'):
        raise SystemExit('ERROR: invalid service preset')
    name = str(raw.get('name', '') or sid).strip() or sid
    if len(name) > 64 or '\n' in name or '\r' in name:
        raise SystemExit('ERROR: invalid service display name')
    local_ip = str(raw.get('local_ip', '')).strip()
    if not local_ip or any(c in local_ip for c in ' \t\r\n/\\;|&$`\'"<>'):
        raise SystemExit('ERROR: invalid target host')
    try:
        local_port = int(str(raw.get('local_port', '')).strip())
    except Exception:
        raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
    if local_port < 1 or local_port > 65535:
        raise SystemExit('ERROR: invalid local_port; must be an integer 1-65535')
    item = {
        'id': sid,
        'name': name,
        'protocol': 'tcp',
        'local_ip': local_ip,
        'local_port': local_port,
        'preset': preset,
    }
    if preset == 'ssh':
        ssh_user = str(raw.get('ssh_user', '') or 'root').strip() or 'root'
        if not re.fullmatch(r'[A-Za-z0-9._@-]{1,32}', ssh_user):
            raise SystemExit('ERROR: invalid ssh_user')
        item['ssh_user'] = ssh_user
    if len(data) >= 32:
        raise SystemExit('ERROR: too many services')
    data.append(item)
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')

path = Path(sys.argv[1])
try:
    raw = json.loads(os.environ.get('FRP_SERVICES_JSON', ''))
except json.JSONDecodeError:
    raise SystemExit('ERROR: FRP_SERVICES_JSON is not valid JSON')
if not isinstance(raw, list):
    raise SystemExit('ERROR: FRP_SERVICES_JSON must be a list')
if not raw:
    raise SystemExit('ERROR: at least one service must be configured')
path.write_text('[]\n', encoding='utf-8')
for item in raw:
    add(path, item)
PY
}

services_list() {
  python3 - "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
data=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if not data:
    print('(none)')
    raise SystemExit(0)
labels = {'ssh': 'SSH / TCP', 'http': 'HTTP / TCP', 'https': 'HTTPS / TCP'}
for i, item in enumerate(data, 1):
    preset = item.get('preset') or 'custom'
    print(f"{i}. {item.get('id')}")
    print(f"   Type   : {labels.get(preset, 'Custom TCP')}")
    print(f"   Target : {item.get('local_ip')}:{item.get('local_port')}")
    print()
PY
}

services_remove_index() {
  python3 - "$SERVICES_FILE" "$1" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1])
data=json.loads(path.read_text(encoding='utf-8'))
try:
    idx=int(sys.argv[2])
except Exception:
    raise SystemExit('ERROR: invalid service number')
if idx < 1 or idx > len(data):
    raise SystemExit('ERROR: service number out of range')
data.pop(idx-1)
path.write_text(json.dumps(data, indent=2)+'\n', encoding='utf-8')
PY
}

merge_allocated_services() {
  python3 - "$SERVICES_FILE" "$ALLOCATED_FILE" <<'PY'
import json,sys
from pathlib import Path
local_path, alloc_path = Path(sys.argv[1]), Path(sys.argv[2])
local = json.loads(local_path.read_text(encoding='utf-8'))
allocated = json.loads(alloc_path.read_text(encoding='utf-8'))
if not isinstance(allocated, list):
    raise SystemExit('ERROR: allocator response services are invalid')
by_id = {}
for item in allocated:
    sid = str(item.get('id', '')).strip()
    if not sid:
        raise SystemExit('ERROR: allocator response is missing a service id')
    if 'remote_port' not in item:
        raise SystemExit(f'ERROR: allocator response is missing remote_port for {sid}')
    by_id[sid] = int(item['remote_port'])
if len(by_id) != len(local):
    raise SystemExit('ERROR: allocator did not return every requested service')
for item in local:
    sid = item['id']
    if sid not in by_id:
        raise SystemExit(f'ERROR: allocator did not allocate a port for {sid}')
    item['remote_port'] = by_id[sid]
local_path.write_text(json.dumps(local, indent=2)+'\n', encoding='utf-8')
PY
}

render_frpc_toml() {
  local dest="$1" server="$2" server_port="$3" token="$4" host_id="$5" services_json_file="$6"
  python3 - "$dest" "$server" "$server_port" "$token" "$host_id" "$services_json_file" <<'PY'
import json, sys
from pathlib import Path
dest, server, server_port, token, host_id, svc_path = sys.argv[1:7]
raw = json.loads(Path(svc_path).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services = []
    for sid, item in raw['services'].items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        services.append(rec)
else:
    services = raw
lines = [
    f'serverAddr = "{server}"',
    f'serverPort = {server_port}',
    '',
    'auth.method = "token"',
    f'auth.token = "{token}"',
    '',
    'transport.tls.enable = true',
]
for item in services:
    if item.get('enabled', True) is False:
        continue
    lines.extend([
        '',
        '[[proxies]]',
        f'name = "{host_id}-{item["id"]}"',
        'type = "tcp"',
        f'localIP = "{item["local_ip"]}"',
        f'localPort = {int(item["local_port"])}',
        f'remotePort = {int(item["remote_port"])}',
    ])
text = '\n'.join(lines) + '\n'
path = Path(dest)
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(path.name + '.tmp')
tmp.write_text(text, encoding='utf-8')
tmp.chmod(0o600)
tmp.replace(path)
PY
}

render_access_info() {
  local dest="$1" server="$2" services_json_file="$3"
  python3 - "$dest" "$server" "$services_json_file" <<'PY'
import json,sys
from pathlib import Path
dest, server, svc_path = sys.argv[1:4]
raw = json.loads(Path(svc_path).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services = []
    for sid, item in raw['services'].items():
        rec = dict(item)
        rec['id'] = rec.get('id') or sid
        services.append(rec)
else:
    services = raw
lines = [f'FRP Server: {server}', '', 'Services:', '']
for item in services:
    if item.get('enabled', True) is False:
        continue
    sid = item['id']
    name = item.get('name') or sid
    preset = item.get('preset') or 'custom'
    local_ip = item.get('local_ip')
    local_port = item.get('local_port')
    remote_port = item.get('remote_port')
    lines.append(sid if name == sid else f'{sid} ({name})')
    lines.append(f'  Target : {local_ip}:{local_port}')
    lines.append(f'  Public : {server}:{remote_port}')
    if preset == 'ssh':
        user = item.get('ssh_user') or 'root'
        lines.append('  Connect:')
        lines.append(f'    ssh -p {remote_port} {user}@{server}')
    elif preset == 'http':
        lines.append('  URL:')
        lines.append(f'    http://{server}:{remote_port}')
    elif preset == 'https':
        lines.append('  URL:')
        lines.append(f'    https://{server}:{remote_port}')
    else:
        lines.append('  Connect:')
        lines.append(f'    {server}:{remote_port}')
    lines.append('')
path = Path(dest)
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(path.name + '.tmp')
tmp.write_text('\n'.join(lines).rstrip()+'\n', encoding='utf-8')
tmp.chmod(0o644)
tmp.replace(path)
PY
}

proxy_names_from_services() {
  local host_id="$1"
  python3 - "$host_id" "$SERVICES_FILE" <<'PY'
import json,sys
from pathlib import Path
host_id=sys.argv[1]
raw=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services=[]
    for sid, item in raw['services'].items():
        rec=dict(item)
        rec['id']=rec.get('id') or sid
        services.append(rec)
else:
    services=raw
for item in services:
    if item.get('enabled', True) is False:
        continue
    print(f'{host_id}-{item["id"]}')
PY
}

wait_for_proxies() {
  local logs proxy missing
  local -a names=("$@")
  local i
  for i in {1..20}; do
    sleep 1
    logs="$(journalctl -u frpc -n 400 --no-pager 2>/dev/null || true)"
    if ! grep -q 'login to server success' <<<"$logs"; then
      continue
    fi
    missing=""
    for proxy in "${names[@]}"; do
      if ! grep -F "[${proxy}] start proxy success" <<<"$logs"; then
        missing="$proxy"
        break
      fi
    done
    if [[ -z "$missing" ]]; then
      return 0
    fi
  done
  return 1
}

frp_enroll_services() {
  local allocator_url="$1" enroll_id="$2" enroll_secret="$3"
  local machine_id="$4" hostname_value="$5" services_file="$6"
  local allocated_file="$7" meta_file="$8"
  local auth_mode="${9:-${FRP_MGMT_AUTH:-enrollment}}"
  local request timestamp signature response curl_err nonce py key_path pubkey_pem
  local verify_rc=0
  frp_client_hook_log enroll
  if [[ "${FRP_CLIENT_HOOK_ENROLL_FAIL:-}" == "1" ]]; then
    echo "ERROR: allocator unavailable" >&2
    return 1
  fi
  if [[ -n "${FRP_CLIENT_ENROLL_COUNT_FILE:-}" ]]; then
    python3 - "$FRP_CLIENT_ENROLL_COUNT_FILE" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
n = int(p.read_text().strip() or '0') if p.is_file() else 0
p.write_text(str(n + 1) + '\n')
PY
    if [[ "${FRP_CLIENT_HOOK_COMPENSATE_FAIL:-}" == "1" ]]; then
      local enroll_n
      enroll_n="$(tr -d '\n' <"$FRP_CLIENT_ENROLL_COUNT_FILE")"
      if (( enroll_n >= 2 )); then
        echo "ERROR: compensating enrollment failed" >&2
        return 1
      fi
    fi
  fi
  pubkey_pem=""
  if [[ "$auth_mode" != identity ]]; then
    case "$(frp_identity_status)" in
      enrolled|pending)
        pubkey_pem="$(frp_identity_public_pem)" || return 1
        ;;
    esac
  fi
  request="$(python3 - "$machine_id" "$hostname_value" "$services_file" "$pubkey_pem" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
if isinstance(raw, dict) and 'services' in raw:
    services=[]
    for sid, item in raw['services'].items():
        rec=dict(item)
        rec['id']=rec.get('id') or sid
        services.append(rec)
else:
    services=raw
enabled=[]
for item in services:
    if item.get('enabled', True) is False:
        continue
    out={
        'id': item['id'],
        'name': item.get('name') or item['id'],
        'protocol': 'tcp',
        'local_ip': item['local_ip'],
        'local_port': item['local_port'],
        'preset': item.get('preset') or 'custom',
    }
    if out['preset']=='ssh':
        out['ssh_user']=item.get('ssh_user') or 'root'
    enabled.append(out)
payload={
  'machine_id': sys.argv[1],
  'hostname': sys.argv[2],
  'services': enabled,
}
pub=sys.argv[4]
if pub:
    payload['mgmt_pubkey']=pub
    payload['mgmt_alg']='ecdsa-p256-sha256'
print(json.dumps(payload, separators=(',', ':')))
PY
)"
  timestamp="$(date +%s)"
  py="$(frp_mgmt_auth_py)" || return 1
  curl_err="$(mktemp)"
  if [[ "$auth_mode" == identity ]]; then
    key_path="$(frp_client_identity_key_path)"
    if [[ "$(frp_identity_status)" != enrolled ]]; then
      echo "ERROR: this client does not have a usable management identity." >&2
      rm -f "$curl_err"
      return 1
    fi
    nonce="$(python3 - "$py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('frp_mgmt_auth', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.new_nonce())
PY
)"
    signature="$(BODY="$request" python3 - "$py" "$key_path" "$machine_id" "$timestamp" "$nonce" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('frp_mgmt_auth', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
key, machine_id, ts, nonce = sys.argv[2:6]
body = os.environ['BODY']
message = mod.signed_message(machine_id, body, ts, nonce)
sys.stdout.write(mod.sign_message(key, message))
PY
)"
    if ! response="$(curl --silent --show-error \
      -X POST \
      -H 'Content-Type: application/json' \
      -H 'X-Mgmt-Auth: 1' \
      -H "X-Timestamp: ${timestamp}" \
      -H "X-Mgmt-Nonce: ${nonce}" \
      -H "X-Mgmt-Signature: ${signature}" \
      --data "$request" \
      "$allocator_url" 2>"$curl_err")"; then
      echo "ERROR: allocator request failed" >&2
      cat "$curl_err" >&2 || true
      rm -f "$curl_err"
      return 1
    fi
    rm -f "$curl_err"
    local mac
    mac="$(frp_identity_load_mac)" || return 1
    if MGMT_MAC_KEY="$mac" RESPONSE="$response" ALLOCATED_FILE="$allocated_file" META_FILE="$meta_file" python3 - <<'PY'
import hashlib,hmac,json,os,sys
from pathlib import Path
secret=os.environ['MGMT_MAC_KEY']
d=json.loads(os.environ['RESPONSE'])
if isinstance(d, dict) and d.get('error'):
    err=str(d.get('error') or '')
    print(f'ERROR: allocator rejected the change: {err}', file=sys.stderr)
    lowered=err.lower()
    if 'revoked' in lowered or 'does not have a management identity' in lowered or 'unknown client identity' in lowered:
        raise SystemExit(2)
    raise SystemExit(1)
received=d.pop('response_hmac',None)
canonical=json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=False)
expected=hmac.new(secret.encode(),canonical.encode(),hashlib.sha256).hexdigest()
if not received or not hmac.compare_digest(received,expected):
    raise SystemExit('ERROR: allocator response HMAC verification failed')
if 'ssh_port' in d or 'https_port' in d:
    raise SystemExit('ERROR: allocator returned a legacy SSH/HTTPS response')
if 'token_ciphertext' in d or 'mgmt_mac_key' in d or d.get('token'):
    raise SystemExit('ERROR: allocator returned unexpected secret material')
services=d.get('services')
if not isinstance(services, list) or not services:
    raise SystemExit('ERROR: allocator response is missing services')
Path(os.environ['ALLOCATED_FILE']).write_text(json.dumps(services)+'\n', encoding='utf-8')
meta={
    'frp_server': str(d['frp_server']),
    'frp_server_port': str(d['frp_server_port']),
    'token_ciphertext': '',
}
Path(os.environ['META_FILE']).write_text(json.dumps(meta)+'\n', encoding='utf-8')
PY
    then
      return 0
    else
      verify_rc=$?
      if [[ "$verify_rc" -eq 2 ]]; then
        return 2
      fi
      return 1
    fi
  fi
  signature="$(ENROLL_SECRET="$enroll_secret" TS="$timestamp" BODY="$request" python3 - <<'PY'
import hashlib,hmac,os
secret=os.environ['ENROLL_SECRET'].encode()
message=(os.environ['TS']+'\n'+os.environ['BODY']).encode()
print(hmac.new(secret,message,hashlib.sha256).hexdigest())
PY
)"
  if ! response="$(curl --silent --show-error \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Enrollment-ID: ${enroll_id}" \
    -H "X-Timestamp: ${timestamp}" \
    -H "X-Signature: ${signature}" \
    --data "$request" \
    "$allocator_url" 2>"$curl_err")"; then
    echo "ERROR: allocator request failed" >&2
    cat "$curl_err" >&2 || true
    rm -f "$curl_err"
    return 1
  fi
  rm -f "$curl_err"
  ENROLL_SECRET="$enroll_secret" RESPONSE="$response" ALLOCATED_FILE="$allocated_file" META_FILE="$meta_file" python3 - <<'PY'
import hashlib,hmac,json,os
from pathlib import Path
secret=os.environ['ENROLL_SECRET']
d=json.loads(os.environ['RESPONSE'])
if isinstance(d, dict) and d.get('error'):
    raise SystemExit(f"ERROR: allocator rejected enrollment: {d.get('error')}")
received=d.pop('response_hmac',None)
canonical=json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=False)
expected=hmac.new(secret.encode(),canonical.encode(),hashlib.sha256).hexdigest()
if not received or not hmac.compare_digest(received,expected):
    raise SystemExit('ERROR: allocator response HMAC verification failed')
if 'ssh_port' in d or 'https_port' in d:
    raise SystemExit('ERROR: allocator returned a legacy SSH/HTTPS response')
if 'mgmt_mac_key' in d:
    raise SystemExit('ERROR: allocator returned unexpected secret material')
services=d.get('services')
if not isinstance(services, list) or not services:
    raise SystemExit('ERROR: allocator response is missing services')
Path(os.environ['ALLOCATED_FILE']).write_text(json.dumps(services)+'\n', encoding='utf-8')
token=str(d.get('token_ciphertext') or '')
if not token:
    raise SystemExit('ERROR: allocator response is missing token_ciphertext')
meta={
    'frp_server': str(d['frp_server']),
    'frp_server_port': str(d['frp_server_port']),
    'token_ciphertext': token,
    'mgmt_status': str(d.get('mgmt_status') or ''),
}
Path(os.environ['META_FILE']).write_text(json.dumps(meta)+'\n', encoding='utf-8')
PY
  if [[ -n "$pubkey_pem" ]]; then
    frp_identity_derive_and_store_mac "$machine_id" "$enroll_secret" || return 1
  fi
}

frp_decrypt_token() {
  local ciphertext="$1" secret="$2"
  local token
  token="$(printf '%s' "$ciphertext" | \
    FRP_ENROLL_SECRET="$secret" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -md sha256 -a -A -pass env:FRP_ENROLL_SECRET 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERROR: failed to decrypt FRP token" >&2
    return 1
  fi
  printf '%s' "$token"
}

frp_state_diff_engine() {
  local mode="$1" current="$2" candidate="$3"
  python3 - "$mode" "$current" "$candidate" <<'PY'
import json, sys
from pathlib import Path

mode = sys.argv[1]

def svcs(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    services = data.get('services') or {}
    if isinstance(services, list):
        return {item['id']: item for item in services}, data
    return {sid: dict(item, id=item.get('id') or sid) for sid, item in services.items()}, data

def enabled(item):
    return item.get('enabled', True) is not False

def port(item):
    try:
        return int(item.get('local_port') or 0)
    except (TypeError, ValueError):
        return 0

def pair_notes(a, b):
    notes = []
    if enabled(a) and not enabled(b):
        notes.append(('runtime', 'disabled (public port remains reserved)'))
    elif (not enabled(a)) and enabled(b):
        notes.append(('runtime', 're-enabled'))
    if a.get('local_ip') != b.get('local_ip') or port(a) != port(b):
        notes.append((
            'runtime',
            f"Target: {a.get('local_ip')}:{a.get('local_port')} -> {b.get('local_ip')}:{b.get('local_port')}",
        ))
    if (a.get('name') or '') != (b.get('name') or ''):
        notes.append(('local', f"Display name: {a.get('name')} -> {b.get('name')}"))
    if a.get('preset') == 'ssh' or b.get('preset') == 'ssh':
        old_user = a.get('ssh_user') or 'root'
        new_user = b.get('ssh_user') or 'root'
        if old_user != new_user:
            notes.append(('local', f'SSH user: {old_user} -> {new_user}'))
    return notes

cur, cur_data = svcs(sys.argv[2])
new, _new_data = svcs(sys.argv[3])
entries = []
classes = set()
for sid in sorted(set(cur) | set(new)):
    a, b = cur.get(sid), new.get(sid)
    if a is None:
        entries.append({
            'id': sid,
            'kind': '+',
            'cls': 'runtime',
            'notes': [
                f"{b.get('local_ip')}:{b.get('local_port')}",
                'public port: assigned automatically',
            ],
        })
        classes.add('runtime')
        continue
    if b is None:
        entries.append({
            'id': sid,
            'kind': '-',
            'cls': 'runtime',
            'notes': [
                'removed from local configuration',
                'The public port remains reserved on the FRP server.',
            ],
        })
        classes.add('runtime')
        continue
    notes = pair_notes(a, b)
    if not notes:
        continue
    note_cls = 'runtime' if any(c == 'runtime' for c, _t in notes) else 'local'
    entries.append({
        'id': sid,
        'kind': '~',
        'cls': note_cls,
        'notes': [text for _c, text in notes],
    })
    classes.add(note_cls)

if 'runtime' in classes:
    overall = 'runtime'
elif 'local' in classes:
    overall = 'local'
else:
    overall = 'none'

if mode == 'class':
    print(overall)
    raise SystemExit(0)

if mode == 'pending':
    if overall == 'none':
        raise SystemExit(0)
    print('Pending changes:')
    print()
    lines = []
    for item in entries:
        lines.append(f"{item['kind']} {item['id']}")
        for note in item['notes']:
            lines.append(f'  {note}')
    print('\n'.join(lines))
    raise SystemExit(0)

print()
print('Ready to apply')
print('==============')
print()
print('Current:')
if not cur:
    print('  (none)')
else:
    for sid, item in cur.items():
        state = 'enabled' if enabled(item) else 'disabled'
        remote = item.get('remote_port')
        extra = f"    public :{remote}" if remote else '    public : assigned automatically'
        print(f"  {sid}")
        print(f"    {item.get('local_ip')}:{item.get('local_port')}")
        print(extra)
        print(f"    {state}")
print()
print('Changes:')
if not entries:
    print('  (none)')
else:
    lines = []
    for item in entries:
        lines.append(f"  {item['kind']} {item['id']}")
        for note in item['notes']:
            lines.append(f'    {note}')
    print('\n'.join(lines))
print()
if overall == 'local':
    print('These changes affect local connection information only.')
    print('The FRP server and running proxy do not need to be changed.')
elif overall == 'runtime':
    print('Applying this configuration will restart the FRP client.')
print()
PY
}

frp_state_diff() {
  frp_state_diff_engine pending "$1" "$2"
}

frp_state_change_class() {
  frp_state_diff_engine class "$1" "$2"
}

frp_state_has_diff() {
  local cls
  cls="$(frp_state_change_class "$1" "$2")"
  [[ "$cls" == none ]]
}

frp_apply_local_metadata() {
  local current="$1" candidate="$2"
  python3 - "$candidate" "$current" <<'PY'
import json, sys
from pathlib import Path
cand = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
cur = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
for key in ('allocator_url', 'frp_server', 'frp_server_port', 'hostname', 'machine_id', 'host_id', 'schema_version'):
    if key in cur and key not in cand:
        cand[key] = cur[key]
    elif key in cur:
        cand.setdefault(key, cur.get(key))
for sid, rec in (cand.get('services') or {}).items():
    prev = (cur.get('services') or {}).get(sid) or {}
    if rec.get('remote_port') in (None, '') and prev.get('remote_port') not in (None, ''):
        rec['remote_port'] = prev['remote_port']
Path(sys.argv[1]).write_text(json.dumps(cand, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
  local server access
  server="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("frp_server",""))' "$candidate")"
  access="$(frp_client_access_path)"
  local tmp_access
  tmp_access="$(mktemp)"
  render_access_info "$tmp_access" "$server" "$candidate"
  frp_backup_client_files >/dev/null
  frp_atomic_write_json_file "$(frp_client_state_path)" "$candidate" 0600
  frp_state_has_secrets "$(frp_client_state_path)" || {
    echo "ERROR: client-state.json must not contain secrets" >&2
    rm -f "$tmp_access"
    return 1
  }
  install -m 0644 "$tmp_access" "$access"
  rm -f "$tmp_access"
  echo "Applied local changes."
  echo "Allocator contacted : NO"
  echo "frpc restarted      : NO"
}

frp_merge_ports_into_state() {
  python3 - "$1" "$2" <<'PY'
import json, sys
from pathlib import Path
state_path, alloc_path = Path(sys.argv[1]), Path(sys.argv[2])
state = json.loads(state_path.read_text(encoding='utf-8'))
allocated = json.loads(alloc_path.read_text(encoding='utf-8'))
by_id = {str(item['id']): int(item['remote_port']) for item in allocated}
services = state['services']
enabled_ids = [sid for sid, rec in services.items() if rec.get('enabled', True) is not False]
if set(by_id) != set(enabled_ids):
    raise SystemExit('ERROR: allocator did not return every requested enabled service')
for sid, rec in services.items():
    if rec.get('enabled', True) is False:
        continue
    rec['remote_port'] = by_id[sid]
state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n', encoding='utf-8')
PY
}

frp_backup_client_files() {
  local stamp dest src
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$(frp_client_backup_dir)/${stamp}"
  mkdir -p "$dest"
  chmod 700 "$(frp_client_backup_dir)" 2>/dev/null || true
  chmod 700 "$dest"
  for src in "$(frp_client_state_path)" "$(frp_client_toml_path)" "$(frp_client_access_path)"; do
    if [[ -f "$src" ]]; then
      install -m 0600 "$src" "$dest/$(basename "$src")"
    fi
  done
  printf '%s' "$dest"
  python3 - "$(frp_client_backup_dir)" "$FRP_CLIENT_BACKUP_KEEP" <<'PY'
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

frp_restore_client_files() {
  local backup="$1"
  [[ -d "$backup" ]] || return 1
  local f dest
  for f in client-state.json frpc.toml access-info.txt; do
    if [[ -f "$backup/$f" ]]; then
      case "$f" in
        client-state.json) dest="$(frp_client_state_path)" ;;
        frpc.toml) dest="$(frp_client_toml_path)" ;;
        access-info.txt) dest="$(frp_client_access_path)" ;;
      esac
      install -m 0600 "$backup/$f" "$dest"
      if [[ "$f" == access-info.txt ]]; then
        chmod 644 "$dest"
      fi
    fi
  done
}

frp_acquire_client_lock() {
  local dir
  dir="$(frp_client_lock_dir)"
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    echo "ERROR: another frp-client management operation is already running." >&2
    return 1
  fi
  printf '%s\n' "$$" >"$dir/pid"
  chmod 700 "$dir" 2>/dev/null || true
}

frp_release_client_lock() {
  local dir
  dir="$(frp_client_lock_dir)"
  rm -rf "$dir"
}

frp_client_verify_config() {
  local cfg="$1"
  frp_client_hook_log verify
  if [[ "${FRP_CLIENT_HOOK_VERIFY_FAIL:-}" == "1" ]]; then
    echo "ERROR: simulated frpc verify failure" >&2
    return 1
  fi
  local frpc_bin
  frpc_bin="$(frp_client_path /usr/local/bin/frpc)"
  if [[ -x "$frpc_bin" ]]; then
    "$frpc_bin" verify -c "$cfg"
  elif command -v frpc >/dev/null 2>&1; then
    frpc verify -c "$cfg"
  else
    echo "ERROR: frpc is not available to verify the generated config" >&2
    return 1
  fi
}

frp_client_restart() {
  frp_client_hook_log restart
  if [[ "${FRP_CLIENT_HOOK_RESTART_FAIL:-}" == "1" ]]; then
    FRP_CLIENT_HOOK_RESTART_FAIL=0
    echo "ERROR: simulated systemctl restart failure" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  systemctl restart frpc
}

frp_client_wait_proxies() {
  frp_client_hook_log proxies
  if [[ "${FRP_CLIENT_HOOK_PROXY_FAIL:-}" == "1" ]]; then
    echo "ERROR: frpc did not register every requested proxy successfully" >&2
    return 1
  fi
  if [[ "${FRP_SKIP_SYSTEMD:-}" == "1" || -n "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    return 0
  fi
  wait_for_proxies "$@"
}

frp_print_state_services() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
server = data.get('frp_server', '')
services = data.get('services') or {}
if not services:
    print('(none)')
    raise SystemExit(0)
n = 0
for sid, item in services.items():
    n += 1
    enabled = item.get('enabled', True) is not False
    state = 'enabled' if enabled else 'disabled'
    print(f"{n}. {item.get('id') or sid}")
    preset = item.get('preset') or 'custom'
    labels = {'ssh': 'SSH / TCP', 'http': 'HTTP / TCP', 'https': 'HTTPS / TCP'}
    print(f"   Type        : {labels.get(preset, 'Custom TCP')}")
    print(f"   Target      : {item.get('local_ip')}:{item.get('local_port')}")
    remote = item.get('remote_port')
    if remote:
        print(f"   Public port : {remote}")
    print(f"   State       : {state}")
    print()
PY
}

# --- Project-layer client upgrade (does not re-enroll) --------------------

frp_client_atomic_install() {
  local src="$1" dest="$2" mode="${3:-0755}"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.frp-upgrade.XXXXXX")"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  if [[ ${EUID} -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest"
}

frp_client_digest() {
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

frp_client_upgrade_source_version() {
  local source="$1"
  if [[ -f "${source}/VERSION" ]]; then
    # shellcheck disable=SC1091
    . "${source}/VERSION"
  fi
}

frp_client_install_management_files() {
  local source="$1"
  local libdir bindir
  libdir="$(frp_client_lib_dir)"
  bindir="$(frp_client_path /usr/local/bin)"
  mkdir -p "$libdir" "$bindir"
  [[ -f "${source}/lib/frp-client-common.sh" ]] || {
    echo "ERROR: missing ${source}/lib/frp-client-common.sh" >&2
    return 1
  }
  [[ -f "${source}/lib/frp_mgmt_auth.py" ]] || {
    echo "ERROR: missing ${source}/lib/frp_mgmt_auth.py" >&2
    return 1
  }
  [[ -f "${source}/tools/frp-client" ]] || {
    echo "ERROR: missing ${source}/tools/frp-client" >&2
    return 1
  }
  [[ -f "${source}/tools/frpctl" ]] || {
    echo "ERROR: missing ${source}/tools/frpctl" >&2
    return 1
  }
  install -m 0644 "${source}/lib/frp-client-common.sh" "${libdir}/frp-client-common.sh"
  install -m 0644 "${source}/lib/frp_mgmt_auth.py" "${libdir}/frp_mgmt_auth.py"
  install -m 0755 "${source}/tools/frp-client" "${bindir}/frp-client"
  install -m 0755 "${source}/tools/frpctl" "${bindir}/frpctl"
  frp_client_upgrade_source_version "$source"
  frp_client_write_version_file
}

frp_client_upgrade_destinations() {
  # dest_rel:mode:source_rel
  printf '%s\n' \
    "usr/local/lib/frp-auto-deploy/frp-client-common.sh:0644:lib/frp-client-common.sh" \
    "usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py:0644:lib/frp_mgmt_auth.py" \
    "usr/local/bin/frp-client:0755:tools/frp-client" \
    "usr/local/bin/frpctl:0755:tools/frpctl"
}

frp_client_upgrade_validate_existing() {
  local state toml ident
  state="$(frp_client_state_path)"
  toml="$(frp_client_toml_path)"
  [[ -f "$state" ]] || {
    echo "ERROR: no existing FRP client installation was found." >&2
    echo "Use the client bootstrap installer to enroll a new client." >&2
    return 1
  }
  frp_load_client_state "$state" || return 1
  if [[ -f "$toml" ]]; then
    frp_client_verify_config "$toml" || return 1
  fi
  ident="$(frp_identity_status)"
  if [[ "$ident" == corrupt ]]; then
    echo "WARNING: this client's management identity is unusable." >&2
    echo "Software upgrade will continue without regenerating identity files." >&2
  fi
  return 0
}

frp_client_upgrade_validate_staged() {
  local staged="$1" rel mode src dest
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    dest="${staged}/${rel}"
    [[ -f "$dest" ]] || {
      echo "ERROR: staged update is missing ${rel}" >&2
      return 1
    }
  done < <(frp_client_upgrade_destinations)
  bash -n "${staged}/usr/local/bin/frp-client" || return 1
  bash -n "${staged}/usr/local/bin/frpctl" || return 1
  bash -n "${staged}/usr/local/lib/frp-auto-deploy/frp-client-common.sh" || return 1
  python3 -m py_compile "${staged}/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" || return 1
  rm -rf "${staged}/usr/local/lib/frp-auto-deploy/__pycache__" \
    "${staged}/usr/local/lib/frp-auto-deploy/"*.pyc 2>/dev/null || true
  [[ -x "${staged}/usr/local/bin/frp-client" ]] || {
    echo "ERROR: staged frp-client is not executable" >&2
    return 1
  }
  [[ -x "${staged}/usr/local/bin/frpctl" ]] || {
    echo "ERROR: staged frpctl is not executable" >&2
    return 1
  }
  if [[ "${FRP_CLIENT_UPGRADE_HOOK_FAIL:-}" == "validate" ]]; then
    echo "ERROR: simulated staged update validation failure" >&2
    return 1
  fi
  return 0
}

frp_client_upgrade_backup_tools() {
  local stamp dest live rel mode src base
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$(frp_client_upgrade_backup_root)/${stamp}"
  mkdir -p "$dest"
  chmod 700 "$(frp_client_upgrade_backup_root)" 2>/dev/null || true
  chmod 700 "$dest"
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    live="$(frp_client_path "/${rel}")"
    base="$(basename "$rel")"
    if [[ -f "$live" ]]; then
      install -m "$mode" "$live" "${dest}/${base}"
      printf 'present %s\n' "$base" >>"${dest}/manifest"
    else
      printf 'absent %s\n' "$base" >>"${dest}/manifest"
    fi
  done < <(frp_client_upgrade_destinations)
  live="$(frp_client_version_file)"
  if [[ -f "$live" ]]; then
    install -m 0644 "$live" "${dest}/version"
    printf 'present version\n' >>"${dest}/manifest"
  else
    printf 'absent version\n' >>"${dest}/manifest"
  fi
  python3 - "$(frp_client_upgrade_backup_root)" "$FRP_CLIENT_UPGRADE_BACKUP_KEEP" <<'PY'
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
  printf '%s' "$dest"
}

frp_client_upgrade_restore_tools() {
  local backup="$1" live rel mode src base
  [[ -d "$backup" ]] || return 1
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    live="$(frp_client_path "/${rel}")"
    base="$(basename "$rel")"
    if [[ -f "${backup}/${base}" ]]; then
      install -m "$mode" "${backup}/${base}" "$live"
    else
      rm -f "$live"
    fi
  done < <(frp_client_upgrade_destinations)
  live="$(frp_client_version_file)"
  if [[ -f "${backup}/version" ]]; then
    mkdir -p "$(dirname "$live")"
    install -m 0644 "${backup}/version" "$live"
  else
    rm -f "$live"
  fi
  return 0
}

frp_client_upgrade_stage() {
  local source="$1" staged="$2" rel mode src
  mkdir -p "$staged"
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    [[ -f "${source}/${src}" ]] || {
      echo "ERROR: update source is missing ${src}" >&2
      return 1
    }
    mkdir -p "$(dirname "${staged}/${rel}")"
    install -m "$mode" "${source}/${src}" "${staged}/${rel}"
  done < <(frp_client_upgrade_destinations)
}

frp_client_upgrade_install_staged() {
  local staged="$1" live rel mode src
  local replaced=0
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    live="$(frp_client_path "/${rel}")"
    frp_client_atomic_install "${staged}/${rel}" "$live" "$mode" || return 1
    replaced=$((replaced + 1))
    if [[ "$replaced" -eq 1 && "${FRP_CLIENT_UPGRADE_HOOK_FAIL:-}" == "install" ]]; then
      echo "ERROR: simulated tool install failure" >&2
      return 1
    fi
  done < <(frp_client_upgrade_destinations)
  return 0
}

frp_client_upgrade_verify() {
  local ident_before="$1"
  local live rel mode src
  while IFS=: read -r rel mode src; do
    [[ -n "$rel" ]] || continue
    live="$(frp_client_path "/${rel}")"
    [[ -f "$live" ]] || {
      echo "ERROR: upgraded file missing: ${live}" >&2
      return 1
    }
  done < <(frp_client_upgrade_destinations)
  [[ -x "$(frp_client_path /usr/local/bin/frp-client)" ]] || return 1
  [[ -x "$(frp_client_path /usr/local/bin/frpctl)" ]] || return 1
  frp_load_client_state "$(frp_client_state_path)" || return 1
  if [[ -f "$(frp_client_toml_path)" ]]; then
    frp_client_verify_config "$(frp_client_toml_path)" || return 1
  fi
  [[ -f "$(frp_client_version_file)" ]] || {
    echo "ERROR: version file was not written" >&2
    return 1
  }
  if [[ "$ident_before" == enrolled && "$(frp_identity_status)" != enrolled ]]; then
    echo "ERROR: management identity was not preserved" >&2
    return 1
  fi
  if [[ "${FRP_CLIENT_UPGRADE_HOOK_FAIL:-}" == "verify" ]]; then
    echo "ERROR: simulated post-upgrade verification failure" >&2
    return 1
  fi
  return 0
}

frp_client_apply_upgrade() {
  local source="${1:-}"
  local check_only="${2:-0}"
  local previous target staged backup ident_before ident_after
  local state_before toml_before access_before key_before pub_before mac_before
  local frp_before frp_after

  if [[ -z "$source" || ! -d "$source" ]]; then
    echo "ERROR: update source directory is required" >&2
    return 1
  fi
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi

  frp_client_upgrade_validate_existing || return 1
  frp_client_upgrade_source_version "$source"
  previous="$(frp_client_installed_project_version)"
  target="${PROJECT_VERSION}"
  frp_before="$(frp_client_installed_frp_version)"
  ident_before="$(frp_identity_status)"

  echo "Installed project version : ${previous}"
  echo "Target project version    : ${target}"
  echo "FRP version               : ${FRP_VERSION}"
  echo

  if [[ "$check_only" == "1" ]]; then
    if [[ "$previous" == "$target" ]]; then
      echo "Update                    : not needed"
    else
      echo "Update                    : available"
    fi
    echo
    echo "A software update does not require an Enrollment Code."
    echo "Client state, public ports, and management identity are preserved."
    return 0
  fi

  echo "Checking existing client state..."
  state_before="$(frp_client_digest "$(frp_client_state_path)")"
  toml_before="$(frp_client_digest "$(frp_client_toml_path)")"
  access_before="$(frp_client_digest "$(frp_client_access_path)")"
  key_before="$(frp_client_digest "$(frp_client_identity_key_path)")"
  pub_before="$(frp_client_digest "$(frp_client_identity_pub_path)")"
  mac_before="$(frp_client_digest "$(frp_client_identity_mac_path)")"

  staged="$(mktemp -d)"
  backup=""
  # shellcheck disable=SC2064
  trap 'rm -rf "'"$staged"'"' RETURN

  echo "Staging new management files..."
  frp_client_upgrade_stage "$source" "$staged" || return 1

  echo "Validating staged files..."
  if ! frp_client_upgrade_validate_staged "$staged"; then
    echo "ERROR: staged update failed validation; existing installation was not changed." >&2
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi

  echo "Backing up replaceable project files..."
  backup="$(frp_client_upgrade_backup_tools)" || return 1

  echo "Installing management files..."
  if ! frp_client_upgrade_install_staged "$staged"; then
    echo "ERROR: tool install failed; restoring previous management files." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi

  echo "Writing project version..."
  if ! frp_client_write_version_file; then
    echo "ERROR: failed to write version file; restoring previous management files." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi

  echo "Verifying upgrade..."
  if ! frp_client_upgrade_verify "$ident_before"; then
    echo "ERROR: post-upgrade verification failed; restoring previous management files." >&2
    if frp_client_upgrade_restore_tools "$backup"; then
      echo "UPGRADE_ROLLBACK=PASS"
    else
      echo "UPGRADE_ROLLBACK=FAIL"
    fi
    return 1
  fi

  if [[ "$(frp_client_digest "$(frp_client_state_path)")" != "$state_before" ]]; then
    echo "ERROR: client-state.json changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ -n "$toml_before" && "$(frp_client_digest "$(frp_client_toml_path)")" != "$toml_before" ]]; then
    echo "ERROR: frpc.toml changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ -n "$access_before" && "$(frp_client_digest "$(frp_client_access_path)")" != "$access_before" ]]; then
    echo "ERROR: access-info.txt changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ -n "$key_before" && "$(frp_client_digest "$(frp_client_identity_key_path)")" != "$key_before" ]]; then
    echo "ERROR: management identity changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ -n "$pub_before" && "$(frp_client_digest "$(frp_client_identity_pub_path)")" != "$pub_before" ]]; then
    echo "ERROR: management public identity changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ -n "$mac_before" && "$(frp_client_digest "$(frp_client_identity_mac_path)")" != "$mac_before" ]]; then
    echo "ERROR: management identity MAC changed during software upgrade; restoring tools." >&2
    frp_client_upgrade_restore_tools "$backup" || true
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi

  ident_after="$(frp_identity_label)"
  frp_after="${FRP_VERSION}"
  echo
  echo "Upgrade complete."
  echo "Project version : ${previous} -> ${target}"
  if [[ "$frp_before" == "$frp_after" ]]; then
    echo "FRP version     : ${frp_after} (unchanged)"
  else
    echo "FRP version     : ${frp_before} -> ${frp_after}"
  fi
  echo "Client state    : preserved"
  echo "Management ID   : ${ident_after}"
  echo "frpc restarted  : NO"
  echo "Enrollment Code : NOT REQUIRED"
  return 0
}

frp_client_fetch_and_upgrade() {
  local source="${1:-}"
  local check_only="${2:-0}"
  local tmp archive
  if [[ -n "$source" ]]; then
    frp_client_apply_upgrade "$source" "$check_only"
    return $?
  fi
  if [[ "${FRP_CLIENT_UPGRADE_HOOK_DOWNLOAD_FAIL:-}" == "1" ]]; then
    echo "ERROR: failed to download the client update bundle" >&2
    return 1
  fi
  if [[ ${EUID} -ne 0 && -z "${FRP_CLIENT_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  tmp="$(mktemp -d)"
  archive="${tmp}/bootstrap-client.sh"
  trap 'rm -rf "'"$tmp"'"' RETURN
  echo "Downloading frp-auto-deploy client update bundle..."
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "$archive" "$FRP_CLIENT_UPDATE_URL" || {
    echo "ERROR: failed to download the client update bundle" >&2
    return 1
  }
  chmod 0755 "$archive"
  echo "Applying update from downloaded bundle..."
  # The bundle extracts a source tree and runs install-client.sh --upgrade.
  if [[ "$check_only" == "1" ]]; then
    bash "$archive" --upgrade --check
  else
    bash "$archive" --upgrade
  fi
}
