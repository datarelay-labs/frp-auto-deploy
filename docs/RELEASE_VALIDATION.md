# Real-environment release validation

Docker `./tests/run-distro-matrix.sh` is **userspace portability** only. It does
not start the distro's systemd as PID 1, does not prove SELinux Enforcing, and
does not prove a real VM.

`tests/live-distro-smoke.sh` is a **read-only** collector for an already
installed systemd host. It does not install, enroll, update, uninstall, or
mutate firewall/SELinux.

## Gate classification

| Item | Classification | Current support claim |
| --- | --- | --- |
| Ubuntu 22.04 / 24.04 real VM | REQUIRED_FOR_STABLE (live baseline) | documented PASS |
| Rocky 9 container | REQUIRED_FOR_STABLE (automated) | container PASS |
| AlmaLinux 9 container | REQUIRED_FOR_STABLE (automated) | container PASS |
| Amazon Linux 2023 container | REQUIRED_FOR_STABLE (automated) | container PASS |
| Amazon Linux 2 container | REQUIRED_FOR_STABLE (automated) | container PASS |
| Rocky 9 real VM | RECOMMENDED | NOT_TESTED; do not advertise full VM support |
| Rocky 9 SELinux Enforcing | RECOMMENDED | NOT_TESTED; do not advertise Enforcing support |
| AlmaLinux 9 real VM | RECOMMENDED | NOT_TESTED |
| AlmaLinux 9 SELinux Enforcing | RECOMMENDED | NOT_TESTED |
| Amazon Linux 2023 real VM | RECOMMENDED | NOT_TESTED |
| Amazon Linux 2 real VM / systemd 219 / TTY | RECOMMENDED | NOT_TESTED |
| Native ARM64 systemd | RECOMMENDED | architecture mapping unit-tested only |
| Real OpenSSL 1.0.2 TLS enrollment | RECOMMENDED | AL2 container userspace is not this gate |

## Result format

Copy per host. Values: `PASS`, `FAIL`, `NOT_TESTED`, `BLOCKED`.

```text
HOST=
OS=
ARCH=
KERNEL=
SELINUX_GETENFORCE=
SYSTEMD_VERSION=
BASH_VERSION=
PYTHON_VERSION=
OPENSSL_VERSION=
PID1=

ROCKY_9_REAL_VM=NOT_TESTED
ROCKY_9_SELINUX_ENFORCING=NOT_TESTED

ALMA_9_REAL_VM=NOT_TESTED
ALMA_9_SELINUX_ENFORCING=NOT_TESTED

AMAZON_LINUX_2023_REAL_VM=NOT_TESTED

AMAZON_LINUX_2_REAL_VM=NOT_TESTED
AMAZON_LINUX_2_SYSTEMD_219_REAL=NOT_TESTED
AMAZON_LINUX_2_REAL_TTY=NOT_TESTED

REAL_ARM_SYSTEMD=NOT_TESTED
REAL_OPENSSL_1_0_2_TLS_ENROLLMENT=NOT_TESTED
```

Do **not** map Docker, LXD, or QEMU TCG to `REAL_VM=PASS`.

## Per disposable test VM

On a throwaway VM only:

1. Fresh install (server and/or client bootstrap)
2. `systemctl is-enabled` / `is-active` for `frps`, `frp-port-allocator`, `frpc` as applicable
3. Reboot; confirm units and `frpctl status`
4. `sudo frpctl doctor` (read-only)
5. Zero-touch **or** manual enrollment
6. Publish a service; connect with the **public** host and **public** service port
   (`ssh -p <public-port> <user>@<public-host>`)
7. Disable and re-enable; confirm the same public port
8. `sudo frpctl update`
9. Uninstall only on the test host (`uninstall-client.sh` does not release server ports;
   server uninstall preserves state; purge requires `--purge --yes`)

Then run `tests/live-distro-smoke.sh` for a non-destructive evidence dump.

## SELinux (Rocky / Alma real VM)

Require `getenforce` => `Enforcing`. Do not `setenforce 0` to obtain PASS.

Validate server install, client install, allocator HTTPS, `frps`, `frpc`,
systemd, local file access, ports, and doctor.

If policy blocks legitimate product behavior, record the exact AVC and decide
whether it is a site policy issue. Do not install custom SELinux policy unless
release-blocking evidence requires it.

## Amazon Linux 2 real gate

Prove systemd 219, Bash 4.2, Python 3.7, OpenSSL 1.0.2k, real PID 1, reboot,
and TTY. Docker userspace PASS is not this column.

## ARM64

Native host only for `REAL_ARM_SYSTEMD=PASS`: architecture detection, FRP
arm64 artifact, install, systemd, basic connection, doctor. QEMU userspace
emulation is not that gate.

## Real OpenSSL 1.0.2 TLS enrollment

Prove allocator CA bootstrap, SHA256 DER fingerprint, TLS 1.2, bootstrap
ticket redemption, and Enrollment on an actual OpenSSL 1.0.2 client. The
Amazon Linux 2 container only proves userspace parsing compatibility.

Until then: `REAL_OPENSSL_1_0_2_TLS_ENROLLMENT=NOT_TESTED`.
