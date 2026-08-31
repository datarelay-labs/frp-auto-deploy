#!/usr/bin/env python3
"""Server-relative management time helpers for clock-skew tolerant clients."""
from __future__ import annotations

import json
import sys
import time

MAX_OFFSET_SEC = 86400 * 366
WARN_OFFSET_SEC = 300
MIN_WRITE_DELTA_SEC = 2


def validate_offset(value):
    if value is None:
        return None
    try:
        offset = int(value)
    except (TypeError, ValueError):
        return None
    if abs(offset) > MAX_OFFSET_SEC:
        return None
    return offset


def compute_timestamp(offset=None, now=None):
    now = int(now if now is not None else time.time())
    offset = validate_offset(offset)
    if offset is None:
        return now
    return now + offset


def offset_from_server_time(server_time, local_time=None):
    local_time = int(local_time if local_time is not None else time.time())
    try:
        server_time = int(server_time)
    except (TypeError, ValueError):
        return None
    return validate_offset(server_time - local_time)


def should_warn_offset(offset):
    offset = validate_offset(offset)
    return offset is not None and abs(offset) > WARN_OFFSET_SEC


def format_skew_warning(offset):
    offset = validate_offset(offset)
    if offset is None:
        return ''
    minutes = abs(offset) // 60
    if minutes >= 60:
        approx = '%s hour(s)' % (abs(offset) // 3600)
    else:
        approx = '%s minute(s)' % max(1, minutes)
    direction = 'ahead of' if offset > 0 else 'behind'
    return (
        'WARNING: Local system clock differs from the FRP server by approximately %s.\n'
        'The local clock is %s the server.\n'
        'FRP management requests will use server-relative time.\n'
        'The operating-system clock was not changed.'
    ) % (approx, direction)


def load_offset_from_state(path):
    try:
        data = json.loads(open(path, encoding='utf-8').read())
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    if not isinstance(data, dict):
        return None
    if 'management_time_offset_sec' not in data:
        return None
    return validate_offset(data.get('management_time_offset_sec'))


def merge_offset_into_state(state_path, offset, force=False):
    offset = validate_offset(offset)
    if offset is None:
        return False
    try:
        data = json.loads(open(state_path, encoding='utf-8').read())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False
    current = validate_offset(data.get('management_time_offset_sec'))
    if not force and current is not None and abs(current - offset) <= MIN_WRITE_DELTA_SEC:
        return False
    data['management_time_offset_sec'] = offset
    payload = json.dumps(data, indent=2, sort_keys=True) + '\n'
    tmp = state_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as handle:
        handle.write(payload)
        handle.flush()
    import os
    os.chmod(tmp, 0o600)
    os.replace(tmp, state_path)
    return True


def refresh_offset_from_server_time(server_time, state_path=None, current_offset=None):
    local_now = int(time.time())
    new_offset = offset_from_server_time(server_time, local_now)
    if new_offset is None:
        return None
    if state_path:
        merge_offset_into_state(state_path, new_offset)
    return new_offset


def is_clock_skew_error(message):
    text = str(message or '').lower()
    return 'timestamp outside allowed window' in text or 'invalid timestamp' in text


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        raise SystemExit(2)
    cmd = argv[0]
    if cmd == 'timestamp':
        offset = validate_offset(argv[1]) if len(argv) > 1 and argv[1] not in ('', 'null', 'None') else None
        print(compute_timestamp(offset))
        return 0
    if cmd == 'offset-from-server':
        print(offset_from_server_time(argv[1], argv[2] if len(argv) > 2 else None))
        return 0
    if cmd == 'warn':
        offset = validate_offset(argv[1]) if len(argv) > 1 else None
        text = format_skew_warning(offset)
        if text:
            print(text)
        return 0
    if cmd == 'load-offset':
        print(load_offset_from_state(argv[1]) if len(argv) > 1 else '')
        return 0
    if cmd == 'merge-offset':
        ok = merge_offset_into_state(argv[1], validate_offset(argv[2]), force='--force' in argv[3:])
        print('ok' if ok else 'skip')
        return 0
    if cmd == 'is-clock-skew-error':
        print('yes' if is_clock_skew_error(argv[1] if len(argv) > 1 else '') else 'no')
        return 0
    raise SystemExit(2)


if __name__ == '__main__':
    raise SystemExit(main())
