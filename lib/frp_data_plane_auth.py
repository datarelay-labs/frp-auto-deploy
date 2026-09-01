#!/usr/bin/env python3
"""FRP data-plane authorization: domain-separated ECDSA proofs and NewProxy authorizer.

Management request signatures (op=enroll, body-bound) and data-plane proofs
(purpose=frp-data-plane, client-id-bound) are intentionally separate domains.
A revoked management identity remains able to prove data-plane authorization
for existing registry reservations; revoke invalidates management API access
only, not port reservations or the stored public key used here.
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
CREG = _load_creg()


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
    CREG.validate_machine_id(str(client_id))
    MGMT.validate_private_key(key_path)
    return MGMT.sign_message(key_path, proof_message_bytes(client_id))


def verify_proof(pub_pem, client_id, signature_b64):
    try:
        CREG.validate_machine_id(str(client_id))
    except ValueError:
        return False
    try:
        return MGMT.verify_signature(pub_pem, proof_message_bytes(client_id), signature_b64)
    except ValueError:
        return False


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
        client_id = CREG.validate_machine_id(client_id)
        service_id = CREG.require_canonical_service_id(service_id, field='service id')
    except ValueError as exc:
        return False, str(exc)

    try:
        CREG.validate_registry_or_raise(registry_state, cfg)
    except ValueError as exc:
        return False, 'registry is invalid: %s' % exc

    clients = registry_state.get('clients') or {}
    if not isinstance(clients, dict):
        return False, 'registry clients are invalid'

    client = clients.get(client_id)
    if not isinstance(client, dict):
        return False, 'unknown client'

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
    if lease_mod is None:
        lease_mod = _load_leases()
    lease_dir = lease_mod.lease_dir_from_cfg(cfg)
    if not lease_mod.acquire_lease(
        lease_dir,
        client_id=client_id,
        service_id=service_id,
        remote_port=remote_port,
        run_id=run_id,
        ttl_sec=LEASE_TTL_SEC,
    ):
        return False, 'failed to record authorization lease'

    return True, None


def handle_close_proxy(content, cfg=None, lease_mod=None):
    if not isinstance(content, dict):
        return _allow()
    user = content.get('user') if isinstance(content.get('user'), dict) else {}
    proxy_name = str(content.get('proxy_name') or '')
    run_id = str(user.get('run_id') or '').strip()
    if lease_mod is None:
        lease_mod = _load_leases()
    lease_dir = lease_mod.lease_dir_from_cfg(cfg)
    lease_mod.release_leases_for_proxy(lease_dir, proxy_name=proxy_name, run_id=run_id)
    return _allow()


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
    strict = bool((cfg or {}).get('data_plane_auth_strict', True))

    if op == 'CloseProxy':
        return 200, handle_close_proxy(content, cfg=cfg)

    if op != 'NewProxy':
        return 400, _reject('unsupported op')

    if not strict:
        return 200, _allow()

    try:
        registry_state = registry_loader()
    except Exception:
        return 200, _reject('registry unavailable')

    allowed, reason = authorize_new_proxy(content, registry_state, cfg=cfg)
    if not allowed:
        return 200, _reject(reason or 'authorization denied')
    return 200, _allow()


def assert_port_releasable(remote_port, cfg=None, lease_mod=None):
    """Raise ValueError when release must be refused (live proxy or active lease)."""
    if remote_port is None:
        return
    port = int(remote_port)
    state = CREG.passive_port_state(port)
    if state != 'offline':
        raise ValueError(
            'port %s is %s; stop publishing before release' % (port, state)
        )
    if lease_mod is None:
        lease_mod = _load_leases()
    lease_dir = lease_mod.lease_dir_from_cfg(cfg)
    lease_mod.expire_stale(lease_dir)
    if lease_mod.has_active_lease(lease_dir, remote_port=port):
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
