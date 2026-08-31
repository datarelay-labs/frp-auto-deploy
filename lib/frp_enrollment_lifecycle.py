#!/usr/bin/env python3
"""Enrollment retention, purge, and pair-aware cleanup helpers."""
from __future__ import annotations

import fcntl
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_RETENTION_DAYS = 30
MIN_RETENTION_DAYS = 1
MAX_RETENTION_DAYS = 3650
RETENTION_CLEANUP_MIN_INTERVAL = 3600
SECONDS_PER_DAY = 86400

TERMINAL_STATES = frozenset({'expired', 'completed', 'revoked'})
ACTIVE_STATES = frozenset({'pending', 'bound'})

_last_retention_cleanup = 0.0


class EnrollmentLifecycleError(Exception):
    pass


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def parse_epoch(value):
    if value in (None, ''):
        return 0, True
    try:
        return int(value), True
    except (TypeError, ValueError):
        return 0, False


def parse_timestamp(value):
    """Return (epoch, valid). Missing values return (None, True)."""
    if value in (None, ''):
        return None, True
    if isinstance(value, bool):
        return None, False
    if isinstance(value, (int, float)):
        try:
            return int(value), True
        except (TypeError, ValueError):
            return None, False
    text = str(value).strip()
    if not text:
        return None, True
    try:
        return int(text), True
    except ValueError:
        pass
    try:
        if text.endswith('Z'):
            text = text[:-1] + '+00:00'
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp()), True
    except (ValueError, OverflowError, OSError):
        return None, False


def retention_days_from_config(cfg):
    raw = (cfg or {}).get('enrollment_retention_days', DEFAULT_RETENTION_DAYS)
    try:
        days = int(raw)
    except (TypeError, ValueError):
        raise EnrollmentLifecycleError(
            'ERROR: enrollment_retention_days must be an integer between %s and %s'
            % (MIN_RETENTION_DAYS, MAX_RETENTION_DAYS)
        )
    if days < MIN_RETENTION_DAYS or days > MAX_RETENTION_DAYS:
        raise EnrollmentLifecycleError(
            'ERROR: enrollment_retention_days must be an integer between %s and %s'
            % (MIN_RETENTION_DAYS, MAX_RETENTION_DAYS)
        )
    return days


def normalize_state(record, now):
    if not isinstance(record, dict):
        return 'invalid'
    if record.get('revoked_at'):
        return 'revoked'
    if record.get('completed_at'):
        return 'completed'
    if record.get('used_at'):
        return 'completed'
    expires, valid = parse_epoch(record.get('expires_at'))
    if not valid:
        return 'invalid'
    if expires and expires < now:
        return 'expired'
    if record.get('bound_machine_id'):
        return 'bound'
    return 'pending'


def terminal_timestamp(record, state, now):
    """Authoritative terminal timestamp for retention (epoch) or None if unknown."""
    if state not in TERMINAL_STATES:
        return None
    if state == 'expired':
        ts, valid = parse_epoch(record.get('expires_at'))
        if not valid or not ts:
            return None
        return ts
    if state == 'completed':
        for key in ('completed_at', 'used_at'):
            ts, valid = parse_timestamp(record.get(key))
            if not valid:
                return None
            if ts is not None:
                return ts
        return None
    if state == 'revoked':
        ts, valid = parse_timestamp(record.get('revoked_at'))
        if not valid or ts is None:
            return None
        return ts
    return None


def _load_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None


def _pair_states_consistent(ticket_state, enroll_state):
    if ticket_state == 'invalid' or enroll_state == 'invalid':
        return False
    if ticket_state in ACTIVE_STATES and enroll_state in ACTIVE_STATES:
        if ticket_state == 'bound' and enroll_state == 'pending':
            return True
        return ticket_state == enroll_state
    if ticket_state in TERMINAL_STATES and enroll_state in TERMINAL_STATES:
        return ticket_state == enroll_state
    return False


def _validate_zero_touch_pair(ticket_rec, enroll_rec, ticket_path, enroll_path, enrollment_map):
    eid = str(ticket_rec.get('enrollment_id') or '').strip().lower()
    if not eid:
        return 'bootstrap ticket has no enrollment_id'
    duplicates = enrollment_map.get(eid) or []
    if len(duplicates) > 1:
        return 'enrollment is paired to multiple bootstrap tickets'
    if enroll_rec is None:
        return 'bootstrap ticket points to missing enrollment record'
    if not isinstance(enroll_rec, dict):
        return 'paired enrollment record is malformed'
    ticket_eid = str(ticket_rec.get('enrollment_id') or '').strip().lower()
    enroll_id = str(enroll_rec.get('id') or '').strip().lower()
    if ticket_eid != enroll_id:
        return 'bootstrap ticket enrollment_id does not match paired enrollment id'
    now = int(time.time())
    ticket_state = normalize_state(ticket_rec, now)
    enroll_state = normalize_state(enroll_rec, now)
    if not _pair_states_consistent(ticket_state, enroll_state):
        return 'bootstrap ticket and paired enrollment states are inconsistent'
    return None


def collect_logical_enrollments(enrollments_dir, bootstrap_dir, now=None):
    """Return logical enrollment rows (manual + deduplicated zero-touch)."""
    now = int(now if now is not None else time.time())
    enrollments_dir = Path(enrollments_dir)
    bootstrap_dir = Path(bootstrap_dir)

    enrollment_map = {}
    ticket_records = []
    if bootstrap_dir.is_dir():
        for path in bootstrap_dir.glob('*.json'):
            rec = _load_json(path)
            if not isinstance(rec, dict):
                continue
            eid = str(rec.get('enrollment_id') or '').strip().lower()
            if eid:
                enrollment_map.setdefault(eid, []).append(path)
            ticket_records.append((path, rec))

    paired_enrollment_ids = set(enrollment_map)
    rows = []

    for ticket_path, ticket_rec in ticket_records:
        ticket_id = str(ticket_rec.get('id') or ticket_path.stem).strip().lower()
        eid = str(ticket_rec.get('enrollment_id') or '').strip().lower()
        enroll_path = enrollments_dir / (eid + '.json') if eid else None
        enroll_rec = _load_json(enroll_path) if enroll_path and enroll_path.is_file() else None
        pair_error = _validate_zero_touch_pair(
            ticket_rec, enroll_rec, ticket_path, enroll_path, enrollment_map
        )
        state = normalize_state(ticket_rec, now)
        terminal_at = terminal_timestamp(ticket_rec, state, now)
        if state in TERMINAL_STATES and terminal_at is None and not pair_error:
            pair_error = 'terminal zero-touch record has malformed timestamp'
        rows.append({
            'id': ticket_id,
            'type': 'zero-touch',
            'state': state,
            'terminal_at': terminal_at,
            'ticket_path': ticket_path,
            'enroll_path': enroll_path if enroll_path and enroll_path.is_file() else None,
            'ticket_record': ticket_rec,
            'enroll_record': enroll_rec,
            'pair_error': pair_error,
        })

    if enrollments_dir.is_dir():
        for path in enrollments_dir.glob('*.json'):
            rec = _load_json(path)
            if not isinstance(rec, dict):
                continue
            raw_id = str(rec.get('id') or path.stem).strip().lower()
            if not raw_id or raw_id in paired_enrollment_ids:
                continue
            state = normalize_state(rec, now)
            terminal_at = terminal_timestamp(rec, state, now)
            pair_error = None
            if state in TERMINAL_STATES and terminal_at is None:
                pair_error = 'terminal manual enrollment has malformed timestamp'
            rows.append({
                'id': raw_id,
                'type': 'manual',
                'state': state,
                'terminal_at': terminal_at,
                'ticket_path': None,
                'enroll_path': path,
                'ticket_record': None,
                'enroll_record': rec,
                'pair_error': pair_error,
            })

    rows.sort(
        key=lambda row: (
            (row.get('ticket_record') or row.get('enroll_record') or {}).get('created_at', ''),
            row['id'],
        )
    )
    return rows


def is_retention_eligible(row, now, retention_days):
    if row.get('pair_error'):
        return False
    state = row.get('state')
    if state not in TERMINAL_STATES:
        return False
    terminal_at = row.get('terminal_at')
    if terminal_at is None:
        return False
    cutoff = now - (int(retention_days) * SECONDS_PER_DAY)
    return terminal_at <= cutoff


def is_bulk_purge_eligible(row, now, older_than_days):
    if row.get('pair_error'):
        return False
    state = row.get('state')
    if state not in TERMINAL_STATES:
        return False
    terminal_at = row.get('terminal_at')
    if terminal_at is None:
        return False
    cutoff = now - (int(older_than_days) * SECONDS_PER_DAY)
    return terminal_at <= cutoff


def resolve_target(rows, target_id):
    target_id = str(target_id or '').strip().lower()
    matches = [row for row in rows if row['id'] == target_id]
    if matches:
        return matches[0]
    for row in rows:
        enroll_rec = row.get('enroll_record') or {}
        if str(enroll_rec.get('id') or '').strip().lower() == target_id:
            return row
    return None


def _stage_delete(path):
    if path is None or not Path(path).is_file():
        return None
    path = Path(path)
    staged = path.with_suffix(path.suffix + '.purging')
    os.replace(path, staged)
    return staged


def _commit_staged_deletes(staged_paths):
    errors = []
    for staged in staged_paths:
        if staged is None:
            continue
        try:
            Path(staged).unlink(missing_ok=True)
        except OSError as exc:
            errors.append('%s: %s' % (staged, exc))
    return errors


def _rollback_staged(staged_paths):
    for staged in staged_paths:
        if staged is None:
            continue
        staged = Path(staged)
        if not staged.is_file():
            continue
        original = Path(str(staged)[:-len('.purging')] if str(staged).endswith('.purging') else staged)
        if str(staged).endswith('.json.purging'):
            original = Path(str(staged)[:-len('.purging')])
        try:
            os.replace(staged, original)
        except OSError:
            pass


def _delete_targets(row):
    """Two-phase tombstone purge.

    Phase 1 (commit): rename every target out of the active namespace (``.purging``).
    If any rename fails, restore all staged paths and raise — never leave a
    ticket-only or enrollment-only active pair.

    Phase 2 (cleanup): unlink tombstones. Failures here are OK when both
    originals are absent from the active namespace (retryable leftover ``.purging``).
    """
    staged = []
    targets = []
    if row.get('enroll_path'):
        targets.append(Path(row['enroll_path']))
    if row.get('ticket_path'):
        targets.append(Path(row['ticket_path']))
    try:
        for path in targets:
            if path.is_symlink():
                raise EnrollmentLifecycleError(
                    'ERROR: refusing to purge through a symlink: %s' % path
                )
            if path.is_file():
                staged.append(_stage_delete(path))
            elif path.exists():
                raise EnrollmentLifecycleError(
                    'ERROR: purge target is not a regular file: %s' % path
                )
    except Exception:
        _rollback_staged([item for item in staged if item is not None])
        raise
    # Both (existing) targets are now out of the active namespace.
    _commit_staged_deletes([item for item in staged if item is not None])
    leftovers = [str(path) for path in targets if path.is_file()]
    if leftovers:
        raise EnrollmentLifecycleError(
            'ERROR: purge left active enrollment artifact(s): %s' % '; '.join(leftovers)
        )


def _registry_lock(registry_file):
    registry_file = Path(registry_file)
    lock_path = registry_file.parent / 'registry.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    return lock_fd


def _release_lock(lock_fd):
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        os.close(lock_fd)


def purge_enrollment_row(row, *, audit_emit=None, reason='manual', retention_days=None):
    state = row.get('state')
    if state in ACTIVE_STATES:
        raise EnrollmentLifecycleError(
            'ERROR: active enrollment cannot be purged.\n'
            'Revoke it first:\n'
            '  revoke enrollment %s' % row.get('id')
        )
    if state not in TERMINAL_STATES:
        raise EnrollmentLifecycleError('ERROR: enrollment is not in a terminal state')
    if row.get('pair_error'):
        raise EnrollmentLifecycleError('ERROR: %s' % row['pair_error'])
    _delete_targets(row)
    if audit_emit:
        details = {
            'enrollment_id': row.get('id'),
            'type': row.get('type'),
            'previous_state': state,
            'reason': reason,
        }
        if retention_days is not None:
            details['retention_days'] = int(retention_days)
        audit_emit('enrollment.purged', details=details)


def purge_enrollment_by_id(
    target_id,
    enrollments_dir,
    bootstrap_dir,
    registry_file,
    *,
    audit_emit=None,
    now=None,
):
    now = int(now if now is not None else time.time())
    rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
    row = resolve_target(rows, target_id)
    if row is None:
        raise EnrollmentLifecycleError('ERROR: enrollment not found')
    lock_fd = _registry_lock(registry_file)
    try:
        rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
        row = resolve_target(rows, target_id)
        if row is None:
            raise EnrollmentLifecycleError('ERROR: enrollment not found')
        purge_enrollment_row(row, audit_emit=audit_emit, reason='manual')
    finally:
        _release_lock(lock_fd)
    return row


def preview_bulk_purge(enrollments_dir, bootstrap_dir, older_than_days, now=None):
    now = int(now if now is not None else time.time())
    try:
        days = int(older_than_days)
    except (TypeError, ValueError):
        raise EnrollmentLifecycleError('ERROR: --older-than requires a positive integer number of days')
    if days < 1:
        raise EnrollmentLifecycleError('ERROR: --older-than requires a positive integer number of days')
    rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
    matched = [row for row in rows if is_bulk_purge_eligible(row, now, days)]
    counts = {'expired': 0, 'completed': 0, 'revoked': 0}
    for row in matched:
        state = row.get('state')
        if state in counts:
            counts[state] += 1
    return {
        'older_than_days': days,
        'matched': matched,
        'counts': counts,
        'total': len(matched),
    }


def bulk_purge_enrollments(
    enrollments_dir,
    bootstrap_dir,
    registry_file,
    older_than_days,
    *,
    audit_emit=None,
    now=None,
):
    preview = preview_bulk_purge(enrollments_dir, bootstrap_dir, older_than_days, now=now)
    now = int(now if now is not None else time.time())
    lock_fd = _registry_lock(registry_file)
    purged = 0
    try:
        rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
        matched = [row for row in rows if is_bulk_purge_eligible(row, now, preview['older_than_days'])]
        for row in matched:
            purge_enrollment_row(
                row,
                audit_emit=audit_emit,
                reason='manual',
                retention_days=preview['older_than_days'],
            )
            purged += 1
    finally:
        _release_lock(lock_fd)
    return purged, preview


def run_retention_cleanup(
    enrollments_dir,
    bootstrap_dir,
    registry_file,
    retention_days,
    *,
    audit_emit=None,
    now=None,
):
    now = int(now if now is not None else time.time())
    rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
    eligible = [row for row in rows if is_retention_eligible(row, now, retention_days)]
    if not eligible:
        return {'purged': 0, 'skipped_pairs': 0}
    lock_fd = _registry_lock(registry_file)
    purged = 0
    try:
        rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
        eligible = [row for row in rows if is_retention_eligible(row, now, retention_days)]
        for row in eligible:
            purge_enrollment_row(
                row,
                audit_emit=audit_emit,
                reason='retention',
                retention_days=retention_days,
            )
            purged += 1
    finally:
        _release_lock(lock_fd)
    return {'purged': purged}



def reap_purging_tombstones(enrollments_dir, bootstrap_dir):
    """Remove orphan ``*.json.purging`` leftovers after a failed phase-2 unlink.

    Conservative rules (fail closed on ambiguity):
    - only delete paths ending in ``.json.purging``
    - skip symlinks
    - never delete when the corresponding active ``*.json`` still exists
    - never resurrect tombstones
    """
    removed = 0
    for directory in (enrollments_dir, bootstrap_dir):
        root = Path(directory or '')
        if not root.is_dir():
            continue
        try:
            candidates = list(root.iterdir())
        except OSError:
            continue
        for path in candidates:
            name = path.name
            if not name.endswith('.json.purging'):
                continue
            if path.is_symlink():
                continue
            if not path.is_file():
                continue
            original = Path(str(path)[:-len('.purging')])
            if original.exists() or original.is_symlink():
                # Ambiguous: active object and tombstone both present — leave alone.
                continue
            try:
                path.unlink()
                removed += 1
            except OSError:
                continue
    return removed


def maybe_run_retention_cleanup(
    cfg,
    *,
    force=False,
    audit_emit=None,
    now=None,
):
    global _last_retention_cleanup
    now_ts = time.time()
    if not force and now_ts - _last_retention_cleanup < RETENTION_CLEANUP_MIN_INTERVAL:
        return {'skipped': True, 'purged': 0}
    retention_days = retention_days_from_config(cfg)
    enrollments_dir = cfg.get('enrollments_dir')
    bootstrap_dir = cfg.get('bootstrap_dir') or str(Path(enrollments_dir).parent / 'bootstrap')
    registry_file = cfg.get('registry_file') or str(Path(enrollments_dir).parent / 'registry.json')
    result = run_retention_cleanup(
        enrollments_dir,
        bootstrap_dir,
        registry_file,
        retention_days,
        audit_emit=audit_emit,
        now=now,
    )
    result['tombstones_reaped'] = reap_purging_tombstones(enrollments_dir, bootstrap_dir)
    _last_retention_cleanup = now_ts
    result['skipped'] = False
    return result


def load_audit_emit():
    try:
        import importlib.util
        here = Path(__file__).resolve()
        for path in (
            here.parent / 'frp_audit.py',
            Path('/usr/local/lib/frp-auto-deploy/frp_audit.py'),
        ):
            if path.is_file():
                spec = importlib.util.spec_from_file_location('frp_audit', str(path))
                audit = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(audit)
                return audit.try_emit
    except Exception:
        pass
    return None


def doctor_scan_enrollment_lifecycle(enrollments_dir, bootstrap_dir, retention_days, now=None):
    """Read-only lifecycle diagnostics for doctor."""
    now = int(now if now is not None else time.time())
    findings = []
    rows = collect_logical_enrollments(enrollments_dir, bootstrap_dir, now)
    cutoff = now - (int(retention_days) * SECONDS_PER_DAY)

    enrollment_map = {}
    if Path(bootstrap_dir).is_dir():
        for path in Path(bootstrap_dir).glob('*.json'):
            rec = _load_json(path)
            if not isinstance(rec, dict):
                findings.append(('orphan_bootstrap_ticket', str(path.name), 'malformed bootstrap ticket JSON'))
                continue
            eid = str(rec.get('enrollment_id') or '').strip().lower()
            if eid:
                enrollment_map.setdefault(eid, []).append(str(path.name))

    for eid, tickets in enrollment_map.items():
        if len(tickets) > 1:
            findings.append(('duplicate_pairing', eid, 'enrollment paired to multiple tickets: %s' % ', '.join(tickets)))

    if Path(enrollments_dir).is_dir():
        for path in Path(enrollments_dir).glob('*.json'):
            rec = _load_json(path)
            if not isinstance(rec, dict):
                findings.append(('malformed_enrollment', str(path.name), 'malformed enrollment JSON'))
                continue
            eid = str(rec.get('id') or path.stem).strip().lower()
            if eid not in enrollment_map:
                continue
            ticket_names = enrollment_map.get(eid) or []
            if not ticket_names:
                findings.append(('orphan_paired_enrollment', eid, 'paired enrollment without bootstrap ticket'))

    for row in rows:
        if row.get('pair_error'):
            findings.append(('invalid_pairing', row['id'], row['pair_error']))
        state = row.get('state')
        if state in TERMINAL_STATES and row.get('terminal_at') is None and not row.get('pair_error'):
            findings.append(('malformed_terminal_timestamp', row['id'], 'terminal record lacks valid timestamp'))
        if is_retention_eligible(row, now, retention_days):
            findings.append((
                'retention_overdue',
                row['id'],
                'terminal record exceeded retention (%s days) but was not purged' % retention_days,
            ))

    return findings
