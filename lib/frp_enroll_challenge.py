#!/usr/bin/env python3
"""Ephemeral server-side enrollment challenges (in-memory, single-process)."""
from __future__ import annotations

import secrets
import threading
import time

ENROLL_CHALLENGE_TTL = 120
CHALLENGE_ID_HEX_LEN = 16
CHALLENGE_NONCE_HEX_LEN = 64
# Soft bound against unbounded in-memory growth under abuse. Expired entries
# are pruned first; issuing still fails closed when the live set is full.
MAX_ACTIVE_CHALLENGES = 4096


class EnrollChallengeStore:
    """Short-lived, single-use enrollment challenges keyed by challenge_id."""

    def __init__(self, max_active=MAX_ACTIVE_CHALLENGES):
        self._lock = threading.Lock()
        self._challenges = {}
        self._max_active = int(max_active)

    def _expire_locked(self, now):
        expired = [
            cid for cid, rec in self._challenges.items()
            if int(rec.get('expires_at') or 0) <= now
        ]
        for cid in expired:
            self._challenges.pop(cid, None)

    def issue(self, enrollment_id, now=None):
        now = int(now if now is not None else time.time())
        eid = str(enrollment_id or '').strip().lower()
        if len(eid) != 16 or any(c not in '0123456789abcdef' for c in eid):
            raise ValueError('invalid enrollment id')
        with self._lock:
            self._expire_locked(now)
            if len(self._challenges) >= self._max_active:
                raise ValueError('enrollment challenge store is full')
            challenge_id = secrets.token_hex(8)
            nonce = secrets.token_hex(32)
            self._challenges[challenge_id] = {
                'enrollment_id': eid,
                'nonce': nonce,
                'expires_at': now + ENROLL_CHALLENGE_TTL,
                'used': False,
            }
            return {
                'challenge_id': challenge_id,
                'nonce': nonce,
                'server_time': now,
                'expires_at': now + ENROLL_CHALLENGE_TTL,
            }

    def consume(self, challenge_id, enrollment_id, nonce, now=None):
        now = int(now if now is not None else time.time())
        cid = str(challenge_id or '').strip().lower()
        eid = str(enrollment_id or '').strip().lower()
        provided_nonce = str(nonce or '').strip().lower()
        if len(cid) != CHALLENGE_ID_HEX_LEN or any(c not in '0123456789abcdef' for c in cid):
            return 'invalid enrollment challenge'
        if len(provided_nonce) != CHALLENGE_NONCE_HEX_LEN:
            return 'invalid enrollment challenge nonce'
        with self._lock:
            self._expire_locked(now)
            rec = self._challenges.get(cid)
            if not rec:
                return 'unknown enrollment challenge'
            if rec.get('used'):
                return 'enrollment challenge already used'
            if now > int(rec.get('expires_at') or 0):
                return 'enrollment challenge expired'
            if rec.get('enrollment_id') != eid:
                return 'enrollment challenge does not match enrollment id'
            if not secrets.compare_digest(str(rec.get('nonce') or ''), provided_nonce):
                return 'invalid enrollment challenge nonce'
            rec['used'] = True
            return None


def enrollment_challenge_message(challenge_id, nonce, body):
    if isinstance(body, bytes):
        body = body.decode('utf-8')
    return '%s\n%s\n%s' % (challenge_id, nonce, body)
