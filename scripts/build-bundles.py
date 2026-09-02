#!/usr/bin/env python3
import base64
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
dist = root / 'dist'
dist.mkdir(exist_ok=True)

sys.path.insert(0, str(root / 'lib'))
from frp_project_files import server_bootstrap_source_rels  # noqa: E402


# Digests of outer bundles that embed SHA256SUMS. Including them inside the
# embedded copy creates an unsatisfiable hash fixed-point (rebuild never
# matches the committed artifact). Repo-root SHA256SUMS still pins them.
_SHA256SUMS_SELF_EMBED_SKIP = frozenset({
    'dist/bootstrap-server.sh',
})


def bundle_payload(rel):
    data = (root / rel).read_bytes()
    if rel == 'SHA256SUMS':
        lines = []
        for line in data.decode('utf-8').splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1] in _SHA256SUMS_SELF_EMBED_SKIP:
                continue
            lines.append(line)
        return ('\n'.join(lines) + '\n').encode('utf-8')
    if rel != 'release-manifest.json':
        return data
    # Artifact hashes describe the outer bundles. Strip them from the
    # embedded manifest so a bundle never contains a hash of itself.
    import_data = json.loads(data.decode('utf-8'))
    for meta in (import_data.get('artifacts') or {}).values():
        if isinstance(meta, dict):
            meta.pop('sha256', None)
    return (json.dumps(import_data, indent=2, sort_keys=False) + '\n').encode('utf-8')


# Server payload is derived from server-project-files.manifest managed classes
# plus bootstrap-only scaffolding (VERSION / install-server.sh / migrate_token).
files = server_bootstrap_source_rels(source_root=root)
for rel in files:
    if not (root / rel).is_file():
        raise SystemExit('ERROR: server bootstrap source missing: %s' % rel)

lines = ['#!/usr/bin/env bash', 'set -euo pipefail', 'TMP="$(mktemp -d)"', 'trap \'rm -rf "$TMP"\' EXIT']
for rel in files:
    data = base64.b64encode(bundle_payload(rel)).decode()
    parent = str(Path(rel).parent)
    if parent != '.':
        lines.append(f'mkdir -p "$TMP/{parent}"')
    lines.append(f"base64 -d >\"$TMP/{rel}\" <<'B64'")
    for i in range(0, len(data), 76):
        lines.append(data[i:i + 76])
    lines.append('B64')
for rel in files:
    if rel.endswith('.sh') or rel.startswith('tools/') or rel.endswith('.py'):
        lines.append(f'chmod +x "$TMP/{rel}"')
lines.append('exec "$TMP/install-server.sh" "$@"')
(dist / 'bootstrap-server.sh').write_text('\n'.join(lines) + '\n')
(dist / 'bootstrap-server.sh').chmod(0o755)

client_files = [
    'VERSION',
    'release-manifest.json',
    'install-client.sh',
    'lib/frp-common.sh',
    'lib/frp-macos.sh',
    'client/com.datarelay.frp-auto-deploy.frpc.plist',
    'lib/frp-client-common.sh',
    'lib/frp_mgmt_auth.py',
    'lib/frp_data_plane_auth.py',
    'lib/frp_clock_sync.py',
    'lib/frp-doctor-common.sh',
    'lib/frp_doctor.py',
    'lib/frp_ctl_grammar.py',
    'lib/frp_ctl_repl.py',
    'lib/frp_project_files.py',
    'lib/client-project-files.manifest',
    'lib/frp-client-lifecycle.sh',
    'lib/frp_client_lifecycle.py',
    'uninstall-client.sh',
    'tools/frp-client',
    'tools/frpctl',
    'tools/frpcli',
]
# The client bundle also runs on macOS, whose BSD base64 spells decode -D on
# older releases. Pick a working decoder once instead of assuming GNU flags.
client_lines = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'TMP="$(mktemp -d)"',
    'trap \'rm -rf "$TMP"\' EXIT',
    "if printf 'Zg==' | base64 -d >/dev/null 2>&1; then",
    '  _frp_b64d() { base64 -d; }',
    "elif printf 'Zg==' | base64 -D >/dev/null 2>&1; then",
    '  _frp_b64d() { base64 -D; }',
    'else',
    "  _frp_b64d() { python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))'; }",
    'fi',
]
for rel in client_files:
    data = base64.b64encode(bundle_payload(rel)).decode()
    parent = str(Path(rel).parent)
    if parent != '.':
        client_lines.append(f'mkdir -p "$TMP/{parent}"')
    client_lines.append(f"_frp_b64d >\"$TMP/{rel}\" <<'B64'")
    for i in range(0, len(data), 76):
        client_lines.append(data[i:i + 76])
    client_lines.append('B64')
for rel in client_files:
    if rel.endswith('.sh') or rel.startswith('tools/'):
        client_lines.append(f'chmod +x "$TMP/{rel}"')
client_lines.append('exec "$TMP/install-client.sh" "$@"')
(dist / 'bootstrap-client.sh').write_text('\n'.join(client_lines) + '\n')
(dist / 'bootstrap-client.sh').chmod(0o755)

# Windows PowerShell bootstrap: embed windows/ tree, extract, run install-client.ps1.
# Hand-edit of dist/bootstrap-client.ps1 is forbidden; regenerate via this script.
win_files = []
windows_root = root / 'windows'
for path in sorted(windows_root.rglob('*')):
    if not path.is_file():
        continue
    rel = path.relative_to(root).as_posix()
    win_files.append(rel)

ps_lines = [
    '#Requires -Version 5.1',
    '$ErrorActionPreference = \'Stop\'',
    '$ProgressPreference = \'SilentlyContinue\'',
    '$tmp = Join-Path $env:TEMP (\'frp-win-bundle-\' + [guid]::NewGuid().ToString(\'N\'))',
    'New-Item -ItemType Directory -Force -Path $tmp | Out-Null',
    'try {',
]
for rel in win_files:
    data = base64.b64encode((root / rel).read_bytes()).decode('ascii')
    parent = str(Path(rel).parent).replace('\\', '/')
    out_rel = rel.replace('\\', '/')
    ps_lines.append(f'  $dir = Join-Path $tmp \'{parent}\'')
    ps_lines.append('  New-Item -ItemType Directory -Force -Path $dir | Out-Null')
    ps_lines.append(f'  $out = Join-Path $tmp \'{out_rel}\'')
    # chunk base64 for readability
    chunks = [data[i:i + 120] for i in range(0, len(data), 120)]
    ps_lines.append('  $b64 = @\'')
    ps_lines.extend(chunks)
    ps_lines.append('\'@')
    ps_lines.append('  [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(($b64 -replace \'\\s\',\'\')))')

ps_lines.extend([
    '  $installer = Join-Path $tmp \'windows/install-client.ps1\'',
    '  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @args',
    '  exit $LASTEXITCODE',
    '} finally {',
    '  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue',
    '}',
])
(dist / 'bootstrap-client.ps1').write_text('\n'.join(ps_lines) + '\n', encoding='utf-8')

# Compact Windows zero-touch launcher (exact-SHA download target).
win_join_src = root / 'windows' / 'windows-join.ps1'
if not win_join_src.is_file():
    raise SystemExit('ERROR: windows/windows-join.ps1 missing')
(dist / 'windows-join.ps1').write_bytes(win_join_src.read_bytes())

for src, dst in [('uninstall-client.sh', 'uninstall-client.sh'), ('uninstall-server.sh', 'uninstall-server.sh')]:
    (dist / dst).write_bytes((root / src).read_bytes())
    (dist / dst).chmod(0o755)
print('Built dist/bootstrap-server.sh, bootstrap-client.sh, bootstrap-client.ps1, and windows-join.ps1')
