# frp-auto-deploy

`frp-auto-deploy` is a lightweight deployment and management layer for the official
[fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or
modify FRP.

It installs `frps`/`frpc`, assigns persistent public TCP ports, enrolls clients
over HTTPS, and provides `frpctl` for day-to-day operations.

> The addresses `203.0.113.10`, `192.0.2.50`, and `198.51.100.10` in this README
> are documentation-only (RFC 5737). Replace them with your own public and
> internal addresses.

Current project version: **2.1.0**
Current pinned FRP version: **v0.70.1**

2.1.0 is the **current stable release**. Direct mode remains the default.
Optional Enterprise single-443 mode is included. FRP stays at **0.70.1**.
See [CHANGELOG.md](CHANGELOG.md),
[docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md), and
[docs/SECURITY.md](docs/SECURITY.md).

---

# What this project does

- Install the FRP server and a project-managed HTTPS allocator
- Create clients with a short-lived Enrollment Code **or** a one-line zero-touch command
- Publish SSH and other TCP services with persistent public ports
- Manage services (add / edit / disable / re-enable / release) without reinstalling FRP
- Diagnose with read-only `frpctl doctor`
- Update and uninstall without silently destroying CA, token, or port reservations

FRP tunnel: native TLS + FRP token.
Management: HTTPS only + private CA + ECDSA client identity.
There is no mTLS, no plain HTTP enrollment, and Direct mode does not require
FRP to own public TCP/443. Enterprise networks that reset TLS on non-standard
ports should use [single-443 mode](docs/DEPLOYMENT_MODES.md) instead of HTTP.

---

# Quick Start

Operator path:

```text
1. Install the FRP server
2. Configure public vs listen ports and NAT/firewall
3. Verify the server
4. Create a client (zero-touch SSH is the fastest path)
5. Install / enroll the client
6. Connect using the public host and public service port
```

Two network models for Direct mode, plus an optional Enterprise mode:

1. **Behind NAT/firewall** — public ports may differ from local listen ports
2. **Direct public IP** — public and listen ports are usually the same
3. **Enterprise single-443** — public TCP/443 carries allocator HTTPS and FRP
   control over WSS; published services stay 6000-6098

In Direct mode, TCP/443 is a convenience default, not a requirement. Published
service ports use 1:1 public/internal port numbers (public 6002 → FRP remote
port 6002). If `curl` can TCP-connect to the allocator port but TLS ClientHello
is reset, see [docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

## 1. Choose ports

### Behind NAT (example: something else already uses TCP/443)

```text
Public host:                 203.0.113.10
Internal FRP server:         192.0.2.50
FRP control:                 public 8443  ->  listen 443
Allocator HTTPS:             public 9443  ->  listen 6099
Published services:          6000-6098 (1:1)
```

Firewall/DNAT:

```text
203.0.113.10:8443  ->  192.0.2.50:443
203.0.113.10:9443  ->  192.0.2.50:6099
203.0.113.10:6002  ->  192.0.2.50:6002
```

Clients use public endpoints only:

```text
FRP Server:  203.0.113.10:8443
Allocator:   https://203.0.113.10:9443/enroll
SSH:         ssh -p 6002 ubuntu@203.0.113.10
```

See [examples/pfsense-firewall.md](examples/pfsense-firewall.md).

### Direct public IP

```text
Public host:                 203.0.113.10
FRP control:                 public 443   =  listen 443
Allocator HTTPS:             public 6099  =  listen 6099
Published services:          6000-6098
```

Open those ports on the host firewall or cloud security group. The installer
does not configure firewalls. If 443 is already taken, put FRP control on 8443
(or any free port).

### Enterprise single-443

Use this when a corporate filter allows TCP to a non-standard port but resets
TLS ClientHello there. Do not switch the allocator to HTTP.

```text
Public host:                 203.0.113.10
Public TCP/443:              nginx (allocator HTTPS + FRP control over WSS)
Allocator backend:           127.0.0.1:6099 (not published)
FRP control backend:         127.0.0.1:7000 (not published)
Published services:          6000-6098
```

```bash
FRP_PUBLIC_HOST=203.0.113.10 FRP_DEPLOYMENT_MODE=single443 sudo bash install-server.sh
```

Inbound: TCP/443 and TCP/6000-6098. Details, migration, and rollback:
[docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

## 2. Install the FRP server

Stable installs pull from the immutable `v2.1.0` tag (not mutable `main`):

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-server.sh | sudo bash
```

Opt into follow-`main` only with `FRP_RELEASE_CHANNEL=dev` (or an explicit
`main` raw URL). A stable server's generated client installer URL also pins
`v2.1.0`.

The installer asks for the public hostname/IP and public vs listen ports. Values
are stored in `/etc/frp-auto-deploy/config.json`. There is no hard-coded public
address.

Non-interactive variables:

```text
FRP_PUBLIC_HOST
FRP_DEPLOYMENT_MODE              (direct | single443; default direct)
FRP_CONFIRM_MODE_SWITCH          (yes; required for a non-interactive mode cutover)
FRP_CONTROL_PUBLIC_PORT          (alias: FRP_CONTROL_PORT when both public and listen are unset)
FRP_CONTROL_LISTEN_PORT
FRP_ALLOCATOR_PUBLIC_PORT
FRP_ALLOCATOR_LISTEN_PORT        (alias: FRP_ALLOCATOR_PORT)
FRP_PORT_START
FRP_PORT_END
FRP_ALLOCATOR_PUBLIC_URL         (alias: FRP_ALLOCATOR_URL; HTTPS required)
```

Direct-mode defaults for a simple exposed server: control 443/443, allocator
6099/6099, services 6000-6098. Single-443 defaults: public 443 for both
allocator HTTPS and FRP WSS, allocator backend 127.0.0.1:6099, FRP backend
127.0.0.1:7000. Re-running the installer reuses the existing runtime config
unless those variables are set. An existing private CA, FRP token, registry,
and reservations are preserved. Switching Direct ↔ single-443 is a
maintenance-window cutover; see [docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

`curl | sudo bash` fetches the installer bundle from GitHub. That is a separate
trust domain from allocator CA pinning. See [docs/SECURITY.md](docs/SECURITY.md).

### Verify the server (after install)

The project CA exists on the **server** only after `install-server.sh` finishes.
Use `--cacert /etc/frp-auto-deploy/pki/ca.crt` for those post-install checks.
Do not use `curl -k` as a production verification flow. Do not download
`/ca.crt` with `--cacert` pointing at a file that does not exist yet
(that is not first-trust bootstrap; see B below).

**A. Pre-enrollment diagnostic (transport only, not a trust test)**

From an operator workstation, TCP reachability is a connectivity check only:

```bash
nc -vz 203.0.113.10 6099    # Direct allocator port; omit for single-443
nc -vz 203.0.113.10 443
```

If TCP connects but TLS ClientHello is reset, that is the enterprise DPI
pattern. Use [single-443 mode](docs/DEPLOYMENT_MODES.md). Do not disable TLS,
do not switch the allocator to HTTP, and do not treat `curl -k` as validation.

**B. First bootstrap fingerprint verification**

The client installer (not a manual `curl --cacert`) does this:

1. GET `/ca.crt` over HTTPS (the local CA file does not exist yet)
2. Parse it as X.509 and SHA256 the **canonical DER** of the **CA**
3. Compare that fingerprint to `FRP_ALLOCATOR_CA_SHA256`
4. Store `/etc/frp-auto-deploy/allocator-ca.crt` only on match

Operators copy the install command printed by `frp-create-client`, which already
sets `FRP_ALLOCATOR_CA_SHA256`. There is no TOFU and no self-signed
`--cacert /tmp/ca.crt https://host/ca.crt -o /tmp/ca.crt` loop.

**C. Post-enrollment / post-install verified HTTPS**

On the **server**, after install (CA file is present):

```bash
sudo frpctl status
sudo frp-server-status --check
sudo systemctl status frps --no-pager
sudo systemctl status frp-port-allocator --no-pager
# Direct mode (allocator listen default 6099):
curl -fsS --cacert /etc/frp-auto-deploy/pki/ca.crt https://127.0.0.1:6099/healthz
# Single-443: public frontend is TCP/443; allocator backend stays localhost:6099
curl -fsS --cacert /etc/frp-auto-deploy/pki/ca.crt https://127.0.0.1:6099/healthz
curl -fsS --cacert /etc/frp-auto-deploy/pki/ca.crt https://127.0.0.1/healthz
sudo systemctl status frp-frontend --no-pager
```

On the **client**, after enrollment, later allocator calls use the stored CA:

```text
/etc/frp-auto-deploy/allocator-ca.crt
```

Adjust the Direct-mode healthz port if the allocator listen port is not 6099.

## 3. Create a client — zero-touch SSH (recommended)

On the FRP server, interactive TTY collects the SSH login account that already
exists on the client. There is no default username (`ubuntu`, `root`, or any
distro-specific account). Blank usernames are rejected.

```bash
sudo frp-create-client \
  --one-line \
  --ssh \
  --note customer-01
```

The same flow is available as `sudo frpctl enroll --one-line --ssh` or from the
guided enrollment menu (`sudo frpctl` → Create enrollment → Zero-touch SSH).

```text
SSH service setup
=================

Enter the SSH login account that already exists on the client machine.

Client SSH user: aella
SSH port [22]:

Client configuration
--------------------
SSH user : aella
SSH port : 22
Target   : 127.0.0.1:22
```

Automation may pass `--ssh-user` and skip the prompt:

```bash
sudo frp-create-client \
  --one-line \
  --ssh \
  --ssh-user aella \
  --note customer-01
```

Non-interactive `--one-line --ssh` without `--ssh-user` fails:

```text
ERROR: --ssh-user is required for non-interactive zero-touch SSH creation.
```

Send the generated **one-line** command to the remote user. They paste it and
press Enter. There is no Enrollment Code prompt, no service menu, and no FRP
configuration knowledge required. The command includes `FRP_SSH_USER` from the
account entered (or supplied) above.

The command contains a short-lived Bootstrap Ticket. Treat it as sensitive until
used or expired. Use a placeholder like `<short-lived-bootstrap-ticket>` in
docs; never publish a real ticket.

Zero-touch does **not**:

- create a user
- install an SSH server
- change passwords
- modify `authorized_keys`
- enable root login
- change `sshd_config`

Required beforehand:

- `sshd` already listening
- the SSH user already exists
- the administrator already has an authentication method

After the client connects:

```bash
sudo frpctl show clients
sudo frpctl show client customer-01
```

Connect with the **public** host and **public** service port:

```bash
ssh -p <public-port> ubuntu@203.0.113.10
```

Never use the internal listen IP/port in connection commands.

## 4. Manual enrollment (still supported)

Zero-touch is not mandatory.

On the server:

```bash
sudo frp-create-client
```

Example (truncated; not a real secret):

```text
Enrollment Code:
7e41d99163a5c410.73f36d...

Expires: 2026-08-26T11:10:00Z (600 seconds)

FRP Server:
203.0.113.10:8443

Allocator:
https://203.0.113.10:9443/enroll

CA SHA256:
<64 lowercase hex characters>

Client install:
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh |
sudo env \
  FRP_ALLOCATOR_URL='https://203.0.113.10:9443/enroll' \
  FRP_ALLOCATOR_CA_SHA256='<sha256>' \
  bash
```

Run that install command on the client. Enter the Enrollment Code interactively,
select services, confirm, install.

`FRP_ALLOCATOR_URL` must be HTTPS. First install is sequence **B** above: download
`/ca.crt`, check the SHA256 fingerprint, store
`/etc/frp-auto-deploy/allocator-ca.crt`. Later calls are sequence **C**
(`curl --cacert` with that stored CA). The CA fingerprint does not validate the
GitHub bootstrap script.

Built-in TCP presets (passthrough, not FRP virtual hosts): SSH `127.0.0.1:22`,
HTTP `127.0.0.1:80`, HTTPS `127.0.0.1:443`, custom TCP.

Example local targets (LAN application addresses, not FRP public endpoints):

```text
SSH         127.0.0.1:22
Grafana     127.0.0.1:3000
Web Admin   192.0.2.80:443
```

A successful install writes `/etc/frp/client-state.json` (mode 600, no secrets).
`frpc.toml` and `access-info.txt` are generated from that state.

If the first-install bootstrap is run again on an already-installed client, it
refuses re-enrollment and points at `sudo frpctl update`.

---

# Everyday operations

For normal operation, remember:

```bash
sudo frpctl
```

That starts the persistent CLI. Type `?` for context help, or `help` for the
full syntax. Press Tab to complete a unique match or list next-token candidates.
`↑` / `↓` walk this session only (nothing is saved to disk). `menu` opens the
guided numbered menu. The canonical client selector is CLIENT ID.

Grammar: `<verb> <resource> [target] [property] [value]`. Full tree:
[docs/CLI_REFERENCE.md](docs/CLI_REFERENCE.md).

```bash
sudo frpctl show status
sudo frpctl show version
sudo frpctl doctor
sudo frpctl doctor --json
sudo frpctl update project --check
sudo frpctl help
sudo frpctl help set client
```

`show status` (`status`) is a fast snapshot. `doctor` is deeper and read-only.
Configuration uses `set` / `unset`. Lifecycle uses `create`, `revoke`,
`release`, `update`, and `restore`. Those verbs are not interchangeable.

Official upstream binaries are `frps` and `frpc`. `frpctl` and the other `frp-*`
commands belong to this project.

| Task | Command |
| --- | --- |
| Interactive CLI | `sudo frpctl` |
| List clients | `sudo frpctl show clients` |
| Client details | `sudo frpctl show client ID` |
| Set label / note / tag | `sudo frpctl set client ID label VALUE` |
| Unset metadata | `sudo frpctl unset client ID label` |
| Enroll / zero-touch | `sudo frpctl create enrollment --ssh --ssh-user USER --label NAME` |
| Revoke identity | `sudo frpctl revoke client ID` |
| Release one service | `sudo frpctl release service ID SVC` |
| Release client | `sudo frpctl release client ID` |
| Update project | `sudo frpctl update project` |
| Client services | `sudo frpctl show services` / `sudo frpctl add service` |

---

# Lifecycle semantics

```text
disable  !=  release
revoke   !=  release
uninstall !=  release
uninstall !=  purge
update   !=  re-enrollment
```

## Services

Add, Edit, Disable, Re-enable, Release.

- Edit preserves the public port
- Disable preserves the public port
- Re-enable reuses the same public port
- Release frees the port

At least one enabled service is required.

## Clients

Enroll → Active → Revoke and/or Release → Uninstall → Re-enroll/recovery.

- Uninstall on the client is local removal only; the server keeps reservations
- Revoke blocks signed management; reservations remain
- Release frees ports
- Lost local identity is recovered with a new Enrollment Code, not with `frpctl update`

## Failure / transaction model

Operations are staged. Critical writes are atomic. Runtime apply is verified.
Failed update/apply rolls back where that is safe. Ambiguous reservation state
is preserved. `RECOVERY_REQUIRED` / `FAILURE_CLASS=` are explicit. Follow
`sudo frpctl doctor` rather than editing the registry by hand.

Retries of the same logical Apply (new timestamp/nonce/signature) reuse existing
public ports. Exact replay of a signed nonce is rejected.

---

# Update

Project version and FRP binary version are different.

| Host | `sudo frpctl update` does |
| --- | --- |
| Client | Upgrades `frp-auto-deploy` tools. Preserves CA file, identity, `client-state.json`, ports. No Enrollment Code when trust exists. Does not rewrite a working `frpc.toml` or restart `frpc` unless the pinned FRP binary actually changes. |
| Server | Upgrades the **pinned FRP binary** (`frps`) only, with health-check rollback. Does not rotate CA, token, or registry. |

Server **project tooling** (allocator scripts, `frpctl`, …) is refreshed by
re-running the server installer / `bootstrap-server.sh`. That reinstall
preserves private CA, FRP token, registry, and reservations unless you change
configuration that requires a leaf certificate reissue.

```bash
sudo frpctl update
sudo frp-update --check          # server FRP binary, check only
sudo frpctl project-update --check
sudo frp-client update           # client project tools
```

Same-version server project updates compare **build identity** (the SHA256SUMS
digest of `dist/bootstrap-server.sh`), not only `PROJECT_VERSION`. `--check` is
read-only. A matching semantic version with a different or unknown bundle SHA
is an update; the same verified SHA is `not needed` and does not mutate state.

Hosts installed before `frpctl`:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/bootstrap-client.sh \
| sudo bash -s -- --upgrade
```

Update is not re-enrollment. Already enrolled 1.9.1 clients remain compatible
with a 2.0.0 server (management protocol schema 1 is unchanged).

Legacy clients installed before secure project-update metadata
require a one-time verified bridge. The old updater cannot retroactively
verify an artifact before executing it. Do not pipe a mutable `main` URL
into `sudo`. Download `SHA256SUMS` and `dist/bootstrap-client.sh` from the
same immutable commit, require the checksums to match, then run the bundle
with explicit `FRP_RELEASE_CHANNEL` / `FRP_EXPECTED_SOURCE_REF` and
`FRP_BUNDLE_SHA256`. See `docs/FRP_UPGRADE.md`.

---

# Uninstall and purge

| Operation | Effect |
| --- | --- |
| Client uninstall | Local removal only. Does **not** contact the server. Does **not** release ports. |
| Server uninstall | Removes software/runtime. Token, CA, config, registry, reservations **preserved**. |
| Server purge | Destructive. Requires `--purge --yes`. Deletes token, CA, registry, enrollments, config. |

### Client

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/uninstall-client.sh | sudo bash
```

After uninstall, a later install is a new enrollment because local identity is
gone. Release ports on the server if they should be freed.

### Server

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/uninstall-server.sh | sudo bash
```

Purge (test hosts / decommission only):

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/v2.1.0/dist/uninstall-server.sh | sudo bash -s -- --purge --yes
```

---

# Doctor and troubleshooting

```bash
sudo frpctl status              # fast snapshot
sudo frpctl doctor              # deeper read-only diagnostics
sudo frpctl doctor --json       # machine-readable; JSON schema_version 1
```

Doctor is **read-only**. It does not restart services, rewrite configuration,
release ports, revoke clients, consume a management nonce, or update software.

Exit 0: no FAIL findings (warnings allowed). Exit 1: one or more FAIL findings.
Exit 2: doctor itself could not complete.

Check IDs in `--json` are a stable automation surface (for example
`client_state`, `frpc_config`, `allocator_health`, `frp_version`,
`pending_transaction`). Do not rename them casually.

Primary recovery: run doctor, then the recommended action.

| Symptom | Typical action |
| --- | --- |
| `client-state.json` invalid | Restore `/etc/frp/client-state.json` from the latest valid backup |
| `frpc.toml` missing | `sudo frp-client` → Apply current configuration (generated from client-state) |
| Allocator TLS hostname mismatch | Re-run the **server** installer (same CA; leaf reissued) |
| FRP binary version mismatch | `sudo frpctl update` |
| Pending Apply / pending update | Retry `sudo frpctl update` or Apply; do not delete markers by hand |
| Rollback failure / `RECOVERY_REQUIRED` | Follow the printed `FAILURE_CLASS`; doctor for state |
| Registry corruption | Restore `registry.json` from backup; doctor does not repair it |
| Allocator unreachable | Check public HTTPS URL, NAT, firewall, `frp-port-allocator` unit |
| TCP connect works, TLS ClientHello reset | Enterprise DPI on a non-standard TLS port; use single-443 mode, not HTTP |
| `frpc` / `frps` inactive | `systemctl status`; then doctor |

---

# Architecture

Public endpoints and local listeners are independent. Direct mode does not
need FRP to own public TCP/443. Enterprise single-443 shares one public TLS
port; see [docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

```text
FRP control:     public port  may differ from  listen port
Allocator HTTPS: public port  may differ from  listen port
Published svc:   public port  ==  remote/listen service port (1:1)
```

Example:

```text
Public FRP 8443       ->  internal frps 443
Public allocator 9443 ->  internal allocator 6099
Public service 6002   ->  internal service port 6002
```

On a direct public host, matching ports (443/443, 6099/6099) are valid
convenience defaults.

Connection info always uses the public host and public service port.

Canonical local files:

```text
client-state.json   canonical desired local state (no secrets)
frpc.toml           generated runtime artifact
access-info.txt     generated display artifact
registry.json       server port/identity registry (do not hand-edit)
```

Registry schema is **v2**. Schema v1 registries are refused, not rewritten.
See [docs/SCHEMA_V2_DEPLOYMENT.md](docs/SCHEMA_V2_DEPLOYMENT.md).

---

# Security model

Summary (full write-up: [docs/SECURITY.md](docs/SECURITY.md)):

1. FRP tunnel = FRP TLS + FRP token (tunnel only)
2. Management transport = HTTPS + private CA + server certificate verification
3. Bootstrap = Enrollment Code **or** short-lived Bootstrap Ticket
4. Persistent management = ECDSA P-256 + timestamp + nonce + signed request
5. Replay window: `MAX_CLOCK_SKEW=300`, `MGMT_NONCE_TTL=900`, `MAX_NONCES_PER_CLIENT=256`

Local root compromise on the FRP server or client is **outside** the protection
boundary.

**Secrets:** FRP token, Enrollment Code, valid Bootstrap Ticket, client private
key, management MAC, CA key, TLS server key.

**Not secrets:** CA cert, CA fingerprint, server cert, management public key,
service ID, public port, public hostname.

Expected modes include `server_token`/`ca.key`/`server.key`/`client-identity.key`
`0600`, and `ca.crt`/`server.crt`/`allocator-ca.crt` `0644`.

Checksums validate FRP archives and repository `SHA256SUMS`. This project does
not currently ship signatures of its own bootstrap scripts.

---

# Compatibility

Automated **systemd Linux** on **x86_64** and **aarch64/arm64**.

Runtime minimums: Bash 4.2, Python 3.7 (distro `python3`, no PyPI), usable
systemd (`/run/systemd/system`), and `apt-get` / `dnf` / `yum`. Also `curl`,
`openssl`, `tar`, and `sha256sum` (or equivalent).

The installers do not disable SELinux and do not change firewalld, ufw,
iptables, or nftables.

### Support matrix

Do not read one `PASS` as covering every column.

| Distribution | Container userspace | LXD systemd PID1 | Real VM | SELinux Enforcing | TTY |
| --- | --- | --- | --- | --- | --- |
| Ubuntu 22.04 | PASS | N/A | PASS (live baseline) | N/A | PASS (live baseline) |
| Ubuntu 24.04 | PASS | N/A | PASS (live baseline) | N/A | PASS (live baseline) |
| Rocky Linux 9 | PASS | PASS | NOT_TESTED | NOT_TESTED | PASS (LXD TTY) |
| AlmaLinux 9 | PASS | PASS | NOT_TESTED | NOT_TESTED | PASS (LXD TTY) |
| Amazon Linux 2023 | PASS | PASS | NOT_TESTED | N/A | PASS (LXD TTY) |
| Amazon Linux 2 | PASS | NOT_TESTED | NOT_TESTED | N/A | NOT_TESTED |
| Debian 12 | Best-effort | NOT_TESTED | NOT_TESTED | N/A | Unit tests |
| Fedora current | Best-effort | NOT_TESTED | NOT_TESTED | N/A | Unit tests |
| RHEL 9 / CentOS Stream 9 | Best-effort | NOT_TESTED | NOT_TESTED | N/A | Unit tests |

**Container** = Docker userspace (`./tests/run-distro-matrix.sh`). Not a real VM,
not real systemd PID 1, not SELinux Enforcing.

Rocky/Alma **SELinux Enforcing** remains `NOT_TESTED`. This project does not
claim full support on Enforcing until that gate is recorded in
[docs/RELEASE_VALIDATION.md](docs/RELEASE_VALIDATION.md).

2.1.0 field-validated Enterprise single-443 on **Ubuntu 24.04 x86_64** with a
direct public-IP server and an enterprise-restricted client: HTTPS/443
enrollment, WSS/443 control, published SSH, and client/server reboot recovery.
That evidence does **not** cover firewall DNAT / private FRP-server topology,
SELinux Enforcing, ARM64 hosts, or OpenSSL 1.0.2 hosts.

Full ARM64 systemd install: `NOT_TESTED` (arch mapping is unit-tested).
Real OpenSSL 1.0.2 TLS enrollment: `NOT_TESTED` (Amazon Linux 2 container is
userspace only).
Firewall DNAT / private FRP-server topology: `NOT_TESTED` in a real environment.

Windows: FRP supports Windows; this package automates systemd Linux only. See
[windows/README.md](windows/README.md).

On Amazon Linux 2 (systemd 219), the allocator unit omits newer hardening
directives (`ProtectSystem=strict`, `ReadWritePaths`, `NoNewPrivileges`).
`PrivateTmp` is kept.

---

# Backups

Server (minimum):

```text
/etc/frp-auto-deploy/pki/
/etc/frp/server_token
/etc/frp-auto-deploy/config.json
/var/lib/frp-auto-deploy/registry.json
```

Losing the private CA is not fixed by `frpctl update`. See
[docs/SECURITY.md](docs/SECURITY.md) for disaster recovery.

Do not copy client private keys over insecure channels. Client uninstall
removes local identity on purpose.

---

# Existing server migration

The server installer can run over an existing FRP deployment. An existing
`/etc/frp/server_token` is reused. Legacy inline `auth.token` is migrated into
that file without changing its value. A new token is generated only on a genuine
fresh install.

Before rewriting `frps.toml`, the old configuration is copied to a timestamped
mode-`600` backup. Active listeners in the configured service range are reserved
so existing published ports are not handed to a new client.

---

# Important files

### Server

```text
/etc/frp/server_token
/etc/frp/frps.toml
/etc/frp-auto-deploy/config.json
/etc/frp-auto-deploy/version
/etc/frp-auto-deploy/pki/ca.crt
/etc/frp-auto-deploy/pki/ca.key
/etc/frp-auto-deploy/pki/server.crt
/etc/frp-auto-deploy/pki/server.key
/var/lib/frp-auto-deploy/registry.json
/var/lib/frp-auto-deploy/mgmt-nonces.json
/var/lib/frp-auto-deploy/enrollments/
/var/lib/frp-auto-deploy/bootstrap/
/usr/local/sbin/frpctl
```

### Client

```text
/etc/frp/frpc.toml
/etc/frp/client-state.json
/etc/frp/client-identity.key
/etc/frp/client-identity.pub
/etc/frp/client-identity.mac
/etc/frp/access-info.txt
/etc/frp-auto-deploy/version
/etc/frp-auto-deploy/allocator-ca.crt
/usr/local/bin/frpc
/usr/local/bin/frp-client
/usr/local/bin/frpctl
```

---

# Development

```bash
git clone https://github.com/datarelay-labs/frp-auto-deploy.git
cd frp-auto-deploy
```

Local non-Docker regression (CI-equivalent minus the container matrix):

```bash
./tests/run-all.sh
```

Release gate:

```bash
./tests/run-all.sh
./tests/run-distro-matrix.sh
./scripts/build-bundles.sh
git diff --exit-code dist/
./scripts/verify-sha256sums.sh
git diff --check HEAD
```

`CONTAINER_MATRIX=PASS` is not `REAL_VM=PASS`. Real-environment procedure:
[docs/RELEASE_VALIDATION.md](docs/RELEASE_VALIDATION.md).
Checklist: [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md).

Read-only live host collector: `tests/live-distro-smoke.sh`.

Rebuild standalone bundles after source changes:

```bash
./scripts/build-bundles.sh
./scripts/update-sha256sums.sh
```

The repository must not contain real tokens, enrollment secrets, private keys,
runtime configs, or live infrastructure addresses.

---

# Known limitations

- TCP services only (no UDP automation)
- Service NAT is 1:1 port-number mapping
- No automatic firewall, SELinux policy, or SSH account/key management
- No Web UI, database, HA, mTLS, or CA-rotation UI
- Windows client automation is not included
- Real VM / SELinux Enforcing / ARM64 systemd / real OpenSSL 1.0.2 TLS enrollment
  remain `NOT_TESTED` where the matrix says so
- Firewall DNAT / private FRP-server topology was not field-validated in 2.1.0
- Installer bundles are checksummed, not signed by this project
