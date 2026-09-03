#!/usr/bin/env bash
# Repeatable Linux Real E2E for frp-e2e-server + frp-e2e-client.
# Lightweight bash/SSH. Does not change firewalls. Does not target dev-dp-mirror.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ALIAS="${FRP_E2E_SERVER_ALIAS:-frp-e2e-server}"
CLIENT_ALIAS="${FRP_E2E_CLIENT_ALIAS:-frp-e2e-client}"
SERVER_IP="${FRP_E2E_SERVER_IP:-221.139.249.112}"
SSH_USER="${FRP_E2E_SSH_USER:-aella}"
SSH_KEY="${FRP_E2E_SSH_KEY:-$HOME/.ssh/frp_e2e_ed25519}"
EXPECTED_SERVER_HOST="${FRP_E2E_SERVER_HOSTNAME:-dp-os-upgrade}"
EXPECTED_CLIENT_HOST="${FRP_E2E_CLIENT_HOSTNAME:-rickmodular}"
FORBIDDEN_HOST="${FRP_E2E_FORBIDDEN_HOSTNAME:-dev-dp-mirror}"
RUN_ID="${FRP_E2E_RUN_ID:-${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}}"
OUT_DIR="${FRP_E2E_OUT_DIR:-${OUT_DIR:-$ROOT/e2e-reports/real-e2e-$RUN_ID}}"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
SCENARIO="${FRP_E2E_SCENARIO:-full}"
STOP_ON_FAIL="${FRP_E2E_STOP_ON_FAIL:-1}"
STEP_TIMEOUT="${FRP_E2E_STEP_TIMEOUT:-240}"
REBOOT_TRIES="${FRP_E2E_REBOOT_TRIES:-36}"
REBOOT_DELAY="${FRP_E2E_REBOOT_DELAY:-5}"
EXT_TRIES="${FRP_E2E_EXT_TRIES:-12}"
EXT_DELAY="${FRP_E2E_EXT_DELAY:-5}"
BACKUP_REPEAT="${FRP_E2E_BACKUP_REPEAT:-1}"
CLIENT_REBOOT_REPEAT="${FRP_E2E_CLIENT_REBOOT_REPEAT:-1}"
SERVER_REBOOT_REPEAT="${FRP_E2E_SERVER_REBOOT_REPEAT:-1}"
OVERALL_TIMEOUT="${FRP_E2E_OVERALL_TIMEOUT:-5400}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
RESULTS="$OUT_DIR/results.tsv"
: >"$SUMMARY"
: >"$RESULTS"

FAILED=0
PASSED=0
SKIPPED=0
ABORTED=0

note() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

redact() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    text = p.read_text(encoding="utf-8", errors="replace")
except Exception:
    raise SystemExit(0)
patterns = [
    (re.compile(r'(Enrollment Code\s*[:=]\s*)\S+', re.I), r'\1[REDACTED]'),
    (re.compile(r'(token(?:_ciphertext)?\s*[:=]\s*)\S+', re.I), r'\1[REDACTED]'),
    (re.compile(r'(mgmt_mac_key\s*[:=]\s*)\S+', re.I), r'\1[REDACTED]'),
    (re.compile(r'(FRP_ENROLLMENT_CODE=)\S+'), r'\1[REDACTED]'),
    (re.compile(r'(curl -fsSL )(\S+)'), r'\1[REDACTED_URL]'),
]
for rx, repl in patterns:
    text = rx.sub(repl, text)
p.write_text(text, encoding="utf-8")
PY
}

record() {
  local name="$1" status="$2" rc="$3" elapsed="$4"
  printf '%s\t%s\t%s\t%ss\n' "$name" "$status" "$rc" "$elapsed" >>"$RESULTS"
  note "STEP $name $status rc=$rc elapsed=${elapsed}s"
  case "$status" in
    PASS) PASSED=$((PASSED + 1)) ;;
    FAIL) FAILED=$((FAILED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    ABORT) ABORTED=$((ABORTED + 1)) ;;
  esac
}

ssh_cmd() {
  local alias="$1"; shift
  ssh "${SSH_OPTS[@]}" "$alias" "$@"
}

run_timed() {
  local name="$1" log="$2"; shift 2
  local start rc=0
  start="$(date +%s)"
  set +e
  timeout "$STEP_TIMEOUT" "$@" >"$log" 2>&1
  rc=$?
  set -uo pipefail
  local elapsed=$(( $(date +%s) - start ))
  redact "$log"
  if [[ "$rc" -eq 0 ]]; then
    record "$name" PASS "$rc" "$elapsed"
    return 0
  fi
  record "$name" FAIL "$rc" "$elapsed"
  note "FAIL_CMD=$name"
  if [[ "$STOP_ON_FAIL" == "1" ]]; then
    return "$rc"
  fi
  return 0
}

run_local() {
  local name="$1"; shift
  run_timed "$name" "$OUT_DIR/${name}.log" "$@"
}

run_server() {
  local name="$1"; shift
  run_timed "$name" "$OUT_DIR/${name}.log" ssh "${SSH_OPTS[@]}" "$SERVER_ALIAS" "$@"
}

run_client() {
  local name="$1"; shift
  run_timed "$name" "$OUT_DIR/${name}.log" ssh "${SSH_OPTS[@]}" "$CLIENT_ALIAS" "$@"
}

wait_host() {
  local alias="$1" name="${2:-wait-$alias}" tries="${3:-$REBOOT_TRIES}" delay="${4:-$REBOOT_DELAY}"
  local i start rc=1
  start="$(date +%s)"
  for i in $(seq 1 "$tries"); do
    if ssh "${SSH_OPTS[@]}" "$alias" 'hostname' >/dev/null 2>&1; then
      rc=0
      break
    fi
    sleep "$delay"
  done
  local elapsed=$(( $(date +%s) - start ))
  if [[ "$rc" -eq 0 ]]; then
    record "$name" PASS 0 "$elapsed"
  else
    record "$name" FAIL 1 "$elapsed"
    note "FAIL reconnect $alias after ${tries}x${delay}s"
  fi
  return "$rc"
}

wait_external_ssh() {
  local name="${1:-wait-external-ssh}" tries="${2:-$EXT_TRIES}" delay="${3:-$EXT_DELAY}"
  local i start rc=1
  start="$(date +%s)"
  for i in $(seq 1 "$tries"); do
    if ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o IdentitiesOnly=yes -i "$SSH_KEY" -p 6000 "$SSH_USER@$SERVER_IP" \
      'hostname && id -un' >"$OUT_DIR/${name}.log" 2>&1; then
      rc=0
      break
    fi
    sleep "$delay"
  done
  redact "$OUT_DIR/${name}.log"
  local elapsed=$(( $(date +%s) - start ))
  if [[ "$rc" -eq 0 ]]; then
    record "$name" PASS 0 "$elapsed"
  else
    record "$name" FAIL 1 "$elapsed"
  fi
  return "$rc"
}

assert_host_identity() {
  local alias="$1" expected="$2" role="$3"
  local got
  got="$(ssh "${SSH_OPTS[@]}" "$alias" 'hostname' 2>/dev/null || echo unreachable)"
  note "$role hostname=$got expected=$expected"
  if [[ "$got" == "$FORBIDDEN_HOST" ]]; then
    note "ABORT: SSH target is forbidden controller host $FORBIDDEN_HOST"
    record "identity-$role" ABORT 2 0
    return 2
  fi
  if [[ "$got" != "$expected" ]]; then
    note "ABORT: unexpected $role identity got=$got expected=$expected"
    record "identity-$role" ABORT 2 0
    return 2
  fi
  record "identity-$role" PASS 0 0
}

python_remote() {
  local alias="$1" name="$2"
  local start rc=0
  start="$(date +%s)"
  set +e
  timeout "$STEP_TIMEOUT" ssh "${SSH_OPTS[@]}" "$alias" 'sudo python3 /dev/stdin' \
    >"$OUT_DIR/${name}.log" 2>&1
  rc=$?
  set -uo pipefail
  local elapsed=$(( $(date +%s) - start ))
  redact "$OUT_DIR/${name}.log"
  if [[ "$rc" -eq 0 ]]; then
    record "$name" PASS "$rc" "$elapsed"
  else
    record "$name" FAIL "$rc" "$elapsed"
  fi
  return "$rc"
}

fail_stop() {
  if [[ "$STOP_ON_FAIL" == "1" ]]; then
    finish 1
  fi
}

finish() {
  local rc="${1:-0}"
  note "PASSED=$PASSED FAILED=$FAILED SKIPPED=$SKIPPED ABORTED=$ABORTED"
  if [[ "$FAILED" -gt 0 || "$ABORTED" -gt 0 ]]; then
    note "FINAL=FAIL"
    rc=1
  else
    note "FINAL=PASS"
  fi
  exit "$rc"
}

scenario_install() {
  run_server 01-server-before "hostname; cat /etc/os-release; uname -a; sudo systemctl --no-pager --full status frps 2>/dev/null || true; sudo /usr/local/sbin/frpctl show status 2>/dev/null || true" || fail_stop
  run_client 02-client-before "hostname; cat /etc/os-release; uname -a; sudo systemctl --no-pager --full status frpc 2>/dev/null || true; sudo /usr/local/bin/frpctl show status 2>/dev/null || true" || fail_stop

  run_local 03-server-purge bash -lc "ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo bash -s -- --purge --yes' < '$ROOT/dist/uninstall-server.sh'" || fail_stop
  run_local 04-client-uninstall bash -lc "ssh ${SSH_OPTS[*]} '$CLIENT_ALIAS' 'sudo bash -s --' < '$ROOT/dist/uninstall-client.sh'" || fail_stop
  run_local 05-server-install bash -lc "ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo env FRP_PUBLIC_IP=$SERVER_IP FRP_INTERNAL_IP=$SERVER_IP FRP_DEPLOYMENT_MODE=direct FRP_CONTROL_PUBLIC_PORT=443 FRP_CONTROL_LISTEN_PORT=443 FRP_ALLOCATOR_PUBLIC_PORT=6099 FRP_ALLOCATOR_LISTEN_PORT=6099 FRP_PORT_START=6000 FRP_PORT_END=6098 FRP_ALLOCATOR_PUBLIC_URL=https://$SERVER_IP:6099/enroll FRP_CLIENT_INSTALLER_URL=https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/$HEAD_SHA/dist/bootstrap-client.sh bash -s --' < '$ROOT/dist/bootstrap-server.sh'" || fail_stop
  run_server 06-server-doctor "sudo /usr/local/sbin/frpctl show status; echo ====; sudo /usr/local/sbin/frpctl doctor" || fail_stop

  local zt_out="$OUT_DIR/07-zero-touch-create.log"
  local start rc=0
  start="$(date +%s)"
  set +e
  ssh "${SSH_OPTS[@]}" "$SERVER_ALIAS" 'sudo /usr/local/sbin/frp-create-client --one-line --ssh --ssh-user aella --client-name real-e2e-client --note automated-real-e2e' >"$zt_out" 2>&1
  rc=$?
  set -uo pipefail
  if [[ "$rc" -eq 0 ]]; then
    python3 - "$zt_out" "$OUT_DIR/07-zero-touch-command.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
cmd = re.search(r"^curl -fsSL .* bash$", text, re.M)
if not cmd:
    raise SystemExit("missing one-line command")
open(sys.argv[2], "w", encoding="utf-8").write(cmd.group(0) + "\n")
PY
    rc=$?
  fi
  redact "$zt_out"
  record 07-zero-touch-create "$([[ $rc -eq 0 ]] && echo PASS || echo FAIL)" "$rc" "$(( $(date +%s) - start ))"
  [[ "$rc" -eq 0 ]] || fail_stop

  run_local 08-zero-touch-run bash -lc "ssh ${SSH_OPTS[*]} '$CLIENT_ALIAS' 'bash -s' < '$OUT_DIR/07-zero-touch-command.sh'" || fail_stop
  redact "$OUT_DIR/08-zero-touch-run.log"
  run_server 09-server-enrollment "sudo /usr/local/sbin/frpctl show clients; echo ====; sudo /usr/local/sbin/frpctl show client 0975f155 || true" || fail_stop
  wait_external_ssh 09b-external-ssh || fail_stop
}

scenario_services() {
  run_client 10-http-fixtures "rm -rf /tmp/frp-e2e-http-a /tmp/frp-e2e-http-b; mkdir -p /tmp/frp-e2e-http-a /tmp/frp-e2e-http-b; printf 'web-a\n' >/tmp/frp-e2e-http-a/index.html; printf 'web-b\n' >/tmp/frp-e2e-http-b/index.html; nohup python3 -m http.server 18080 --bind 127.0.0.1 -d /tmp/frp-e2e-http-a >/tmp/frp-http-a.log 2>&1 </dev/null & nohup python3 -m http.server 18081 --bind 127.0.0.1 -d /tmp/frp-e2e-http-b >/tmp/frp-http-b.log 2>&1 </dev/null & sleep 1; curl -fsS http://127.0.0.1:18080; echo ====; curl -fsS http://127.0.0.1:18081" || fail_stop
  run_client 11-http-add "sudo /usr/local/bin/frp-client add-service --preset http --id web --name Web --target-host 127.0.0.1 --target-port 18080 && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services" || fail_stop
  run_server 12-http-external "curl -fsS 'http://127.0.0.1:6001'" || fail_stop
  run_client 13-http-edit "sudo /usr/local/bin/frp-client set-service web target-port 18081 && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services" || fail_stop
  run_server 14-http-external-edited "curl -fsS 'http://127.0.0.1:6001'" || fail_stop
  run_client 15-http-disable "sudo /usr/local/bin/frp-client disable-service web && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services" || fail_stop
  run_server 16-http-disabled "! curl -fsS --max-time 5 'http://127.0.0.1:6001'" || fail_stop
  run_client 17-http-enable "sudo /usr/local/bin/frp-client enable-service web && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services" || fail_stop
  run_server 18-http-reenabled "curl -fsS 'http://127.0.0.1:6001'" || fail_stop
  run_client 19-http-disable-again "sudo /usr/local/bin/frp-client disable-service web && sudo /usr/local/bin/frp-client apply-pending >/dev/null" || fail_stop
  run_server 20-release "printf 'RELEASE\n' | sudo /usr/local/sbin/frpctl release service 0975f155 web" || fail_stop
  run_server 21-http-released "! curl -fsS --max-time 5 'http://127.0.0.1:6001'" || fail_stop

  python_remote "$SERVER_ALIAS" 22-server-after-release <<'PY' || fail_stop
import json
from pathlib import Path

d = json.loads(Path('/var/lib/frp-auto-deploy/registry.json').read_text(encoding='utf-8'))
prefix = '0975f155'
match = None
for mid, client in (d.get('clients') or {}).items():
    if str(mid).startswith(prefix):
        match = (mid, client)
        break
if not match:
    raise SystemExit('client not found in registry for mid prefix %r' % prefix)
mid, client = match
services = client.get('services') or {}
if 'web' in services:
    raise SystemExit('released service web still present in server registry for %s' % mid)
print('server registry: web removed for %s' % mid)
PY

  run_client 23-client-show-services "sudo /usr/local/bin/frpctl show services" || fail_stop
  python_remote "$CLIENT_ALIAS" 24-client-state-assert <<'PY' || fail_stop
import json
from pathlib import Path

state = json.loads(Path('/etc/frp/client-state.json').read_text(encoding='utf-8'))
services = state.get('services') or {}
if 'web' in services:
    raise SystemExit('released service web still present in client-state.json')
if 'ssh' not in services:
    raise SystemExit('ssh service missing (unexpected)')
print('client state: web removed; ssh present')
PY
  wait_external_ssh 24b-ssh-unaffected || fail_stop
}

scenario_reboots() {
  local i
  for i in $(seq 1 "$CLIENT_REBOOT_REPEAT"); do
    run_local "30-client-reboot-$i" bash -lc "ssh ${SSH_OPTS[*]} '$CLIENT_ALIAS' 'sudo reboot' || true"
    wait_host "$CLIENT_ALIAS" "31-client-reconnect-$i" || fail_stop
    wait_external_ssh "32-client-reboot-ssh-$i" || fail_stop
    run_client "33-client-id-after-reboot-$i" "sudo python3 -c \"import json; d=json.load(open('/etc/frp/client-state.json')); print(d.get('machine_id')); print(list((d.get('services') or {}).keys()))\"" || fail_stop
  done
  for i in $(seq 1 "$SERVER_REBOOT_REPEAT"); do
    run_local "34-server-reboot-$i" bash -lc "ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo reboot' || true"
    wait_host "$SERVER_ALIAS" "35-server-reconnect-$i" || fail_stop
    wait_external_ssh "36-server-reboot-ssh-$i" || fail_stop
    run_server "37-server-registry-after-reboot-$i" "sudo /usr/local/sbin/frpctl show client 0975f155; sudo /usr/local/sbin/frpctl doctor" || fail_stop
  done
}

scenario_backup_repeat() {
  local i
  for i in $(seq 1 "$BACKUP_REPEAT"); do
    run_server "40-backup-$i" "sudo /usr/local/sbin/frpctl create backup /var/lib/frp-auto-deploy/backups/real-e2e-backup-$i.tar.gz" || fail_stop
    run_server "41-mutate-$i" "sudo /usr/local/sbin/frpctl set client 0975f155 label mutated-label-$i && sudo /usr/local/sbin/frpctl set client 0975f155 note 'mutated note $i' && sudo /usr/local/sbin/frpctl set client 0975f155 tag env e2e$i && sudo /usr/local/sbin/frpctl show client 0975f155" || fail_stop
    run_local "42-restore-$i" bash -lc "cat '$ROOT/tools/frp-restore' | ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo tee /tmp/frp-restore >/dev/null && sudo chmod 755 /tmp/frp-restore'; cat '$ROOT/tools/frp-backup' | ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo tee /tmp/frp-backup >/dev/null && sudo chmod 755 /tmp/frp-backup'; ssh ${SSH_OPTS[*]} '$SERVER_ALIAS' 'sudo python3 /tmp/frp-restore /var/lib/frp-auto-deploy/backups/real-e2e-backup-$i.tar.gz'" || fail_stop
    run_server "43-restore-verify-$i" "sudo /usr/local/sbin/frpctl show client 0975f155; echo ====; sudo /usr/local/sbin/frpctl doctor; echo ====; sudo test ! -f /var/lib/frp-auto-deploy/update-pending.json && echo PENDING_MARKER_CLEARED=YES" || fail_stop
    wait_external_ssh "44-restore-ssh-$i" || fail_stop
  done
}

scenario_uninstall_reinstall() {
  run_server 50-pre-uninstall-server "sudo /usr/local/sbin/frpctl show client 0975f155" || fail_stop
  run_client 51-pre-uninstall-client "sudo /usr/local/bin/frpctl show services; sudo /usr/local/bin/frpctl show status" || fail_stop
  run_local 52-client-uninstall bash -lc "ssh ${SSH_OPTS[*]} '$CLIENT_ALIAS' 'sudo bash -s --' < '$ROOT/dist/uninstall-client.sh'" || fail_stop
  run_client 53-post-uninstall-local "echo frpc=\$(systemctl is-active frpc 2>/dev/null || echo inactive); ls /etc/frp 2>/dev/null || echo NO_ETC_FRP; ls /usr/local/bin/frp* 2>/dev/null || echo NO_FRP_BIN; test ! -f /etc/frp/client-state.json && echo CLIENT_STATE_GONE=YES || echo CLIENT_STATE_GONE=NO; ps -eo comm= | grep -E '^(frpc|frp-client)\$' || echo NO_FRP_PROCESS" || fail_stop
  run_server 54-post-uninstall-server "sudo /usr/local/sbin/frpctl show client 0975f155" || fail_stop

  local zt_out="$OUT_DIR/55-zero-touch-create.log"
  local start rc=0
  start="$(date +%s)"
  set +e
  ssh "${SSH_OPTS[@]}" "$SERVER_ALIAS" 'sudo /usr/local/sbin/frp-create-client --one-line --ssh --ssh-user aella --client-name real-e2e-reinstall --note uninstall-reinstall' >"$zt_out" 2>&1
  rc=$?
  set -uo pipefail
  if [[ "$rc" -eq 0 ]]; then
    python3 - "$zt_out" "$OUT_DIR/55-zero-touch-command.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
cmd = re.search(r"^curl -fsSL .* bash$", text, re.M)
if not cmd:
    raise SystemExit("missing one-line command")
open(sys.argv[2], "w", encoding="utf-8").write(cmd.group(0) + "\n")
PY
    rc=$?
  fi
  redact "$zt_out"
  record 55-zero-touch-create "$([[ $rc -eq 0 ]] && echo PASS || echo FAIL)" "$rc" "$(( $(date +%s) - start ))"
  [[ "$rc" -eq 0 ]] || fail_stop

  run_local 56-reinstall bash -lc "ssh ${SSH_OPTS[*]} '$CLIENT_ALIAS' 'bash -s' < '$OUT_DIR/55-zero-touch-command.sh'" || fail_stop
  redact "$OUT_DIR/56-reinstall.log"
  run_client 57-post-reinstall "sudo /usr/local/bin/frpctl show services; sudo /usr/local/bin/frpctl show status" || fail_stop
  run_server 58-post-reinstall-server "sudo /usr/local/sbin/frpctl show clients; sudo /usr/local/sbin/frpctl show client 0975f155" || fail_stop
  wait_external_ssh 59-reinstall-ssh || fail_stop
}

scenario_groups_probe() {
  run_server 60-groups-probe "sudo /usr/local/sbin/frpctl show groups || true"
}

main() {
  note "RUN_ID=$RUN_ID"
  note "CANDIDATE_SHA=$HEAD_SHA"
  note "SCENARIO=$SCENARIO"
  note "STOP_ON_FAIL=$STOP_ON_FAIL"
  note "OVERALL_TIMEOUT=$OVERALL_TIMEOUT"
  note "STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  assert_host_identity "$SERVER_ALIAS" "$EXPECTED_SERVER_HOST" server || finish 2
  assert_host_identity "$CLIENT_ALIAS" "$EXPECTED_CLIENT_HOST" client || finish 2

  case "$SCENARIO" in
    full)
      scenario_install
      scenario_services
      scenario_reboots
      scenario_backup_repeat
      scenario_uninstall_reinstall
      scenario_groups_probe
      ;;
    install) scenario_install ;;
    services) scenario_services ;;
    reboot-repeat)
      CLIENT_REBOOT_REPEAT="${FRP_E2E_CLIENT_REBOOT_REPEAT:-3}"
      SERVER_REBOOT_REPEAT="${FRP_E2E_SERVER_REBOOT_REPEAT:-3}"
      scenario_reboots
      ;;
    backup-repeat)
      BACKUP_REPEAT="${FRP_E2E_BACKUP_REPEAT:-5}"
      scenario_backup_repeat
      ;;
    uninstall) scenario_uninstall_reinstall ;;
    *)
      note "unknown scenario $SCENARIO"
      finish 2
      ;;
  esac

  note "FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finish 0
}

if [[ "${FRP_E2E_INNER:-}" == "1" ]]; then
  main
  exit $?
fi

export FRP_E2E_INNER=1
export FRP_E2E_RUN_ID="$RUN_ID"
export FRP_E2E_OUT_DIR="$OUT_DIR"
export ROOT SERVER_ALIAS CLIENT_ALIAS SERVER_IP SSH_USER SSH_KEY
export EXPECTED_SERVER_HOST EXPECTED_CLIENT_HOST FORBIDDEN_HOST
export RUN_ID OUT_DIR HEAD_SHA SCENARIO STOP_ON_FAIL STEP_TIMEOUT
export REBOOT_TRIES REBOOT_DELAY EXT_TRIES EXT_DELAY
export BACKUP_REPEAT CLIENT_REBOOT_REPEAT SERVER_REBOOT_REPEAT OVERALL_TIMEOUT
exec timeout "$OVERALL_TIMEOUT" bash "$0" "$@"
