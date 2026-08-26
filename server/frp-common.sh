#!/usr/bin/env bash
# Shared helpers for FRP download/verify/version probing.
# Sourced by install-server.sh, frp-update, and frp-server-status.
# shellcheck shell=bash

frp_detect_arch() {
  case "$(uname -m)" in
    x86_64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) return 1 ;;
  esac
}

frp_release_url() {
  local version="$1" arch="$2"
  printf 'https://github.com/fatedier/frp/releases/download/v%s/frp_%s_linux_%s.tar.gz\n' \
    "$version" "$version" "$arch"
}

frp_expected_sha() {
  local arch="$1"
  case "$arch" in
    amd64) printf '%s\n' "${FRP_SHA256_AMD64:?}" ;;
    arm64) printf '%s\n' "${FRP_SHA256_ARM64:?}" ;;
    *) return 1 ;;
  esac
}

frp_parse_binary_version() {
  local bin="$1"
  if [[ ! -x "$bin" ]]; then
    return 1
  fi
  local out
  out="$("$bin" --version 2>/dev/null || "$bin" -v 2>/dev/null || true)"
  out="$(printf '%s' "$out" | tr -d '\r' | head -n1 | awk '{print $NF}')"
  if [[ "$out" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

frp_sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}

frp_verify_archive_sha() {
  local archive="$1" expected="$2"
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null
}

frp_download_archive() {
  local url="$1" dest="$2"
  curl -fL --retry 3 --connect-timeout 10 --max-time 300 -o "$dest" "$url"
}

frp_extract_frps() {
  local archive="$1" version="$2" arch="$3" dest_bin="$4"
  local tmp
  tmp="$(mktemp -d)"
  # Caller should clean via trap if needed; best-effort local cleanup.
  tar xzf "$archive" -C "$tmp"
  install -m 0755 "$tmp/frp_${version}_linux_${arch}/frps" "$dest_bin"
  rm -rf "$tmp"
}

frp_atomic_install_bin() {
  local src="$1" dest="$2" mode="${3:-0755}"
  local dir tmp
  dir="$(dirname -- "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp -p "$dir" ".$(basename -- "$dest").XXXXXX")"
  # mktemp creates 0600; copy then set mode before replace.
  cat -- "$src" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

frp_compare_versions() {
  # Prints: equal | older | newer | unknown
  # Compares $1 against $2 (is $1 older/newer than $2?)
  local a="$1" b="$2"
  if [[ -z "$a" || -z "$b" || "$a" == unknown || "$b" == unknown ]]; then
    printf '%s\n' unknown
    return 0
  fi
  if [[ "$a" == "$b" ]]; then
    printf '%s\n' equal
    return 0
  fi
  local IFS=.
  # shellcheck disable=SC2206
  local aa=($a) bb=($b)
  local i
  for i in 0 1 2; do
    local x="${aa[$i]:-0}" y="${bb[$i]:-0}"
    if (( x < y )); then printf '%s\n' older; return 0; fi
    if (( x > y )); then printf '%s\n' newer; return 0; fi
  done
  printf '%s\n' equal
}

frp_fetch_upstream_latest() {
  local json tag
  json="$(curl -fsS --connect-timeout 2 --max-time 3 \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    return 1
  fi
  tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' <<<"$json" 2>/dev/null || true)"
  tag="${tag#v}"
  if [[ "$tag" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s\n' "$tag"
    return 0
  fi
  return 1
}

frp_control_port_listening() {
  local port="$1"
  [[ -n "$port" ]] || return 1
  ss -H -lnt 2>/dev/null | awk -v p="$port" '{
    for (i=1; i<=NF; i++) {
      addr=$i
      if (addr ~ /:/) {
        sub(/^.*:/, "", addr)
        if (addr == p) found=1
      }
    }
  } END { exit(found?0:1) }'
}

frp_write_installed_version() {
  local path="$1" project_version="$2" frp_version="$3"
  mkdir -p "$(dirname -- "$path")"
  cat >"$path" <<EOF
PROJECT_VERSION=${project_version}
FRP_VERSION=${frp_version}
EOF
  chmod 644 "$path"
}
