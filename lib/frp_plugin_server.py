#!/usr/bin/env python3
"""Localhost-only FRP server plugin HTTP listener."""
from __future__ import annotations

import importlib.util
import json
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

_LIB = Path(__file__).resolve().parent
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))

import frp_data_plane_auth as DPA  # noqa: E402


def _load_audit():
    path = _LIB / 'frp_audit.py'
    if not path.is_file():
        return None
    spec = importlib.util.spec_from_file_location('frp_audit', str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PluginContext:
    def __init__(self, registry_loader, cfg):
        self.registry_loader = registry_loader
        self.cfg = cfg or {}


def make_handler(ctx):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'frp-auto-deploy-plugin/1.0'
        timeout = 5

        def log_message(self, fmt, *args):
            print('plugin %s - %s' % (self.address_string(), fmt % args), flush=True)

        def do_POST(self):
            parsed = urlparse(self.path)
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > DPA.MAX_PLUGIN_BODY:
                self._send_json(400, DPA._reject('invalid request body length'))
                return
            body = self.rfile.read(length)
            code, payload = DPA.handle_plugin_http(
                'POST',
                parsed.path,
                parsed.query,
                body,
                ctx.registry_loader,
                ctx.cfg,
            )
            if code == 200 and isinstance(payload, dict) and payload.get('reject'):
                audit = _load_audit()
                if audit is not None:
                    try:
                        audit.try_emit(
                            'data_plane.proxy_rejected',
                            details={'reason': str(payload.get('reject_reason') or '')[:120]},
                        )
                    except Exception:
                        pass
            elif code == 200 and isinstance(payload, dict) and not payload.get('reject'):
                audit = _load_audit()
                if audit is not None and os.environ.get('FRP_DATA_PLANE_AUDIT_ALLOW') == '1':
                    try:
                        audit.try_emit('data_plane.proxy_allowed', details={})
                    except Exception:
                        pass
            self._send_json(code, payload)

        def _send_json(self, code, payload):
            body = json.dumps(payload).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass

    return Handler


def systemd_notify_ready():
    """Notify systemd that this Type=notify service is ready (no-op outside systemd)."""
    addr = os.environ.get('NOTIFY_SOCKET')
    if not addr:
        return
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            if addr.startswith('@'):
                sock.connect('\0' + addr[1:])
            else:
                sock.connect(addr)
            sock.sendall(b'READY=1')
        finally:
            sock.close()
    except OSError:
        pass


def start_plugin_server(registry_loader, cfg, host='127.0.0.1', port=6100):
    ctx = PluginContext(registry_loader, cfg)
    server = HTTPServer((host, int(port)), make_handler(ctx))
    thread = threading.Thread(
        target=server.serve_forever,
        name='frp-data-plane-plugin',
        daemon=True,
    )
    thread.start()
    return server, thread


def plugin_listen_from_cfg(cfg):
    host = str((cfg or {}).get('frp_plugin_listen_host') or '127.0.0.1').strip()
    if host not in ('127.0.0.1', '::1', 'localhost'):
        raise ValueError('frp plugin listen host must be loopback-only')
    port = int((cfg or {}).get('frp_plugin_listen_port') or 6100)
    return host, port
