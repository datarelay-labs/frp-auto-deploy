#!/usr/bin/env python3
"""FRP data-plane authorization: domain-separated ECDSA proofs and NewProxy authorizer.

Management request signatures (op=enroll, body-bound) and data-plane proofs
(purpose=frp-data-plane, client-id-bound) are intentionally separate domains.
Revoke invalidates future management API access and future/reconnected NewProxy
authorization. Existing connected proxies are not force-disconnected; port
reservations, service records, and audit history remain until explicit release.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

_LIB = Path(__file__).resolve().parent
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))

DATA_PLANE_ALG = 'ecdsa-p256-sha256'
DATA_PLANE_PURPOSE = 'frp-data-plane'
DATA_PLANE_SCHEMA = 1

META_CLIENT_ID = 'frp_ad_client_id'
META_PROOF_SCHEMA = 'frp_ad_proof_schema'
META_PROOF = 'frp_ad_proof'
META_SERVICE_ID = 'frp_ad_service_id'

PLUGIN_PATH = '/handler'
MAX_PLUGIN_BODY = 65536
LEASE_TTL_SEC = 30


def _load_mgmt():
    path = _LIB / 'frp_mgmt_auth.py'
    spec = importlib.util.spec_from_file_location('frp_mgmt_auth', str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_creg():
    path = _LIB / 'frp_client_registry.py'
    spec = importlib.util.spec_from_file_location('frp_client_registry', str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _load_leases():
    path = _LIB / 'frp_proxy_leases.py'
    spec = importlib.util.spec_from_file_location('frp_proxy_leases', str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MGMT = _load_mgmt()
CREG = None

MACHINE_ID_MAX_LEN = 128
MACHINE_ID_SAFE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
SERVICE_ID_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,31}$')


def _creg():
    global CREG
    if CREG is None:
        CREG = _load_creg()
    return CREG


def _load_locks():
    path = _LIB / 'frp_control_locks.py'
    spec = importlib.util.spec_from_file_location('frp_control_locks', str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def validate_client_id(value):
    try:
        return _creg().validate_machine_id(str(value))
    except ValueError:
        raise
    except Exception:
        pass
    if value is None:
        raise ValueError('machine_id is required')
    text = str(value).strip()
    if not text:
        raise ValueError('machine_id is required')
    if len(text) > MACHINE_ID_MAX_LEN:
        raise ValueError('machine_id exceeds maximum length')
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in text):
        raise ValueError('machine_id contains control characters')
    if any(ch in text for ch in '/\\'):
        raise ValueError('machine_id contains path separators')
    if not MACHINE_ID_SAFE_RE.fullmatch(text):
        raise ValueError('machine_id contains unsafe characters')
    return text


def validate_service_id(value, field='service id'):
    try:
        return _creg().require_canonical_service_id(value, field=field)
    except ValueError:
        raise
    except Exception:
        pass
    if not isinstance(value, str):
        raise ValueError('%s must be a string' % field)
    if value != value.strip() or value != value.lower():
        raise ValueError('noncanonical %s' % field)
    if not SERVICE_ID_RE.fullmatch(value):
        raise ValueError('invalid %s; use [a-z0-9][a-z0-9._-]{0,31}' % field)
    return value


def canonical_json(data):
    return MGMT.canonical_json(data)


def proof_object(client_id):
    return {
        'alg': DATA_PLANE_ALG,
        'client_id': str(client_id),
        'purpose': DATA_PLANE_PURPOSE,
        'schema': DATA_PLANE_SCHEMA,
    }


def proof_message_bytes(client_id):
    return canonical_json(proof_object(client_id)).encode('utf-8')


def sign_proof(key_path, client_id):
    validate_client_id(str(client_id))
    MGMT.validate_private_key(key_path)
    return MGMT.sign_message(key_path, proof_message_bytes(client_id))


def verify_proof(pub_pem, client_id, signature_b64):
    try:
        validate_client_id(str(client_id))
    except ValueError:
        return False
    try:
        return MGMT.verify_signature(pub_pem, proof_message_bytes(client_id), signature_b64)
    except ValueError:
        return False


def parse_frpc_toml_sections(text):
    global_kv = {}
    proxies = []
    current = None
    for raw in str(text or '').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('[[proxies]]'):
            if current is not None:
                proxies.append(current)
            current = {}
            continue
        if line.startswith('['):
            if current is not None:
                proxies.append(current)
                current = None
            continue
        if '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"') and value.endswith('"') and len(value) >= 2:
            value = value[1:-1].replace('\\"', '"').replace('\\\\', '\\')
        if current is not None:
            current[key] = value
        else:
            global_kv[key] = value
    if current is not None:
        proxies.append(current)
    return global_kv, proxies


def validate_frpc_data_plane_metadata(
    toml_text,
    machine_id,
    enabled_services,
    pub_pem=None,
    host_id=None,
):
    """Validate exact per-proxy service metadata mapping after data-plane upgrade.

    enabled_services may be:
      - dict of service_id -> service record (preferred; must include remote_port)
      - iterable of service records with id/remote_port
      - iterable of service id strings (remote_port required from matching proxy only
        when records are unavailable — callers should pass records)
    """
    cid = validate_client_id(machine_id)
    global_kv, proxies = parse_frpc_toml_sections(toml_text)
    if str(global_kv.get('clientID') or '') != cid:
        raise ValueError('frpc.toml clientID does not match machine_id')
    if str(global_kv.get('metadatas.%s' % META_CLIENT_ID) or '') != cid:
        raise ValueError('frpc.toml frp_ad_client_id does not match machine_id')
    if str(global_kv.get('metadatas.%s' % META_PROOF_SCHEMA) or '') != str(DATA_PLANE_SCHEMA):
        raise ValueError('frpc.toml frp_ad_proof_schema is not the expected schema')
    proof = str(global_kv.get('metadatas.%s' % META_PROOF) or '').strip()
    if not proof:
        raise ValueError('frpc.toml is missing frp_ad_proof')

    expected = {}
    if isinstance(enabled_services, dict):
        iterator = enabled_services.items()
        for sid, rec in iterator:
            if not isinstance(rec, dict):
                continue
            if rec.get('enabled', True) is False:
                continue
            service_id = validate_service_id(str(rec.get('id') or sid).strip().lower())
            if 'remote_port' not in rec or rec.get('remote_port') in (None, ''):
                raise ValueError('enabled service %s is missing remote_port' % service_id)
            expected[service_id] = int(rec['remote_port'])
    else:
        for item in enabled_services or []:
            if isinstance(item, dict):
                if item.get('enabled', True) is False:
                    continue
                service_id = validate_service_id(str(item.get('id') or '').strip().lower())
                if 'remote_port' not in item or item.get('remote_port') in (None, ''):
                    raise ValueError('enabled service %s is missing remote_port' % service_id)
                expected[service_id] = int(item['remote_port'])
            else:
                service_id = validate_service_id(str(item).strip().lower())
                expected[service_id] = None

    found = {}
    for proxy in proxies:
        if str(proxy.get('type') or '').lower() not in ('', 'tcp'):
            continue
        sid_raw = str(proxy.get('metadatas.%s' % META_SERVICE_ID) or '').strip().lower()
        if not sid_raw:
            raise ValueError('enabled proxy is missing frp_ad_service_id')
        sid = validate_service_id(sid_raw)
        if sid in found:
            raise ValueError('duplicate frp_ad_service_id mapping for %s' % sid)
        try:
            remote_port = int(proxy.get('remotePort'))
        except (TypeError, ValueError):
            raise ValueError('proxy for service %s has invalid remotePort' % sid) from None
        if not 1 <= remote_port <= 65535:
            raise ValueError('proxy for service %s has invalid remotePort' % sid)
        name = str(proxy.get('name') or '')
        if host_id:
            expected_name = '%s-%s' % (host_id, sid)
            if name != expected_name:
                raise ValueError(
                    'proxy name for service %s does not match canonical identity' % sid
                )
        found[sid] = remote_port

    missing = sorted(set(expected) - set(found))
    if missing:
        raise ValueError('enabled service missing from frpc.toml metadata: %s' % missing)
    extra = sorted(set(found) - set(expected))
    if extra:
        raise ValueError('unexpected frp_ad_service_id mapping in frpc.toml: %s' % extra)
    for sid, want_port in expected.items():
        if want_port is None:
            continue
        if int(found[sid]) != int(want_port):
            raise ValueError(
                'remotePort for service %s does not match client state (%s != %s)'
                % (sid, found[sid], want_port)
            )
    if pub_pem:
        if not verify_proof(pub_pem, cid, proof):
            raise ValueError('frpc.toml data-plane proof did not verify')
    return True


def _toml_escape(value):
    text = str(value or '')
    return text.replace('\\', '\\\\').replace('"', '\\"')


def frpc_global_metadata_lines(client_id, proof_b64):
    cid = _toml_escape(client_id)
    proof = _toml_escape(proof_b64)
    return [
        f'clientID = "{cid}"',
        f'metadatas.{META_CLIENT_ID} = "{cid}"',
        f'metadatas.{META_PROOF_SCHEMA} = "{DATA_PLANE_SCHEMA}"',
        f'metadatas.{META_PROOF} = "{proof}"',
    ]


def frpc_proxy_metadata_lines(service_id):
    sid = _toml_escape(service_id)
    return [f'metadatas.{META_SERVICE_ID} = "{sid}"']


def _reject(reason):
    return {'reject': True, 'reject_reason': str(reason)}


def _allow():
    if os.environ.get('FRP_DATA_PLANE_HOOK_DELAY_AFTER_LEASE') == '1':
        time.sleep(2.0)
    return {'reject': False, 'unchange': True}


def _parse_metas(value):
    if not isinstance(value, dict):
        return {}
    return {str(k): str(v) for k, v in value.items()}


def _coerce_port(value):
    try:
        port = int(value)
    except (TypeError, ValueError):
        return None
    if 1 <= port <= 65535:
        return port
    return None


def authorize_new_proxy(content, registry_state, cfg=None, lease_mod=None):
    """Return (allowed: bool, reason: str|None). Fail closed on any error."""
    if os.environ.get('FRP_DATA_PLANE_HOOK_FORCE_REJECT') == '1':
        return False, 'simulated authorizer rejection'

    if not isinstance(content, dict):
        return False, 'invalid NewProxy content'

    proxy_type = str(content.get('proxy_type') or '').strip().lower()
    if proxy_type != 'tcp':
        return False, 'only tcp proxies are authorized'

    remote_port = _coerce_port(content.get('remote_port'))
    if remote_port is None:
        return False, 'remote_port is required'

    user = content.get('user')
    if not isinstance(user, dict):
        return False, 'missing user'

    user_metas = _parse_metas(user.get('metas'))
    proxy_metas = _parse_metas(content.get('metas'))

    client_id = str(user_metas.get(META_CLIENT_ID) or user.get('user') or '').strip()
    proof_schema = str(user_metas.get(META_PROOF_SCHEMA) or '').strip()
    proof = str(user_metas.get(META_PROOF) or '').strip()
    service_id = str(proxy_metas.get(META_SERVICE_ID) or '').strip().lower()

    if not client_id:
        return False, 'missing client identity metadata'
    if proof_schema != str(DATA_PLANE_SCHEMA):
        return False, 'invalid proof schema'
    if not proof:
        return False, 'missing data-plane proof'
    if not service_id:
        return False, 'missing service identity metadata'

    try:
        client_id = validate_client_id(client_id)
        service_id = validate_service_id(service_id, field='service id')
    except ValueError as exc:
        return False, str(exc)

    try:
        _creg().validate_registry_or_raise(registry_state, cfg)
    except ValueError as exc:
        return False, 'registry is invalid: %s' % exc

    clients = registry_state.get('clients') or {}
    if not isinstance(clients, dict):
        return False, 'registry clients are invalid'

    client = clients.get(client_id)
    if not isinstance(client, dict):
        return False, 'unknown client'

    if _creg().mgmt_status(client) == 'revoked':
        return False, 'client management identity is revoked'

    pub = client.get('mgmt_pubkey')
    if not pub:
        return False, 'client has no management public key'
    if not verify_proof(pub, client_id, proof):
        return False, 'invalid data-plane proof'

    services = client.get('services') or {}
    if not isinstance(services, dict):
        return False, 'client services are invalid'
    service = services.get(service_id)
    if not isinstance(service, dict):
        return False, 'unknown service'

    if service.get('enabled', True) is False:
        return False, 'service is disabled'

    reg_port = _coerce_port(service.get('remote_port'))
    if reg_port is None:
        return False, 'service has no remote port'
    if reg_port != remote_port:
        return False, 'remote_port does not match registry reservation'

    run_id = str(user.get('run_id') or '').strip()
    hook = os.environ.get('FRP_DATA_PLANE_HOOK_AFTER_REGISTRY_AUTH_BEFORE_LEASE') or ''
    if hook:
        marker = os.environ.get('FRP_DATA_PLANE_HOOK_MARKER') or ''
        if marker:
            Path(marker).write_text('holding-registry-lock\n', encoding='utf-8')
        try:
            time.sleep(float(hook))
        except ValueError:
            time.sleep(2.0)
    if lease_mod is None:
        lease_mod = _load_leases()
    try:
        lease_dir = lease_mod.lease_dir_from_cfg(cfg)
        lease_mod.acquire_lease(
            lease_dir,
            client_id=client_id,
            service_id=service_id,
            remote_port=remote_port,
            run_id=run_id,
            ttl_sec=LEASE_TTL_SEC,
        )
    except getattr(lease_mod, 'LeaseCapacityExceeded', tuple()):
        return False, 'authorization lease capacity exceeded'
    except getattr(lease_mod, 'LeaseStoreInvalid', tuple()):
        return False, 'LEASE_STORE_INVALID'
    except OSError:
        return False, 'failed to record authorization lease'
    except ValueError as exc:
        return False, str(exc)

    return True, None


def registry_file_from_cfg(cfg):
    path = ''
    if isinstance(cfg, dict):
        path = str(cfg.get('registry_file') or '').strip()
    root = os.environ.get('FRP_DEPLOY_TEST_ROOT') or os.environ.get('FRP_SERVER_TEST_ROOT') or ''
    if not path:
        return ''
    if root and not path.startswith(root):
        return str(Path(root) / path.lstrip('/'))
    return path


def handle_plugin_http(method, path, query, body_bytes, registry_loader, cfg=None):
    """FRP server plugin HTTP entry. Always returns a JSON-serializable dict."""
    if method != 'POST':
        return 405, {'error': 'method not allowed'}
    parsed = urlparse(path or '')
    if parsed.path != PLUGIN_PATH:
        return 404, {'error': 'not found'}
    if len(body_bytes or b'') > MAX_PLUGIN_BODY:
        return 400, _reject('request body too large')

    try:
        payload = json.loads((body_bytes or b'').decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return 400, _reject('invalid JSON')

    if not isinstance(payload, dict):
        return 400, _reject('invalid JSON object')

    params = parse_qs(query or '', keep_blank_values=False)
    op = (params.get('op') or [''])[0] or str(payload.get('op') or '').strip()
    if not op:
        return 400, _reject('missing op')

    content = payload.get('content')
    strict = (cfg or {}).get('data_plane_auth_strict', True) is True

    # v2.1.1: NewProxy-only. Do not delete leases on CloseProxy (one run_id
    # covers multiple proxies). Expired leases clean up by TTL.
    if op == 'CloseProxy':
        return 200, _allow()

    if op != 'NewProxy':
        return 400, _reject('unsupported op')

    if not strict:
        return 200, _allow()

    registry_file = registry_file_from_cfg(cfg)
    if not registry_file:
        return 200, _reject('registry path is not configured')

    locks = _load_locks()
    with locks.acquire_registry_lock(registry_file):
        try:
            registry_state = registry_loader()
        except Exception:
            return 200, _reject('registry unavailable')
        allowed, reason = authorize_new_proxy(content, registry_state, cfg=cfg)
        if not allowed:
            return 200, _reject(reason or 'authorization denied')
        return 200, _allow()


def assert_port_releasable(remote_port, cfg=None, lease_mod=None):
    """Raise ValueError when release must be refused (live proxy or active lease).

    Caller must already hold registry.lock. Malformed lease state fails closed.
    """
    if remote_port is None:
        return
    port = int(remote_port)
    state = _creg().passive_port_state(port)
    if state != 'offline':
        raise ValueError(
            'port %s is %s; stop publishing before release' % (port, state)
        )
    if lease_mod is None:
        lease_mod = _load_leases()
    lease_dir = lease_mod.lease_dir_from_cfg(cfg)
    try:
        lease_mod.expire_stale(lease_dir)
        active = lease_mod.has_active_lease(lease_dir, remote_port=port)
    except Exception as exc:
        if type(exc).__name__ == 'LeaseStoreInvalid' or 'LEASE_STORE_INVALID' in str(exc):
            raise ValueError('LEASE_STORE_INVALID: RELEASE_REFUSED') from exc
        raise
    if active:
        raise ValueError(
            'port %s has an active authorization lease; retry after proxy bind completes or expires'
            % port
        )


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description='FRP data-plane proof helpers')
    sub = parser.add_subparsers(dest='cmd', required=True)

    sign_p = sub.add_parser('sign-proof')
    sign_p.add_argument('client_id')
    sign_p.add_argument('key_path')

    verify_p = sub.add_parser('verify-proof')
    verify_p.add_argument('client_id')
    verify_p.add_argument('pub_path')
    verify_p.add_argument('signature')

    args = parser.parse_args(argv)
    if args.cmd == 'sign-proof':
        print(sign_proof(args.key_path, args.client_id))
        return 0
    if args.cmd == 'verify-proof':
        pub = Path(args.pub_path).read_text(encoding='utf-8')
        ok = verify_proof(pub, args.client_id, args.signature)
        raise SystemExit(0 if ok else 1)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
