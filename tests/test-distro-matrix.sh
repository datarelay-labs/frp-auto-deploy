#!/usr/bin/env bash
# Self-tests for tests/run-distro-matrix.sh using a mocked docker command.
# Does not pull images or start nested Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# shellcheck source=./run-distro-matrix.sh
. "$ROOT/tests/run-distro-matrix.sh"

frp_matrix_load_images || fail "load images"
[[ ${#FRP_MATRIX_IMAGES[@]} -eq 7 ]] || fail "expected 7 default images"
[[ "${FRP_MATRIX_IMAGES[0]}" == ubuntu:22.04 ]] || fail "first image"
[[ "${FRP_MATRIX_IMAGES[2]}" == rockylinux:8 ]] || fail "rockylinux:8 required"
[[ "${FRP_MATRIX_IMAGES[6]}" == amazonlinux:2 ]] || fail "amazonlinux:2 required"
pass "image list includes Amazon Linux 2"

[[ "$(frp_matrix_display_name ubuntu:22.04)" == "Ubuntu 22.04" ]] || fail "ubuntu 22 name"
[[ "$(frp_matrix_display_name ubuntu:24.04)" == "Ubuntu 24.04" ]] || fail "ubuntu 24 name"
[[ "$(frp_matrix_display_name rockylinux:8)" == "Rocky Linux 8" ]] || fail "rocky8 name"
[[ "$(frp_matrix_display_name rockylinux:9)" == "Rocky Linux 9" ]] || fail "rocky name"
[[ "$(frp_matrix_display_name almalinux:9)" == "AlmaLinux 9" ]] || fail "alma name"
[[ "$(frp_matrix_display_name amazonlinux:2023)" == "Amazon Linux 2023" ]] || fail "al2023 name"
[[ "$(frp_matrix_display_name amazonlinux:2)" == "Amazon Linux 2" ]] || fail "al2 name"
[[ "$(frp_matrix_log_name amazonlinux:2023)" == amazonlinux-2023 ]] || fail "log name"
pass "image-name to display-name mapping"

if "$ROOT/tests/run-distro-matrix.sh" --bogus >/dev/null 2>"$WORKDIR/unknown.err"; then
  fail "unknown argument should fail"
fi
grep -q 'unknown argument' "$WORKDIR/unknown.err" || fail "unknown argument message"
pass "unknown CLI argument rejection"

if "$ROOT/tests/run-distro-matrix.sh" --image not-a-real-image >/dev/null 2>"$WORKDIR/badimg.err"; then
  fail "unsupported image should fail"
fi
grep -qi 'unsupported image' "$WORKDIR/badimg.err" || fail "unsupported image message"
pass "unsupported image rejection"

grep -q '/src:ro' "$ROOT/tests/run-distro-matrix.sh" || fail "read-only mount missing"
if grep -nE -- '--privileged|--pid=host|--network=host|--cap-add=SYS_ADMIN' "$ROOT/tests/run-distro-matrix.sh"; then
  fail "orchestrator weakens container isolation"
fi
if grep -nE 'docker.sock|/\.ssh|/\.aws|/\.docker' "$ROOT/tests/run-distro-matrix.sh"; then
  fail "orchestrator mounts host secrets or docker socket"
fi
grep -q -- '--rm' "$ROOT/tests/run-distro-matrix.sh" || fail "missing --rm cleanup"
pass "source mount is read-only and unprivileged"

# Workflow matrix must match tests/distro-images.txt (intentional duplication).
python3 - "$ROOT/tests/distro-images.txt" "$ROOT/.github/workflows/lint.yml" <<'PY' || fail "CI image list drift"
from pathlib import Path
import sys
listed = []
for raw in Path(sys.argv[1]).read_text(encoding='utf-8').splitlines():
    line = raw.split('#', 1)[0].strip()
    if line:
        listed.append(line)
text = Path(sys.argv[2]).read_text(encoding='utf-8')
missing = [img for img in listed if f'- {img}' not in text]
if missing:
    raise SystemExit('workflow missing images: %s' % missing)
extra_ok = True
print('ok')
PY
pass "GitHub Actions matrix matches distro-images.txt"

FAKE="$WORKDIR/fake-docker"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${FAKE_DOCKER_LOG:-/dev/null}"
printf 'argv:%s\n' "$*" >>"$LOG"
cmd="${1:-}"
shift || true
case "$cmd" in
  info)
    exit 0
    ;;
  pull)
    echo "pull $1"
    exit 0
    ;;
  rm)
    exit 0
    ;;
  run)
    image=""
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "--name" || "$prev" == "-e" || "$prev" == "-v" ]]; then
        prev=""
        continue
      fi
      case "$arg" in
        --name|-e|-v) prev="$arg"; continue ;;
        --rm) continue ;;
        -*) continue ;;
      esac
      image="$arg"
      break
    done
    echo "IMAGE=${image}"
    echo "CONTAINER_DISTRO_ID=mock"
    echo "CONTAINER_DISTRO_NAME=Mock"
    echo "CONTAINER_DISTRO_VERSION=1"
    echo "CONTAINER_PACKAGE_MANAGER=mock"
    echo "CONTAINER_ARCH=amd64"
    echo "CONTAINER_BASH=5.0"
    echo "CONTAINER_PYTHON=3.11.0"
    if [[ "$image" == amazonlinux:2 ]]; then
      echo "CONTAINER_OPENSSL=OpenSSL 1.0.2k-fips  26 Jan 2017"
    else
      echo "CONTAINER_OPENSSL=OpenSSL 3.0.0"
    fi
    echo "CONTAINER_SYSTEMD_USABLE=no"
    echo "CONTAINER_SYSTEMD_VERSION="
    echo "SYSTEMD_SMOKE=NOT_TESTED"
    echo "REAL_ARM_SYSTEMD_SMOKE=NOT_TESTED"
    fail_img="${FAKE_DOCKER_FAIL_IMAGE:-}"
    if [[ -n "$fail_img" && "$image" == "$fail_img" ]]; then
      echo "FAIL simulated-portability"
      echo "CONTAINER_PORTABILITY=FAIL"
      exit 1
    fi
    echo "CONTAINER_PORTABILITY=PASS"
    exit 0
    ;;
  *)
    echo "unexpected docker command: $cmd $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE"

export FRP_DOCKER="$FAKE"
export FRP_MATRIX_ROOT="$ROOT"
export FAKE_DOCKER_LOG="$WORKDIR/docker.argv"

run_matrix() {
  local logdir="$1"
  shift
  export FRP_MATRIX_LOGDIR="$logdir"
  mkdir -p "$logdir"
  : >"$FAKE_DOCKER_LOG"
  "$ROOT/tests/run-distro-matrix.sh" "$@"
}

LOGDIR="$WORKDIR/all-pass"
if ! run_matrix "$LOGDIR" --no-pull >"$WORKDIR/all-pass.out"; then
  fail "all-pass matrix should exit 0"
fi
grep -q 'CONTAINER_MATRIX=PASS' "$WORKDIR/all-pass.out" || fail "all-pass summary"
grep -q 'TOTAL=7' "$WORKDIR/all-pass.out" || fail "all-pass total"
grep -q 'PASSED=7' "$WORKDIR/all-pass.out" || fail "all-pass passed"
grep -q 'FAILED=0' "$WORKDIR/all-pass.out" || fail "all-pass failed count"
grep -q 'Amazon Linux 2' "$WORKDIR/all-pass.out" || fail "all-pass al2 row"
grep -q 'AMAZON_LINUX_2_CONTAINER=PASS' "$WORKDIR/all-pass.out" || fail "al2 container flag"
grep -q 'AMAZON_LINUX_2_OPENSSL_1_0_2_CONTAINER=PASS' "$WORKDIR/all-pass.out" || fail "al2 openssl flag"
if grep -q 'AMAZON_LINUX_2_SYSTEMD_219_REAL=PASS' "$WORKDIR/all-pass.out"; then
  fail "must not claim real systemd 219 from Docker"
fi
if grep -q 'REAL_VM=PASS' "$WORKDIR/all-pass.out"; then
  fail "must not claim REAL_VM from Docker"
fi
grep -q 'SYSTEMD_SMOKE=NOT_TESTED' "$WORKDIR/all-pass.out" || fail "systemd smoke disclaimer"
pass "summary aggregation PASS exit code"

if grep -q -- '--privileged' "$FAKE_DOCKER_LOG"; then
  fail "mocked docker run used --privileged"
fi
grep -q '/src:ro' "$FAKE_DOCKER_LOG" || fail "mocked docker run missing :ro"
pass "docker invocation stays read-only"

LOGDIR="$WORKDIR/one"
if ! run_matrix "$LOGDIR" --no-pull --image amazonlinux:2 >"$WORKDIR/one.out"; then
  fail "single-image should exit 0"
fi
grep -q 'TOTAL=1' "$WORKDIR/one.out" || fail "single-image total"
grep -q 'amazonlinux:2' "$WORKDIR/one.out" || fail "single-image row"
if grep -q 'ubuntu:22.04' "$WORKDIR/one.out"; then
  fail "single-image ran extra distros"
fi
grep -q 'CONTAINER_MATRIX=PASS' "$WORKDIR/one.out" || fail "single-image matrix"
pass "single-image mode"

export FAKE_DOCKER_FAIL_IMAGE=rockylinux:9
LOGDIR="$WORKDIR/one-fail"
set +e
run_matrix "$LOGDIR" --no-pull >"$WORKDIR/one-fail.out"
rc=$?
set -e
unset FAKE_DOCKER_FAIL_IMAGE
[[ "$rc" -ne 0 ]] || fail "matrix should exit non-zero on a distro failure"
grep -q 'CONTAINER_MATRIX=FAIL' "$WORKDIR/one-fail.out" || fail "fail summary"
grep -q 'FAILED_DISTROS=rockylinux:9' "$WORKDIR/one-fail.out" || fail "failed distros list"
grep -q 'PASSED=6' "$WORKDIR/one-fail.out" || fail "continue-after-failure passed count"
grep -q 'FAILED=1' "$WORKDIR/one-fail.out" || fail "continue-after-failure failed count"
grep -q 'Ubuntu 22.04' "$WORKDIR/one-fail.out" || fail "ubuntu 22 still attempted"
grep -q 'Amazon Linux 2' "$WORKDIR/one-fail.out" || fail "amazon linux 2 still attempted"
grep -q 'Rocky Linux 9' "$WORKDIR/one-fail.out" || fail "rocky row missing"
pass "continue-after-one-failure behavior"
pass "FAIL exit code"

echo
echo "DISTRO_MATRIX_SELF_TEST=PASS"
