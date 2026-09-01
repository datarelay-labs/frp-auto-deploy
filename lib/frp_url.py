#!/usr/bin/env python3
"""Canonical HTTPS URL validation (allocator / installer URLs).

Matches lib/frp-common.sh frp_validate_https_url:
  https only, hostname required, no userinfo, port in 1..65535 when set,
  reject control characters (including DEL) and encoded controls in the host.
"""
from __future__ import annotations

from urllib.parse import unquote, urlsplit


def validate_https_url(url):
    """Return True when url is a safe https URL."""
    if not url or any(ord(ch) < 32 or ord(ch) == 127 for ch in url):
        return False
    if any(ch.isspace() for ch in url):
        return False
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        return False
    if parsed.scheme != "https" or not parsed.hostname:
        return False
    if parsed.username is not None or parsed.password is not None:
        return False
    if port is not None and not (1 <= port <= 65535):
        return False
    host = parsed.hostname
    decoded_host = unquote(host)
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in decoded_host):
        return False
    if any(ch.isspace() for ch in host) or any(ch.isspace() for ch in decoded_host):
        return False
    return True


# Alias used by allocator-facing call sites.
validate_https_allocator_url = validate_https_url
