#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo 'Run as root' >&2; exit 1; fi
systemctl stop frpc 2>/dev/null || true
systemctl disable frpc 2>/dev/null || true
pkill -x frpc 2>/dev/null || true
rm -f /etc/systemd/system/frpc.service /usr/local/bin/frpc
rm -rf /etc/frp
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
echo 'FRP client removed locally. The central port reservation is intentionally preserved.'
