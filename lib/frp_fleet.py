#!/usr/bin/env python3
"""Server fleet visibility: overview, port inventory, filters."""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import frp_client_registry as CREG
except ImportError:
    CREG = None


def _root():
    return os.environ.get('FRP_DEPLOY_TEST_ROOT') or os.environ.get('FRP_CTL_TEST_ROOT') or ''


def _path(rel):
    base = _root()
    p = rel if rel.startswith('/') else '/' + rel
    return Path(base + p) if base else Path(p)


def load_context():
    if CREG is None:
        raise RuntimeError('frp_client_registry unavailable')
    cfg, reg_path, state = CREG.load_server_registry(_root() or None)
    return cfg, reg_path, state


def stale_seconds(cfg):
    days = cfg.get('client_stale_days', 30)
    try:
        days = int(days)
    except (TypeError, ValueError):
        days = 30
    if days < 1:
        days = 30
    return days * 86400


def used_ports(state):
    used = set()
    for item in state.get('reserved') or []:
        try:
            used.add(int(item))
        except (TypeError, ValueError):
            continue
    for client in (state.get('clients') or {}).values():
        if not isinstance(client, dict):
            continue
        for svc in (client.get('services') or {}).values():
            if not isinstance(svc, dict):
                continue
            port = svc.get('remote_port')
            if port is not None:
                try:
                    used.add(int(port))
                except (TypeError, ValueError):
                    pass
    return used


def port_range(cfg):
    start = int(cfg.get('port_start', 6000))
    end = int(cfg.get('port_end', 6098))
    return start, end


def enrollment_counts(cfg):
    now = int(time.time())
    counts = {'pending': 0, 'bound': 0, 'completed': 0, 'expired': 0, 'revoked': 0}
    root = _root()
    enroll_dir = Path(str(cfg.get('enrollments_dir') or ''))
    bootstrap_dir = Path(str(cfg.get('bootstrap_dir') or ''))
    if root:
        if not str(enroll_dir).startswith(root):
            enroll_dir = Path(root + str(enroll_dir))
        if not str(bootstrap_dir).startswith(root):
            bootstrap_dir = Path(root + str(bootstrap_dir))
    seen_ticket_enrollment = set()

    def norm_state(rec):
        if rec.get('revoked_at'):
            return 'revoked'
        if rec.get('completed_at') or rec.get('used_at'):
            return 'completed'
        try:
            exp = int(rec.get('expires_at') or 0)
        except (TypeError, ValueError):
            return 'invalid'
        if exp and exp < now:
            return 'expired'
        if rec.get('bound_machine_id'):
            return 'bound'
        return 'pending'

    if bootstrap_dir.is_dir():
        for path in bootstrap_dir.glob('*.json'):
            try:
                rec = json.loads(path.read_text(encoding='utf-8'))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(rec, dict):
                continue
            eid = str(rec.get('enrollment_id') or '')
            if eid:
                seen_ticket_enrollment.add(eid)
            st = norm_state(rec)
            if st in counts:
                counts[st] += 1
    if enroll_dir.is_dir():
        for path in enroll_dir.glob('*.json'):
            try:
                rec = json.loads(path.read_text(encoding='utf-8'))
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(rec, dict):
                continue
            eid = str(rec.get('id') or '')
            if eid and eid in seen_ticket_enrollment:
                continue
            st = norm_state(rec)
            if st in counts:
                counts[st] += 1
    return counts


def server_health_summary(cfg, state):
    """Lightweight health labels for fleet overview (local checks only)."""
    import subprocess

    out = {}
    try:
        from frp_doctor import PASS, WARN, FAIL, validate_registry
        status, msg, issues = validate_registry(state, cfg)
        if status == PASS:
            out['registry'] = 'PASS'
        elif status == WARN:
            out['registry'] = 'WARN'
        else:
            detail = msg or ''
            if issues:
                detail = '%s: %s' % (detail, issues[0]) if detail else str(issues[0])
            if 'corrupt' in detail.lower() or 'canonical' in detail.lower() or 'invalid' in detail.lower():
                out['registry'] = 'CORRUPT'
            else:
                out['registry'] = 'FAIL'
            if detail:
                out['registry_detail'] = detail[:200]
    except Exception:
        out['registry'] = 'FAIL'

    def unit_label(unit, unit_file):
        if not _path(unit_file).is_file():
            return 'SKIP'
        if os.environ.get('FRP_SKIP_SYSTEMD') == '1' or _root():
            hook = os.environ.get(
                'FRP_SERVER_LIFECYCLE_UNIT_%s' % unit.upper().replace('-', '_')
            )
            if hook == 'active':
                return 'PASS'
            if hook == 'inactive':
                return 'WARN'
            # Unit file present but activity not verified in test mode.
            return 'Configured'
        try:
            proc = subprocess.run(
                ['systemctl', 'is-active', unit],
                capture_output=True,
                text=True,
                timeout=3,
            )
            state_txt = (proc.stdout or proc.stderr or '').strip()
            if state_txt == 'active':
                return 'PASS'
            return 'WARN'
        except Exception:
            return 'Configured'

    out['frps'] = unit_label('frps', '/etc/systemd/system/frps.service')
    out['allocator'] = unit_label(
        'frp-port-allocator', '/etc/systemd/system/frp-port-allocator.service'
    )
    mode_raw = cfg.get('deployment_mode')
    try:
        from frp_frontend import normalize_deployment_mode
        if mode_raw is None or (isinstance(mode_raw, str) and not str(mode_raw).strip()):
            mode = 'direct'
        else:
            mode = normalize_deployment_mode(mode_raw)
    except Exception:
        mode = 'INVALID'
    if mode == 'single443':
        out['frontend'] = unit_label(
            'frp-frontend', '/etc/systemd/system/frp-frontend.service'
        )
    elif mode not in ('direct', 'single443'):
        out['deployment_mode'] = 'FAIL'
    cert = cfg.get('tls_server_cert') or ''
    cert_path = _path(cert) if str(cert).startswith('/') else Path(cert)
    if cert and cert_path.is_file():
        out['TLS'] = 'PASS'
    elif cert:
        out['TLS'] = 'WARN'
    else:
        out['TLS'] = 'SKIP'
    return out


def group_summary_counts(state):
    """Count persisted manual/dynamic groups and ungrouped clients.

    System views ``all`` / ``ungrouped`` are virtual and must not inflate the
    manual group count.
    """
    groups = CREG.ensure_groups_map(state)
    manual = 0
    dynamic = 0
    for _gid, group in groups.items():
        if not isinstance(group, dict):
            continue
        try:
            gtype = CREG.group_record_type(group)
        except ValueError:
            continue
        if gtype == 'manual':
            manual += 1
        elif gtype == 'dynamic':
            dynamic += 1
    ungrouped = 0
    for _mid, client in (state.get('clients') or {}).items():
        if not isinstance(client, dict):
            continue
        try:
            if CREG.client_is_ungrouped(state, client):
                ungrouped += 1
        except ValueError:
            # Corrupt membership must not inflate ungrouped counts.
            continue
    return {'manual': manual, 'dynamic': dynamic, 'ungrouped': ungrouped}


def fleet_summary():
    cfg, _reg_path, state = load_context()
    clients = state.get('clients') or {}
    stale_sec = stale_seconds(cfg)
    expected = CREG.load_server_version_metadata(_root())

    mgmt_recent = mgmt_stale = mgmt_unknown = revoked = 0
    build_current = build_drift = build_unknown = 0
    services_total = services_enabled = services_disabled = 0

    for _mid, client in clients.items():
        if not isinstance(client, dict):
            continue
        act = CREG.mgmt_activity_class(client, stale_sec)
        if act == 'revoked':
            revoked += 1
        elif act == 'recent':
            mgmt_recent += 1
        elif act == 'stale':
            mgmt_stale += 1
        else:
            mgmt_unknown += 1
        drift = CREG.build_drift_class(client, expected)
        if drift == 'current':
            build_current += 1
        elif drift == 'drift':
            build_drift += 1
        else:
            build_unknown += 1
        for svc in (client.get('services') or {}).values():
            if not isinstance(svc, dict):
                continue
            services_total += 1
            if svc.get('enabled', True) is False:
                services_disabled += 1
            else:
                services_enabled += 1

    start, end = port_range(cfg)
    total_ports = max(0, end - start + 1)
    allocated = len(used_ports(state))
    available = max(0, total_ports - allocated)
    enroll = enrollment_counts(cfg)
    health = server_health_summary(cfg, state)
    groups = group_summary_counts(state)

    lines = ['FRP Fleet Overview', '==================', '']
    lines.extend([
        'Clients',
        '  Total                 %d' % len(clients),
        '  Mgmt recent           %d' % mgmt_recent,
        '  Mgmt stale            %d' % mgmt_stale,
        '  Mgmt unknown          %d' % mgmt_unknown,
        '  Revoked               %d' % revoked,
        '',
        'Groups',
        '  Manual                %d' % groups['manual'],
        '  Dynamic               %d' % groups['dynamic'],
        '  Ungrouped             %d' % groups['ungrouped'],
        '',
        'Services',
        '  Total                 %d' % services_total,
        '  Enabled               %d' % services_enabled,
        '  Disabled              %d' % services_disabled,
        '',
        'Ports',
        '  Allocated             %d / %d' % (allocated, total_ports),
        '  Available             %d' % available,
        '',
        'Build',
        '  Current               %d' % build_current,
        '  Drift                 %d' % build_drift,
        '  Unknown               %d' % build_unknown,
        '',
        'Enrollments',
        '  Pending               %d' % enroll.get('pending', 0),
        '  Bound                 %d' % enroll.get('bound', 0),
        '  Completed             %d' % enroll.get('completed', 0),
        '  Expired               %d' % enroll.get('expired', 0),
        '',
        'Server Health',
    ])
    for label, st in health.items():
        lines.append('  %-20s %s' % (label, st))
    lines.append('')
    lines.append('Note: Mgmt recent/stale reflects last authenticated management')
    lines.append('communication (LAST MGMT SEEN), not FRP tunnel activity.')
    lines.append('Note: Manual/Dynamic counts are persisted groups only;')
    lines.append('system views all/ungrouped are not counted as manual groups.')
    return '\n'.join(lines) + '\n'


def port_inventory(filters=None):
    filters = filters or {}
    cfg, _reg_path, state = load_context()
    start, end = port_range(cfg)
    total = max(0, end - start + 1)
    used = used_ports(state)
    available = max(0, total - len(used))

    port_map = {}
    for mid, client in (state.get('clients') or {}).items():
        if not isinstance(client, dict):
            continue
        short = CREG.unique_short_id(mid, list((state.get('clients') or {}).keys()))
        for sid, svc in (client.get('services') or {}).items():
            if not isinstance(svc, dict):
                continue
            port = svc.get('remote_port')
            if port is None:
                continue
            try:
                port = int(port)
            except (TypeError, ValueError):
                continue
            enabled = svc.get('enabled', True) is not False
            state_label = 'reserved' if not enabled else 'reserved'
            port_map[port] = {
                'port': port,
                'client_id': short,
                'machine_id': mid,
                'service': sid,
                'state': state_label,
                'enabled': enabled,
            }

    lines = [
        'Public Port Inventory',
        '=====================',
        '',
        'Range       : %d-%d' % (start, end),
        'Total       : %d' % total,
        'Allocated   : %d' % len(used),
        'Available   : %d' % available,
        '',
    ]

    client_filter = str(filters.get('client') or '').strip().lower()
    want_free = bool(filters.get('free'))
    want_reserved = bool(filters.get('reserved'))

    rows = []
    for port in sorted(used):
        info = port_map.get(port)
        if info:
            if client_filter:
                cid = str(info.get('client_id') or '').lower()
                mid = str(info.get('machine_id') or '').lower()
                if not (cid.startswith(client_filter) or mid.startswith(client_filter) or client_filter in cid):
                    continue
            if want_free:
                continue
            label = 'reserved' if not info.get('enabled') else 'reserved'
            rows.append((port, info.get('client_id') or '-', info.get('service') or '-', label))
        else:
            rows.append((port, '(reserved)', '-', 'reserved'))

    if want_free or (not rows and not want_reserved):
        for port in range(start, end + 1):
            if port in used:
                continue
            if client_filter or want_reserved:
                continue
            rows.append((port, '-', '-', 'free'))

    if rows:
        lines.append('PORT    CLIENT ID   SERVICE      STATE')
        for port, cid, svc, st in rows:
            if want_reserved and st == 'free':
                continue
            if want_free and st != 'free':
                continue
            lines.append('%-7s %-11s %-12s %s' % (port, str(cid)[:11], str(svc)[:12], st))
    return '\n'.join(lines) + '\n'


def filter_clients(state, cfg, stale_only=False, last_mgmt_before=None, build_drift_only=False):
    stale_sec = stale_seconds(cfg)
    if last_mgmt_before is not None:
        stale_sec = last_mgmt_before
    expected = CREG.load_server_version_metadata(_root())
    out = []
    for mid, client in CREG.sorted_clients(state):
        if stale_only or last_mgmt_before is not None:
            act = CREG.mgmt_activity_class(client, stale_sec)
            if act != 'stale':
                continue
        if build_drift_only:
            if CREG.build_drift_class(client, expected) != 'drift':
                continue
        out.append((mid, client))
    return out


def main(argv=None):
    import sys
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else 'fleet'
    if cmd == 'fleet':
        print(fleet_summary(), end='')
        return 0
    if cmd == 'ports':
        filters = {}
        i = 1
        while i < len(argv):
            if argv[i] == '--client' and i + 1 < len(argv):
                filters['client'] = argv[i + 1]
                i += 2
            elif argv[i] == '--free':
                filters['free'] = True
                i += 1
            elif argv[i] == '--reserved':
                filters['reserved'] = True
                i += 1
            else:
                raise SystemExit('ERROR: unknown ports option: %s' % argv[i])
        print(port_inventory(filters), end='')
        return 0
    raise SystemExit('usage: frp_fleet.py fleet|ports')


if __name__ == '__main__':
    raise SystemExit(main())
