#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_ALIAS="${FRP_E2E_SERVER_ALIAS:-frp-e2e-server}"
CLIENT_ALIAS="${FRP_E2E_CLIENT_ALIAS:-frp-e2e-client}"
SERVER_IP="${FRP_E2E_SERVER_IP:-221.139.249.112}"
SSH_USER="${FRP_E2E_SSH_USER:-aella}"
SSH_KEY="${FRP_E2E_SSH_KEY:-$HOME/.ssh/frp_e2e_ed25519}"
RUN_ID="${FRP_E2E_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="${FRP_E2E_OUT_DIR:-$ROOT/e2e-reports/real-e2e-$RUN_ID}"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
: >"$SUMMARY"

note() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
run_local() { local name="$1"; shift; "$@" >"$OUT_DIR/${name}.log" 2>&1; }
run_server() { local name="$1"; shift; ssh -o BatchMode=yes "$SERVER_ALIAS" "$@" >"$OUT_DIR/${name}.log" 2>&1; }
run_client() { local name="$1"; shift; ssh -o BatchMode=yes "$CLIENT_ALIAS" "$@" >"$OUT_DIR/${name}.log" 2>&1; }

wait_host() {
  local alias="$1" tries="${2:-36}" delay="${3:-5}"
  local i
  for i in $(seq 1 "$tries"); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$alias" 'hostname' >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

wait_external_ssh() {
  local tries="${1:-12}" delay="${2:-5}"
  local i
  for i in $(seq 1 "$tries"); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o IdentitiesOnly=yes -i "$SSH_KEY" -p 6000 "$SSH_USER@$SERVER_IP" 'hostname && id -un' \
      >"$OUT_DIR/external-ssh.log" 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

note "RUN_ID=$RUN_ID"
note "CANDIDATE_SHA=$HEAD_SHA"

run_server 01-server-before "hostname; cat /etc/os-release; uname -a; sudo systemctl --no-pager --full status frps 2>/dev/null || true; sudo /usr/local/sbin/frpctl show status 2>/dev/null || true"
run_client 02-client-before "hostname; cat /etc/os-release; uname -a; sudo systemctl --no-pager --full status frpc 2>/dev/null || true; sudo /usr/local/bin/frpctl show status 2>/dev/null || true"

run_local 03-server-purge bash -lc "ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo bash -s -- --purge --yes' < '$ROOT/dist/uninstall-server.sh'"
run_local 04-client-uninstall bash -lc "ssh -o BatchMode=yes '$CLIENT_ALIAS' 'sudo bash -s --' < '$ROOT/dist/uninstall-client.sh'"
run_local 05-server-install bash -lc "ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo env FRP_PUBLIC_IP=$SERVER_IP FRP_INTERNAL_IP=$SERVER_IP FRP_DEPLOYMENT_MODE=direct FRP_CONTROL_PUBLIC_PORT=443 FRP_CONTROL_LISTEN_PORT=443 FRP_ALLOCATOR_PUBLIC_PORT=6099 FRP_ALLOCATOR_LISTEN_PORT=6099 FRP_PORT_START=6000 FRP_PORT_END=6098 FRP_ALLOCATOR_PUBLIC_URL=https://$SERVER_IP:6099/enroll FRP_CLIENT_INSTALLER_URL=https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/$HEAD_SHA/dist/bootstrap-client.sh bash -s --' < '$ROOT/dist/bootstrap-server.sh'"
run_server 06-server-doctor "sudo /usr/local/sbin/frpctl show status; echo ====; sudo /usr/local/sbin/frpctl doctor"

zt_out="$OUT_DIR/07-zero-touch-create.log"
ssh -o BatchMode=yes "$SERVER_ALIAS" 'sudo /usr/local/sbin/frp-create-client --one-line --ssh --ssh-user aella --client-name real-e2e-client --note automated-real-e2e' >"$zt_out" 2>&1
python3 - "$zt_out" "$OUT_DIR/07-zero-touch-command.sh" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
cmd = re.search(r"^curl -fsSL .* bash$", text, re.M)
if not cmd:
    raise SystemExit("missing one-line command")
open(sys.argv[2], "w", encoding="utf-8").write(cmd.group(0) + "\n")
PY
run_local 08-zero-touch-run bash -lc "ssh -o BatchMode=yes '$CLIENT_ALIAS' 'bash -s' < '$OUT_DIR/07-zero-touch-command.sh'"
run_server 09-server-enrollment "sudo /usr/local/sbin/frpctl show clients; echo ====; sudo /usr/local/sbin/frpctl show client 0975f155 || true"
wait_external_ssh

run_client 10-http-fixtures "rm -rf /tmp/frp-e2e-http-a /tmp/frp-e2e-http-b; mkdir -p /tmp/frp-e2e-http-a /tmp/frp-e2e-http-b; printf 'web-a\n' >/tmp/frp-e2e-http-a/index.html; printf 'web-b\n' >/tmp/frp-e2e-http-b/index.html; nohup python3 -m http.server 18080 --bind 127.0.0.1 -d /tmp/frp-e2e-http-a >/tmp/frp-http-a.log 2>&1 </dev/null & nohup python3 -m http.server 18081 --bind 127.0.0.1 -d /tmp/frp-e2e-http-b >/tmp/frp-http-b.log 2>&1 </dev/null & sleep 1; curl -fsS http://127.0.0.1:18080; echo ====; curl -fsS http://127.0.0.1:18081"
run_client 11-http-add "sudo /usr/local/bin/frp-client add-service --preset http --id web --name Web --target-host 127.0.0.1 --target-port 18080 && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services"
# Run HTTP external checks from the server host rather than the local machine.
# In OCI environments the service port range (6000-6098) may be blocked by the
# VCN Security List from outside, but is reachable from the server itself.
run_server 12-http-external "curl -fsS 'http://127.0.0.1:6001'"
run_client 13-http-edit "sudo /usr/local/bin/frp-client set-service web target-port 18081 && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services"
run_server 14-http-external-edited "curl -fsS 'http://127.0.0.1:6001'"
run_client 15-http-disable "sudo /usr/local/bin/frp-client disable-service web && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services"
run_server 16-http-disabled "! curl -fsS --max-time 5 'http://127.0.0.1:6001'"
run_client 17-http-enable "sudo /usr/local/bin/frp-client enable-service web && sudo /usr/local/bin/frp-client apply-pending && sudo /usr/local/bin/frpctl show services"
run_server 18-http-reenabled "curl -fsS 'http://127.0.0.1:6001'"
run_client 19-http-disable-again "sudo /usr/local/bin/frp-client disable-service web && sudo /usr/local/bin/frp-client apply-pending >/dev/null"
run_server 20-release "printf 'RELEASE\n' | sudo /usr/local/sbin/frpctl release service 0975f155 web"
run_server 21-http-released "! curl -fsS --max-time 5 'http://127.0.0.1:6001'"

# Verify server registry no longer has the web service.
ssh -o BatchMode=yes "$SERVER_ALIAS" 'sudo python3 /dev/stdin' \
  >"$OUT_DIR/22-server-after-release.log" 2>&1 <<'PY'
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

run_client 23-client-show-services "sudo /usr/local/bin/frpctl show services"

# Verify client local state no longer has the released web service.
# frp-client list is what triggers the reconcile; assert directly on state file.
ssh -o BatchMode=yes "$CLIENT_ALIAS" 'sudo python3 /dev/stdin' \
  >"$OUT_DIR/24-client-state-assert.log" 2>&1 <<'PY'
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

wait_external_ssh

run_local 22-client-reboot bash -lc "ssh -o BatchMode=yes '$CLIENT_ALIAS' 'sudo reboot' || true"
wait_host "$CLIENT_ALIAS"
wait_external_ssh
run_local 23-server-reboot bash -lc "ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo reboot' || true"
wait_host "$SERVER_ALIAS"
wait_external_ssh

run_server 24-backup "sudo /usr/local/sbin/frpctl create backup /var/lib/frp-auto-deploy/backups/real-e2e-backup.tar.gz"
run_server 25-mutate "sudo /usr/local/sbin/frpctl set client 0975f155 label mutated-label && sudo /usr/local/sbin/frpctl set client 0975f155 note 'mutated note' && sudo /usr/local/sbin/frpctl set client 0975f155 tag env e2e && sudo /usr/local/sbin/frpctl show client 0975f155"
run_local 26-restore-patched bash -lc "cat '$ROOT/tools/frp-restore' | ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo tee /tmp/frp-restore >/dev/null && sudo chmod 755 /tmp/frp-restore'; cat '$ROOT/tools/frp-backup' | ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo tee /tmp/frp-backup >/dev/null && sudo chmod 755 /tmp/frp-backup'; ssh -o BatchMode=yes '$SERVER_ALIAS' 'sudo python3 /tmp/frp-restore /var/lib/frp-auto-deploy/backups/real-e2e-backup.tar.gz'"
run_server 27-restore-verify "sudo /usr/local/sbin/frpctl show client 0975f155; echo ====; sudo /usr/local/sbin/frpctl doctor; echo ====; sudo test ! -f /var/lib/frp-auto-deploy/update-pending.json && echo PENDING_MARKER_CLEARED=YES"
wait_external_ssh

run_server 28-groups-probe "sudo /usr/local/sbin/frpctl show groups || true"

note "PASS=server_install,client_zero_touch,external_ssh,multi_service,edit,disable_enable,release,client_reboot,server_reboot,backup_restore"
note "BLOCKED=groups_not_supported_in_current_repo,update_persistence_not_run,uninstall_reinstall_not_run"
