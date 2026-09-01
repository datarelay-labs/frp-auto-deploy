#!/usr/bin/env python3
"""Canonical server configuration / public-namespace validator.

Public-namespace decisions must use PUBLIC port values. Listen ports may differ
under NAT split. Never silently repairs unsafe configuration.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

_LIB = Path(__file__).resolve().parent
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))

import frp_frontend as FRONTEND  # noqa: E402

_TCP_PORT_RE = re.compile(r'^[0-9]+$')


def require_tcp_port(value, field):
    if value is None or isinstance(value, bool):
        raise ValueError('%s must be a TCP port' % field)
    if isinstance(value, int):
        port = value
    elif isinstance(value, str):
        text = value.strip()
        if not text or not _TCP_PORT_RE.fullmatch(text):
            raise ValueError('%s must be a TCP port' % field)
        port = int(text)
    else:
        raise ValueError('%s must be a TCP port' % field)
    if not 1 <= port <= 65535:
        raise ValueError('%s must be a TCP port' % field)
    return port


def _optional_port(cfg, *keys):
    for key in keys:
        if key in cfg and cfg.get(key) is not None and str(cfg.get(key)).strip() != '':
            return require_tcp_port(cfg.get(key), key)
    return None


def _required_port(cfg, *keys, field=None):
    for key in keys:
        if key in cfg and cfg.get(key) is not None and str(cfg.get(key)).strip() != '':
            return require_tcp_port(cfg.get(key), field or key)
    raise ValueError('%s is required' % (field or keys[0]))


def normalize_mode_and_transport(cfg):
    raw_mode = cfg.get('deployment_mode')
    if raw_mode is None or (isinstance(raw_mode, str) and not str(raw_mode).strip()):
        mode = 'direct'
    else:
        mode = FRONTEND.normalize_deployment_mode(raw_mode)
    transport = FRONTEND.normalize_transport(cfg.get('frp_transport'), mode)
    if mode == 'single443' and transport != 'wss':
        raise ValueError('single443 requires frp_transport=wss')
    if mode == 'direct' and transport == 'wss':
        # Allowed only if explicitly configured; installer may warn, but keep
        # canonical validator focused on port/namespace safety unless contradictory.
        pass
    return mode, transport


def extract_ports(cfg):
    """Return normalized port roles from a server config object."""
    if not isinstance(cfg, dict):
        raise ValueError('server config is not an object')
    mode, transport = normalize_mode_and_transport(cfg)
    port_start = _required_port(cfg, 'port_start')
    port_end = _required_port(cfg, 'port_end')
    control_listen = _optional_port(
        cfg, 'frp_control_listen_port', 'control_listen_port', 'control_port'
    )
    control_public = _optional_port(
        cfg, 'frp_control_public_port', 'control_port'
    )
    allocator_listen = _optional_port(
        cfg, 'allocator_listen_port', 'listen_port'
    )
    allocator_public = _optional_port(
        cfg, 'allocator_public_port', 'listen_port'
    )
    frontend_public = _optional_port(
        cfg, 'frontend_public_port', 'single443_frontend_port'
    )
    if mode == 'single443':
        if frontend_public is None:
            frontend_public = 443
        if control_public is None:
            control_public = frontend_public
        if allocator_public is None:
            allocator_public = frontend_public
        if control_listen is None:
            control_listen = FRONTEND.DEFAULT_BACKEND_CONTROL_PORT
        if allocator_listen is None:
            allocator_listen = FRONTEND.DEFAULT_ALLOCATOR_LISTEN_PORT
    else:
        if control_listen is None and control_public is not None:
            control_listen = control_public
        if control_public is None and control_listen is not None:
            control_public = control_listen
        if allocator_listen is None and allocator_public is not None:
            allocator_listen = allocator_public
        if allocator_public is None and allocator_listen is not None:
            allocator_public = allocator_listen
    plugin_listen = _optional_port(cfg, 'frp_plugin_listen_port')
    if plugin_listen is None and cfg.get('data_plane_auth_strict', True) is not False:
        plugin_listen = 6100
    plugin_host = str(cfg.get('frp_plugin_listen_host') or '127.0.0.1').strip()
    if plugin_host not in ('127.0.0.1', '::1', 'localhost'):
        raise ValueError('frp_plugin_listen_host must be loopback-only')
    return {
        'deployment_mode': mode,
        'frp_transport': transport,
        'port_start': port_start,
        'port_end': port_end,
        'frp_control_listen_port': control_listen,
        'frp_control_public_port': control_public,
        'allocator_listen_port': allocator_listen,
        'allocator_public_port': allocator_public,
        'frontend_public_port': frontend_public,
        'frp_plugin_listen_port': plugin_listen,
        'frp_plugin_listen_host': plugin_host,
    }


def _in_service_range(port, start, end):
    return port is not None and start <= port <= end


def validate_server_config(cfg):
    """Fail closed on unsafe persisted/candidate server configuration."""
    ports = extract_ports(cfg)
    mode = ports['deployment_mode']
    start = ports['port_start']
    end = ports['port_end']
    if start > end:
        raise ValueError('service port_start must be <= port_end')

    control_listen = ports['frp_control_listen_port']
    control_public = ports['frp_control_public_port']
    allocator_listen = ports['allocator_listen_port']
    allocator_public = ports['allocator_public_port']
    frontend_public = ports['frontend_public_port']
    plugin_listen = ports.get('frp_plugin_listen_port')

    if control_listen is None:
        raise ValueError('frp control listen port is required')
    if control_public is None:
        raise ValueError('frp control public port is required')
    if allocator_listen is None:
        raise ValueError('allocator listen port is required')
    if allocator_public is None:
        raise ValueError('allocator public port is required')

    if control_listen == allocator_listen:
        raise ValueError('frp control listen port collides with allocator listen port')

    if plugin_listen is not None:
        if plugin_listen == control_listen or plugin_listen == allocator_listen:
            raise ValueError('frp plugin listen port collides with internal service ports')
        for label, port in (
            ('frp plugin listen port', plugin_listen),
        ):
            if _in_service_range(port, start, end):
                raise ValueError('%s collides with service port range' % label)

    for label, port in (
        ('allocator listen port', allocator_listen),
        ('frp control listen port', control_listen),
    ):
        if _in_service_range(port, start, end):
            raise ValueError('%s collides with service port range' % label)

    # Public namespace decisions use PUBLIC values.
    for label, port in (
        ('frp control public port', control_public),
        ('allocator public port', allocator_public),
    ):
        if _in_service_range(port, start, end):
            raise ValueError('%s collides with service port range' % label)

    if mode == 'single443':
        if frontend_public is None:
            raise ValueError('single443 frontend public port is required')
        if frontend_public != 443 and 'frontend_public_port' not in cfg and 'single443_frontend_port' not in cfg:
            # Explicit non-443 is allowed only when configured; default remains 443.
            pass
        if control_public != allocator_public:
            raise ValueError('single443 control public port must equal allocator public port')
        if control_public != frontend_public:
            raise ValueError('single443 public ports must share the frontend public port')
        if control_listen == frontend_public or allocator_listen == frontend_public:
            raise ValueError('single443 internal backend ports must remain distinct from frontend public port')
        if _in_service_range(control_listen, start, end) or _in_service_range(allocator_listen, start, end):
            raise ValueError('single443 internal backend ports collide with service port range')
        if control_listen == allocator_listen:
            raise ValueError('single443 internal allocator and FRP backends must remain separate')
    else:
        # Direct mode: public ports must not collide with the service range
        # (already checked). Accidental public overlap with each other is a
        # hard error for allocator/restore/doctor — install may warn, but
        # runtime must not start with an ambiguous public namespace.
        if control_public == allocator_public:
            raise ValueError('direct mode control and allocator public ports must not collide')

    return ports
