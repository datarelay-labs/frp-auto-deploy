#!/usr/bin/env python3
"""Append-only structured audit log for frp-auto-deploy.

Audit failures must not corrupt the primary operation. Callers should treat
write errors as warnings unless they explicitly choose fail-closed.
"""
from __future__ import annotations

import json
import os
import re
import stat
from datetime import datetime, timezone
from pathlib import Path

AUDIT_SCHEMA = 1
DEFAULT_AUDIT_PATH = "/var/log/frp-auto-deploy/audit.jsonl"
MAX_RECORD_BYTES = 16_384
SECRET_KEY_RE = re.compile(
    r"(ticket|secret|token|password|passwd|private.?key|mac_key|enrollment.?code|"
    r"bootstrap|hmac|auth_token|server_token)",
    re.IGNORECASE,
)
SECRET_VALUE_RE = re.compile(
    r"(BEGIN [A-Z ]*PRIVATE KEY|btck\.[0-9a-f]{16}\.|enroll-secret-)",
    re.IGNORECASE,
)


class AuditError(Exception):
    pass


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def audit_path():
    root = os.environ.get("FRP_DEPLOY_TEST_ROOT", "")
    configured = os.environ.get("FRP_AUDIT_LOG", "")
    if configured:
        path = Path(configured)
    else:
        path = Path(DEFAULT_AUDIT_PATH)
    if root:
        text = str(path)
        if text.startswith("/"):
            path = Path(root + text)
        else:
            path = Path(root) / path
    return path


def _redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if SECRET_KEY_RE.search(str(key)):
                out[key] = "[REDACTED]"
            else:
                out[key] = _redact(item)
        return out
    if isinstance(value, list):
        return [_redact(item) for item in value]
    if value is None or isinstance(value, (int, float, bool)):
        return value
    text = str(value)
    if SECRET_VALUE_RE.search(text):
        return "[REDACTED]"
    return text


def _atomic_append(path: Path, line: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.touch()
        os.chmod(path, 0o600)
        os.chmod(path.parent, 0o700)
    else:
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            os.chmod(path, 0o600)
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)


def emit(event, actor="local-root", details=None, fail_closed=False, **fields):
    """Write one JSONL audit record. Returns True on success."""
    record = {
        "schema_version": AUDIT_SCHEMA,
        "timestamp": utc_now_iso(),
        "event": str(event),
        "actor": str(actor or "local-root"),
    }
    for key, value in fields.items():
        if value is not None:
            record[key] = value
    if details:
        record["details"] = _redact(details)
    record = _redact(record)
    try:
        rotate_if_needed(
            max_bytes=int(os.environ.get("FRP_AUDIT_ROTATE_BYTES", str(5 * 1024 * 1024))),
            keep=int(os.environ.get("FRP_AUDIT_ROTATE_KEEP", "5")),
        )
        payload = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        if len(payload.encode("utf-8")) > MAX_RECORD_BYTES:
            raise AuditError("audit record too large")
        _atomic_append(audit_path(), payload + "\n")
        return True
    except Exception as exc:
        if fail_closed:
            raise AuditError(str(exc)) from exc
        sys_stderr_warn(f"WARNING: audit log write failed: {exc}")
        return False


def try_emit(event, **kwargs):
    """Emit an audit event; never raise to the caller."""
    try:
        return emit(event, **kwargs)
    except Exception:
        return False


def discover_audit_path(caller_file=None):
    candidates = []
    if caller_file:
        here = Path(caller_file).resolve()
        candidates.append(here.parent.parent / "lib" / "frp_audit.py")
        candidates.append(here.parent.parent / "lib" / "frp-auto-deploy" / "frp_audit.py")
    root = os.environ.get("FRP_DEPLOY_TEST_ROOT", "")
    if root:
        candidates.append(Path(root) / "usr/local/lib/frp-auto-deploy/frp_audit.py")
    candidates.append(Path("/usr/local/lib/frp-auto-deploy/frp_audit.py"))
    here = Path(__file__).resolve()
    candidates.append(here)
    for path in candidates:
        if path.is_file():
            return path
    return None


def emit_from_tool(caller_file, event, **kwargs):
    """Load this module from the repo or installed path, then emit. Never raises."""
    try:
        import importlib.util

        path = discover_audit_path(caller_file)
        if path is None:
            return False
        spec = importlib.util.spec_from_file_location("frp_audit", str(path))
        if spec is None or spec.loader is None:
            return False
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.try_emit(event, **kwargs)
    except Exception:
        return False


def sys_stderr_warn(message):
    import sys

    sys.stderr.write(message + "\n")


def rotate_if_needed(max_bytes=5 * 1024 * 1024, keep=5):
    path = audit_path()
    if not path.is_file() or path.stat().st_size < max_bytes:
        return
    keep = max(int(keep), 1)
    # Drop the oldest retained file (.keep), then shift .1 .. .(keep-1) up by one.
    # Never create .keep+1 (query only reads .1 .. .keep).
    oldest = Path(f"{path}.{keep}")
    if oldest.exists() or oldest.is_symlink():
        oldest.unlink()
    for index in range(keep - 1, 0, -1):
        src = Path(f"{path}.{index}")
        if src.exists() or src.is_symlink():
            src.replace(Path(f"{path}.{index + 1}"))
    path.replace(Path(f"{path}.1"))
    path.touch()
    os.chmod(path, 0o600)


def _row_timestamp(row):
    """Prefer canonical timestamp; accept legacy ts."""
    return row.get("timestamp") or row.get("ts") or ""


def _row_details(row):
    """Prefer canonical details; accept legacy meta."""
    details = row.get("details")
    if details is None:
        details = row.get("meta")
    return details if isinstance(details, dict) else {}


def _iter_audit_paths(path: Path, keep: int):
    """Current audit file plus rotated .1 .. .keep (oldest last)."""
    paths = []
    if path.is_file():
        paths.append(path)
    for index in range(1, max(int(keep), 0) + 1):
        rotated = Path(f"{path}.{index}")
        if rotated.is_file():
            paths.append(rotated)
    return paths


def query(
    *,
    since=None,
    event=None,
    client_id=None,
    group=None,
    limit=500,
):
    """Return filtered audit rows (server-side timestamps, redacted).

    Results are sorted newest-first by timestamp. ``limit`` keeps the NEWEST
    matching entries (deterministic for ``show audit``).
    """
    from frp_client_registry import parse_duration, parse_iso_timestamp

    path = audit_path()
    keep = int(os.environ.get("FRP_AUDIT_ROTATE_KEEP", "5"))
    sources = _iter_audit_paths(path, keep)
    if not sources:
        return []
    cutoff = None
    if since:
        try:
            delta = parse_duration(since)
        except ValueError as exc:
            raise ValueError(str(exc)) from exc
        from datetime import timedelta
        cutoff = datetime.now(timezone.utc) - timedelta(seconds=delta)
    matched = []
    for source in sources:
        try:
            text = source.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            ts_raw = _row_timestamp(row)
            ts = parse_iso_timestamp(ts_raw)
            if cutoff and (ts is None or ts < cutoff):
                continue
            if event and row.get("event") != event:
                continue
            details = _row_details(row)
            if client_id:
                cid = str(client_id).lower()
                top = str(row.get("client_id", "")).lower()
                nested = str(details.get("client_id", "")).lower()
                if top != cid and nested != cid:
                    continue
            if group:
                g = str(group).lower()
                top_g = str(row.get("group", "") or row.get("group_id", "")).lower()
                nested_g = str(
                    details.get("group", "") or details.get("group_id", "")
                ).lower()
                if top_g != g and nested_g != g:
                    continue
            matched.append((ts or datetime(1970, 1, 1, tzinfo=timezone.utc), row))
    matched.sort(key=lambda item: item[0], reverse=True)
    return [row for _ts, row in matched[: max(int(limit), 1)]]


def format_audit_table(rows):
    """Format rows newest-first (query order) for ``show audit``."""
    lines = []
    for row in rows:
        details = _row_details(row)
        meta_bits = []
        for key in sorted(details.keys()):
            meta_bits.append("%s=%s" % (key, details[key]))
        meta_text = ", ".join(meta_bits)
        lines.append(
            "%s  event=%s  actor=%s%s"
            % (
                _row_timestamp(row),
                row.get("event", ""),
                row.get("actor", ""),
                ("  " + meta_text) if meta_text else "",
            )
        )
    return "\n".join(lines) + ("\n" if lines else "")


def format_audit_json(rows):
    return json.dumps(rows, indent=2, sort_keys=True) + "\n"


def format_audit_csv(rows):
    import csv
    import io

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["timestamp", "event", "actor", "client_id", "details_json"])
    for row in rows:
        details = _row_details(row)
        writer.writerow(
            [
                _row_timestamp(row),
                row.get("event", ""),
                row.get("actor", ""),
                row.get("client_id", details.get("client_id", "")),
                json.dumps(details, sort_keys=True),
            ]
        )
    return buf.getvalue()


def main(argv=None):
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Append or show frp-auto-deploy audit events")
    parser.add_argument("action", nargs="?", default="tail", choices=["emit", "tail"])
    parser.add_argument("--event")
    parser.add_argument("--actor", default="local-root")
    parser.add_argument("-n", "--lines", type=int, default=50)
    args = parser.parse_args(argv)
    if args.action == "emit":
        if not args.event:
            raise SystemExit("ERROR: --event is required")
        emit(args.event, actor=args.actor)
        return 0
    rows = query(limit=max(args.lines, 1))
    if not rows:
        sys.stdout.write("(no audit log)\n")
        return 0
    for row in rows:
        sys.stdout.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
