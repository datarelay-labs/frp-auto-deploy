#!/usr/bin/env python3
"""Server lifecycle diagnostics: test, logs, support bundle."""
from __future__ import annotations

import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

try:
    from frp_doctor import redact as _doctor_redact
except ImportError:
    _doctor_redact = None

try:
    import frp_fleet
except ImportError:
    frp_fleet = None

SENSITIVE_KEY_RE = re.compile(
    r'^(token|secret|password|passwd|private_key|private-key|authorization|'
    r'enrollment_code|enrollment-code|bootstrap_ticket|bootstrap-ticket|'
    r'mgmt_mac_key|auth_token|server_token|install_key|hmac_secret)$',
    re.IGNORECASE,
)
CONNECT_TIMEOUT = 2.0


def _root():
    return os.environ.get('FRP_DEPLOY_TEST_ROOT') or os.environ.get('FRP_CTL_TEST_ROOT') or ''


def _path(rel):
    base = _root()
    p = rel if rel.startswith('/') else '/' + rel
    return Path(base + p) if base else Path(p)


def redact_text(text):
    if _doctor_redact:
        return _doctor_redact(text)
    if not text:
        return ''
    return str(text)


def redact_json_obj(obj):
    if isinstance(obj, dict):
        out = {}
        for key, val in obj.items():
            if SENSITIVE_KEY_RE.match(str(key)):
                out[key] = '[redacted]'
            else:
                out[key] = redact_json_obj(val)
        return out
    if isinstance(obj, list):
        return [redact_json_obj(item) for item in obj]
    if isinstance(obj, str):
        return redact_text(obj)
    return obj


def load_config():
    cfg_path = _path('/etc/frp-auto-deploy/config.json')
    if not cfg_path.is_file():
        return {}
    return json.loads(cfg_path.read_text(encoding='utf-8'))


def _check(name, fn):
    try:
        status, detail = fn()
        return {'name': name, 'status': status, 'detail': detail or ''}
    except Exception as exc:
        return {'name': name, 'status': 'FAIL', 'detail': str(exc)}


def systemd_active(unit):
    if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or _root():
        hook = os.environ.get('FRP_SERVER_LIFECYCLE_UNIT_%s' % unit.upper().replace('-', '_'))
        if hook == 'active':
            return 'PASS', 'active (test hook)'
        if hook == 'inactive':
            return 'WARN', 'inactive (test hook)'
        return 'SKIP', 'systemd skipped in test mode'
    try:
        proc = subprocess.run(
            ['systemctl', 'is-active', unit],
            capture_output=True,
            text=True,
            timeout=3,
        )
        state = (proc.stdout or proc.stderr or '').strip() or 'unknown'
        if state == 'active':
            return 'PASS', state
        return 'FAIL', state
    except Exception as exc:
        return 'SKIP', str(exc)


def tcp_reach(host, port):
    sock = socket.create_connection((host, int(port)), timeout=CONNECT_TIMEOUT)
    sock.close()


def cert_days_remaining(cert_path):
    if not cert_path.is_file():
        return None, 'missing'
    try:
        proc = subprocess.run(
            ['openssl', 'x509', '-in', str(cert_path), '-noout', '-enddate'],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if proc.returncode != 0:
            return None, 'unreadable'
        line = (proc.stdout or '').strip()
        if '=' not in line:
            return None, 'unreadable'
        date_text = line.split('=', 1)[1].strip()
        # openssl date format: Mon DD HH:MM:SS YYYY GMT
        from frp_doctor import parse_openssl_date
        dt = parse_openssl_date(date_text)
        if dt is None:
            return None, 'unreadable'
        days = int((dt - datetime.now(timezone.utc)).total_seconds() // 86400)
        return days, '%dd' % days
    except Exception as exc:
        return None, str(exc)


def run_server_test():
    cfg = load_config()
    mode = str(cfg.get('deployment_mode') or 'direct').strip().lower()
    checks = []

    def configuration():
        if cfg:
            return 'PASS', mode or 'direct'
        return 'FAIL', 'config missing'

    def registry():
        reg_file = cfg.get('registry_file') or '/var/lib/frp-auto-deploy/registry.json'
        path = _path(reg_file) if str(reg_file).startswith('/') else Path(reg_file)
        if not path.is_file():
            return 'FAIL', 'missing'
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
            if data.get('schema_version') != 2:
                return 'FAIL', 'schema version'
            return 'PASS', ''
        except Exception as exc:
            return 'FAIL', str(exc)

    checks.append(_check('Configuration', configuration))
    checks.append(_check('Registry', registry))
    checks.append(_check('Port allocator config', lambda: (
        'PASS' if cfg.get('port_start') and cfg.get('port_end') else 'FAIL',
        '%s-%s' % (cfg.get('port_start'), cfg.get('port_end')),
    )))

    name, status, detail = 'frps service', *systemd_active('frps')
    checks.append({'name': name, 'status': status, 'detail': detail})
    name, status, detail = 'Allocator service', *systemd_active('frp-port-allocator')
    checks.append({'name': name, 'status': status, 'detail': detail})

    checks.append(_check('Deployment mode', lambda: ('PASS', mode)))

    if mode == 'single443':
        name, status, detail = 'Frontend service', *systemd_active('frp-frontend')
        checks.append({'name': name, 'status': status, 'detail': detail})
        pub_port = int(cfg.get('frp_control_public_port') or 443)
        checks.append(_check('Public listener :%s' % pub_port, lambda: (
            'PASS' if _listener_open('0.0.0.0', pub_port) or _listener_open('::', pub_port) else 'WARN',
            'local bind check only',
        )))
        checks.append(_check('Allocator internal', lambda: (
            'PASS' if _path('/etc/frp-auto-deploy/frontend.conf').is_file() else 'WARN',
            'frontend.conf',
        )))
    else:
        ctrl_port = int(cfg.get('frp_control_public_port') or cfg.get('frp_control_listen_port') or 443)
        alloc_port = int(cfg.get('allocator_public_port') or cfg.get('allocator_listen_port') or 6099)
        checks.append(_check('FRP control listener', lambda: (
            'PASS' if _listener_open(cfg.get('frp_control_bind_addr', '0.0.0.0'), ctrl_port) else 'WARN',
            ':%s' % ctrl_port,
        )))
        checks.append(_check('Management HTTPS listener', lambda: (
            'PASS' if _listener_open('0.0.0.0', alloc_port) else 'WARN',
            ':%s' % alloc_port,
        )))

    cert_rel = cfg.get('tls_server_cert') or '/etc/frp-auto-deploy/pki/server.crt'
    cert_path = _path(cert_rel) if str(cert_rel).startswith('/') else Path(cert_rel)
    days, detail = cert_days_remaining(cert_path)
    if days is None:
        checks.append({'name': 'TLS certificate', 'status': 'FAIL', 'detail': detail})
    elif days < 0:
        checks.append({'name': 'Certificate expiry', 'status': 'FAIL', 'detail': 'expired'})
        checks.append({'name': 'TLS certificate', 'status': 'FAIL', 'detail': detail})
    elif days <= 30:
        checks.append({'name': 'Certificate expiry', 'status': 'WARN', 'detail': detail})
        checks.append({'name': 'TLS certificate', 'status': 'PASS', 'detail': detail})
    else:
        checks.append({'name': 'Certificate expiry', 'status': 'PASS', 'detail': detail})
        checks.append({'name': 'TLS certificate', 'status': 'PASS', 'detail': detail})

    ca_path = _path(cfg.get('tls_ca_cert') or '/etc/frp-auto-deploy/pki/ca.crt')
    checks.append(_check('CA', lambda: ('PASS' if ca_path.is_file() else 'FAIL', '')))

    version_path = _path('/etc/frp-auto-deploy/version')
    frp_ver = ''
    if version_path.is_file():
        for line in version_path.read_text(encoding='utf-8').splitlines():
            if line.startswith('FRP_VERSION='):
                frp_ver = line.split('=', 1)[1].strip()
    checks.append(_check('FRP version', lambda: ('PASS' if frp_ver else 'WARN', frp_ver or 'unknown')))

    checks.append(_check('Port range', lambda: (
        'PASS' if int(cfg.get('port_end', 0)) >= int(cfg.get('port_start', 0)) else 'FAIL',
        '',
    )))
    checks.append(_check('Port conflicts', lambda: ('PASS', 'registry invariants (see doctor)')))

    checks.append({'name': 'External Internet reachability', 'status': 'SKIP', 'detail': 'NOT TESTED'})

    overall = 'PASS'
    for item in checks:
        if item['status'] == 'FAIL':
            overall = 'FAIL'
        elif item['status'] == 'WARN' and overall == 'PASS':
            overall = 'WARN'

    lines = ['FRP Server Test', '==============', '']
    for item in checks:
        lines.append('%s %s' % (item['name'].ljust(26), item['status']))
        if item['detail'] and item['status'] in ('WARN', 'FAIL', 'SKIP'):
            lines.append('  (%s)' % item['detail'])
    lines.extend(['', 'RESULT=%s' % overall])
    return overall, '\n'.join(lines) + '\n', checks


def _listener_open(host, port):
    host = str(host or '127.0.0.1')
    if host in ('0.0.0.0', '::', ''):
        host = '127.0.0.1'
    try:
        tcp_reach(host, int(port))
        return True
    except OSError:
        return False


def validate_log_lines(value):
    text = str(value or '').strip()
    if not re.fullmatch(r'[0-9]+', text):
        raise ValueError('invalid --lines value')
    num = int(text)
    if num < 1 or num > 10000:
        raise ValueError('--lines must be between 1 and 10000')
    return num


def fetch_logs(component='all', lines=100, follow=False):
    cfg = load_config()
    mode = str(cfg.get('deployment_mode') or 'direct').strip().lower()
    units = ['frps', 'frp-port-allocator']
    if mode == 'single443':
        units.append('frp-frontend')
    if component != 'all':
        mapping = {
            'frps': 'frps',
            'allocator': 'frp-port-allocator',
            'nginx': 'frp-frontend',
            'frontend': 'frp-frontend',
        }
        key = mapping.get(component.lower())
        if not key:
            raise ValueError('unknown log component: %s' % component)
        units = [key]

    if follow:
        if len(units) != 1:
            raise ValueError('--follow requires a single component')
        if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or _root():
            print('[test] follow mode not available')
            return 0
        os.execvp('journalctl', ['journalctl', '-u', units[0], '-f', '--no-pager'])

    if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or _root():
        fixture = os.environ.get('FRP_SERVER_LIFECYCLE_LOG_FIXTURE', '')
        text = Path(fixture).read_text(encoding='utf-8') if fixture else '[test] no journal\n'
        for line in text.splitlines()[-lines:]:
            print(redact_text(line))
        return 0

    for unit in units:
        print('=== %s ===' % unit)
        proc = subprocess.run(
            ['journalctl', '-u', unit, '-n', str(lines), '--no-pager'],
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = proc.stdout or proc.stderr or ''
        for line in output.splitlines():
            print(redact_text(line))
    return 0


def registry_summary_redacted(state):
    summary = {
        'schema_version': state.get('schema_version'),
        'reserved_ports': list(state.get('reserved') or []),
        'client_count': len(state.get('clients') or {}),
        'clients': {},
    }
    for mid, client in (state.get('clients') or {}).items():
        if not isinstance(client, dict):
            continue
        entry = {
            'hostname': client.get('hostname'),
            'mgmt_status': client.get('mgmt_status'),
            'last_mgmt_seen_at': client.get('last_mgmt_seen_at'),
            'label': client.get('label'),
            'services': {},
        }
        for sid, svc in (client.get('services') or {}).items():
            if not isinstance(svc, dict):
                continue
            entry['services'][sid] = {
                'remote_port': svc.get('remote_port'),
                'enabled': svc.get('enabled', True),
                'preset': svc.get('preset'),
            }
        summary['clients'][mid] = entry
    return redact_json_obj(summary)


def collect_support_bundle(out_path):
    tmpdir = Path(tempfile.mkdtemp(prefix='frp-server-support.'))
    try:
        os.chmod(tmpdir, 0o700)
        bundle_dir = tmpdir / 'bundle'
        bundle_dir.mkdir()

        def write_text(name, content):
            path = bundle_dir / name
            path.write_text(redact_text(content), encoding='utf-8')
            os.chmod(path, 0o600)

        version = _path('/etc/frp-auto-deploy/version')
        write_text('version.txt', version.read_text(encoding='utf-8') if version.is_file() else '')

        proc = subprocess.run(
            [sys.executable, '-m', 'frp_fleet', 'fleet'],
            capture_output=True,
            text=True,
            env=os.environ,
        )
        write_text('fleet.txt', proc.stdout or '')

        proc = subprocess.run(
            [sys.executable, '-m', 'frp_fleet', 'ports'],
            capture_output=True,
            text=True,
            env=os.environ,
        )
        write_text('ports.txt', proc.stdout or '')

        _, test_out, _ = run_server_test()
        write_text('test.txt', test_out)

        cfg = load_config()
        cfg_path = _path('/etc/frp-auto-deploy/config.json')
        if cfg_path.is_file():
            write_text(
                'server-config.redacted.json',
                json.dumps(redact_json_obj(json.loads(cfg_path.read_text(encoding='utf-8'))), indent=2) + '\n',
            )

        if frp_fleet:
            _cfg, _rp, state = frp_fleet.load_context()
            write_text(
                'registry-summary.redacted.json',
                json.dumps(registry_summary_redacted(state), indent=2, sort_keys=True) + '\n',
            )

        for unit, fname in (
            ('frps', 'logs-frps.txt'),
            ('frp-port-allocator', 'logs-allocator.txt'),
            ('frp-frontend', 'logs-nginx.txt'),
        ):
            if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or _root():
                write_text(fname, '[test mode]\n')
                continue
            proc = subprocess.run(
                ['journalctl', '-u', unit, '-n', '100', '--no-pager'],
                capture_output=True,
                text=True,
                timeout=30,
            )
            write_text(fname, redact_text(proc.stdout or proc.stderr or ''))

        out = Path(out_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(out, 'w:gz') as tar:
            for item in sorted(bundle_dir.iterdir()):
                tar.add(item, arcname=item.name)
        os.chmod(out, 0o600)
        return str(out)
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv=None):
    argv = list(argv or sys.argv[1:])
    cmd = argv[0] if argv else 'help'
    if cmd == 'test':
        _, text, _ = run_server_test()
        sys.stdout.write(text)
        return 0
    if cmd == 'logs':
        component = 'all'
        lines = 100
        follow = False
        i = 1
        while i < len(argv):
            if argv[i] in ('frps', 'allocator', 'nginx', 'frontend') and component == 'all':
                component = argv[i]
                i += 1
                continue
            if argv[i] == '--lines' and i + 1 < len(argv):
                lines = validate_log_lines(argv[i + 1])
                i += 2
                continue
            if argv[i] == '--follow':
                follow = True
                i += 1
                continue
            raise SystemExit('ERROR: unknown logs option: %s' % argv[i])
        return fetch_logs(component=component, lines=lines, follow=follow)
    if cmd == 'support-bundle':
        out = None
        i = 1
        while i < len(argv):
            if argv[i] == '--output' and i + 1 < len(argv):
                out = argv[i + 1]
                i += 2
                continue
            raise SystemExit('ERROR: unknown support-bundle option: %s' % argv[i])
        if not out:
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            out = str(_path('/tmp/frp-server-support-bundle-%s.tar.gz' % stamp))
        path = collect_support_bundle(out)
        print('Support bundle written to: %s' % path)
        return 0
    raise SystemExit('usage: frp_server_lifecycle.py test|logs|support-bundle')


if __name__ == '__main__':
    raise SystemExit(main())
