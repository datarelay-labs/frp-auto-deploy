#!/usr/bin/env bash
# macOS zero-touch enrollment: one-line command, compact join descriptor, and
# the guided frpctl menus. Portable: runs on Linux by faking uname.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

CREATE="$ROOT/tools/frp-create-client"
CTL="$ROOT/tools/frpctl"

# --- Server tree ------------------------------------------------------------

TREE="$WORKDIR/tree"
mkdir -p "$TREE/etc/frp-auto-deploy/pki" "$TREE/var/lib/frp-auto-deploy/enrollments"
python3 "$ROOT/lib/frp_pki.py" ensure \
  --pki-dir "$TREE/etc/frp-auto-deploy/pki" \
  --public-host 203.0.113.10 >/dev/null
CA_FP="$(python3 "$ROOT/lib/frp_pki.py" fingerprint --cert "$TREE/etc/frp-auto-deploy/pki/ca.crt")"

write_config() {
  python3 - "$TREE/etc/frp-auto-deploy/config.json" \
    "$TREE/var/lib/frp-auto-deploy/enrollments" \
    "$TREE/etc/frp-auto-deploy/pki/ca.crt" \
    "${1:-}" <<'PY'
import json, sys
from pathlib import Path

cfg = {
    "public_host": "203.0.113.10",
    "public_ip": "203.0.113.10",
    "frp_control_public_port": 8443,
    "frp_control_listen_port": 443,
    "allocator_public_url": "https://203.0.113.10:9443/enroll",
    "tls_ca_cert": sys.argv[3],
    "client_installer_url": (
        "https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy"
        "/main/dist/bootstrap-client.sh"
    ),
    "enrollments_dir": sys.argv[2],
}
macos_url = sys.argv[4]
if macos_url:
    cfg["macos_client_installer_url"] = macos_url
Path(sys.argv[1]).write_text(json.dumps(cfg, indent=2) + "\n")
PY
}

write_config ""

create_macos() {
  FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$CREATE" --platform macos "$@"
}

# --- One-line macOS command -------------------------------------------------

OUT="$WORKDIR/macos-ssh.out"
create_macos --one-line --ssh --ssh-user aella --client-name mac-mini >"$OUT"

grep -q 'Zero-touch macOS client command' "$OUT" || fail "macOS heading"
CMD="$(grep -m1 '^curl -fsSL ' "$OUT")" || fail "no one-line curl command"

grep -qF 'FRP_PLATFORM=macos' <<<"$CMD" || fail "FRP_PLATFORM=macos missing"
grep -qF 'FRP_ZERO_TOUCH=1' <<<"$CMD" || fail "FRP_ZERO_TOUCH=1 missing"
grep -qF 'FRP_ALLOCATOR_URL=' <<<"$CMD" || fail "allocator URL missing"
grep -qE "FRP_ALLOCATOR_CA_SHA256='?${CA_FP}'?" <<<"$CMD" || fail "pinned CA fingerprint missing"
grep -qF 'FRP_BOOTSTRAP_TICKET=' <<<"$CMD" || fail "bootstrap ticket missing"
grep -qE "FRP_SSH_USER='?aella'?" <<<"$CMD" || fail "ssh user missing"
grep -qF '| sudo env ' <<<"$CMD" || fail "installer must run through sudo env"
pass "one-line: zero-touch env carries platform, ticket, and pinned CA"

# The macOS command reuses the Darwin-aware Linux bootstrap; a second installer
# artifact would be one more thing to keep in sync and to review.
grep -qF 'dist/bootstrap-client.sh' <<<"$CMD" || fail "macOS must reuse dist/bootstrap-client.sh"
if grep -qE 'bootstrap-client-macos|bootstrap-macos' <<<"$CMD"; then
  fail "macOS one-line must not point at a separate installer artifact"
fi
pass "one-line: reuses the shared Darwin-aware bootstrap"

# Insecure transport must never be reachable from a generated command.
if grep -qE ' -k( |$)|--insecure|http://' "$OUT"; then
  fail "insecure transport in macOS zero-touch output"
fi
pass "one-line: no insecure transport"

grep -q 'Apple Silicon' "$OUT" || fail "Apple Silicon guidance missing"
grep -qi 'Intel Macs are not supported' "$OUT" || fail "Intel refusal not stated"
grep -qi 'does not enable Remote Login' "$OUT" || fail "no-Remote-Login promise missing"
grep -qi 'firewall' "$OUT" || fail "no-firewall promise missing"
if grep -qi 'systemctl\|systemd\|journalctl' "$OUT"; then
  fail "Linux service manager referenced in macOS output"
fi
pass "one-line: states Apple Silicon only and the no-mutation promises"

# --- No RDP preset on macOS -------------------------------------------------

if create_macos --one-line --rdp >"$WORKDIR/rdp.out" 2>"$WORKDIR/rdp.err"; then
  fail "--rdp must be rejected on macOS"
fi
grep -qi 'rdp' "$WORKDIR/rdp.err" || fail "macOS --rdp rejection message"
# The opaque descriptor is base64 of a random ticket, so only the human-readable
# lines are meaningful here.
if grep -v 'frpj1\.' "$OUT" | grep -qi 'rdp'; then
  fail "RDP mentioned in macOS zero-touch output"
fi
pass "presets: RDP refused on macOS"

# --- Installer URL override -------------------------------------------------

write_config "https://mac.example.test/bootstrap-client.sh"
create_macos --one-line --ssh --ssh-user aella >"$WORKDIR/override.out"
grep -q '^curl -fsSL .https://mac.example.test/bootstrap-client.sh' "$WORKDIR/override.out" \
  || fail "macos_client_installer_url not honored"
FRP_DEPLOY_TEST_ROOT="$TREE" python3 "$CREATE" --platform linux --one-line --ssh --ssh-user aella \
  >"$WORKDIR/linux-unchanged.out"
grep -q 'dist/bootstrap-client.sh' "$WORKDIR/linux-unchanged.out" \
  || fail "macos_client_installer_url leaked into the Linux command"
if grep -q 'mac.example.test' "$WORKDIR/linux-unchanged.out"; then
  fail "Linux one-line picked up the macOS installer override"
fi
pass "config: macos_client_installer_url overrides macOS only"

write_config ""

# --- Compact join descriptor ------------------------------------------------

JOIN_LINE="$(grep -m1 'sudo frpctl join ' "$OUT")" || fail "no frpctl join equivalent printed"
DESCRIPTOR="$(sed -E "s/.*sudo frpctl join '?//; s/'?[[:space:]]*$//" <<<"$JOIN_LINE")"
[[ "$DESCRIPTOR" == frpj1.* ]] || fail "join descriptor is not a frpj1 credential (got: $DESCRIPTOR)"
pass "join: one-line output offers the compact Homebrew equivalent"

export FRP_TEST_UNAME_S=Darwin
export FRP_TEST_UNAME_M=arm64
export FRP_CLIENT_TEST_ROOT="$WORKDIR/client-root"
# shellcheck disable=SC1091
. "$ROOT/lib/frp-common.sh"

DECODED="$(frp_macos_decode_join_descriptor "$DESCRIPTOR")" || fail "descriptor did not decode"
grep -qx "FRP_ALLOCATOR_URL=https://203.0.113.10:9443/enroll" <<<"$DECODED" \
  || fail "decoded allocator URL"
grep -qx "FRP_ALLOCATOR_CA_SHA256=${CA_FP}" <<<"$DECODED" || fail "decoded CA fingerprint"
grep -qE '^FRP_BOOTSTRAP_TICKET=.+' <<<"$DECODED" || fail "decoded bootstrap ticket"
TICKET_FROM_CMD="$(sed -E "s/.*FRP_BOOTSTRAP_TICKET='?([^' ]+)'?.*/\1/" <<<"$CMD")"
grep -qx "FRP_BOOTSTRAP_TICKET=${TICKET_FROM_CMD}" <<<"$DECODED" \
  || fail "join descriptor carries a different ticket than the curl command"
pass "join: descriptor round-trips to the same allocator, CA, and ticket"

# The descriptor is a compact credential, not a trusted channel: every field is
# revalidated locally before it can steer an install.
bad_descriptor() {
  python3 - "$1" <<'PY'
import base64, sys
print('frpj1.' + base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip('='))
PY
}

expect_reject() {
  local label="$1" desc="$2"
  if frp_macos_decode_join_descriptor "$desc" >/dev/null 2>"$WORKDIR/reject.err"; then
    fail "descriptor accepted: $label"
  fi
  grep -q 'ERROR' "$WORKDIR/reject.err" || fail "no error message for: $label"
}

expect_reject "http allocator" \
  "$(bad_descriptor "http://203.0.113.10:9443/enroll|${CA_FP}|t.i.k|stable|")"
expect_reject "allocator credentials" \
  "$(bad_descriptor "https://user:pw@203.0.113.10/enroll|${CA_FP}|t.i.k|stable|")"
expect_reject "short CA fingerprint" \
  "$(bad_descriptor "https://203.0.113.10/enroll|abcd|t.i.k|stable|")"
expect_reject "missing ticket" \
  "$(bad_descriptor "https://203.0.113.10/enroll|${CA_FP}||stable|")"
expect_reject "unknown channel" \
  "$(bad_descriptor "https://203.0.113.10/enroll|${CA_FP}|t.i.k|backdoor|")"
expect_reject "wrong field count" \
  "$(bad_descriptor "https://203.0.113.10/enroll|${CA_FP}|t.i.k")"
expect_reject "not base64url" "frpj1.not base64"
expect_reject "wrong prefix" "frpj9.AAAA"
pass "join: malformed and downgraded descriptors are refused"

# --- frpctl join hands the ticket over out of band --------------------------

FAKE="$WORKDIR/fake"
mkdir -p "$FAKE/tools"
cp "$CTL" "$FAKE/tools/frpctl"
ln -s "$ROOT/lib" "$FAKE/lib"
cat >"$FAKE/install-client.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV:%s\n' "$*"
env | grep -E '^FRP_(ALLOCATOR_URL|ALLOCATOR_CA_SHA256|BOOTSTRAP_TICKET|ZERO_TOUCH|PLATFORM)=' | sort
EOF
chmod +x "$FAKE/install-client.sh"

JOIN_OUT="$WORKDIR/join.out"
FRP_CTL_TEST_ROOT="$WORKDIR/client-root" \
  "$FAKE/tools/frpctl" join "$DESCRIPTOR" >"$JOIN_OUT" 2>"$WORKDIR/join.err" \
  || fail "frpctl join failed: $(cat "$WORKDIR/join.err")"

grep -qx 'ARGV:' "$JOIN_OUT" || fail "installer must be invoked with no arguments"
if grep -q "$TICKET_FROM_CMD" <<<"$(grep '^ARGV:' "$JOIN_OUT")"; then
  fail "one-time ticket passed through argv where ps can see it"
fi
grep -qx "FRP_BOOTSTRAP_TICKET=${TICKET_FROM_CMD}" "$JOIN_OUT" || fail "ticket not exported"
grep -qx "FRP_ALLOCATOR_CA_SHA256=${CA_FP}" "$JOIN_OUT" || fail "CA fingerprint not exported"
grep -qx 'FRP_ZERO_TOUCH=1' "$JOIN_OUT" || fail "zero-touch not exported"
grep -qx 'FRP_PLATFORM=macos' "$JOIN_OUT" || fail "platform not exported"
pass "join: ticket reaches the installer through the environment, not argv"

FRP_TEST_UNAME_S=Linux FRP_CTL_TEST_ROOT="$WORKDIR/client-root" \
  "$FAKE/tools/frpctl" join "$DESCRIPTOR" >/dev/null 2>"$WORKDIR/join-linux.err" \
  && fail "frpctl join must refuse to run on Linux"
grep -qi 'macOS only' "$WORKDIR/join-linux.err" || fail "Linux join refusal message"
pass "join: refused on Linux, where the curl one-liner is the supported path"

# --- Guided zero-touch menus ------------------------------------------------

GUIDED="$WORKDIR/guided"
mkdir -p "$GUIDED/etc/frp-auto-deploy" "$GUIDED/var/lib/frp-auto-deploy"
python3 - "$GUIDED/etc/frp-auto-deploy/config.json" "$GUIDED/var/lib/frp-auto-deploy/registry.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "public_ip": "203.0.113.10",
    "control_port": 443,
    "port_start": 6000,
    "port_end": 6098,
    "listen_port": 6099,
    "allocator_public_url": "https://203.0.113.10:6099/enroll",
    "registry_file": "/var/lib/frp-auto-deploy/registry.json",
}, indent=2, sort_keys=True) + "\n")
Path(sys.argv[2]).write_text(json.dumps({
    "schema_version": 2, "reserved": [], "clients": {},
}, indent=2, sort_keys=True) + "\n")
PY
cat >"$GUIDED/etc/frp-auto-deploy/version" <<'EOF'
PROJECT_VERSION=1.4.0
FRP_VERSION=0.70.1
EOF

run_repl() {
  local outfile="$1" rc=0
  shift
  FRP_CTL_TEST_INPUT="$(printf '%s\n' "$@")" \
  FRP_CTL_TEST_ROOT="$GUIDED" \
  FRP_CTL_DRY_RUN=1 \
  FRP_CTL_BIN_DIR="$ROOT/tools" \
  FRP_SKIP_SYSTEMD=1 \
  HOME="$WORKDIR/home" \
  FRP_TEST_UNAME_S=Linux \
    "$CTL" >"$outfile" 2>"${outfile}.err" || rc=$?
  return "$rc"
}
mkdir -p "$WORKDIR/home"

run_repl "$WORKDIR/zt-mac-ssh.out" "create zero-touch" 3 1 mac-ssh "Design Mac" aella 22 exit \
  || fail "guided macOS SSH flow"
grep -q '3) macOS (Apple Silicon)' "$WORKDIR/zt-mac-ssh.out" || fail "macOS platform option"
grep -q 'macOS Zero-touch enrollment' "$WORKDIR/zt-mac-ssh.out" || fail "macOS submenu heading"
grep -q 'Intel Macs are not supported' "$WORKDIR/zt-mac-ssh.out" || fail "guided Intel warning"
grep -qF 'DISPATCH frp-create-client --platform macos --one-line --ssh --ssh-user aella --ssh-port 22 --client-name mac-ssh --note Design Mac' \
  "$WORKDIR/zt-mac-ssh.out" || fail "guided macOS SSH dispatch"
pass "guided: macOS SSH-only enrollment dispatches --platform macos"

run_repl "$WORKDIR/zt-mac-svc.out" "create zero-touch" 3 2 mac-svc "" \
  1 "" "" "" aella \
  2 "" "" "" \
  5 \
  exit || fail "guided macOS services flow"
python3 - "$WORKDIR/zt-mac-svc.out" <<'PY' || fail "guided macOS services content"
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^SERVICES_JSON (.+)$", text, re.M)
if not m:
    raise SystemExit("no SERVICES_JSON")
items = json.loads(m.group(1))
presets = [i.get("preset") for i in items]
if presets != ["ssh", "http"]:
    raise SystemExit("presets=%r" % presets)
if items[0].get("ssh_user") != "aella":
    raise SystemExit("ssh user")
if int(items[1].get("local_port")) != 80:
    raise SystemExit("http port")
PY
grep -qF 'DISPATCH frp-create-client --platform macos --one-line --services-file ' \
  "$WORKDIR/zt-mac-svc.out" || fail "guided macOS services dispatch"
pass "guided: macOS multi-service enrollment builds SSH and HTTP"

# The macOS service menu offers SSH, HTTP, HTTPS, and Custom TCP — and no RDP,
# because this installer never turns on a remote-access service.
menu="$(sed -n '/Configure services/,/Select:/p' "$WORKDIR/zt-mac-svc.out" | head -n 40)"
grep -q '1) Add SSH' <<<"$menu" || fail "macOS menu missing SSH"
grep -q '2) Add HTTP' <<<"$menu" || fail "macOS menu missing HTTP"
grep -q '3) Add HTTPS' <<<"$menu" || fail "macOS menu missing HTTPS"
grep -q '4) Add Custom TCP' <<<"$menu" || fail "macOS menu missing Custom TCP"
if grep -qi 'RDP' <<<"$menu"; then
  fail "RDP offered in the macOS service menu"
fi
pass "guided: macOS presets are SSH, HTTP, HTTPS, Custom TCP only"

# Linux and Windows guided flows keep their existing menus.
run_repl "$WORKDIR/zt-linux.out" "create zero-touch" 1 1 lin-ssh "" aella 22 exit \
  || fail "guided linux flow regressed"
grep -qF 'DISPATCH frp-create-client --platform linux --one-line --ssh --ssh-user aella --ssh-port 22 --client-name lin-ssh' \
  "$WORKDIR/zt-linux.out" || fail "linux dispatch regressed"
run_repl "$WORKDIR/zt-win.out" "create zero-touch" 2 1 win-rdp "" 3389 exit \
  || fail "guided windows flow regressed"
grep -qF 'DISPATCH frp-create-client --platform windows --one-line --rdp --rdp-port 3389 --client-name win-rdp' \
  "$WORKDIR/zt-win.out" || fail "windows dispatch regressed"
pass "guided: Linux and Windows enrollment unchanged"

echo
echo "MACOS_ZERO_TOUCH_COMMAND_TEST=PASS"
