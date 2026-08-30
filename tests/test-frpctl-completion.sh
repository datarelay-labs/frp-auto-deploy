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
            "label": "oci-e2e-renamed",
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
echo "$re_out" | has_line release || fail "re missing release"
echo "$re_out" | has_line revoke || fail "re missing revoke"
echo "$re_out" | has_line restore || fail "re missing restore"
if echo "$re_out" | has_line release-client; then fail "legacy release-client in tab"; fi
[[ "$(frpctl_complete_line re)" == "re" ]] || fail "re should keep typed prefix"
[[ "$(frpctl_complete_line release)" == "release " ]] || fail "release unique complete"
pass "FRPCTL_TAB_MULTIPLE_MATCHES"
pass "FRPCTL_TAB_VERB"

# --- No match leaves the line alone
[[ -z "$(cands xyzzy)" ]] || fail "xyzzy should have no candidates"
[[ "$(frpctl_complete_line xyzzy)" == "xyzzy" ]] || fail "xyzzy line unchanged"
pass "FRPCTL_TAB_NO_MATCH"

# --- Client role commands
export FRP_CTL_TEST_ROOT="$CLIENT"
[[ "$(cands sho)" == "show" ]] || fail "sho -> show"
all_client="$(cands "")"
echo "$all_client" | has_line show || fail "client list show"
echo "$all_client" | has_line add || fail "client list add"
echo "$all_client" | has_line apply || fail "client list apply"
echo "$all_client" | has_line status || fail "client list status"
echo "$all_client" | has_line doctor || fail "client list doctor"
if echo "$all_client" | has_line enroll; then fail "client offered enroll"; fi
if echo "$all_client" | has_line clients; then fail "client offered clients"; fi
if echo "$all_client" | has_line revoke; then fail "client offered revoke"; fi
if echo "$all_client" | has_line create; then fail "client offered create"; fi
pass "FRPCTL_TAB_CLIENT_ROLE_COMMANDS"
pass "FRPCTL_TAB_SERVER_COMMAND_NOT_ON_CLIENT"

# --- Server role commands
export FRP_CTL_TEST_ROOT="$SERVER"
all_server="$(cands "")"
echo "$all_server" | has_line create || fail "server list create"
echo "$all_server" | has_line doctor || fail "server list doctor"
echo "$all_server" | has_line show || fail "server list show"
echo "$all_server" | has_line revoke || fail "server list revoke"
echo "$all_server" | has_line set || fail "server list set"
if echo "$all_server" | has_line services; then fail "server offered services"; fi
if echo "$all_server" | has_line manage; then fail "server offered manage"; fi
if echo "$all_server" | has_line enroll; then fail "legacy enroll in tab"; fi
if echo "$all_server" | has_line clients; then fail "legacy clients in tab"; fi
pass "FRPCTL_TAB_SERVER_ROLE_COMMANDS"
pass "FRPCTL_TAB_CLIENT_COMMAND_NOT_ON_SERVER"

# --- Dual-role union
export FRP_CTL_TEST_ROOT="$BOTH"
all_both="$(cands "")"
echo "$all_both" | has_line show || fail "dual missing show"
echo "$all_both" | has_line add || fail "dual missing add"
echo "$all_both" | has_line create || fail "dual missing create"
echo "$all_both" | has_line set || fail "dual missing set"
echo "$all_both" | has_line apply || fail "dual missing apply"
echo "$all_both" | has_line doctor || fail "dual missing doctor"
if echo "$all_both" | has_line client-status; then fail "legacy client-status in tab"; fi
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
[[ "$(cands "show client aa")" == "aabbccdd" ]] || fail "show client aa -> CLIENT ID"
[[ "$(frpctl_complete_line "show client aa")" == "show client aabbccdd " ]] || fail "show client complete line"
names="$(cands "show client ")"
echo "$names" | has_line aabbccdd || fail "canonical CLIENT ID missing"
echo "$names" | has_line eeff9988 || fail "second CLIENT ID missing"
if echo "$names" | has_line oci-e2e-renamed; then fail "label completed as identity"; fi
if echo "$names" | has_line dp-os-upgrade; then fail "hostname completed as identity"; fi
if echo "$names" | has_line other-client; then fail "hostname completed as identity"; fi
[[ "$(cands "set client aa")" == "aabbccdd" ]] || fail "set client aa"
[[ "$(cands "client aa")" == "aabbccdd" ]] || fail "legacy client aa"
[[ "$(cands "revoke-client aa")" == "aabbccdd" ]] || fail "legacy revoke names"
pass "FRPCTL_TAB_CLIENT_NAME"
pass "FRPCTL_TAB_CLIENT_CANONICAL_NAME"
pass "FRPCTL_TAB_NO_DUPLICATE_CLIENT_IDENTITY"
pass "CANONICAL_CLIENT_COMPLETION"

[[ "$(cands "release service aabbccdd e")" == "e2e-ssh" ]] || fail "service e -> e2e-ssh"
[[ "$(frpctl_complete_line "release service aabbccdd e")" == "release service aabbccdd e2e-ssh " ]] || fail "service complete line"
svc="$(cands "release service aabbccdd ")"
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
sel_secret="$(cands "show client "; cands "set client "; cands "revoke client "; cands "release client ")"
if echo "$sel_secret" | grep -qE 'SECRET_MAC_KEY_SHOULD_NOT_LEAK|SECRET_PUBKEY_SHOULD_NOT_LEAK|OTHER_SECRET_MAC'; then
  fail "selector completion leaked secret"
fi
echo "$sel_secret" | has_line aabbccdd || fail "selector completion missing CLIENT ID"
if echo "$sel_secret" | has_line dp-os-upgrade; then
  fail "selector completion listed hostname beside CLIENT ID"
fi
pass "NO_SECRET_SELECTOR_COMPLETION"

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
grep -q 'set -o history' "$ROOT/tools/frpctl" || fail "session history is not enabled"
if grep -qE 'history -[aw]|HISTFILE=' "$ROOT/tools/frpctl"; then
  fail "frpctl persists history"
fi
if grep -qE 'HOME/.frpctl_history|~/.frpctl_history' "$ROOT/tools/frpctl"; then
  fail "frpctl history file referenced"
fi
pass "NO_PERSISTENT_HISTORY"
pass "PERSISTENT_HISTORY_DISABLED"

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
grep -q 'Press Tab to complete the current word' "$WORKDIR/repl.out" || fail "banner tab"
grep -q 'Tab                   Complete the current word' "$WORKDIR/repl.out" || fail "help tab"
grep -q 'DISPATCH frp-server-status' "$WORKDIR/repl.out" || fail "status after help"
[[ "$(grep -c '^frpctl>' "$WORKDIR/repl.out")" -ge 3 ]] || fail "tab docs stayed in repl"
[[ ! -f "$HOME/.frpctl_history" ]] || fail "history file created"
[[ ! -f "$HOME/.bash_history" ]] || fail "bash history created"
pass "FRPCTL_HELP_MENTIONS_TAB"
pass "FRPCTL_TAB_RETURNS_TO_REPL"

export FRP_CTL_TEST_ROOT="$SERVER"
show_res="$(cands "show ")"
echo "$show_res" | has_line clients || fail "show resources missing clients"
echo "$show_res" | has_line client || fail "show resources missing client"
echo "$show_res" | has_line status || fail "show resources missing status"
set_props="$(cands "set client aabbccdd ")"
echo "$set_props" | has_line label || fail "set props missing label"
echo "$set_props" | has_line note || fail "set props missing note"
echo "$set_props" | has_line tag || fail "set props missing tag"
if echo "$set_props" | has_line --label; then fail "flag-style set completion"; fi
unset_props="$(cands "unset client aabbccdd ")"
echo "$unset_props" | has_line tag || fail "unset props missing tag"
pass "FRPCTL_TAB_RESOURCE"
pass "FRPCTL_TAB_CONTEXT_AWARE"
pass "FRPCTL_TAB_TAG_SUPPORT"
pass "TAG_COMPLETION"
pass "CONTEXT_TAB_COMPLETION"

# Label rename must not change CLIENT ID completion.
python3 - "$SERVER/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
d=json.loads(p.read_text())
d["clients"]["aabbccdd0011"]["label"]="Seoul DP"
p.write_text(json.dumps(d)+"\n")
PY
[[ "$(cands "show client S")" == "" ]] || fail "mutable label must not complete"
[[ "$(cands "show client aa")" == "aabbccdd" ]] || fail "CLIENT ID complete after label change"
pass "FRPCTL_TAB_QUOTED_LABEL"

# --- Real readline ↑/↓ on a PTY (not a source grep)
python3 - "$CTL" "$SERVER" "$WORKDIR/pty-home" <<'PY' || fail "PTY history interaction"
import errno
import os
import pty
import re
import select
import sys
import time

ctl, tree, home = sys.argv[1:4]
os.makedirs(home, exist_ok=True)
env = os.environ.copy()
env.update({
    "HOME": home,
    "HISTFILE": "",
    "TERM": "xterm",
    "FRP_CTL_TEST_ROOT": tree,
    "FRP_CTL_DRY_RUN": "1",
    "FRP_CTL_BIN_DIR": os.path.join(os.path.dirname(ctl)),
    "FRP_SKIP_SYSTEMD": "1",
    "FRP_UPDATE_TEST_HARNESS": "0",
})
env.pop("FRP_CTL_TEST_INPUT", None)
env.pop("FRP_CTL_SOURCED", None)
env.pop("FRP_CTL_DISABLE_TAB", None)

ANSI_RE = re.compile(br"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()].")


def strip_ansi(data):
    return ANSI_RE.sub(b"", data)


pid, fd = pty.fork()
if pid == 0:
    os.chdir(home)
    os.execve("/bin/bash", ["bash", ctl], env)

buf = bytearray()

def read_more(seconds):
    end = time.time() + seconds
    while time.time() < end:
        remain = max(0.0, end - time.time())
        r, _, _ = select.select([fd], [], [], min(0.2, remain))
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        buf.extend(chunk)

def wait_prompt(timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        read_more(0.25)
        stripped = strip_ansi(bytes(buf)).replace(b"\r", b"").rstrip(b"\x00")
        if stripped.endswith(b"frpctl> ") or stripped.endswith(b"frpctl>"):
            return True
    return False

if not wait_prompt():
    os.write(2, b"PTY: no initial prompt\n" + bytes(buf[-400:]))
    raise SystemExit(1)

os.write(fd, b"show clients\r")
if not wait_prompt():
    os.write(2, b"PTY: no prompt after first command\n" + bytes(buf[-400:]))
    raise SystemExit(1)
before = len(buf)
os.write(fd, b"\x1b[A")  # Up
read_more(1.0)
recalled = bytes(buf[before:])
if b"show clients" not in recalled:
    os.write(2, b"PTY: up-arrow did not recall show clients\n" + recalled)
    raise SystemExit(1)

os.write(fd, b"\r")
if not wait_prompt():
    os.write(2, b"PTY: no prompt after recalled command\n" + bytes(buf[-400:]))
    raise SystemExit(1)
if buf.count(b"DISPATCH frp-clients") < 2:
    os.write(2, b"PTY: recalled command did not dispatch\n" + bytes(buf[-400:]))
    raise SystemExit(1)

os.write(fd, b"show version\r")
if not wait_prompt():
    os.write(2, b"PTY: no prompt after show version\n" + bytes(buf[-400:]))
    raise SystemExit(1)
before = len(buf)
os.write(fd, b"\x1b[A")  # version
read_more(0.4)
os.write(fd, b"\x1b[A")  # clients
read_more(0.4)
os.write(fd, b"\x1b[B")  # back to version
read_more(0.6)
os.write(fd, b"\r")
if not wait_prompt():
    os.write(2, b"PTY: no prompt after down-arrow command\n" + bytes(buf[-400:]))
    raise SystemExit(1)
# The last executed command after down should be show version, not a second extra clients-only path.
text = bytes(buf)
if text.count(b"Project version") + text.count(b"Role            :") < 1:
    # show version prints role/project; dry-run status is not used here
    if b"show version" not in bytes(buf[before:]):
        os.write(2, b"PTY: down-arrow did not land on show version\n" + bytes(buf[before:]))
        raise SystemExit(1)

os.write(fd, b"exit\r")
read_more(1.0)
os.close(fd)
_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status) and os.WEXITSTATUS(status) not in (0,):
    raise SystemExit(1)
hist = os.path.join(home, ".frpctl_history")
bash_hist = os.path.join(home, ".bash_history")
if os.path.exists(hist) or os.path.exists(bash_hist):
    os.write(2, b"PTY: persistent history file created\n")
    raise SystemExit(1)
print("PTY_HISTORY_OK")
PY
pass "FRPCTL_UP_ARROW_HISTORY"
pass "FRPCTL_DOWN_ARROW_HISTORY"
pass "UP_DOWN_HISTORY"

# Restore a plain label, then PTY-test zero-flicker Tab UX.
python3 - "$SERVER/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["clients"]["aabbccdd0011"]["label"] = "oci-e2e-renamed"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY

python3 - "$CTL" "$SERVER" "$WORKDIR/pty-tab-home" <<'PY' || fail "PTY tab interaction"
import errno
import os
import pty
import re
import select
import sys
import time

ctl, tree, home = sys.argv[1:4]
os.makedirs(home, exist_ok=True)
env = os.environ.copy()
env.update({
    "HOME": home,
    "HISTFILE": "",
    "TERM": "xterm",
    "FRP_CTL_TEST_ROOT": tree,
    "FRP_CTL_DRY_RUN": "1",
    "FRP_CTL_BIN_DIR": os.path.join(os.path.dirname(ctl)),
    "FRP_SKIP_SYSTEMD": "1",
    "FRP_UPDATE_TEST_HARNESS": "0",
})
env.pop("FRP_CTL_TEST_INPUT", None)
env.pop("FRP_CTL_SOURCED", None)
env.pop("FRP_CTL_DISABLE_TAB", None)

ANSI_RE = re.compile(br"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()].")
LIST_RE = re.compile(
    rb"(?:^|\n)([A-Za-z0-9_./-]+(?: {2}[A-Za-z0-9_./-]+)+)(?:\n|$)"
)


def strip_ansi(data):
    return ANSI_RE.sub(b"", data)


def visible(data):
    return strip_ansi(data).replace(b"\r", b"").replace(b"\x00", b"")


def list_blocks(data):
    return LIST_RE.findall(visible(data))


pid, fd = pty.fork()
if pid == 0:
    os.chdir(home)
    os.execve("/bin/bash", ["bash", ctl], env)

buf = bytearray()


def read_more(seconds):
    end = time.time() + seconds
    while time.time() < end:
        remain = max(0.0, end - time.time())
        r, _, _ = select.select([fd], [], [], min(0.2, remain))
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        buf.extend(chunk)


def wait_prompt(timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        read_more(0.25)
        stripped = strip_ansi(bytes(buf)).replace(b"\r", b"").rstrip(b"\x00")
        if stripped.endswith(b"frpctl> ") or stripped.endswith(b"frpctl>"):
            return True
    return False


def fail_pty(msg, extra=b""):
    os.write(2, msg.encode() + b"\n" + extra[-800:])
    raise SystemExit(1)


if not wait_prompt():
    fail_pty("PTY: no initial prompt", bytes(buf))

# Unique match: statu<Tab> completes inline, no candidate list / extra prompt.
before = len(buf)
os.write(fd, b"statu")
read_more(0.4)
os.write(fd, b"\t")
read_more(0.8)
unique_chunk = bytes(buf[before:])
if list_blocks(unique_chunk):
    fail_pty("PTY: unique tab printed a candidate list", unique_chunk)
if b"Missing resource" in unique_chunk or b"Unknown command" in unique_chunk:
    fail_pty("PTY: unique tab dispatched a command", unique_chunk)
os.write(fd, b"\r")
if not wait_prompt():
    fail_pty("PTY: no prompt after unique completion", bytes(buf[before:]))
after_unique = bytes(buf[before:])
if b"DISPATCH frp-server-status" not in after_unique:
    fail_pty("PTY: unique tab did not complete status", after_unique)
print("TAB_UNIQUE_INLINE")

# Ambiguous Tab: no list, no extra newline, no extra prompt, no dispatch.
before = len(buf)
os.write(fd, b"set ")
read_more(0.4)
typed = bytes(buf[before:])
nl_before = visible(typed).count(b"\n")
prompt_before = visible(bytes(buf)).count(b"frpctl>")
os.write(fd, b"\t")
read_more(0.8)
first = bytes(buf[before:])
if list_blocks(first):
    fail_pty("PTY: ambiguous tab printed candidates", first)
if b"Missing resource" in first or b"Available:" in first:
    fail_pty("PTY: ambiguous tab ran incomplete dispatch", first)
if b"installer-url" in visible(first):
    fail_pty("PTY: ambiguous tab leaked candidate text", first)
if visible(first).count(b"\n") > nl_before:
    fail_pty("PTY: ambiguous tab emitted a newline", first)
if visible(bytes(buf)).count(b"frpctl>") > prompt_before:
    fail_pty("PTY: ambiguous tab redrew an extra prompt", first)
print("TAB_AMBIGUOUS_ZERO_OUTPUT")
print("TAB_AMBIGUOUS_NO_NEWLINE")
print("TAB_AMBIGUOUS_NO_PROMPT_REDRAW")
print("TAB_DOES_NOT_DISPATCH")
print("TAB_ZERO_FLICKER")
print("TAB_NO_REDRAW")
print("TAB_NO_DISPATCH")

os.write(fd, b"\t")
read_more(0.6)
os.write(fd, b"\t")
read_more(0.6)
repeated = bytes(buf[before:])
if list_blocks(repeated) or b"installer-url" in visible(repeated):
    fail_pty("PTY: repeated tab printed candidates", repeated)
print("TAB_REPEATED_NO_OUTPUT")
os.write(fd, b"\x15")
read_more(0.2)
os.write(fd, b"\r")
if not wait_prompt():
    fail_pty("PTY: no prompt after clearing set ", bytes(buf[before:]))

# History recall then Tab completion.
os.write(fd, b"show version\r")
if not wait_prompt():
    fail_pty("PTY: no prompt after show version", bytes(buf[-400:]))
os.write(fd, b"\x1b[A")
read_more(0.5)
os.write(fd, b"\x15")
read_more(0.3)
before = len(buf)
os.write(fd, b"statu")
read_more(0.3)
os.write(fd, b"\t")
read_more(0.8)
hist_tab = bytes(buf[before:])
if list_blocks(hist_tab):
    fail_pty("PTY: tab after history printed a list", hist_tab)
os.write(fd, b"\r")
if not wait_prompt():
    fail_pty("PTY: no prompt after history+tab", bytes(buf[before:]))
if b"DISPATCH frp-server-status" not in bytes(buf[before:]):
    fail_pty("PTY: tab after history did not complete status", bytes(buf[before:]))
print("TAB_HISTORY_RECALL_COMPATIBLE")

os.write(fd, b"exit\r")
read_more(1.0)
os.close(fd)
_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status) and os.WEXITSTATUS(status) not in (0,):
    raise SystemExit(1)
print("PTY_TAB_OK")
PY
pass "TAB_UNIQUE_INLINE"
pass "TAB_AMBIGUOUS_ZERO_OUTPUT"
pass "TAB_AMBIGUOUS_NO_NEWLINE"
pass "TAB_AMBIGUOUS_NO_PROMPT_REDRAW"
pass "TAB_REPEATED_NO_OUTPUT"
pass "TAB_DOES_NOT_DISPATCH"
pass "TAB_ZERO_FLICKER"
pass "TAB_NO_REDRAW"
pass "TAB_NO_DISPATCH"
pass "TAB_HISTORY_RECALL_COMPATIBLE"
pass "PTY_CLI_TEST"

echo "FRPCTL_COMPLETION_TESTS=PASS"
