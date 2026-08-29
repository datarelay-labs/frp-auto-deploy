#!/usr/bin/env bash
# Role-aware frpctl dispatcher and persistent CLI. Uses fixtures; does not
# mutate a live host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

chmod +x "$ROOT/tools/frpctl" "$ROOT/tools/frp-client"

CTL="$ROOT/tools/frpctl"
export FRP_CTL_BIN_DIR="$ROOT/tools"
export FRP_CLIENT_LIB="$ROOT/lib/frp-client-common.sh"
export FRP_SKIP_SYSTEMD=1
export HOME="$WORKDIR/home"
mkdir -p "$HOME"

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
    "frp_server_port": 443,
    "hostname": "ctl-client",
    "machine_id": "00112233445566778899aabbccddeeff",
    "host_id": "ctl-client-00112233",
    "services": {
        "ssh": {
            "id": "ssh", "name": "SSH", "preset": "ssh", "protocol": "tcp",
            "local_ip": "127.0.0.1", "local_port": 22, "remote_port": 6002,
            "enabled": True, "ssh_user": "aella",
        }
    },
}, indent=2, sort_keys=True) + "\n")
PY
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.4.0
FRP_VERSION=0.70.1
EOF
}

write_server_tree() {
  local tree="$1"
  mkdir -p "$tree/etc/frp-auto-deploy" "$tree/var/lib/frp-auto-deploy"
  python3 - "$tree/etc/frp-auto-deploy/config.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "public_ip": "203.0.113.10",
    "control_port": 443,
    "port_start": 6000,
    "port_end": 6098,
    "listen_port": 6099,
    "allocator_public_url": "https://203.0.113.10:6099/enroll",
}, indent=2, sort_keys=True) + "\n")
PY
  cat >"$tree/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.4.0
FRP_VERSION=0.70.1
EOF
}

prompt_count() {
  grep -c '^frpctl>' "$1"
}

run_repl() {
  local tree="$1" outfile="$2" rc
  shift 2
  export FRP_CTL_TEST_ROOT="$tree"
  FRP_CTL_TEST_INPUT="$(printf '%s\n' "$@")"
  export FRP_CTL_TEST_INPUT
  set +e
  "$CTL" >"$outfile" 2>"${outfile}.err"
  rc=$?
  set -e
  cat "${outfile}.err" >>"$outfile"
  return "$rc"
}

CLIENT="$WORKDIR/client"
SERVER="$WORKDIR/server"
BOTH="$WORKDIR/both"
write_client_tree "$CLIENT"
write_server_tree "$SERVER"
write_client_tree "$BOTH"
write_server_tree "$BOTH"

# --- Help / unknown (direct mode)
"$CTL" help >"$WORKDIR/help.out"
grep -q 'only command you need to remember' "$WORKDIR/help.out" || fail "help remember line"
grep -q 'sudo frpctl' "$WORKDIR/help.out" || fail "help sudo frpctl"
grep -q 'frps' "$WORKDIR/help.out" || fail "help mentions frps"
grep -q 'frpc' "$WORKDIR/help.out" || fail "help mentions frpc"
grep -q 'doctor             Run read-only health and consistency checks' "$WORKDIR/help.out" || fail "help doctor"
grep -q 'Persistent interactive CLI' "$WORKDIR/help.out" || fail "help persistent CLI"
"$CTL" --help >"$WORKDIR/help2.out"
grep -q 'Usage: frpctl' "$WORKDIR/help2.out" || fail "--help usage"
if "$CTL" definitely-not-a-command >"$WORKDIR/unknown.out" 2>"$WORKDIR/unknown.err"; then
  fail "unknown command should fail"
fi
grep -q 'unknown command' "$WORKDIR/unknown.err" || fail "unknown error"
grep -q 'Usage: frpctl' "$WORKDIR/unknown.err" || fail "unknown usage"
pass "FRPCTL_HELP"
pass "FRPCTL_UNKNOWN_COMMAND_RECOVERY"

# --- Direct client role
export FRP_CTL_TEST_ROOT="$CLIENT"
export FRP_CLIENT_TEST_ROOT="$CLIENT"
"$CTL" status >"$WORKDIR/client-status.out"
grep -q 'FRP Client' "$WORKDIR/client-status.out" || fail "client status header"
grep -q 'Hostname        : ctl-client' "$WORKDIR/client-status.out" || fail "client status hostname"
pass "FRPCTL_CLIENT_STATUS"

export FRP_CTL_DRY_RUN=1
"$CTL" manage >"$WORKDIR/client-manage.out"
grep -qx 'DISPATCH frp-client' "$WORKDIR/client-manage.out" || fail "manage dispatch"
"$CTL" update >"$WORKDIR/client-update.out"
grep -qx 'DISPATCH frp-client update' "$WORKDIR/client-update.out" || fail "client update dispatch"
"$CTL" info >"$WORKDIR/client-info.out"
grep -qx 'DISPATCH frp-client info' "$WORKDIR/client-info.out" || fail "info dispatch"
"$CTL" services >"$WORKDIR/client-services.out"
grep -qx 'DISPATCH frp-client list' "$WORKDIR/client-services.out" || fail "services dispatch"
unset FRP_CTL_DRY_RUN
pass "FRPCTL_CLIENT_MANAGE_DISPATCH"
pass "FRPCTL_CLIENT_UPDATE_DISPATCH"

if "$CTL" clients >"$WORKDIR/client-clients.out" 2>"$WORKDIR/client-clients.err"; then
  fail "client host should reject server clients command"
fi
grep -q 'installed FRP server' "$WORKDIR/client-clients.err" || fail "client reject server command"

# --- Direct server role
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_TEST_ROOT="$SERVER"
export FRP_CTL_DRY_RUN=1
export FRP_UPDATE_TEST_HARNESS=0
"$CTL" status >"$WORKDIR/server-status.out"
grep -qx 'DISPATCH frp-server-status' "$WORKDIR/server-status.out" || fail "server status dispatch"
"$CTL" clients >"$WORKDIR/server-clients.out"
grep -qx 'DISPATCH frp-clients' "$WORKDIR/server-clients.out" || fail "clients dispatch"
"$CTL" create-client >"$WORKDIR/server-create.out"
grep -qx 'DISPATCH frp-create-client' "$WORKDIR/server-create.out" || fail "create-client dispatch"
"$CTL" enroll >"$WORKDIR/server-enroll.out"
grep -qx 'DISPATCH frp-create-client' "$WORKDIR/server-enroll.out" || fail "enroll dispatch"
"$CTL" enroll --one-line --ssh >"$WORKDIR/server-enroll-ssh.out"
grep -qx 'DISPATCH frp-create-client --one-line --ssh' "$WORKDIR/server-enroll-ssh.out" \
  || fail "enroll --one-line --ssh dispatch"
pass "FRPCTL_ENROLL_ONE_LINE_DISPATCH"
"$CTL" client-info customer-dp >"$WORKDIR/server-info.out"
grep -qx 'DISPATCH frp-client-info customer-dp' "$WORKDIR/server-info.out" || fail "client-info dispatch"
"$CTL" client customer-dp >"$WORKDIR/server-client.out"
grep -qx 'DISPATCH frp-client-info customer-dp' "$WORKDIR/server-client.out" || fail "client alias dispatch"
"$CTL" revoke-client customer-dp >"$WORKDIR/server-revoke.out"
grep -qx 'DISPATCH frp-revoke-client customer-dp' "$WORKDIR/server-revoke.out" || fail "revoke dispatch"
"$CTL" revoke customer-dp >"$WORKDIR/server-revoke2.out"
grep -qx 'DISPATCH frp-revoke-client customer-dp' "$WORKDIR/server-revoke2.out" || fail "revoke alias dispatch"
"$CTL" release-service customer-dp grafana >"$WORKDIR/server-relsvc.out"
grep -qx 'DISPATCH frp-release-service customer-dp grafana' "$WORKDIR/server-relsvc.out" || fail "release-service dispatch"
"$CTL" release-client customer-dp >"$WORKDIR/server-relcli.out"
grep -qx 'DISPATCH frp-release-client customer-dp' "$WORKDIR/server-relcli.out" || fail "release-client dispatch"
"$CTL" update >"$WORKDIR/server-update.out"
grep -qx 'DISPATCH frp-update' "$WORKDIR/server-update.out" || fail "server update dispatch"
unset FRP_CTL_DRY_RUN
pass "FRPCTL_SERVER_STATUS"
pass "FRPCTL_CLIENTS_DISPATCH"
pass "FRPCTL_CREATE_CLIENT_DISPATCH"
pass "FRPCTL_REVOKE_DISPATCH"
pass "FRPCTL_RELEASE_SERVICE_DISPATCH"
pass "FRPCTL_DIRECT_COMMANDS_PRESERVED"

for cmd in frp-client frp-clients frp-client-info frp-create-client \
  frp-release-client frp-release-service frp-revoke-client \
  frp-server-status frp-update frp-set-client-installer-url; do
  [[ -e "$ROOT/tools/$cmd" ]] || fail "missing command $cmd"
done
pass "EXISTING_COMMANDS_PRESERVED"

export FRP_CTL_TEST_ROOT="$BOTH"
export FRP_CTL_DRY_RUN=1
"$CTL" status >"$WORKDIR/both-status.out"
grep -q 'DISPATCH frp-client status' "$WORKDIR/both-status.out" || fail "both status client"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/both-status.out" || fail "both status server"
unset FRP_CTL_DRY_RUN

# --- Guided menu still available via `menu`
export FRP_CLIENT_TEST_ROOT="$CLIENT"
export FRP_CTL_TEST_ROOT="$CLIENT"
export FRP_CTL_TEST_MENU=1
run_repl "$CLIENT" "$WORKDIR/client-menu.out" menu exit || fail "client menu repl"
unset FRP_CTL_TEST_MENU
grep -q 'Role            : Client' "$WORKDIR/client-menu.out" || fail "client role"
grep -q 'Project version : 1.4.0' "$WORKDIR/client-menu.out" || fail "client menu version"
grep -q '1) Manage services' "$WORKDIR/client-menu.out" || fail "client menu manage"
grep -q '4) Update FRP Auto Deploy' "$WORKDIR/client-menu.out" || fail "client menu update"
[[ "$(prompt_count "$WORKDIR/client-menu.out")" -ge 2 ]] || fail "menu returns to prompt"
pass "FRPCTL_CLIENT_DETECTION"
pass "FRPCTL_REPL_MENU_RETURNS_TO_PROMPT"

unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_TEST_ROOT="$SERVER"
export FRP_CTL_TEST_MENU=1
run_repl "$SERVER" "$WORKDIR/server-menu.out" menu exit || fail "server menu repl"
grep -q 'Role            : Server' "$WORKDIR/server-menu.out" || fail "server role"
grep -q '2) List clients' "$WORKDIR/server-menu.out" || fail "server menu clients"
grep -q '5) Revoke management access' "$WORKDIR/server-menu.out" || fail "server menu revoke"
pass "FRPCTL_SERVER_DETECTION"

unset FRP_CTL_TEST_MENU
export FRP_CTL_TEST_ROOT="$BOTH"
export FRP_CTL_TEST_MENU=1
run_repl "$BOTH" "$WORKDIR/both-menu.out" menu exit || fail "both menu repl"
grep -q 'Role            : Client + Server' "$WORKDIR/both-menu.out" || fail "both role"
grep -q '1) Client operations' "$WORKDIR/both-menu.out" || fail "both menu"
unset FRP_CTL_TEST_MENU
pass "FRPCTL_REPL_START_DUAL_ROLE"

# --- Persistent CLI: client
unset FRP_CTL_DRY_RUN
export FRP_CLIENT_TEST_ROOT="$CLIENT"
run_repl "$CLIENT" "$WORKDIR/client-repl.out" status help version exit || fail "client repl"
grep -q 'FRP Auto Deploy CLI' "$WORKDIR/client-repl.out" || fail "client repl banner"
grep -q 'Role            : Client' "$WORKDIR/client-repl.out" || fail "client repl role"
grep -q 'Project version : 1.4.0' "$WORKDIR/client-repl.out" || fail "client repl version"
grep -q 'FRP version     : 0.70.1' "$WORKDIR/client-repl.out" || fail "client repl frp version"
grep -q "Type 'help' or '?' for available commands." "$WORKDIR/client-repl.out" || fail "client repl hint"
[[ "$(prompt_count "$WORKDIR/client-repl.out")" -ge 3 ]] || fail "client repl stays after status/help"
grep -q 'FRP Client' "$WORKDIR/client-repl.out" || fail "client repl status body"
grep -q 'FRP Auto Deploy — Client Commands' "$WORKDIR/client-repl.out" || fail "client repl help"
grep -q 'services' "$WORKDIR/client-repl.out" || fail "client help services"
pass "FRPCTL_REPL_START_CLIENT"
pass "FRPCTL_REPL_HELP"
pass "FRPCTL_REPL_VERSION"
pass "FRPCTL_REPL_STATUS"
pass "FRPCTL_REPL_EXIT"

run_repl "$CLIENT" "$WORKDIR/client-qhelp.out" '?' exit || fail "client ? help"
grep -q 'FRP Auto Deploy — Client Commands' "$WORKDIR/client-qhelp.out" || fail "question mark help"
pass "FRPCTL_REPL_QUESTION_MARK_HELP"

export FRP_CTL_DRY_RUN=1
run_repl "$CLIENT" "$WORKDIR/client-svc.out" services exit || fail "client services"
grep -q 'DISPATCH frp-client list' "$WORKDIR/client-svc.out" || fail "repl services dispatch"
pass "FRPCTL_REPL_CLIENT_SERVICES"
unset FRP_CTL_DRY_RUN

# manage must return to the prompt (no exec)
MOCKBIN="$WORKDIR/mockbin"
mkdir -p "$MOCKBIN"
cat >"$MOCKBIN/frp-client" <<EOF
#!/bin/bash
echo "MOCK-FRP-CLIENT \$*"
echo "frp-client" >> "$WORKDIR/manage.log"
exit 0
EOF
chmod +x "$MOCKBIN/frp-client"
SAVE_BIN="${FRP_CTL_BIN_DIR}"
export FRP_CTL_BIN_DIR="$MOCKBIN"
: >"$WORKDIR/manage.log"
run_repl "$CLIENT" "$WORKDIR/client-manage-repl.out" manage exit || fail "client manage repl"
grep -q 'MOCK-FRP-CLIENT' "$WORKDIR/client-manage-repl.out" || fail "manage invoked frp-client"
[[ "$(prompt_count "$WORKDIR/client-manage-repl.out")" -ge 2 ]] || fail "manage did not return to prompt"
grep -qx 'frp-client' "$WORKDIR/manage.log" || fail "manage mock log"
pass "FRPCTL_REPL_CLIENT_MANAGE_RETURNS_TO_PROMPT"
export FRP_CTL_BIN_DIR="$SAVE_BIN"

# --- Persistent CLI: server
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_DRY_RUN=1
run_repl "$SERVER" "$WORKDIR/server-repl.out" status help version exit || fail "server repl"
grep -q 'FRP Auto Deploy CLI' "$WORKDIR/server-repl.out" || fail "server repl banner"
grep -q 'Role            : Server' "$WORKDIR/server-repl.out" || fail "server repl role"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/server-repl.out" || fail "server repl status"
grep -q 'FRP Auto Deploy — Server Commands' "$WORKDIR/server-repl.out" || fail "server repl help"
grep -q 'enroll' "$WORKDIR/server-repl.out" || fail "server help enroll"
[[ "$(prompt_count "$WORKDIR/server-repl.out")" -ge 3 ]] || fail "server repl persistent"
pass "FRPCTL_REPL_START_SERVER"

run_repl "$SERVER" "$WORKDIR/server-cmds.out" \
  clients \
  "client dp-os-upgrade" \
  enroll \
  "revoke dp-os-upgrade" \
  "release-service dp-os-upgrade e2e-ssh" \
  "release-client dp-os-upgrade" \
  exit || fail "server cmds"
grep -q 'DISPATCH frp-clients' "$WORKDIR/server-cmds.out" || fail "repl clients"
grep -q 'DISPATCH frp-client-info dp-os-upgrade' "$WORKDIR/server-cmds.out" || fail "repl client info"
grep -q 'DISPATCH frp-create-client' "$WORKDIR/server-cmds.out" || fail "repl enroll"
grep -q 'DISPATCH frp-revoke-client dp-os-upgrade' "$WORKDIR/server-cmds.out" || fail "repl revoke"
grep -q 'DISPATCH frp-release-service dp-os-upgrade e2e-ssh' "$WORKDIR/server-cmds.out" || fail "repl release-service"
grep -q 'DISPATCH frp-release-client dp-os-upgrade' "$WORKDIR/server-cmds.out" || fail "repl release-client"
[[ "$(prompt_count "$WORKDIR/server-cmds.out")" -ge 6 ]] || fail "server cmds returned to prompt"
pass "FRPCTL_REPL_SERVER_CLIENTS"
pass "FRPCTL_REPL_SERVER_CLIENT_INFO"
pass "FRPCTL_REPL_SERVER_ENROLL_DISPATCH"

export FRP_CTL_DRY_RUN=1
run_repl "$SERVER" "$WORKDIR/guided-enroll.out" menu 3 1 11 exit || fail "guided enroll zero-touch"
grep -q 'Create enrollment' "$WORKDIR/guided-enroll.out" || fail "guided enroll heading"
grep -q 'Zero-touch SSH' "$WORKDIR/guided-enroll.out" || fail "guided enroll zero-touch option"
grep -q 'Manual Enrollment Code' "$WORKDIR/guided-enroll.out" || fail "guided enroll manual option"
grep -q 'DISPATCH frp-create-client --one-line --ssh' "$WORKDIR/guided-enroll.out" \
  || fail "guided enroll did not dispatch zero-touch"
pass "FRPCTL_GUIDED_ENROLL_ZERO_TOUCH"

run_repl "$SERVER" "$WORKDIR/guided-enroll-manual.out" menu 3 2 11 exit || fail "guided enroll manual"
grep -q 'DISPATCH frp-create-client' "$WORKDIR/guided-enroll-manual.out" \
  || fail "guided enroll manual dispatch"
if grep -q 'DISPATCH frp-create-client --one-line' "$WORKDIR/guided-enroll-manual.out"; then
  fail "manual enroll used zero-touch flags"
fi
pass "FRPCTL_GUIDED_ENROLL_MANUAL"

export FRP_CTL_DRY_RUN=1
run_repl "$SERVER" "$WORKDIR/enroll-oneline.out" "enroll --one-line --ssh" exit \
  || fail "repl enroll --one-line --ssh"
grep -q 'DISPATCH frp-create-client --one-line --ssh' "$WORKDIR/enroll-oneline.out" \
  || fail "enroll --one-line --ssh dispatch"
pass "FRPCTL_ENROLL_ONE_LINE_SSH"
pass "FRPCTL_REPL_SERVER_REVOKE_DISPATCH"
pass "FRPCTL_REPL_SERVER_RELEASE_SERVICE_DISPATCH"
pass "FRPCTL_REPL_SERVER_RELEASE_CLIENT_DISPATCH"
pass "SERVER_COMMANDS_RETURN_TO_REPL"
unset FRP_CTL_DRY_RUN

# --- Invalid command recovery
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_DRY_RUN=1
run_repl "$SERVER" "$WORKDIR/badcmd.out" clints status exit || fail "invalid command recovery"
grep -q 'Unknown command: clints' "$WORKDIR/badcmd.out" || fail "unknown clints"
grep -q 'Did you mean:' "$WORKDIR/badcmd.out" || fail "did you mean header"
grep -q '  clients' "$WORKDIR/badcmd.out" || fail "did you mean clients"
grep -q "Type 'help' for available commands." "$WORKDIR/badcmd.out" || fail "unknown help hint"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/badcmd.out" || fail "status after unknown"
[[ "$(prompt_count "$WORKDIR/badcmd.out")" -ge 3 ]] || fail "unknown stayed in cli"
pass "FRPCTL_REPL_INVALID_COMMAND_RECOVERY"
unset FRP_CTL_DRY_RUN

# --- Invalid argument recovery
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_DRY_RUN=1
run_repl "$SERVER" "$WORKDIR/badargs.out" client "release-service dp-os-upgrade" clients exit || fail "bad args"
grep -q 'ERROR: usage: client <name>' "$WORKDIR/badargs.out" || fail "client usage"
grep -q 'ERROR: usage: release-service <client> <service-id>' "$WORKDIR/badargs.out" || fail "release-service usage"
grep -q 'DISPATCH frp-clients' "$WORKDIR/badargs.out" || fail "clients after bad args"
[[ "$(prompt_count "$WORKDIR/badargs.out")" -ge 4 ]] || fail "bad args stayed in cli"
pass "FRPCTL_REPL_INVALID_ARGUMENT_RECOVERY"
unset FRP_CTL_DRY_RUN

# --- Child failure recovery
FAILBIN="$WORKDIR/failbin"
mkdir -p "$FAILBIN"
cat >"$FAILBIN/frp-client-info" <<'EOF'
#!/bin/bash
echo "ERROR: no such client" >&2
exit 1
EOF
cat >"$FAILBIN/frp-clients" <<'EOF'
#!/bin/bash
echo "HOSTNAME ..."
exit 0
EOF
chmod +x "$FAILBIN/frp-client-info" "$FAILBIN/frp-clients"
export FRP_CTL_BIN_DIR="$FAILBIN"
run_repl "$SERVER" "$WORKDIR/childfail.out" "client nonexistent" clients exit || fail "child fail repl"
grep -q 'ERROR: no such client' "$WORKDIR/childfail.out" || fail "child error shown"
grep -q 'Command failed with exit code 1.' "$WORKDIR/childfail.out" || fail "child fail message"
grep -q 'HOSTNAME ...' "$WORKDIR/childfail.out" || fail "later command after child fail"
[[ "$(prompt_count "$WORKDIR/childfail.out")" -ge 3 ]] || fail "child fail stayed in cli"
pass "FRPCTL_REPL_CHILD_FAILURE_RECOVERY"
export FRP_CTL_BIN_DIR="$SAVE_BIN"

# --- quit / EOF
export FRP_CLIENT_TEST_ROOT="$CLIENT"
run_repl "$CLIENT" "$WORKDIR/quit.out" quit || fail "quit"
grep -q 'FRP Auto Deploy CLI' "$WORKDIR/quit.out" || fail "quit banner"
[[ "$(prompt_count "$WORKDIR/quit.out")" -ge 1 ]] || fail "quit prompt"
pass "FRPCTL_REPL_QUIT"

run_repl "$CLIENT" "$WORKDIR/eof.out" status || fail "eof exit"
grep -q 'FRP Client' "$WORKDIR/eof.out" || fail "eof ran status"
pass "FRPCTL_REPL_EOF_EXIT"

# --- No TTY
unset FRP_CTL_TEST_INPUT
export FRP_CTL_TEST_ROOT="$CLIENT"
export FRP_CLIENT_TEST_ROOT="$CLIENT"
set +e
"$CTL" </dev/null >"$WORKDIR/notty.out" 2>"$WORKDIR/notty.err"
notty_rc=$?
set -e
[[ "$notty_rc" -ne 0 ]] || fail "no-tty interactive should fail"
grep -q 'interactive frpctl requires a TTY' "$WORKDIR/notty.err" || fail "no-tty message"
grep -q 'Use: frpctl <command>' "$WORKDIR/notty.err" || fail "no-tty hint"
pass "FRPCTL_NO_TTY_INTERACTIVE_FAILS_CLEANLY"

"$CTL" status </dev/null >"$WORKDIR/notty-status.out"
grep -q 'FRP Client' "$WORKDIR/notty-status.out" || fail "no-tty direct status"
pass "FRPCTL_NO_TTY_DIRECT_MODE"
pass "FRPCTL_NO_TTY_HANDLING"

# --- No arbitrary shell execution
unset FRP_CLIENT_TEST_ROOT
export FRP_CTL_TEST_ROOT="$SERVER"
CANARY="$WORKDIR/canary.txt"
run_repl "$SERVER" "$WORKDIR/noshell.out" \
  '!ls' \
  shell \
  exec \
  bash \
  "/bin/touch ${CANARY}" \
  exit || fail "noshell repl"
grep -q 'arbitrary shell execution is not allowed' "$WORKDIR/noshell.out" || fail "shell rejected"
grep -q 'Unknown command: /bin/touch' "$WORKDIR/noshell.out" || fail "path command unknown"
[[ ! -f "$CANARY" ]] || fail "canary created"
if grep -nE '(^|[[:space:]])eval |bash -c |sh -c |system\(' "$ROOT/tools/frpctl"; then
  fail "frpctl uses unsafe command dispatch"
fi
pass "NO_ARBITRARY_SHELL_EXECUTION"
pass "NO_EVAL_DISPATCH"

# --- No persistent history
[[ ! -f "$HOME/.frpctl_history" ]] || fail "frpctl history file created"
[[ ! -f "$HOME/.bash_history" ]] || fail "bash history file created"
grep -q 'unset HISTFILE' "$ROOT/tools/frpctl" || fail "HISTFILE is not unset"
if grep -qE 'HISTFILE=' "$ROOT/tools/frpctl"; then
  fail "frpctl assigns HISTFILE"
fi
pass "NO_PERSISTENT_HISTORY"

# Dual-role help
run_repl "$BOTH" "$WORKDIR/both-help.out" help exit || fail "both help"
grep -q 'Client commands' "$WORKDIR/both-help.out" || fail "dual client section"
grep -q 'Server commands' "$WORKDIR/both-help.out" || fail "dual server section"
grep -q 'Common commands' "$WORKDIR/both-help.out" || fail "dual common section"

echo "FRPCTL_TESTS=PASS"
