#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true
systemctl stop frp-port-allocator frps 2>/dev/null || true
systemctl disable frp-port-allocator frps 2>/dev/null || true
rm -f /etc/systemd/system/frps.service /etc/systemd/system/frp-port-allocator.service
rm -f /usr/local/bin/frps
rm -f /usr/local/sbin/frp-create-client /usr/local/sbin/frp-clients /usr/local/sbin/frp-client-info \
      /usr/local/sbin/frp-release-client /usr/local/sbin/frp-release-service /usr/local/sbin/frp-revoke-client /usr/local/sbin/frp-set-client-installer-url /usr/local/sbin/frp-server-status \
      /usr/local/sbin/frp-update /usr/local/sbin/frpctl
rm -rf /usr/local/lib/frp-auto-deploy
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
if [[ "$PURGE" == true ]]; then
  rm -rf /etc/frp /etc/frp-auto-deploy /var/lib/frp-auto-deploy
  echo 'FRP server removed and state/secrets purged.'
else
  echo 'FRP server binaries/services removed. Configuration, token, and registry were preserved.'
  echo 'Use --purge only if you intentionally want to delete all reservations and secrets.'
fi
