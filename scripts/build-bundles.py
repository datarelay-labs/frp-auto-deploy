#!/usr/bin/env python3
import base64
from pathlib import Path

root=Path(__file__).resolve().parents[1]
dist=root/'dist'
dist.mkdir(exist_ok=True)

files=[
 'VERSION',
 'release-manifest.json',
 'install-server.sh',
 'lib/frp-common.sh',
 'lib/frp_mgmt_auth.py',
 'lib/frp_pki.py',
 'lib/frp_frontend.py',
 'lib/frp_install_txn.py',
 'lib/frp-server-upgrade.sh',
 'lib/frp_client_registry.py',
 'lib/frp_audit.py',
 'lib/frp-doctor-common.sh',
 'lib/frp_doctor.py',
 'server/frp-port-allocator.py',
 'server/migrate_token.py',
 'server/frps.service',
 'server/frp-port-allocator.service',
 'server/frp-frontend.service',
 'tools/frp-create-client',
 'tools/frp-clients',
 'tools/frp-client-info',
 'tools/frp-release-client',
 'tools/frp-release-service',
 'tools/frp-revoke-client',
 'tools/frp-client-set',
 'tools/frp-set-client-installer-url',
 'tools/frp-server-status',
 'tools/frp-project-update',
 'tools/frp-update',
 'tools/frp-upstream',
 'tools/frpctl',
]

lines=['#!/usr/bin/env bash','set -euo pipefail','TMP="$(mktemp -d)"','trap \'rm -rf "$TMP"\' EXIT']
for rel in files:
    data=base64.b64encode((root/rel).read_bytes()).decode()
    parent=str(Path(rel).parent)
    if parent!='.': lines.append(f'mkdir -p "$TMP/{parent}"')
    lines.append(f"base64 -d >\"$TMP/{rel}\" <<'B64'")
    for i in range(0,len(data),76): lines.append(data[i:i+76])
    lines.append('B64')
for rel in files:
    if rel.endswith('.sh') or rel.startswith('tools/') or rel.endswith('.py'):
        lines.append(f'chmod +x "$TMP/{rel}"')
lines.append('exec "$TMP/install-server.sh" "$@"')
(dist/'bootstrap-server.sh').write_text('\n'.join(lines)+'\n')
(dist/'bootstrap-server.sh').chmod(0o755)

client_files=[
 'VERSION',
 'install-client.sh',
 'lib/frp-common.sh',
 'lib/frp-client-common.sh',
 'lib/frp_mgmt_auth.py',
 'lib/frp-doctor-common.sh',
 'lib/frp_doctor.py',
 'tools/frp-client',
 'tools/frpctl',
]
client_lines=['#!/usr/bin/env bash','set -euo pipefail','TMP="$(mktemp -d)"','trap \'rm -rf "$TMP"\' EXIT']
for rel in client_files:
    data=base64.b64encode((root/rel).read_bytes()).decode()
    parent=str(Path(rel).parent)
    if parent!='.': client_lines.append(f'mkdir -p "$TMP/{parent}"')
    client_lines.append(f"base64 -d >\"$TMP/{rel}\" <<'B64'")
    for i in range(0,len(data),76): client_lines.append(data[i:i+76])
    client_lines.append('B64')
for rel in client_files:
    if rel.endswith('.sh') or rel.startswith('tools/'):
        client_lines.append(f'chmod +x "$TMP/{rel}"')
client_lines.append('exec "$TMP/install-client.sh" "$@"')
(dist/'bootstrap-client.sh').write_text('\n'.join(client_lines)+'\n')
(dist/'bootstrap-client.sh').chmod(0o755)

for src,dst in [('uninstall-client.sh','uninstall-client.sh'),('uninstall-server.sh','uninstall-server.sh')]:
    (dist/dst).write_bytes((root/src).read_bytes())
    (dist/dst).chmod(0o755)
print('Built dist/bootstrap-server.sh and client bundles')
