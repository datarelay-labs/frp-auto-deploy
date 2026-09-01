# Real-environment release validation

This file is the **authoritative** policy for which real-environment gates are
required for a stable tag versus recommended. `docs/RELEASE_CHECKLIST.md`
defers to this classification.

Docker `./tests/run-distro-matrix.sh` is **userspace portability** only. It does
not start the distro's systemd as PID 1, does not prove SELinux Enforcing, and
does not prove a real VM.

`tests/live-distro-smoke.sh` is a **read-only** collector for an already
installed systemd host. It does not install, enroll, update, uninstall, or
mutate firewall/SELinux.

## Gate classification

| Item | Classification | Current support claim |
| --- | --- | --- |
| Ubuntu 22.04 / 24.04 real VM | REQUIRED_FOR_STABLE (live baseline) | requires fresh PASS per release |
| Ubuntu 24.04 x86_64 single-443 (direct public-IP, enterprise-restricted client) | REQUIRED_FOR_STABLE (2.1.1); 2.1.0 PASS is historical baseline only | 2.1.0 PASS (2026-08-29); **2.1.1 real E2E required before stable tag** |
| Windows client | CI-tested; real-environment validation pending | do not claim Stable field validation |
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

## 2.1.1 real E2E requirement

For **2.1.1** stable release, historical 2.1.0 real Ubuntu E2E evidence is a
**historical baseline / previous-release evidence** only. It does **not** prove
the 2.1.1 code line.

Required sequence:

```text
Full Automated Gates
        ↓ PASS
candidate integration
        ↓
real 2.1.1 Ubuntu/OCI E2E
        ↓ PASS
main
        ↓
v2.1.1 stable tag
```

Do not mark `STABLE_TAG_READY=YES` for 2.1.1 until the fresh real 2.1.1
Ubuntu/OCI E2E records PASS. Windows remains **CI-tested** with
**real-environment validation pending**.

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

## 2.1.0 real-environment acceptance (2026-08-29)

**Historical baseline / previous-release evidence only.** This block records the
2.1.0 field result. It must **not** be reused as sufficient real validation for
changed **2.1.1** code. See **2.1.1 real E2E requirement** above.

```text
REAL_SERVER_OS=Ubuntu 24.04.4 LTS x86_64
REAL_SERVER_FRP=0.70.1
REAL_SERVER_TOPOLOGY=direct public-IP
REAL_CLIENT_OS=Ubuntu 24.04.3 LTS x86_64
REAL_CLIENT_NETWORK=enterprise restricted

OBSERVED_BEFORE_SINGLE443=TLS on non-443 ports was reset
OBSERVED_AFTER_SINGLE443=HTTPS enrollment and FRP WSS control succeeded over TCP/443; published SSH TCP/6000 reachable end-to-end

REAL_SERVER_MIGRATION_1_9_1_TO_2_1_0=PASS
REAL_SINGLE443_SERVER_CUTOVER=PASS
REAL_ENTERPRISE_TLS_443_PATH=PASS
REAL_CA_BOOTSTRAP_443=PASS
REAL_VERIFIED_HTTPS_443=PASS
REAL_ZERO_TOUCH_BOOTSTRAP=PASS
REAL_ENROLLMENT_443=PASS
REAL_CLIENT_CA_PINNING=PASS
REAL_WSS_E2E=PASS
REAL_FRPC_LOGIN=PASS
REAL_PROXY_REGISTRATION=PASS
REAL_SSH_SERVICE_E2E=PASS
REAL_ENTERPRISE_RESTRICTED_NETWORK_E2E=PASS
REAL_CLIENT_REBOOT_RECONNECT=PASS
REAL_SERVER_REBOOT_RECONNECT=PASS
REAL_END_TO_END_REBOOT_RECOVERY=PASS
PUBLIC_6099_NOT_EXPOSED=PASS
PUBLIC_7000_NOT_EXPOSED=PASS
PUBLIC_80_NOT_EXPOSED=PASS
SERVER_DOCTOR_AFTER_REBOOT=PASS
```

Real tested:

- Ubuntu x86_64
- Direct public-IP server
- Enterprise restricted client network
- HTTPS/443 enrollment
- WSS/443 control
- SSH published service
- Client reboot recovery
- Server reboot recovery

Not real-environment tested (remain `NOT_TESTED`; do not advertise as
field-validated):

- Firewall DNAT / private FRP-server topology
- SELinux Enforcing
- ARM64 host
- OpenSSL 1.0.2 host

```text
FIREWALL_DNAT_PRIVATE_FRP_SERVER=NOT_TESTED
ROCKY_9_SELINUX_ENFORCING=NOT_TESTED
REAL_ARM_SYSTEMD=NOT_TESTED
REAL_OPENSSL_1_0_2_TLS_ENROLLMENT=NOT_TESTED
```
