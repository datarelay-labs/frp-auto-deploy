#!/usr/bin/env bash
# Safe, non-interactive management-software upgrade for an installed server.

FRP_SERVER_UPGRADE_BACKUP_KEEP="${FRP_SERVER_UPGRADE_BACKUP_KEEP:-5}"

frp_server_upgrade_destinations() {
  # destination:mode:source
  printf '%s\n' \
    "usr/local/lib/frp-auto-deploy/frp-port-allocator.py:0700:server/frp-port-allocator.py" \
    "usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py:0644:lib/frp_mgmt_auth.py" \
    "usr/local/lib/frp-auto-deploy/frp_pki.py:0644:lib/frp_pki.py" \
    "usr/local/lib/frp-auto-deploy/frp_frontend.py:0644:lib/frp_frontend.py" \
    "usr/local/lib/frp-auto-deploy/frp-common.sh:0644:lib/frp-common.sh" \
    "usr/local/lib/frp-auto-deploy/frp-doctor-common.sh:0644:lib/frp-doctor-common.sh" \
    "usr/local/lib/frp-auto-deploy/frp_doctor.py:0644:lib/frp_doctor.py" \
    "usr/local/lib/frp-auto-deploy/frp_install_txn.py:0644:lib/frp_install_txn.py" \
    "usr/local/lib/frp-auto-deploy/frp-server-upgrade.sh:0644:lib/frp-server-upgrade.sh" \
    "usr/local/lib/frp-auto-deploy/frp_client_registry.py:0644:lib/frp_client_registry.py" \
    "usr/local/lib/frp-auto-deploy/release-manifest.json:0644:release-manifest.json" \
    "etc/systemd/system/frps.service:0644:server/frps.service" \
    "etc/systemd/system/frp-port-allocator.service:0644:server/frp-port-allocator.service" \
    "usr/local/sbin/frp-create-client:0755:tools/frp-create-client" \
    "usr/local/sbin/frp-clients:0755:tools/frp-clients" \
    "usr/local/sbin/frp-client-info:0755:tools/frp-client-info" \
    "usr/local/sbin/frp-client-set:0755:tools/frp-client-set" \
    "usr/local/sbin/frp-release-client:0755:tools/frp-release-client" \
    "usr/local/sbin/frp-release-service:0755:tools/frp-release-service" \
    "usr/local/sbin/frp-revoke-client:0755:tools/frp-revoke-client" \
    "usr/local/sbin/frp-set-client-installer-url:0755:tools/frp-set-client-installer-url" \
    "usr/local/sbin/frp-server-status:0755:tools/frp-server-status" \
    "usr/local/sbin/frp-update:0755:tools/frp-update" \
    "usr/local/sbin/frp-project-update:0755:tools/frp-project-update" \
    "usr/local/sbin/frpctl:0755:tools/frpctl"
  if frp_server_upgrade_is_single443; then
    printf '%s\n' "etc/systemd/system/frp-frontend.service:0644:server/frp-frontend.service"
  fi
}

frp_server_upgrade_is_single443() {
  python3 - "$(frp_server_fs /etc/frp-auto-deploy/config.json)" <<'PY'
import json
import sys
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get("deployment_mode", "direct") == "single443" else 1)
PY
}

frp_server_upgrade_tree_digest() {
  python3 - "$@" <<'PY'
import hashlib
import os
import sys
from pathlib import Path

h = hashlib.sha256()
for raw in sorted(sys.argv[1:]):
    path = Path(raw)
    h.update((raw + "\0").encode())
    if path.is_file():
        h.update(b"F")
        h.update(path.read_bytes())
    elif path.is_dir():
        h.update(b"D")
        for child in sorted(p for p in path.rglob("*") if p.is_file()):
            h.update((str(child.relative_to(path)) + "\0").encode())
            h.update(child.read_bytes())
    else:
        h.update(b"M")
print(h.hexdigest())
PY
}

frp_server_upgrade_preserved_digest() {
  frp_server_upgrade_tree_digest \
    "$(frp_server_fs /usr/local/bin/frps)" \
    "$(frp_server_fs /etc/frp/frps.toml)" \
    "$(frp_server_fs /etc/frp/server_token)" \
    "$(frp_server_fs /etc/frp-auto-deploy/config.json)" \
    "$(frp_server_fs /etc/frp-auto-deploy/pki)" \
    "$(frp_server_fs /var/lib/frp-auto-deploy/registry.json)" \
    "$(frp_server_fs /var/lib/frp-auto-deploy/enrollments)" \
    "$(frp_server_fs /var/lib/frp-auto-deploy/bootstrap)" \
    "$(frp_server_fs /var/lib/frp-auto-deploy/nginx-ownership)"
}

frp_server_upgrade_allocator_port() {
  python3 - "$(frp_server_fs /etc/frp-auto-deploy/config.json)" <<'PY'
import json
import sys
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    value = data.get("allocator_listen_port", data.get("listen_port", 6099))
    print(int(value))
except Exception:
    print(6099)
PY
}

frp_server_upgrade_validate_source_metadata() {
  local source="$1"
  python3 - "$source/release-manifest.json" "$source/VERSION" \
    "${FRP_EXPECTED_SOURCE_REF:-}" "${FRP_EXPECTED_RELEASE_CHANNEL:-}" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path, version_path, expected_ref, expected_channel = sys.argv[1:]
try:
    data = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
except Exception:
    sys.stderr.write("ERROR: missing or invalid release-manifest.json\n")
    raise SystemExit(1)
values = {}
try:
    for line in Path(version_path).read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
except OSError:
    sys.stderr.write("ERROR: missing VERSION metadata\n")
    raise SystemExit(1)
project = values.get("PROJECT_VERSION", "")
if not re.fullmatch(r"\d+\.\d+\.\d+", project):
    sys.stderr.write("ERROR: invalid project version metadata\n")
    raise SystemExit(1)
if str(data.get("project_version") or "") != project:
    sys.stderr.write("ERROR: release metadata project version mismatch\n")
    raise SystemExit(1)
if expected_ref and str(data.get("git_ref") or "") != expected_ref:
    sys.stderr.write("ERROR: release metadata source ref mismatch\n")
    raise SystemExit(1)
if expected_channel and str(data.get("channel") or "") != expected_channel:
    sys.stderr.write("ERROR: release metadata channel mismatch\n")
    raise SystemExit(1)
print(project)
PY
}

frp_server_upgrade_stage() {
  local source="$1" staged="$2" rel mode src
  mkdir -p "$staged"
  while IFS=: read -r rel mode src; do
    [[ -f "${source}/${src}" ]] || {
      echo "ERROR: update source is missing ${src}" >&2
      return 1
    }
    mkdir -p "$(dirname "${staged}/${rel}")"
    install -m "$mode" "${source}/${src}" "${staged}/${rel}"
  done < <(frp_server_upgrade_destinations)
}

frp_server_upgrade_validate_staged() {
  local staged="$1" file
  for file in \
    usr/local/lib/frp-auto-deploy/frp-common.sh \
    usr/local/lib/frp-auto-deploy/frp-doctor-common.sh \
    usr/local/lib/frp-auto-deploy/frp-server-upgrade.sh \
    usr/local/sbin/frp-server-status usr/local/sbin/frp-update \
    usr/local/sbin/frp-project-update usr/local/sbin/frpctl; do
    bash -n "${staged}/${file}" || return 1
  done
  python3 -m py_compile \
    "${staged}/usr/local/lib/frp-auto-deploy/frp-port-allocator.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_pki.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_frontend.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_doctor.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_install_txn.py" \
    "${staged}/usr/local/lib/frp-auto-deploy/frp_client_registry.py" \
    "${staged}/usr/local/sbin/frp-create-client" \
    "${staged}/usr/local/sbin/frp-clients" \
    "${staged}/usr/local/sbin/frp-client-info" \
    "${staged}/usr/local/sbin/frp-client-set" \
    "${staged}/usr/local/sbin/frp-release-client" \
    "${staged}/usr/local/sbin/frp-release-service" \
    "${staged}/usr/local/sbin/frp-revoke-client" \
    "${staged}/usr/local/sbin/frp-set-client-installer-url" || return 1
  find "$staged" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  if [[ "${FRP_SERVER_UPGRADE_HOOK_FAIL:-}" == "validate" ]]; then
    echo "ERROR: simulated staged update validation failure" >&2
    return 1
  fi
}

frp_server_upgrade_changed() {
  local staged="$1" rel="$2"
  [[ "$(frp_file_sha256 "${staged}/${rel}")" != \
     "$(frp_file_sha256 "$(frp_server_fs "/${rel}")")" ]]
}

frp_server_upgrade_install_staged() {
  local staged="$1" rel mode src count=0
  while IFS=: read -r rel mode src; do
    frp_atomic_install "${staged}/${rel}" "$(frp_server_fs "/${rel}")" "$mode" || return 1
    count=$((count + 1))
    if [[ "$count" -eq 1 && "${FRP_SERVER_UPGRADE_HOOK_FAIL:-}" == "install" ]]; then
      echo "ERROR: simulated project file install failure" >&2
      return 1
    fi
  done < <(frp_server_upgrade_destinations)
}

frp_server_upgrade_rollback() {
  local snapshot="$1"
  FRP_INSTALL_SNAPSHOT="$snapshot"
  frp_server_rollback_snapshot
  frp_txn_clear
  echo "UPGRADE_ROLLBACK=PASS"
}

frp_server_apply_project_upgrade() {
  local source="$1" check_only="${2:-0}"
  local version_file previous target staged snapshot backups preserved_before
  local restart_frps=0 restart_alloc=0 restart_frontend=0 rel

  [[ -d "$source" ]] || { echo "ERROR: update source directory is required" >&2; return 1; }
  if [[ ${EUID} -ne 0 && -z "${FRP_SERVER_TEST_ROOT:-}" ]]; then
    echo "ERROR: run with sudo" >&2
    return 1
  fi
  [[ -f "$(frp_server_fs /etc/frp-auto-deploy/config.json)" ]] &&
  [[ -s "$(frp_server_fs /etc/frp/server_token)" ]] &&
  [[ -f "$(frp_server_fs /var/lib/frp-auto-deploy/registry.json)" ]] &&
  [[ -f "$(frp_server_fs /etc/frp-auto-deploy/pki/ca.crt)" ]] || {
    echo "ERROR: no complete existing FRP server installation was found" >&2
    return 1
  }

  target="$(frp_server_upgrade_validate_source_metadata "$source")" || return 1
  version_file="$(frp_server_fs /etc/frp-auto-deploy/version)"
  previous="$(frp_read_kv_file "$version_file" PROJECT_VERSION)"
  previous="${previous:-legacy / unknown}"
  echo "Installed project version : ${previous}"
  echo "Target project version    : ${target}"
  echo "FRP binary update         : NO"
  if [[ "$previous" != "legacy / unknown" && "$(frp_version_compare "$previous" "$target")" == "gt" ]]; then
    echo "ERROR: installed project version ${previous} is newer than candidate ${target}" >&2
    frp_emit_failure_class DOWNGRADE_REFUSED
    return 1
  fi

  staged="$(frp_secure_mktemp_dir)"
  trap 'rm -rf "'"$staged"'"' RETURN
  frp_server_upgrade_stage "$source" "$staged" || return 1
  if ! frp_server_upgrade_validate_staged "$staged"; then
    echo "ERROR: staged update failed validation; installed files were not changed." >&2
    echo "UPGRADE_ROLLBACK=PASS"
    return 1
  fi
  if [[ "$check_only" == "1" ]]; then
    [[ "$previous" == "$target" ]] && echo "Update                    : not needed" ||
      echo "Update                    : available"
    echo "State mutation             : NO"
    return 0
  fi

  frp_acquire_server_lock || return 1
  trap 'frp_release_server_lock; rm -rf "'"$staged"'"' RETURN
  preserved_before="$(frp_server_upgrade_preserved_digest)"
  backups="$(frp_server_fs /var/lib/frp-auto-deploy/backups)"
  snapshot="${backups}/project-update-$(date -u +%Y%m%dT%H%M%SZ)"
  FRP_INSTALL_SNAPSHOT="$snapshot"
  frp_server_create_snapshot "$snapshot" || return 1
  frp_prune_backup_dirs "$backups" "$FRP_SERVER_UPGRADE_BACKUP_KEEP"

  frp_server_upgrade_changed "$staged" etc/systemd/system/frps.service && restart_frps=1
  frp_server_upgrade_changed "$staged" etc/systemd/system/frp-port-allocator.service && restart_alloc=1
  frp_server_upgrade_changed "$staged" usr/local/lib/frp-auto-deploy/frp-port-allocator.py && restart_alloc=1
  for rel in frp_mgmt_auth.py frp_pki.py frp_client_registry.py; do
    frp_server_upgrade_changed "$staged" "usr/local/lib/frp-auto-deploy/${rel}" && restart_alloc=1
  done
  if frp_server_upgrade_is_single443; then
    frp_server_upgrade_changed "$staged" etc/systemd/system/frp-frontend.service && restart_frontend=1
  fi

  frp_txn_write project-update commit "$previous" "$target"
  if ! frp_server_upgrade_install_staged "$staged"; then
    frp_server_upgrade_rollback "$snapshot"
    frp_emit_failure_class FILE_COMMIT_FAILED
    return 1
  fi
  if [[ "${FRP_SERVER_UPGRADE_HOOK_FAIL:-}" == "verify" ]]; then
    echo "ERROR: simulated post-install verification failure" >&2
    frp_server_upgrade_rollback "$snapshot"
    frp_emit_failure_class HEALTH_CHECK_FAILED
    return 1
  fi
  if [[ "$(frp_server_upgrade_preserved_digest)" != "$preserved_before" ]]; then
    echo "ERROR: protected server state changed during project update" >&2
    frp_server_upgrade_rollback "$snapshot"
    frp_emit_failure_class STATE_PRESERVATION_FAILED
    return 1
  fi

  if [[ "$restart_frps" == "1" || "$restart_alloc" == "1" || "$restart_frontend" == "1" ]]; then
    if ! frp_server_skip_systemd; then
      frp_server_systemctl daemon-reload || {
        frp_server_upgrade_rollback "$snapshot"; return 1;
      }
    else
      frp_server_record_action "daemon-reload"
    fi
  fi
  if [[ "$restart_frps" == "1" ]]; then
    frp_server_restart_unit frps || { frp_server_upgrade_rollback "$snapshot"; return 1; }
    frp_server_health_frps || { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi
  if [[ "$restart_alloc" == "1" ]]; then
    frp_server_restart_unit frp-port-allocator || { frp_server_upgrade_rollback "$snapshot"; return 1; }
    frp_server_health_allocator "$(frp_server_upgrade_allocator_port)" ||
      { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi
  if [[ "$restart_frontend" == "1" ]]; then
    frp_server_restart_unit frp-frontend || { frp_server_upgrade_rollback "$snapshot"; return 1; }
    frp_server_health_frontend || { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi
  if [[ "$restart_frps" != "1" ]]; then
    frp_server_health_frps || { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi
  if [[ "$restart_alloc" != "1" ]]; then
    frp_server_health_allocator "$(frp_server_upgrade_allocator_port)" ||
      { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi
  if frp_server_upgrade_is_single443 && [[ "$restart_frontend" != "1" ]]; then
    frp_server_health_frontend || { frp_server_upgrade_rollback "$snapshot"; return 1; }
  fi

  if ! PROJECT_VERSION="$target" frp_write_version_file "$version_file" server; then
    frp_server_upgrade_rollback "$snapshot"
    frp_emit_failure_class FILE_COMMIT_FAILED
    return 1
  fi
  frp_txn_clear
  FRP_INSTALL_SNAPSHOT=""
  echo "Server project update completed successfully."
  echo "Project version : ${previous} -> ${target}"
  echo "FRP binary      : unchanged"
  echo "Server state    : preserved"
  echo "Client re-enroll: NOT REQUIRED"
}
