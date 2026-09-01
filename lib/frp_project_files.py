#!/usr/bin/env python3
"""Canonical project-file manifest loader.

This is the source of truth for:
  full installation managed files
  project-update staging/install/validation
  snapshot/rollback managed project files
  uninstall managed project/optional/unit removal
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SERVER_MANIFEST_NAME = "server-project-files.manifest"
CLIENT_MANIFEST_NAME = "client-project-files.manifest"
# Backward-compatible alias
MANIFEST_NAME = SERVER_MANIFEST_NAME
MANAGED_CLASSES = ("project", "optional", "unit", "unit-single443")
SNAPSHOT_EXTRA_CLASSES = ("generated", "binary", "version")


class FileEntry:
    __slots__ = ("cls", "dest", "mode", "source", "validate")

    def __init__(self, cls, dest, mode, source, validate):
        self.cls = cls
        self.dest = dest
        self.mode = mode
        self.source = source
        self.validate = validate


def _resolve_manifest(name, explicit=None, env_key="FRP_PROJECT_FILE_MANIFEST"):
    if explicit:
        return Path(explicit)
    here = Path(__file__).resolve().parent
    candidate = here / name
    if candidate.is_file():
        return candidate
    installed = Path("/usr/local/lib/frp-auto-deploy") / name
    if installed.is_file():
        return installed
    env = os.environ.get(env_key, "")
    if env:
        return Path(env)
    raise FileNotFoundError("%s is missing" % name)


def manifest_path(explicit=None):
    return _resolve_manifest(SERVER_MANIFEST_NAME, explicit)


def client_manifest_path(explicit=None):
    return _resolve_manifest(
        CLIENT_MANIFEST_NAME,
        explicit,
        env_key="FRP_CLIENT_PROJECT_FILE_MANIFEST",
    )


def load_entries(path=None):
    text = manifest_path(path).read_text(encoding="utf-8")
    return _parse_entries(text)


def load_client_entries(path=None):
    text = client_manifest_path(path).read_text(encoding="utf-8")
    return _parse_entries(text)


def _parse_entries(text):
    entries = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 5:
            raise ValueError("invalid manifest line: %s" % raw)
        entries.append(FileEntry(*parts))
    return entries


def _source_exists(source_root, source):
    if not source_root or source in ("-", ""):
        return True
    return (Path(source_root) / source).is_file()


def managed_entries(single443=False, source_root=None, include_optional=True, path=None):
    out = []
    for entry in load_entries(path):
        if entry.cls not in MANAGED_CLASSES:
            continue
        if entry.cls == "unit-single443" and not single443:
            continue
        if entry.cls == "optional":
            if not include_optional:
                continue
            if source_root is not None and not _source_exists(source_root, entry.source):
                continue
        out.append(entry)
    return out


def client_managed_entries(source_root=None, include_optional=True, path=None):
    out = []
    for entry in load_client_entries(path):
        if entry.cls not in MANAGED_CLASSES:
            continue
        if entry.cls == "optional":
            if not include_optional:
                continue
            if source_root is not None and not _source_exists(source_root, entry.source):
                continue
        out.append(entry)
    return out


def snapshot_rels(path=None):
    rels = []
    for entry in load_entries(path):
        if entry.cls in MANAGED_CLASSES or entry.cls in SNAPSHOT_EXTRA_CLASSES:
            rels.append(entry.dest)
    return rels


def managed_dests(single443=False, source_root=None, path=None):
    return [entry.dest for entry in managed_entries(single443, source_root, True, path)]


def client_managed_dests(source_root=None, path=None):
    return [entry.dest for entry in client_managed_entries(source_root, True, path)]


def client_project_entries(source_root=None, path=None):
    """Replaceable client management software (project + optional), excluding unit/binary."""
    out = []
    for entry in client_managed_entries(source_root, True, path):
        if entry.cls in ("project", "optional"):
            out.append(entry)
    return out


def client_project_destination_lines(source_root=None, path=None):
    lines = []
    for entry in client_project_entries(source_root, path):
        lines.append("%s:%s:%s" % (entry.dest, entry.mode, entry.source))
    return lines


def uninstall_rels(single443=True, source_root=None, path=None):
    """Managed project/optional/unit paths removed by default server uninstall.

    Excludes protected/protected-prefix/generated/version persistent state.
    Binary (frps) is not in this list; uninstall removes it separately.
    """
    return managed_dests(single443=single443, source_root=source_root, path=path)


def client_uninstall_rels(source_root=None, path=None):
    """Managed client project/optional/unit paths removed by client uninstall."""
    return client_managed_dests(source_root=source_root, path=path)


def dual_role_shared_lib_basenames(server_path=None, client_path=None):
    """Basenames under usr/local/lib/frp-auto-deploy shared by both roles."""
    prefix = "usr/local/lib/frp-auto-deploy/"
    server = {
        e.dest[len(prefix) :]
        for e in load_entries(server_path)
        if e.cls in MANAGED_CLASSES and e.dest.startswith(prefix)
    }
    client = {
        e.dest[len(prefix) :]
        for e in load_client_entries(client_path)
        if e.cls in MANAGED_CLASSES and e.dest.startswith(prefix)
    }
    return tuple(sorted(server & client))


def protected_exact(path=None):
    return tuple(e.dest for e in load_entries(path) if e.cls == "protected")


def protected_prefixes(path=None):
    return tuple(e.dest for e in load_entries(path) if e.cls == "protected-prefix")


def destination_lines(single443=False, source_root=None, path=None):
    lines = []
    for entry in managed_entries(single443, source_root, True, path):
        lines.append("%s:%s:%s" % (entry.dest, entry.mode, entry.source))
    return lines


def client_destination_lines(source_root=None, path=None):
    lines = []
    for entry in client_managed_entries(source_root, True, path):
        lines.append("%s:%s:%s" % (entry.dest, entry.mode, entry.source))
    return lines


def validate_paths(kind, staged_root=None, single443=False, source_root=None, path=None):
    paths = []
    for entry in managed_entries(single443, source_root, True, path):
        if entry.validate != kind:
            continue
        rel = entry.dest
        paths.append(str(Path(staged_root, rel)) if staged_root else rel)
    return paths


# --- Client upgrade snapshot metadata (self-describing rollback/recovery) ---

CLIENT_UPGRADE_SNAPSHOT_KIND = "client-upgrade-snapshot"
CLIENT_UPGRADE_SNAPSHOT_SCHEMA = 1
CLIENT_UPGRADE_DEST_PREFIXES = (
    "usr/local/bin/",
    "usr/local/lib/frp-auto-deploy/",
)
CLIENT_UPGRADE_EXTRA_ALLOWED = {
    "version": ("etc/frp-auto-deploy/version", "0644"),
    "frpc.toml": ("etc/frp/frpc.toml", "0600"),
}


class ClientUpgradeSnapshotError(ValueError):
    """Malformed or unsafe client-upgrade snapshot metadata."""


def _normalize_mode(mode):
    text = str(mode or "").strip()
    if not text:
        raise ClientUpgradeSnapshotError("missing mode")
    if text.startswith("0o") or text.startswith("0O"):
        text = text[2:]
    if not text.isdigit() or len(text) < 3 or len(text) > 4:
        raise ClientUpgradeSnapshotError("invalid mode: %s" % mode)
    value = int(text, 8)
    if value < 0 or value > 0o7777:
        raise ClientUpgradeSnapshotError("invalid mode: %s" % mode)
    return "%04o" % value if value > 0o777 else "%03o" % value


def validate_client_upgrade_dest(rel, *, allow_extras=False):
    """Fail-closed relative destination under canonical client-managed locations."""
    if not isinstance(rel, str) or not rel:
        raise ClientUpgradeSnapshotError("empty destination")
    if rel.startswith("/") or rel.startswith("\\"):
        raise ClientUpgradeSnapshotError("absolute destination refused: %s" % rel)
    if "\\" in rel:
        raise ClientUpgradeSnapshotError("destination escape refused: %s" % rel)
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise ClientUpgradeSnapshotError("destination traversal refused: %s" % rel)
    if allow_extras:
        for dest, _mode in CLIENT_UPGRADE_EXTRA_ALLOWED.values():
            if rel == dest:
                return rel
    if not any(rel.startswith(prefix) for prefix in CLIENT_UPGRADE_DEST_PREFIXES):
        raise ClientUpgradeSnapshotError(
            "destination outside client project locations: %s" % rel
        )
    return rel


def _validate_backup_rel(backup, snapshot_root):
    if backup is None:
        return None
    if not isinstance(backup, str) or not backup:
        raise ClientUpgradeSnapshotError("empty backup path")
    if backup.startswith("/") or backup.startswith("\\"):
        raise ClientUpgradeSnapshotError("absolute backup path refused: %s" % backup)
    parts = backup.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise ClientUpgradeSnapshotError("backup traversal refused: %s" % backup)
    if not (backup.startswith("files/") or backup.startswith("extras/")):
        raise ClientUpgradeSnapshotError("backup path not under snapshot store: %s" % backup)
    root = Path(snapshot_root).resolve(strict=False)
    candidate = (root / backup).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise ClientUpgradeSnapshotError(
            "backup path escapes snapshot root: %s" % backup
        ) from exc
    return backup


def _reject_symlink(path: Path, label: str):
    if path.is_symlink():
        raise ClientUpgradeSnapshotError("%s is a symlink: %s" % (label, path))
    for parent in path.parents:
        if parent == path.anchor or str(parent) == "/":
            break
        if parent.is_symlink():
            raise ClientUpgradeSnapshotError(
                "%s path has symlink parent: %s" % (label, path)
            )


def load_client_upgrade_snapshot(snapshot_dir):
    """Load and validate snapshot metadata; returns dict or raises."""
    root = Path(snapshot_dir)
    if not root.is_dir():
        raise ClientUpgradeSnapshotError("snapshot directory missing")
    _reject_symlink(root, "snapshot")
    meta_path = root / "metadata.json"
    if not meta_path.is_file():
        raise ClientUpgradeSnapshotError("snapshot metadata.json missing")
    _reject_symlink(meta_path, "metadata")
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ClientUpgradeSnapshotError("snapshot metadata is not valid JSON") from exc
    if not isinstance(meta, dict):
        raise ClientUpgradeSnapshotError("snapshot metadata must be an object")
    if meta.get("kind") != CLIENT_UPGRADE_SNAPSHOT_KIND:
        raise ClientUpgradeSnapshotError("snapshot kind mismatch")
    if int(meta.get("schema_version") or 0) != CLIENT_UPGRADE_SNAPSHOT_SCHEMA:
        raise ClientUpgradeSnapshotError("unsupported snapshot schema_version")
    files = meta.get("files")
    if not isinstance(files, list) or not files:
        raise ClientUpgradeSnapshotError("snapshot files list missing")
    seen = set()
    normalized = []
    for item in files:
        if not isinstance(item, dict):
            raise ClientUpgradeSnapshotError("snapshot file entry must be an object")
        dest = validate_client_upgrade_dest(str(item.get("dest") or ""))
        if dest in seen:
            raise ClientUpgradeSnapshotError("duplicate snapshot dest: %s" % dest)
        seen.add(dest)
        state = str(item.get("state") or "").strip()
        if state not in ("present", "absent"):
            raise ClientUpgradeSnapshotError("invalid state for %s" % dest)
        mode = _normalize_mode(item.get("mode"))
        backup = item.get("backup")
        if state == "present":
            backup = _validate_backup_rel(backup, root)
            if backup is None:
                raise ClientUpgradeSnapshotError("present entry missing backup: %s" % dest)
            backup_path = root / backup
            if not backup_path.is_file():
                raise ClientUpgradeSnapshotError("backup file missing: %s" % backup)
            _reject_symlink(backup_path, "backup")
        else:
            if backup not in (None, ""):
                raise ClientUpgradeSnapshotError(
                    "absent entry must not name a backup: %s" % dest
                )
            backup = None
        normalized.append(
            {"dest": dest, "mode": mode, "state": state, "backup": backup}
        )
    extras = meta.get("extras")
    if extras is None:
        extras = []
    if not isinstance(extras, list):
        raise ClientUpgradeSnapshotError("snapshot extras must be a list")
    norm_extras = []
    seen_extra = set()
    for item in extras:
        if not isinstance(item, dict):
            raise ClientUpgradeSnapshotError("snapshot extra entry must be an object")
        extra_id = str(item.get("id") or "").strip()
        if extra_id not in CLIENT_UPGRADE_EXTRA_ALLOWED:
            raise ClientUpgradeSnapshotError("unknown snapshot extra id: %s" % extra_id)
        if extra_id in seen_extra:
            raise ClientUpgradeSnapshotError("duplicate snapshot extra: %s" % extra_id)
        seen_extra.add(extra_id)
        expected_dest, default_mode = CLIENT_UPGRADE_EXTRA_ALLOWED[extra_id]
        dest = validate_client_upgrade_dest(
            str(item.get("dest") or expected_dest), allow_extras=True
        )
        if dest != expected_dest:
            raise ClientUpgradeSnapshotError(
                "extra dest mismatch for %s: %s" % (extra_id, dest)
            )
        state = str(item.get("state") or "").strip()
        if state not in ("present", "absent"):
            raise ClientUpgradeSnapshotError("invalid extra state for %s" % extra_id)
        mode = _normalize_mode(item.get("mode") or default_mode)
        backup = item.get("backup")
        if state == "present":
            backup = _validate_backup_rel(backup, root)
            if backup is None:
                raise ClientUpgradeSnapshotError(
                    "present extra missing backup: %s" % extra_id
                )
            backup_path = root / backup
            if not backup_path.is_file():
                raise ClientUpgradeSnapshotError("extra backup missing: %s" % backup)
            _reject_symlink(backup_path, "extra backup")
        else:
            if backup not in (None, ""):
                raise ClientUpgradeSnapshotError(
                    "absent extra must not name a backup: %s" % extra_id
                )
            backup = None
        norm_extras.append(
            {
                "id": extra_id,
                "dest": dest,
                "mode": mode,
                "state": state,
                "backup": backup,
            }
        )
    return {
        "schema_version": CLIENT_UPGRADE_SNAPSHOT_SCHEMA,
        "kind": CLIENT_UPGRADE_SNAPSHOT_KIND,
        "files": normalized,
        "extras": norm_extras,
    }


def write_client_upgrade_snapshot_metadata(snapshot_dir, files, extras):
    """Persist canonical snapshot metadata next to backed-up files."""
    root = Path(snapshot_dir)
    root.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": CLIENT_UPGRADE_SNAPSHOT_SCHEMA,
        "kind": CLIENT_UPGRADE_SNAPSHOT_KIND,
        "files": files,
        "extras": extras,
    }
    # Validate before write so callers cannot persist unsafe manifests.
    tmp = root / ".metadata.json.tmp"
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    # Re-read via loader after move so missing backups fail closed.
    meta_path = root / "metadata.json"
    os.replace(tmp, meta_path)
    return load_client_upgrade_snapshot(root)


def client_upgrade_snapshot_restore_lines(snapshot_dir):
    """Emit state|mode|dest|backup_or_- for shell restore/verify (no source needed)."""
    meta = load_client_upgrade_snapshot(snapshot_dir)
    lines = []
    for item in meta["files"]:
        backup = item["backup"] if item["backup"] else "-"
        lines.append(
            "%s|%s|%s|%s" % (item["state"], item["mode"], item["dest"], backup)
        )
    for item in meta["extras"]:
        backup = item["backup"] if item["backup"] else "-"
        lines.append(
            "%s|%s|%s|%s" % (item["state"], item["mode"], item["dest"], backup)
        )
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description="Project-file manifest")
    parser.add_argument(
        "action",
        choices=(
            "destinations",
            "snapshot-rels",
            "managed-rels",
            "uninstall-rels",
            "client-destinations",
            "client-project-destinations",
            "client-managed-rels",
            "client-uninstall-rels",
            "dual-role-shared-libs",
            "validate-list",
            "client-upgrade-snapshot-entries",
            "client-upgrade-snapshot-validate",
        ),
    )
    parser.add_argument("--single443", action="store_true")
    parser.add_argument("--source")
    parser.add_argument("--staged")
    parser.add_argument("--kind", choices=("bash", "python"))
    parser.add_argument("--manifest")
    parser.add_argument("--client-manifest")
    parser.add_argument("--snapshot")
    args = parser.parse_args(argv)
    if args.action == "destinations":
        for line in destination_lines(args.single443, args.source, args.manifest):
            print(line)
        return 0
    if args.action == "snapshot-rels":
        for rel in snapshot_rels(args.manifest):
            print(rel)
        return 0
    if args.action == "managed-rels":
        for rel in managed_dests(args.single443, args.source, args.manifest):
            print(rel)
        return 0
    if args.action == "uninstall-rels":
        # Always include unit-single443 so a leftover frontend unit is removed.
        for rel in uninstall_rels(True, args.source, args.manifest):
            print(rel)
        return 0
    if args.action == "client-destinations":
        for line in client_destination_lines(args.source, args.client_manifest):
            print(line)
        return 0
    if args.action == "client-project-destinations":
        for line in client_project_destination_lines(args.source, args.client_manifest):
            print(line)
        return 0
    if args.action == "client-managed-rels":
        for rel in client_managed_dests(args.source, args.client_manifest):
            print(rel)
        return 0
    if args.action == "client-uninstall-rels":
        for rel in client_uninstall_rels(args.source, args.client_manifest):
            print(rel)
        return 0
    if args.action == "dual-role-shared-libs":
        for name in dual_role_shared_lib_basenames(args.manifest, args.client_manifest):
            print(name)
        return 0
    if args.action == "validate-list":
        if not args.kind:
            raise SystemExit("ERROR: --kind is required")
        for rel in validate_paths(args.kind, args.staged, args.single443, args.source, args.manifest):
            print(rel)
        return 0
    if args.action in (
        "client-upgrade-snapshot-entries",
        "client-upgrade-snapshot-validate",
    ):
        if not args.snapshot:
            raise SystemExit("ERROR: --snapshot is required")
        try:
            lines = client_upgrade_snapshot_restore_lines(args.snapshot)
        except ClientUpgradeSnapshotError as exc:
            sys.stderr.write("ERROR: %s\n" % exc)
            return 1
        if args.action == "client-upgrade-snapshot-validate":
            print("SNAPSHOT_MANIFEST_OK")
            return 0
        for line in lines:
            print(line)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
