#!/usr/bin/env bash
# Write SHA256SUMS for every tracked file except SHA256SUMS itself.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git ls-files -z | grep -zv '^SHA256SUMS$' | sort -z | xargs -0 sha256sum | LC_ALL=C sort -k2 >"$tmp"
mv "$tmp" SHA256SUMS
echo "Updated SHA256SUMS ($(wc -l <SHA256SUMS) files)"
