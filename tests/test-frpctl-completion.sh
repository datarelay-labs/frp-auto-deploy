#!/usr/bin/env bash
# Role-aware frpctl Tab completion. Pure functions; no live host, no TTY.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

FRP_CTL_SOURCED=1
# shellcheck source=../tools/frpctl
. "$ROOT/tools/frpctl"

write_client_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp" "$tree/etc/frp-auto-deploy"
  python3 - "$tree/etc/frp/client-state.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "allocator_url": "https://127.0.0.1:9/enroll",
    "frp_server": "203.0.113.10",
    "hostname": "ctl-client",
    "machine_id": "00112233445566778899aabbccddeeff",
    "services": {"ssh": {"id": "ssh", "remote_port": 6002, "enabled": True}},
}, indent=2, sort_keys=True) + "\n")
PY
}

write_server_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp-auto-deploy" "$tree/var/lib/frp-auto-deploy"
  python3 - "$tree/etc/frp-auto-deploy/config.json" "$tree/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json, sys
from pathlib import Path
cfg, reg = Path(sys.argv[1]), Path(sys.argv[2])
cfg.write_text(json.dumps({
    "public_ip": "203.0.113.10",
    "control_port": 443,
    "port_start": 6000,
    "port_end": 6098,
    "listen_port": 6099,
    "allocator_public_url": "https://203.0.113.10:6099/enroll",
    "registry_file": "/var/lib/frp-auto-deploy/registry.json",
}, indent=2, sort_keys=True) + "\n")
reg.write_text(json.dumps({
    "schema_version": 2,
    "reserved": [],
    "clients": {
        "aabbccdd0011": {
            "hostname": "dp-os-upgrade",
            "mgmt_status": "enrolled",
            "mgmt_mac_key": "SECRET_MAC_KEY_SHOULD_NOT_LEAK",
            "mgmt_pubkey": "SECRET_PUBKEY_SHOULD_NOT_LEAK",
            "services": {
                "e2e-ssh": {"id": "e2e-ssh", "remote_port": 6002, "enabled": True},
                "grafana": {"id": "grafana", "remote_port": 6003, "enabled": True},
            },
        },
        "eeff99887766": {
            "hostname": "other-client",
            "mgmt_mac_key": "OTHER_SECRET_MAC",
            "services": {
                "ssh": {"id": "ssh", "remote_port": 6004, "enabled": True},
            },
        },
    },
}, indent=2, sort_keys=True) + "\n")
PY
}

cands() {
  frpctl_completion_candidates "$1" | sort
}

has_line() {
  local needle="$1"
  grep -qx -- "$needle"
}

CLIENT="$WORKDIR/client"
SERVER="$WORKDIR/server"
BOTH="$WORKDIR/both"
write_client_tree "$CLIENT"
write_server_tree "$SERVER"
write_client_tree "$BOTH"
write_server_tree "$BOTH"

# --- Single match
export FRP_CTL_TEST_ROOT="$SERVER"
[[ "$(cands sta)" == "status" ]] || fail "sta -> status"
[[ "$(cands doc)" == "doctor" ]] || fail "doc -> doctor"
[[ "$(frpctl_complete_line sta)" == "status " ]] || fail "sta complete line"
[[ "$(cands upd)" == "update" ]] || fail "upd -> update"
[[ "$(cands ver)" == "version" ]] || fail "ver -> version"
[[ "$(cands hel)" == "help" ]] || fail "hel -> help"
[[ "$(cands exi)" == "exit" ]] || fail "exi -> exit"
pass "FRPCTL_TAB_SINGLE_MATCH"

# --- Multiple matches keep input when common prefix equals the typed prefix
re_out="$(cands re)"
echo "$re_out" | has_line release-client || fail "re missing release-client"
echo "$re_out" | has_line release-service || fail "re missing release-service"
echo "$re_out" | has_line revoke || fail "re missing revoke"
echo "$re_out" | has_line revoke-client || fail "re missing revoke-client"
[[ "$(frpctl_complete_line re)" == "re" ]] || fail "re should keep typed prefix"
[[ "$(frpctl_complete_line release)" == "release-" ]] || fail "release common prefix"
cli_out="$(cands cli)"
echo "$cli_out" | has_line client || fail "cli missing client"
echo "$cli_out" | has_line clients || fail "cli missing clients"
echo "$cli_out" | has_line client-info || fail "cli missing client-info"
pass "FRPCTL_TAB_MULTIPLE_MATCHES"

# --- No match leaves the line alone
[[ -z "$(cands xyzzy)" ]] || fail "xyzzy should have no candidates"
[[ "$(frpctl_complete_line xyzzy)" == "xyzzy" ]] || fail "xyzzy line unchanged"
pass "FRPCTL_TAB_NO_MATCH"

# --- Client role commands
export FRP_CTL_TEST_ROOT="$CLIENT"
[[ "$(cands serv)" == "services" ]] || fail "serv -> services"
[[ "$(cands man)" == "manage" ]] || fail "man -> manage"
all_client="$(cands "")"
echo "$all_client" | has_line services || fail "client list services"
echo "$all_client" | has_line manage || fail "client list manage"
echo "$all_client" | has_line status || fail "client list status"
echo "$all_client" | has_line doctor || fail "client list doctor"
if echo "$all_client" | has_line enroll; then fail "client offered enroll"; fi
if echo "$all_client" | has_line clients; then fail "client offered clients"; fi
if echo "$all_client" | has_line revoke; then fail "client offered revoke"; fi
if echo "$(cands cli)" | has_line clients; then fail "client cli offered clients"; fi
pass "FRPCTL_TAB_CLIENT_ROLE_COMMANDS"
pass "FRPCTL_TAB_SERVER_COMMAND_NOT_ON_CLIENT"

# --- Server role commands
export FRP_CTL_TEST_ROOT="$SERVER"
all_server="$(cands "")"
echo "$all_server" | has_line enroll || fail "server list enroll"
echo "$all_server" | has_line doctor || fail "server list doctor"
echo "$all_server" | has_line clients || fail "server list clients"
echo "$all_server" | has_line revoke || fail "server list revoke"
echo "$all_server" | has_line create-client || fail "server list create-client"
if echo "$all_server" | has_line services; then fail "server offered services"; fi
if echo "$all_server" | has_line manage; then fail "server offered manage"; fi
if echo "$(cands serv)" | has_line services; then fail "server serv offered services"; fi
pass "FRPCTL_TAB_SERVER_ROLE_COMMANDS"
pass "FRPCTL_TAB_CLIENT_COMMAND_NOT_ON_SERVER"

# --- Dual-role union
export FRP_CTL_TEST_ROOT="$BOTH"
all_both="$(cands "")"
echo "$all_both" | has_line services || fail "dual missing services"
echo "$all_both" | has_line enroll || fail "dual missing enroll"
echo "$all_both" | has_line clients || fail "dual missing clients"
echo "$all_both" | has_line manage || fail "dual missing manage"
echo "$all_both" | has_line client-status || fail "dual missing client-status"
echo "$all_both" | has_line server-update || fail "dual missing server-update"
echo "$all_both" | has_line doctor || fail "dual missing doctor"
pass "FRPCTL_TAB_DUAL_ROLE_COMMANDS"

# --- doctor flags
export FRP_CTL_TEST_ROOT="$CLIENT"
[[ "$(cands "doctor --j")" == "--json" ]] || fail "doctor --j -> --json"
flags="$(cands "doctor --")"
echo "$flags" | has_line --json || fail "doctor flags missing --json"
echo "$flags" | has_line --verbose || fail "doctor flags missing --verbose"
echo "$flags" | has_line --quiet || fail "doctor flags missing --quiet"
pass "FRPCTL_TAB_DOCTOR_FLAGS"

# --- create-client / enroll flags
export FRP_CTL_TEST_ROOT="$SERVER"
[[ "$(cands "enroll --one")" == "--one-line" ]] || fail "enroll --one -> --one-line"
enroll_flags="$(cands "create-client --")"
echo "$enroll_flags" | has_line --one-line || fail "create-client flags missing --one-line"
echo "$enroll_flags" | has_line --ssh || fail "create-client flags missing --ssh"
echo "$enroll_flags" | has_line --ssh-user || fail "create-client flags missing --ssh-user"
echo "$enroll_flags" | has_line --ssh-port || fail "create-client flags missing --ssh-port"
echo "$enroll_flags" | has_line --ttl || fail "create-client flags missing --ttl"
echo "$enroll_flags" | has_line --note || fail "create-client flags missing --note"
pass "FRPCTL_TAB_CREATE_CLIENT_FLAGS"
export FRP_CTL_TEST_ROOT="$SERVER"
[[ "$(cands "client d")" == "dp-os-upgrade" ]] || fail "client d -> dp-os-upgrade"
[[ "$(frpctl_complete_line "client d")" == "client dp-os-upgrade " ]] || fail "client d complete line"
names="$(cands "client ")"
echo "$names" | has_line dp-os-upgrade || fail "client names missing dp-os-upgrade"
echo "$names" | has_line other-client || fail "client names missing other-client"
[[ "$(cands "revoke d")" == "dp-os-upgrade" ]] || fail "revoke d"
[[ "$(cands "release-client d")" == "dp-os-upgrade" ]] || fail "release-client d"
pass "FRPCTL_TAB_CLIENT_NAME"

[[ "$(cands "release-service dp-os-upgrade e")" == "e2e-ssh" ]] || fail "service e -> e2e-ssh"
[[ "$(frpctl_complete_line "release-service dp-os-upgrade e")" == "release-service dp-os-upgrade e2e-ssh " ]] || fail "service complete line"
svc="$(cands "release-service dp-os-upgrade ")"
echo "$svc" | has_line e2e-ssh || fail "service list e2e-ssh"
echo "$svc" | has_line grafana || fail "service list grafana"
if echo "$svc" | has_line ssh; then fail "other client service leaked"; fi
pass "FRPCTL_TAB_SERVICE_ID"

[[ -z "$(cands "client nosuch")" ]] || fail "unknown client should not complete"
[[ -z "$(cands "release-service nosuch e")" ]] || fail "unknown client service complete"
[[ "$(frpctl_complete_line "client nosuch")" == "client nosuch" ]] || fail "unknown client line"
pass "FRPCTL_TAB_UNKNOWN_CLIENT_SAFE"

# --- Secrets never appear in completion output
secret_out="$(cands "client "; cands "release-service dp-os-upgrade "; cands "")"
if echo "$secret_out" | grep -q 'SECRET_MAC_KEY_SHOULD_NOT_LEAK'; then
  fail "mac key leaked in completion"
fi
if echo "$secret_out" | grep -q 'SECRET_PUBKEY_SHOULD_NOT_LEAK'; then
  fail "pubkey leaked in completion"
fi
if echo "$secret_out" | grep -q 'OTHER_SECRET_MAC'; then
  fail "other mac leaked in completion"
fi
if echo "$secret_out" | grep -qiE 'server_token|BEGIN .*PRIVATE KEY'; then
  fail "secret-like material in completion"
fi
pass "NO_SECRET_COMPLETION"

# --- No arbitrary shell / eval completion
[[ -z "$(cands bash)" ]] || fail "bash must not complete"
[[ -z "$(cands sh)" ]] || fail "sh must not complete"
[[ -z "$(cands exec)" ]] || fail "exec must not complete"
[[ -z "$(cands '!ls')" ]] || fail "!ls must not complete"
[[ -z "$(cands system)" ]] || fail "system must not complete"
[[ "$(cands exi)" == "exit" ]] || fail "exi should still complete exit"
if grep -nE '(^|[[:space:]])eval |bash -c |sh -c |system\(' "$ROOT/tools/frpctl"; then
  fail "frpctl uses unsafe dispatch/completion"
fi
pass "NO_ARBITRARY_SHELL_COMPLETION"
pass "NO_EVAL_COMPLETION"

# --- History still not persisted
grep -q 'unset HISTFILE' "$ROOT/tools/frpctl" || fail "HISTFILE is not unset"
grep -q 'set +o history' "$ROOT/tools/frpctl" || fail "history is not disabled"
if grep -qE 'history -[aw]|HISTFILE=' "$ROOT/tools/frpctl"; then
  fail "frpctl persists history"
fi
if grep -q 'frpctl_history' "$ROOT/tools/frpctl"; then
  fail "frpctl history file referenced"
fi
pass "NO_PERSISTENT_HISTORY"

# --- Help / banner / REPL still work with Tab docs
export HOME="$WORKDIR/home"
mkdir -p "$HOME"
chmod +x "$ROOT/tools/frpctl"
CTL="$ROOT/tools/frpctl"
export FRP_CTL_BIN_DIR="$ROOT/tools"
export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
export FRP_SKIP_SYSTEMD=1
export FRP_CTL_DRY_RUN=1
unset FRP_CTL_SOURCED
FRP_CTL_TEST_INPUT=$'help\nstatus\nexit\n'
export FRP_CTL_TEST_INPUT
"$CTL" >"$WORKDIR/repl.out" 2>"$WORKDIR/repl.err" || fail "repl after completion"
cat "$WORKDIR/repl.err" >>"$WORKDIR/repl.out"
grep -q 'Press Tab to complete commands' "$WORKDIR/repl.out" || fail "banner tab"
grep -q 'Tab                   Complete commands' "$WORKDIR/repl.out" || fail "help tab"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/repl.out" || fail "status after help"
[[ "$(grep -c '^frpctl>' "$WORKDIR/repl.out")" -ge 3 ]] || fail "tab docs stayed in repl"
[[ ! -f "$HOME/.frpctl_history" ]] || fail "history file created"
[[ ! -f "$HOME/.bash_history" ]] || fail "bash history created"
pass "FRPCTL_HELP_MENTIONS_TAB"
pass "FRPCTL_TAB_RETURNS_TO_REPL"

echo "FRPCTL_COMPLETION_TESTS=PASS"
