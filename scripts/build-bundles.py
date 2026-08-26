#!/usr/bin/env python3
import base64
from pathlib import Path

root=Path(__file__).resolve().parents[1]
dist=root/'dist'
dist.mkdir(exist_ok=True)

files=[
 'VERSION',
 'install-server.sh',
 'lib/frp-common.sh',
 'server/frp-port-allocator.py',
 'server/migrate_token.py',
 'server/frps.service',
 'server/frp-port-allocator.service',
 'tools/frp-create-client',
 'tools/frp-clients',
 'tools/frp-client-info',
 'tools/frp-release-client',
 'tools/frp-set-client-installer-url',
 'tools/frp-server-status',
 'tools/frp-update',
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

for src,dst in [('install-client.sh','bootstrap-client.sh'),('uninstall-client.sh','uninstall-client.sh'),('uninstall-server.sh','uninstall-server.sh')]:
    (dist/dst).write_bytes((root/src).read_bytes())
    (dist/dst).chmod(0o755)
print('Built dist/bootstrap-server.sh and client bundles')
