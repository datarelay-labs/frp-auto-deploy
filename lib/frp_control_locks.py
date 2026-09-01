#!/usr/bin/env python3
"""Shared control-state locks for backup, restore, and registry writers.

Canonical lock order (mandatory; never invert):

  1. server-lifecycle.lock
     backup, restore, and other lifecycle mutations only.
  2. registry.lock
     NewProxy authorization (load + validate + lease create),
     service/client port release, and allocator HTTP registry writers.
  3. proxy-leases/.leases.lock
     only while already holding registry.lock for authorization or
     release-safety lease inspection/creation.

Allocator HTTP writers and the NewProxy plugin take only registry.lock
(plus an in-process thread lock / lease lock). They must never acquire
the lifecycle lock after registry.lock.

Release tools take only registry.lock, then inspect leases.

Backup and restore take lifecycle then registry, with a timeout, so they
cannot block network operations indefinitely if a lifecycle holder is stuck.
"""
from __future__ import annotations

import fcntl
import os
import time
from contextlib import contextmanager
from pathlib import Path

LIFECYCLE_LOCK_REL = "var/lib/frp-auto-deploy/server-lifecycle.lock"
DEFAULT_TIMEOUT_SEC = 30


class LockTimeout(TimeoutError):
    pass


class ExclusiveFileLock:
    """fcntl exclusive lock with a bounded wait. Released on process death."""

    def __init__(self, path, timeout=DEFAULT_TIMEOUT_SEC):
        self.path = Path(path)
        self.timeout = float(timeout)
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR, 0o600)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    self.fd = None
                    raise LockTimeout("timed out waiting for %s" % self.path)
                time.sleep(0.05)
            except Exception:
                os.close(self.fd)
                self.fd = None
                raise

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        return False


def lifecycle_lock_path(root):
    return Path(root) / LIFECYCLE_LOCK_REL


def registry_lock_path(root, registry_rel="var/lib/frp-auto-deploy/registry.json"):
    return (Path(root) / registry_rel).resolve().parent / "registry.lock"


@contextmanager
def acquire_control_locks(root, timeout=DEFAULT_TIMEOUT_SEC, registry_rel="var/lib/frp-auto-deploy/registry.json"):
    """Acquire lifecycle then registry. Same order as documented above."""
    with ExclusiveFileLock(lifecycle_lock_path(root), timeout=timeout) as life:
        with ExclusiveFileLock(registry_lock_path(root, registry_rel), timeout=timeout) as reg:
            yield (life, reg)


def registry_lock_path_for_file(registry_file):
    return Path(registry_file).resolve().parent / "registry.lock"


class BlockingFileLock:
    """Blocking fcntl exclusive lock. Same primitive as allocator FileLock and release tools."""

    def __init__(self, path):
        self.path = Path(path)
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX)
        except Exception:
            os.close(self.fd)
            self.fd = None
            raise
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
        return False


@contextmanager
def acquire_registry_lock(registry_file):
    """Blocking exclusive lock on the canonical registry.lock next to registry.json."""
    with BlockingFileLock(registry_lock_path_for_file(registry_file)) as lock:
        yield lock
