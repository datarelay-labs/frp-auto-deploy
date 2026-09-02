#!/usr/bin/env python3
"""Client lifecycle diagnostics: pause state, connectivity test, support bundle."""
from __future__ import annotations

import json
import os
import platform
import re
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

# Reuse doctor redaction patterns.
try:
    from frp_doctor import redact as _doctor_redact
except ImportError:
    _doctor_redact = None

PAUSE_SCHEMA = 1
SENSITIVE_KEY_RE = re.compile(
    r'^(token|secret|password|passwd|private_key|private-key|authorization|'
    r'enrollment_code|enrollment-code|bootstrap_ticket|bootstrap-ticket|'
    r'mgmt_mac_key|auth_token|server_token|install_key|frp_ad_proof)$',
    re.IGNORECASE,
)
SENSITIVE_VALUE_RE = re.compile(
    r'(BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY|'
    r'auth\.token\s*=\s*(?!"\[redacted\]")\S+|'
    r'metadatas\.frp_ad_proof\s*=\s*(?!"\[redacted\]")\S+|'
    r'(?<![A-Za-z0-9_])frp_ad_proof\s*=\s*(?!"\[redacted\]")\S+|'
    r'bt1\.[0-9a-f]{16}\.[0-9a-f]{32,}|'
    r'Enrollment Code:\s*\S+)',
    re.IGNORECASE,
)
CONNECT_TIMEOUT = 2.0


MACOS_LAUNCHD_LABEL = (
    os.environ.get('FRP_MACOS_LAUNCHD_LABEL') or 'com.datarelay.frp-auto-deploy.frpc'
)


def _is_darwin():
    return (os.environ.get('FRP_TEST_UNAME_S') or platform.system()) == 'Darwin'


def _macos_state_root():
    return (
        os.environ.get('FRP_MACOS_STATE_ROOT')
        or '/Library/Application Support/frp-auto-deploy'
    )


def _macos_map(absolute):
    """Mirror of frp_macos_map_path for the paths this module reads.

    Only the state-root families are needed here; nothing in the lifecycle
    module resolves a Homebrew-prefix path.
    """
    state = _macos_state_root()
    text = str(absolute)
    for prefix, replacement in (
        ('/etc/frp/', state + '/'),
        ('/etc/frp-auto-deploy/', state + '/'),
        ('/var/lib/frp-auto-deploy/', state + '/state/'),
        ('/usr/local/lib/frp-auto-deploy/', state + '/lib/'),
    ):
        if text.startswith(prefix):
            return replacement + text[len(prefix):]
    if text in ('/etc/frp', '/etc/frp-auto-deploy'):
        return state
    if text == '/usr/local/lib/frp-auto-deploy':
        return state + '/lib'
    if text == '/usr/local/bin/frpc':
        return state + '/bin/frpc'
    return text


def _root():
    """Return test-root Path, or None when unset (production absolute paths)."""
    raw = os.environ.get('FRP_CLIENT_TEST_ROOT', '')
    return Path(raw) if raw else None


def _path(rel):
    text = str(rel) if str(rel).startswith('/') else '/' + str(rel)
    if _is_darwin():
        text = _macos_map(text)
    absolute = Path(text)
    root = _root()
    if root is None:
        return absolute
    return root / str(absolute).lstrip('/')


def _path_has_symlink_component(path):
    path = Path(path)
    try:
        cur = path if path.exists() or path.is_symlink() else path.parent
    except OSError:
        cur = path.parent
    seen = 0
    while True:
        try:
            if cur.is_symlink():
                return True
        except OSError:
            return True
        parent = cur.parent
        if parent == cur:
            break
        cur = parent
        seen += 1
        if seen > 64:
            return True
    return False


def _secure_write_tar_gz(out_path, bundle_dir):
    """Write gzip tar without following symlinks; mode 0600; atomic replace."""
    out = Path(out_path)
    if not str(out).startswith('/'):
        out = Path('/') / out
    out = Path(os.path.abspath(str(out)))
    if out.exists() or out.is_symlink():
        if out.is_symlink():
            raise OSError('refusing to write support bundle through a symlink: %s' % out)
        raise OSError('support bundle output already exists: %s' % out)
    parent = out.parent
    if not parent.exists():
        parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(parent, 0o700)
        except OSError:
            pass
    if _path_has_symlink_component(out) or _path_has_symlink_component(parent):
        raise OSError('refusing to write support bundle through a symlink: %s' % out)
    fd, tmp_name = tempfile.mkstemp(prefix='.frp-support.', suffix='.tmp', dir=str(parent))
    tmp_path = Path(tmp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as handle:
            with tarfile.open(fileobj=handle, mode='w:gz') as tar:
                for item in sorted(Path(bundle_dir).iterdir()):
                    tar.add(item, arcname=item.name)
            handle.flush()
            os.fsync(handle.fileno())
        if out.exists() or out.is_symlink():
            raise OSError('support bundle output path became unsafe: %s' % out)
        os.replace(str(tmp_path), str(out))
        os.chmod(out, 0o600)
        return str(out)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except TypeError:
            try:
                tmp_path.unlink()
            except OSError:
                pass
        except OSError:
            pass
        raise


def pause_marker_path():
    return _path('/etc/frp/remote-access-paused.json')


def read_pause_state():
    path = pause_marker_path()
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return {'paused': True, 'schema_version': PAUSE_SCHEMA}
    if not isinstance(data, dict):
        return {'paused': True, 'schema_version': PAUSE_SCHEMA}
    data.setdefault('paused', True)
    return data


def is_paused():
    state = read_pause_state()
    return bool(state and state.get('paused'))


def write_pause_state(autostart_was_enabled):
    path = pause_marker_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        'schema_version': PAUSE_SCHEMA,
        'paused': True,
        'paused_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'autostart_was_enabled': bool(autostart_was_enabled),
    }
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    return payload


def clear_pause_state():
    path = pause_marker_path()
    if path.is_file():
        path.unlink()


def redact_text(text):
    if _doctor_redact:
        return _doctor_redact(text)
    if not text:
        return ''
    text = str(text)
    text = SENSITIVE_VALUE_RE.sub('[redacted]', text)
    text = re.sub(r'auth\.token\s*=\s*".*?"', 'auth.token = "[redacted]"', text)
    return text


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


def redact_toml(text):
    lines = []
    for line in str(text or '').splitlines():
        if re.match(r'^\s*token\s*=', line, re.IGNORECASE):
            lines.append('token = "[redacted]"')
        elif re.match(r'^\s*auth\.token\s*=', line, re.IGNORECASE):
            lines.append('auth.token = "[redacted]"')
        elif re.match(r'^\s*metadatas\.frp_ad_proof\s*=', line, re.IGNORECASE):
            lines.append('metadatas.frp_ad_proof = "[redacted]"')
        else:
            lines.append(redact_text(line))
    return '\n'.join(lines) + ('\n' if text and str(text).endswith('\n') else '')


def anonymize_text(text, hostnames=None, ips=None):
    text = str(text or '')
    for item in sorted(set(hostnames or []), key=len, reverse=True):
        if item:
            text = text.replace(item, '<hostname>')
    for item in sorted(set(ips or []), key=len, reverse=True):
        if item:
            text = text.replace(item, '<ip>')
    return text


def _load_client_state():
    path = _path('/etc/frp/client-state.json')
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return None


def _check(name, fn):
    try:
        status, detail = fn()
        return {'name': name, 'status': status, 'detail': detail or ''}
    except Exception as exc:
        return {'name': name, 'status': 'FAIL', 'detail': str(exc)}


def _tcp_reach(host, port):
    sock = socket.create_connection((host, int(port)), timeout=CONNECT_TIMEOUT)
    sock.close()


def _https_head(url):
    parsed = urlparse(url)
    if parsed.scheme != 'https':
        raise ValueError('not https')
    host = parsed.hostname
    port = parsed.port or 443
    ca = _path('/etc/frp-auto-deploy/allocator-ca.crt')
    if not ca.is_file():
        raise ValueError('allocator CA missing')
    ctx = ssl.create_default_context()
    ctx.load_verify_locations(cafile=str(ca))
    with socket.create_connection((host, port), timeout=CONNECT_TIMEOUT) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            tls.settimeout(CONNECT_TIMEOUT)
            try:
                tls.sendall(b'HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n' % host.encode())
                tls.recv(64)
            except Exception:
                pass


def _resolve_host(host):
    host = str(host or '').strip()
    if not host:
        return 'FAIL', 'empty host'
    # IP literal (v4/v6)
    try:
        socket.inet_pton(socket.AF_INET, host)
        return 'PASS', 'IP literal'
    except OSError:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, host.strip('[]'))
        return 'PASS', 'IP literal'
    except OSError:
        pass
    try:
        socket.getaddrinfo(host, None)
        return 'PASS', host
    except socket.gaierror as exc:
        return 'FAIL', 'DNS resolution failed: %s' % exc


def _identity_permissions():
    key = _path('/etc/frp/client-identity.key')
    if not key.is_file():
        return 'FAIL', 'client-identity.key missing'
    mode = key.stat().st_mode & 0o777
    if mode != 0o600:
        return 'FAIL', 'client-identity.key mode 0o%o (expected 0600)' % mode
    return 'PASS', '0600'


def _frpc_active():
    if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or os.environ.get('FRP_CLIENT_TEST_ROOT'):
        hook = os.environ.get('FRP_CLIENT_LIFECYCLE_FRPC_ACTIVE')
        if hook == '1':
            return 'PASS', 'running (test hook)'
        if hook == '0':
            return 'PASS', 'stopped (test hook)'
        return 'SKIP', 'service checks skipped in test mode'
    try:
        if _is_darwin():
            # launchd has no `is-active`; a non-zero pid in `launchctl print`
            # is the equivalent signal. /proc does not exist here.
            proc = subprocess.run(
                ['launchctl', 'print', 'system/' + MACOS_LAUNCHD_LABEL],
                capture_output=True,
                text=True,
                timeout=5,
            )
            text = proc.stdout or ''
            match = re.search(r'^\s*pid\s*=\s*(\d+)', text, re.M)
            if match and match.group(1) != '0':
                return 'PASS', 'running'
            if is_paused():
                return 'PASS', 'stopped (paused)'
            if proc.returncode != 0:
                return 'WARN', 'not loaded'
            return 'WARN', 'loaded but not running'
        proc = subprocess.run(
            ['systemctl', 'is-active', 'frpc'],
            capture_output=True,
            text=True,
            timeout=3,
        )
        active = (proc.stdout or proc.stderr or '').strip()
        if active == 'active':
            return 'PASS', 'running'
        if is_paused():
            return 'PASS', 'stopped (paused)'
        return 'WARN', active or 'inactive'
    except Exception as exc:
        return 'SKIP', str(exc)


def run_connectivity_test():
    checks = []
    state = _load_client_state()
    pause = is_paused()

    def local_state():
        if state:
            return 'PASS', ''
        return 'FAIL', 'client-state.json missing'

    def mgmt_identity():
        for rel in ('/etc/frp/client-identity.key', '/etc/frp/client-identity.pub'):
            if not _path(rel).is_file():
                return 'FAIL', '%s missing' % rel
        return 'PASS', ''

    def frp_config():
        toml = _path('/etc/frp/frpc.toml')
        if not toml.is_file():
            return 'FAIL', 'frpc.toml missing'
        return 'PASS', ''

    checks.append(_check('Local state', local_state))
    checks.append(_check('Management identity', mgmt_identity))
    checks.append(_check('Identity permissions', _identity_permissions))
    checks.append(_check('FRP configuration', frp_config))
    checks.append(_check('Remote access pause marker', lambda: (
        'PASS' if pause else 'PASS',
        'paused' if pause else 'not paused',
    )))

    server = (state or {}).get('frp_server') or ''
    port = int((state or {}).get('frp_server_port') or 0)
    allocator = (state or {}).get('allocator_url') or ''

    if server:
        checks.append(_check('FRP server DNS', lambda: _resolve_host(server)))
        checks.append(_check('FRP server TCP reach', lambda: (
            'PASS' if _tcp_ok(server, port) else 'FAIL',
            '%s:%s' % (server, port),
        )))
    else:
        checks.append(_check('FRP server DNS', lambda: ('SKIP', 'no server in state')))
        checks.append(_check('FRP server TCP reach', lambda: ('SKIP', 'no server in state')))

    if allocator:
        ca_path = _path('/etc/frp-auto-deploy/allocator-ca.crt')
        if not ca_path.is_file():
            checks.append(_check('Allocator HTTPS', lambda: ('FAIL', 'allocator CA missing')))
            checks.append(_check('CA validation', lambda: ('FAIL', 'missing')))
        else:
            checks.append(_check('Allocator HTTPS', lambda: (
                'PASS' if _https_ok(allocator) else 'FAIL',
                allocator,
            )))
            checks.append(_check('CA validation', lambda: ('PASS', 'allocator CA present')))
    else:
        checks.append(_check('Allocator HTTPS', lambda: ('SKIP', 'no allocator URL')))
        checks.append(_check('CA validation', lambda: ('SKIP', 'no allocator URL')))

    # Clock skew: lightweight client test does not query server time.
    checks.append(_check('Server time', lambda: ('SKIP', 'not queried in client test')))
    checks.append(_check('Local clock skew', lambda: ('SKIP', 'see doctor for skew details')))

    name, status, detail = 'frpc process', *_frpc_active()
    checks.append({'name': name, 'status': status, 'detail': detail})

    services = (state or {}).get('services') or {}
    for sid, item in sorted(services.items()):
        if item.get('enabled', True) is False:
            continue
        host = str(item.get('local_ip') or '127.0.0.1')
        lport = int(item.get('local_port') or 0)
        label = '%s %s:%s' % (item.get('id') or sid, host, lport)

        def target_check(h=host, p=lport, lbl=label):
            if _tcp_ok(h, p):
                return 'PASS', lbl
            return 'FAIL', lbl

        checks.append(_check('Services', target_check))

    checks.append({
        'name': 'External public reachability',
        'status': 'SKIP',
        'detail': 'NOT TESTED',
    })

    overall = 'PASS'
    for item in checks:
        st = item['status']
        if st == 'FAIL':
            overall = 'FAIL'
        elif st == 'WARN' and overall == 'PASS':
            overall = 'WARN'

    lines = ['FRP Client Connectivity Test', '=' * 28, '']
    last_group = None
    for item in checks:
        name = item['name']
        if name == 'Services' and last_group != 'Services':
            if last_group is not None:
                lines.append('')
            lines.append('Services')
            last_group = 'Services'
            lines.append('%s  %s' % (item['detail'].ljust(24), item['status']))
            continue
        if name == 'Services':
            lines.append('%s  %s' % (item['detail'].ljust(24), item['status']))
            continue
        last_group = name
        label = name.ljust(24)
        lines.append('%s %s' % (label, item['status']))
        show_detail = item['detail'] and (
            item['status'] in ('WARN', 'FAIL', 'SKIP')
            or name in ('FRP server DNS', 'Identity permissions', 'CA validation')
        )
        if show_detail:
            lines.append('  (%s)' % item['detail'])

    lines.extend(['', 'RESULT=%s' % overall])
    return overall, '\n'.join(lines) + '\n', checks


def _tcp_ok(host, port):
    try:
        _tcp_reach(host, port)
        return True
    except OSError:
        return False


def _https_ok(url):
    try:
        _https_head(url)
        return True
    except Exception:
        return False



def _validate_support_bundle_output(out_path):
    """Fail closed before collecting if the destination is unsafe."""
    out = Path(out_path)
    if not str(out).startswith('/'):
        out = Path('/') / out
    out = Path(os.path.abspath(str(out)))
    if out.is_symlink() or (out.exists() and out.is_symlink()):
        raise OSError('refusing to write support bundle through a symlink: %s' % out)
    if out.exists():
        raise OSError('support bundle output already exists: %s' % out)
    parent = out.parent
    if parent.exists() and _path_has_symlink_component(parent):
        raise OSError('refusing to write support bundle through a symlink: %s' % out)
    return out


def collect_support_bundle(out_path, anonymize=False):
    _validate_support_bundle_output(out_path)
    root = _root()
    tmpdir = Path(tempfile.mkdtemp(prefix='frp-support-bundle.'))
    try:
        os.chmod(tmpdir, 0o700)
        bundle_dir = tmpdir / 'bundle'
        bundle_dir.mkdir()
        state = _load_client_state()
        hostnames = set()
        ips = set()
        if state:
            if state.get('hostname'):
                hostnames.add(str(state['hostname']))
            if state.get('frp_server'):
                ips.add(str(state['frp_server']))
            for item in (state.get('services') or {}).values():
                if item.get('local_ip'):
                    ips.add(str(item['local_ip']))

        def write_text(name, content, *, already_redacted=False):
            # TOML/JSON helpers already redact; a second pass would turn
            # auth.token = "[redacted]" / metadatas.frp_ad_proof = "[redacted]"
            # into a bare [redacted] via SECRET_RE.
            text = content if already_redacted else redact_text(content)
            if anonymize:
                text = anonymize_text(text, hostnames, ips)
            path = bundle_dir / name
            path.write_text(text, encoding='utf-8')
            os.chmod(path, 0o600)

        version = _path('/etc/frp-auto-deploy/version')
        write_text('version.txt', version.read_text(encoding='utf-8') if version.is_file() else '')

        proc = subprocess.run(
            [sys.executable, '-m', 'frp_client_lifecycle', 'status-snapshot'],
            capture_output=True,
            text=True,
            env={**os.environ, 'PYTHONPATH': str(_path('/usr/local/lib/frp-auto-deploy') or Path(__file__).parent)},
        )
        write_text('status.txt', proc.stdout or proc.stderr or '')

        proc = subprocess.run(
            [sys.executable, '-m', 'frp_doctor'],
            capture_output=True,
            text=True,
            env={**os.environ, 'PYTHONPATH': str(_path('/usr/local/lib/frp-auto-deploy') or Path(__file__).parent)},
        )
        if proc.returncode not in (0, 1, 2):
            proc = subprocess.run(
                ['frpctl', 'doctor'],
                capture_output=True,
                text=True,
                env=os.environ,
            )
        write_text('doctor.txt', proc.stdout or proc.stderr or '')

        _, test_out, _ = run_connectivity_test()
        write_text('test.txt', test_out)

        logs = subprocess.run(
            [sys.executable, '-m', 'frp_client_lifecycle', 'logs', '--lines', '100'],
            capture_output=True,
            text=True,
            env=os.environ,
        )
        write_text('logs.txt', logs.stdout or logs.stderr or '')

        state_path = _path('/etc/frp/client-state.json')
        if state_path.is_file():
            write_text(
                'client-state.redacted.json',
                json.dumps(redact_json_obj(json.loads(state_path.read_text(encoding='utf-8'))), indent=2, sort_keys=True) + '\n',
                already_redacted=True,
            )
        toml_path = _path('/etc/frp/frpc.toml')
        if toml_path.is_file():
            write_text(
                'frpc.redacted.toml',
                redact_toml(toml_path.read_text(encoding='utf-8')),
                already_redacted=True,
            )

        uname = subprocess.run(['uname', '-a'], capture_output=True, text=True)
        write_text('system.txt', uname.stdout or '')

        ip_out = subprocess.run(['ip', '-br', 'addr'], capture_output=True, text=True)
        if ip_out.returncode != 0:
            ip_out = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        write_text('network.txt', ip_out.stdout or ip_out.stderr or '')

        return _secure_write_tar_gz(out_path, bundle_dir)
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


def validate_log_lines(value):
    text = str(value or '').strip()
    if not text:
        return 100
    if not re.fullmatch(r'[0-9]+', text):
        raise ValueError('invalid --lines value')
    num = int(text)
    if num < 1 or num > 10000:
        raise ValueError('--lines must be between 1 and 10000')
    return num


def _macos_log_paths():
    log_dir = _path('/etc/frp') / 'logs'
    return [log_dir / 'frpc.out.log', log_dir / 'frpc.err.log']


def _macos_read_logs(lines):
    """launchd writes plain files, so tail them instead of querying a journal."""
    collected = []
    for path in _macos_log_paths():
        try:
            collected.extend(path.read_text(encoding='utf-8', errors='replace').splitlines())
        except OSError:
            continue
    return collected[-lines:]


def fetch_logs(lines=100, follow=False):
    if follow:
        if os.environ.get('FRP_CLIENT_TEST_ROOT') or os.environ.get('FRP_SKIP_SYSTEMD') == '1':
            for line in ('[test] follow mode not available',):
                print(line)
                sys.stdout.flush()
            return 0
        if _is_darwin():
            args = ['tail', '-n', '100', '-F'] + [str(p) for p in _macos_log_paths()]
            os.execvp('tail', args)
        os.execvp('journalctl', ['journalctl', '-u', 'frpc', '-f', '--no-pager'])
    lines = validate_log_lines(lines)
    if os.environ.get('FRP_CLIENT_TEST_ROOT') or os.environ.get('FRP_SKIP_SYSTEMD') == '1':
        hook = os.environ.get('FRP_CLIENT_LIFECYCLE_LOG_FIXTURE', '')
        if hook:
            text = Path(hook).read_text(encoding='utf-8')
        else:
            text = '[test] no journal in test mode\n'
        for line in text.splitlines()[-lines:]:
            print(redact_text(line))
        return 0
    if _is_darwin():
        for line in _macos_read_logs(lines):
            print(redact_text(line))
        return 0
    proc = subprocess.run(
        ['journalctl', '-u', 'frpc', '-n', str(lines), '--no-pager'],
        capture_output=True,
        text=True,
        timeout=30,
    )
    output = proc.stdout or proc.stderr or ''
    for line in output.splitlines():
        print(redact_text(line))
    return proc.returncode


def main(argv=None):
    argv = list(argv or sys.argv[1:])
    cmd = argv[0] if argv else 'help'
    if cmd == 'test':
        overall, text, _ = run_connectivity_test()
        sys.stdout.write(text)
        return 1 if overall == 'FAIL' else 0
    if cmd == 'logs':
        lines = 100
        follow = False
        i = 1
        while i < len(argv):
            if argv[i] == '--lines' and i + 1 < len(argv):
                lines = validate_log_lines(argv[i + 1])
                i += 2
                continue
            if argv[i] == '--follow':
                follow = True
                i += 1
                continue
            raise SystemExit('ERROR: unknown logs option: %s' % argv[i])
        return fetch_logs(lines=lines, follow=follow)
    if cmd == 'support-bundle':
        anonymize = '--anonymize' in argv
        out = None
        i = 1
        while i < len(argv):
            if argv[i] == '--anonymize':
                i += 1
                continue
            if argv[i] == '--output' and i + 1 < len(argv):
                out = argv[i + 1]
                i += 2
                continue
            raise SystemExit('ERROR: unknown support-bundle option: %s' % argv[i])
        if not out:
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            out = str(_path('/tmp/frp-support-bundle-%s.tar.gz' % stamp))
        try:
            path = collect_support_bundle(out, anonymize=anonymize)
        except OSError as exc:
            raise SystemExit('ERROR: %s' % exc)
        print('Support bundle written to: %s' % path)
        return 0
    if cmd == 'status-snapshot':
        proc = subprocess.run(
            ['frp-client', 'status'],
            capture_output=True,
            text=True,
            env=os.environ,
        )
        sys.stdout.write(redact_text(proc.stdout or proc.stderr or ''))
        return proc.returncode
    if cmd == 'is-paused':
        print('yes' if is_paused() else 'no')
        return 0
    raise SystemExit('usage: frp_client_lifecycle.py test|logs|support-bundle|is-paused')


if __name__ == '__main__':
    raise SystemExit(main())
