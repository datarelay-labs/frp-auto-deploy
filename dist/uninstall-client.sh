#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop frpc 2>/dev/null || true
  systemctl disable frpc 2>/dev/null || true
fi
pkill -x frpc 2>/dev/null || true
rm -f /etc/systemd/system/frpc.service /usr/local/bin/frpc /usr/local/bin/frp-client
rm -rf /etc/frp /usr/local/lib/frp-auto-deploy/frp-client-common.sh
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
fi
echo 'FRP client removed locally. The central port reservation is intentionally preserved.'
