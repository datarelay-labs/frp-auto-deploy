#!/usr/bin/env python3
"""CONFIG_SETTER_CONTROL_LOCK — frp-set-client-installer-url uses control locks."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
import frp_control_locks as locks  # noqa: E402


def pass_(name):
    print('PASS %s' % name)


def fail(name, detail=''):
    print('FAIL %s %s' % (name, detail), file=sys.stderr)
    raise SystemExit(1)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'etc/frp-auto-deploy').mkdir(parents=True)
        (root / 'var/lib/frp-auto-deploy').mkdir(parents=True)
        cfg = {
            'deployment_mode': 'direct',
            'frp_transport': 'tcp',
            'port_start': 6000,
            'port_end': 6099,
            'frp_control_listen_port': 7000,
            'frp_control_public_port': 7000,
            'allocator_listen_port': 7500,
            'allocator_public_port': 7500,
            'public_host': '203.0.113.10',
            'client_installer_url': 'https://example.test/old.sh',
            'registry_file': str(root / 'var/lib/frp-auto-deploy/registry.json'),
        }
        cfg_path = root / 'etc/frp-auto-deploy/config.json'
        cfg_path.write_text(json.dumps(cfg) + '\n')
        (root / 'var/lib/frp-auto-deploy/registry.json').write_text(
            json.dumps({'schema_version': 2, 'clients': {}, 'reserved': [], 'groups': {}}) + '\n'
        )

        env = os.environ.copy()
        env['FRP_DEPLOY_TEST_ROOT'] = str(root)
        env['FRP_CONTROL_LOCK_TIMEOUT'] = '1'
        tool = str(ROOT / 'tools' / 'frp-set-client-installer-url')
        url = 'https://example.test/new-install-client.sh'

        held = threading.Event()
        release = threading.Event()

        def holder():
            with locks.acquire_control_locks(root, timeout=5):
                held.set()
                release.wait(10)

        t = threading.Thread(target=holder, daemon=True)
        t.start()
        if not held.wait(5):
            fail('CONFIG_SETTER_CONTROL_LOCK', 'holder did not acquire')

        proc = subprocess.run(
            [tool, url],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        release.set()
        t.join(5)
        if proc.returncode == 0:
            fail('CONFIG_SETTER_CONTROL_LOCK', 'setter succeeded while lock held')
        err = (proc.stderr or '') + (proc.stdout or '')
        if 'lock' not in err.lower() and 'timed out' not in err.lower():
            fail('CONFIG_SETTER_CONTROL_LOCK', err)
        # Config must remain unchanged.
        after = json.loads(cfg_path.read_text())
        if after.get('client_installer_url') != cfg['client_installer_url']:
            fail('CONFIG_SETTER_CONTROL_LOCK', 'config mutated under contention')
        pass_('CONFIG_SETTER_CONTROL_LOCK')

        # Uncontended update succeeds.
        proc = subprocess.run(
            [tool, url],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        if proc.returncode != 0:
            fail('CONFIG_SETTER_UNCONTENDED', proc.stderr)
        after = json.loads(cfg_path.read_text())
        if after.get('client_installer_url') != url:
            fail('CONFIG_SETTER_UNCONTENDED', after)
        pass_('CONFIG_SETTER_UNCONTENDED')


if __name__ == '__main__':
    main()
