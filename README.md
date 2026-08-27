# frp-auto-deploy

`frp-auto-deploy` is a lightweight deployment and management layer for the official [fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or modify FRP.

It automates FRP server/client installation, persistent public port assignment for SSH, web, and custom TCP services, short-lived client enrollment, systemd startup, migration from an existing FRP deployment, and connection-info output.

> **Note**
> The IP addresses `203.0.113.10` and `192.0.2.50` used in this README are documentation-only example addresses (RFC 5737). Replace them with your own public and internal addresses when deploying.

Current pinned FRP version: **v0.70.1**
Current project version: **1.6.0**

---

# Everyday command

For normal operation, this is the only command you need to remember:

```bash
sudo frpctl
```

That starts the persistent interactive management CLI. Then type `help` or `?` for the commands that apply to this host. Press Tab to complete commands. On a server, Tab also completes registered client names and service IDs. If this shell cannot bind custom Tab completion, `frpctl` stays usable and does **not** fall back to filesystem completion.

```text
$ sudo frpctl

FRP Auto Deploy CLI
===================

Role            : Server
Project version : 1.6.0
FRP version     : 0.70.1

Type 'help' or '?' for available commands.
Press Tab to complete commands.

frpctl> clients
...

frpctl> client dp-os-upgrade
...

frpctl> exit
```

Client example:

```text
$ sudo frpctl

FRP Auto Deploy CLI
===================

Role            : Client
Project version : 1.6.0
FRP version     : 0.70.1

frpctl> status
...

frpctl> manage
...
frpctl> exit
```

Inside the CLI, `menu` opens the guided numbered menu. After you leave that menu, you return to `frpctl>`, not to the Linux shell.

Direct commands remain available for automation, scripts, and advanced users:

```bash
sudo frpctl status
sudo frpctl clients
sudo frpctl update
sudo frpctl help
```

Official upstream FRP binaries are:

```text
frps   # FRP server
frpc   # FRP client
```

`frps` and `frpc` are the official upstream FRP binaries. `frpctl` and the other `frp-*` commands (`frp-client`, `frp-clients`, `frp-create-client`, `frp-server-status`, `frp-release-service`, `frp-revoke-client`, `frp-update`, and so on) belong to this `frp-auto-deploy` operational layer. This project does **not** fork or modify FRP. Advanced users and automation may continue calling the individual commands directly.

---

# Quick Start

Two common deployment models are supported:

1. **FRP server behind a firewall/NAT device** — public ports may differ from the ports `frps` and the allocator listen on locally.
2. **FRP server directly on a public IP** — public and listen ports are usually the same.

TCP/443 is **not** required. A site may already use 443 for a web server, VPN, or another HTTPS service.

Management (enrollment and signed client updates) is **HTTPS-only** and uses a project-managed private CA. FRP data/control traffic continues to use FRP native TLS plus the FRP token. There is no mutual TLS: clients authenticate with the existing ECDSA P-256 management identity after the one-time Enrollment Code.

Published service ports use a 1:1 public/internal port-number model (public 6002 forwards to the same remote port 6002 on this FRP server).

## 1. Choose your network topology

### Option A — NAT, existing service already on TCP/443

```text
Internet

Existing service
     TCP/443
        |
        v
   other system


FRP client  --TCP/8443-->  Public/NAT  --8443->443-->  frps listen TCP/443

Management  --HTTPS/9443--> Public/NAT --9443->6099--> allocator HTTPS TCP/6099

Service user --TCP/6002--> Public/NAT --6002->6002--> frps remote port 6002
```

Server installer values:

```text
Public hostname or IP:       203.0.113.10
FRP control public port:     8443
FRP control listen port:     443
Allocator public HTTPS port: 9443
Allocator listen port:       6099
Service range start:         6000
Service range end:           6098
```

Client-facing endpoints:

```text
FRP Server:  203.0.113.10:8443
Allocator:   https://203.0.113.10:9443/enroll
```

Required DNAT (port numbers for published services stay 1:1):

```text
203.0.113.10:8443      -> 192.0.2.50:443
203.0.113.10:9443      -> 192.0.2.50:6099
203.0.113.10:6000-6098 -> 192.0.2.50:6000-6098
```

The installer prints this mapping. It does not configure upstream routers, cloud NAT, or load balancers.

### Option B — FRP server directly on a public IP

```text
Internet / Remote Linux clients
        |
        v
203.0.113.10  (FRP server public IP)
        |
        +-- TCP/443        frps control (public = listen)
        +-- TCP/6000-6098  published TCP service ports
        +-- TCP/6099       enrollment allocator HTTPS
```

Use values like:

```text
Public hostname or IP:       203.0.113.10
FRP control public port:     443
FRP control listen port:     443
Allocator public HTTPS port: 6099
Allocator listen port:       6099
```

Allocator URL (derived when not overridden):

```text
https://203.0.113.10:6099/enroll
```

Allow inbound TCP for the ports you actually configured. Defaults are convenience only.

If you already occupy TCP/443, put FRP control on 8443 (or any free port) instead. Do not assume two raw TCP services can share one public IP:port without an external proxy.

## 2. Install the FRP server

Run on the FRP server:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-server.sh | sudo bash
```

The installer asks for the public hostname/IP and the public vs internal listen ports shown above. There is no hard-coded public address; values are stored in `/etc/frp-auto-deploy/config.json`.

Non-interactive install uses environment variables:

```text
FRP_PUBLIC_HOST
FRP_CONTROL_PUBLIC_PORT          (alias: FRP_CONTROL_PORT when both public and listen are unset)
FRP_CONTROL_LISTEN_PORT
FRP_ALLOCATOR_PUBLIC_PORT
FRP_ALLOCATOR_LISTEN_PORT        (alias: FRP_ALLOCATOR_PORT)
FRP_PORT_START
FRP_PORT_END
FRP_ALLOCATOR_PUBLIC_URL         (alias: FRP_ALLOCATOR_URL; HTTPS required)
```

Defaults for a simple directly exposed server are control 443/443, allocator 6099/6099, and services 6000-6098. Re-running the installer reuses the existing runtime config unless those variables are set. An existing private CA is preserved; a public-host change may reissue the server certificate from the same CA. Pre-P2.8 `http://` allocator URLs are not reused.

Verify the server:

```bash
sudo frpctl
sudo frpctl status
sudo frp-server-status --check
sudo frpctl update
```

`frpctl` is the everyday entry point. With no arguments it starts the persistent CLI. `frp-server-status --check` confirms registry schema v2 and that the public host and allocator URL are configured. It does not change the server.

`frpctl update` on a server host runs `frp-update`, which upgrades the FRP server binary only to the version tested by `frp-auto-deploy` and automatically rolls back if the new server fails its health checks. On a fresh install it is a no-op.

You can also inspect systemd directly:

```bash
sudo systemctl status frps --no-pager
sudo systemctl status frp-port-allocator --no-pager
curl -fsS --cacert /etc/frp-auto-deploy/pki/ca.crt https://127.0.0.1:6099/healthz
```

## 3. Create a client enrollment code

On the FRP server:

```bash
sudo frp-create-client
```

Example:

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
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh |
sudo env \
  FRP_ALLOCATOR_URL='https://203.0.113.10:9443/enroll' \
  FRP_ALLOCATOR_CA_SHA256='<sha256>' \
  bash
```

Enrollment codes expire after 10 minutes by default and are bound to the first machine that uses them. The enrollment secret is entered interactively; it is not placed on the command line. The CA fingerprint is public trust metadata and may appear in the install command.

`sudo env` is required so `FRP_ALLOCATOR_URL` and `FRP_ALLOCATOR_CA_SHA256` reach the installer after `sudo` resets the environment.

## 4. Install a remote Linux client

Run the command printed by `frp-create-client` on the remote Linux server. Example:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh \
| sudo env \
    FRP_ALLOCATOR_URL='https://203.0.113.10:9443/enroll' \
    FRP_ALLOCATOR_CA_SHA256='<sha256>' \
    bash
```

`FRP_ALLOCATOR_URL` must be HTTPS. First install downloads `/ca.crt` once, checks the SHA256 fingerprint, and stores `/etc/frp-auto-deploy/allocator-ca.crt`. All later allocator calls use verified HTTPS (`curl --cacert`). Software update preserves that CA file and does not require a new Enrollment Code.

If it is missing, the client bootstrap exits with a clear error and does not install FRP.

The installer explains each field as you go. Values in `[brackets]` are defaults; press Enter to accept them. You need a short-lived Enrollment Code from `sudo frp-create-client` on the FRP server. It is entered interactively, is not stored on the client, and is not the FRP token. After this first enrollment, the client creates a local management identity so later configuration changes do not require another Enrollment Code.

```text
=========================================
 FRP Client Setup
=========================================

This installer publishes services on this Linux system
through your FRP server.

Before continuing, you need an Enrollment Code.

Generate one on the FRP server with:

  sudo frp-create-client

Tip:
  Values shown in [brackets] are defaults.
  Press Enter to accept the default value.

Enrollment Code:
```

Then add one or more TCP services. SSH is optional. The FRP server assigns the public port automatically.

```text
Add a service
=============

1) SSH
   Remote shell access.
   Default target: 127.0.0.1:22

2) HTTP
   Web application using plain HTTP.
   Default target: 127.0.0.1:80

3) HTTPS
   Web application using HTTPS.
   Default target: 127.0.0.1:443

4) Custom TCP
   Any other TCP service.

5) Back
```

Built-in presets:

- SSH (`127.0.0.1:22` by default)
- HTTP (`127.0.0.1:80` by default)
- HTTPS (`127.0.0.1:443` by default) — TCP passthrough, no TLS termination
- Custom TCP (any host:port)

The installer shows a review and asks `Continue? [Y/n]` before changing the system.

### First-time field guide

These fields are also explained in the installer:

```text
Enrollment Code
  Generated on the FRP server with:
  sudo frp-create-client

Service ID
  Stable unique identifier used to preserve the public port.
  Lowercase and case-insensitive (SSH, ssh, and Ssh are the same ID).

Target host
  Where the real service runs.
  127.0.0.1 means this client machine.

Target port
  Port used by the real service.

SSH user
  Username displayed in the generated SSH command.
  This does not create an OS account.

Public port
  Automatically allocated by the FRP server.
```

Example:

```text
SSH
127.0.0.1:22

Grafana
127.0.0.1:3000

Web Admin
192.168.122.2:443
```

Example completion output:

```text
=========================================
 FRP Installation Complete
=========================================

Your FRP client is running successfully.

Published services
------------------

SSH
  Local target : 127.0.0.1:22
  Public port  : 6002

Connect from another machine with:

  ssh -p 6002 aella@203.0.113.10

For normal operation, this is the only command you need to remember:

  sudo frpctl

Then type help inside the CLI.

Useful commands
---------------

Everyday CLI / status / update:
  sudo frpctl
  sudo frpctl status
  sudo frpctl update

Advanced direct commands (still supported):
  sudo frp-client
  sudo frp-client status
  sudo frp-client info
```

The assigned ports are persistent. Reinstalling the same service on the same machine reuses the previous public port based on `/etc/machine-id` plus the service ID. Changing a service's local target does not reallocate its public port.

A successful install writes `/etc/frp/client-state.json` (mode 600, no secrets). `frpc.toml` and `access-info.txt` are generated from that state. Do not treat `frpc.toml` as the document to edit.

## 5. Manage an installed client

Need to expose another service later? Do not reinstall FRP. Do not re-run the bootstrap installer.

```bash
sudo frpctl
```

That starts the persistent CLI. Type `manage` to add or edit services, or `menu` for the guided numbered menu. Equivalents:

```bash
sudo frpctl manage
sudo frp-client
```

Example:

```text
FRP Client Management
=====================

Client: dp-example
Server: 203.0.113.10

1) Add service
→ Custom TCP
→ grafana
→ 127.0.0.1:3000

6) Apply pending changes
Authentication: existing client identity
Continue? [Y/n]: Y
```

Read-only commands do not require an Enrollment Code and do not contact the allocator:

```bash
sudo frpctl status
sudo frp-client status
sudo frp-client info
```

The Enrollment Code is a short-lived bootstrap/recovery credential. After the first successful enrollment, later add/edit/enable/disable applies are authorized by this client's local management identity. The private identity stays on the client (`/etc/frp/client-identity.key`, mode 600). The FRP server stores only the matching public identity. The FRP tunnel token is separate and is never used as a management password.

An Enrollment Code is needed again only to enroll a new client, recover a lost local identity, or re-establish trust after an administrator revokes management access with `sudo frp-revoke-client`.

Existing clients that already have `client-state.json` but no management identity are asked for a one-time Enrollment Code on the first server-affecting Apply. After that, later changes use the local identity.

Display-name and SSH-user metadata changes stay local: they do not contact the allocator, do not require an Enrollment Code or management signature, and do not restart `frpc`.

Disable a service to stop publishing it. The public port stays reserved. Re-enable to get the same port back. Permanent per-service release is done on the server with `sudo frp-release-service <client> <service-id>`. `frp-release-client` still releases the whole client. Revoking a client's management identity (`sudo frp-revoke-client`) does not release ports.

At least one enabled service is required. Clients installed before this management state must be re-enrolled once with the current bootstrap installer.

### Update an installed client

Do not re-run the enrollment bootstrap to update software. That installer asks for an Enrollment Code and is for first install or trust recovery only.

```bash
sudo frpctl update
```

Equivalent:

```bash
sudo frp-client update
```

A host that was installed before `frpctl` existed can upgrade from the current bundle without first installing the new command:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh \
| sudo bash -s -- --upgrade
```

A software update preserves client state, `frpc.toml`, access information, management identity files, `/etc/frp-auto-deploy/allocator-ca.crt`, service IDs, enabled/disabled state, and public port assignments. It does **not** require an Enrollment Code when trust already exists. It does not regenerate a valid management identity, does not rewrite a working `frpc.toml`, and does not restart `frpc` unless the runtime FRP binary actually changes. Existing clients without `/etc/frp-auto-deploy/version` are treated as legacy/pre-version-tracking installs and are migrated into version tracking.

If the bootstrap installer is run again on an already-installed client, it refuses to re-enroll and points at `sudo frpctl update`.

## 6. Manage clients on the server

The everyday command is still `sudo frpctl`. Inside the CLI, `clients`, `client <name>`, `enroll`, `revoke <name>`, `release-service`, and `release-client` dispatch to the existing tools. Direct equivalents remain available:

List registered clients:

```bash
sudo frpctl clients
sudo frp-clients
```

Show connection information for one client:

```bash
sudo frpctl client-info customer-dp
sudo frp-client-info customer-dp
```

Release a client's reserved ports after its remote `frpc` has been stopped or uninstalled:

```bash
sudo frpctl release-client customer-dp
sudo frp-release-client customer-dp
```

Release one service reservation while leaving the rest of the client intact:

```bash
sudo frpctl release-service customer-dp grafana
sudo frp-release-service customer-dp grafana
```

Revoke a client's management identity without releasing ports:

```bash
sudo frpctl revoke-client customer-dp
sudo frp-revoke-client customer-dp
```

Create a longer-lived enrollment code when needed:

```bash
sudo frpctl create-client --ttl 1800 --note customer-dp
sudo frp-create-client --ttl 1800 --note customer-dp
```

---

# Uninstall

## Client

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/uninstall-client.sh | sudo bash
```

The local FRP client, `frp-client`, generated config, and local client-state are removed, but the central port reservation is intentionally preserved. Release it on the FRP server only when you want those ports reused.

## Server

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/uninstall-server.sh | sudo bash
```

Binaries and systemd units are removed. Token, configuration, and registry are preserved unless `--purge` is used.

---

# Project Details

## What this project provides

`frp-auto-deploy` adds an operational layer around upstream FRP:

- automatic FRP server installation
- automatic FRP client installation with menu-driven TCP service setup
- unified `frpctl` persistent CLI on server and client hosts
- post-install `frp-client` service add/edit/disable/re-enable without reinstalling FRP
- persistent client management identity after one-time enrollment
- persistent public port assignment for SSH, HTTP, HTTPS, and custom TCP services
- short-lived enrollment codes
- HMAC-authenticated enrollment requests and responses
- systemd service creation and restart handling
- central client/port registry (generic multi-service schema)
- migration from an existing manually configured FRP server
- client list, connection-info, and reservation management commands
- uninstall helpers and standalone bootstrap bundles
- safe client project-layer upgrades that preserve identity, state, and ports
- safe FRP server updates to the tested/pinned FRP version, with automatic rollback

FRP itself remains upstream and is downloaded from the official release during installation.

## Why not fork FRP?

This project does not need to change the FRP protocol or core FRP code. Keeping FRP upstream avoids maintaining a long-lived fork and makes FRP upgrades simpler. This repository focuses only on deployment, enrollment, persistence, migration, and management.

## Supported operating systems

This release automates **systemd Linux** on **x86_64** and **aarch64/arm64**.

Runtime minimums:

- Bash 4.2 or newer (Amazon Linux 2)
- Python 3.7 or newer (distribution `python3`, no PyPI packages)
- `systemctl` with a usable systemd runtime (`/run/systemd/system`)
- `apt-get`, `dnf`, or `yum` for automatic dependency installation

The installers detect **commands and package managers**, not marketing names. They do not disable SELinux and do not change firewalld, ufw, iptables, or nftables.

### Supported vs tested

Do not read a single `ROCKY_9=PASS` (or similar) as covering both container portability and a real VM. The columns below are separate.

| Distribution | Container | Systemd PID1 (LXD) | Real VM | SELinux | TTY Tab |
| --- | --- | --- | --- | --- | --- |
| Ubuntu 22.04 | PASS | N/A | PASS (live baseline) | N/A | PASS (live baseline) |
| Ubuntu 24.04 | PASS | N/A | PASS (live baseline) | N/A | PASS (live baseline) |
| Rocky Linux 9 | PASS | PASS | NOT_TESTED | NOT_TESTED | PASS (LXD TTY) |
| AlmaLinux 9 | PASS | PASS | NOT_TESTED | NOT_TESTED | PASS (LXD TTY) |
| Amazon Linux 2023 | PASS | PASS | NOT_TESTED | N/A | PASS (LXD TTY) |
| Amazon Linux 2 | PASS | NOT_TESTED | NOT_TESTED | N/A | NOT_TESTED |
| Debian 12 | Best-effort (apt path) | NOT_TESTED | NOT_TESTED | N/A | Unit tests |
| Fedora current | Best-effort (dnf) | NOT_TESTED | NOT_TESTED | N/A | Unit tests |
| RHEL 9 / CentOS Stream 9 | Best-effort (dnf) | NOT_TESTED | NOT_TESTED | N/A | Unit tests |

**Container** means GitHub Actions (or a local Docker run) installed the mapped packages and ran systemd-free installer/CLI tests inside the vendor image. It does **not** mean `frps` / `frpc` / allocator units were started under that distro's PID 1.

**Systemd PID1 (LXD)** means a disposable LXD system container whose PID 1 is that distro's systemd. Server/client install, unit enable/start/restart, allocator `/healthz`, `frpctl`, and `lxc restart` boot persistence were exercised for Rocky 9, AlmaLinux 9, and Amazon Linux 2023. That is **not** a real VM: the kernel is the Ubuntu host kernel, and SELinux is `Disabled`.

**Real VM** means a disposable virtual machine with its own kernel and that distro's systemd as PID 1. Ubuntu remains the live baseline. Nested KVM was not available on the P2.7.1 test host; QEMU TCG booted Amazon Linux 2023 to a login prompt but was too slow for SSH/install. Rocky/Alma/Amazon Linux **real VM** rows stay `NOT_TESTED` until a nested-virt or bare-metal disposable VM is used.

**SELinux** for Rocky/Alma remains `NOT_TESTED` until an Enforcing kernel (a real VM or SELinux-enabled host) is used. LXD containers on an AppArmor Ubuntu host reported `getenforce=Disabled`. This project does not run `setenforce 0`.

**Live baseline** means the current known-good Ubuntu server/client pair. Those hosts were not modified during P2.7.1.

A non-destructive collector for an already-installed systemd host is `tests/live-distro-smoke.sh`. It does not create, release, or revoke objects and does not print secrets.

Architecture: `x86_64 → amd64` and `aarch64/arm64 → arm64` are unit-tested. A full ARM64 systemd install is `NOT_TESTED` unless you run one.

Windows: FRP supports Windows, but automated PowerShell enrollment is not included. See `windows/README.md`.

### Server and client

Both the FRP Auto Deploy server and client use the same dependency installer (`apt` / `dnf` / `yum`). Other systemd Linux distributions can work when the required commands are already installed.

Required inbound ports on the FRP **server** (open them on the host firewall or cloud security group; the installer does not do this):

```text
TCP control port     (default 443)
TCP service range    (default 6000-6098)
TCP allocator port   (default 6099), or TCP/80 if you reverse-proxy enrollment
```

The client needs outbound connectivity to the FRP server. Opening local inbound ports for published services remains the administrator's responsibility.

Internet access is required for bootstrap and the official FRP download. Local/offline package mirrors are not part of this release.

On Amazon Linux 2 (systemd 219), the installer writes an allocator unit without `ProtectSystem=strict`, `ReadWritePaths`, and `NoNewPrivileges`. Newer systemd keeps those hardening lines. `PrivateTmp` is kept on both.

Enrollment token wrap stays compatible with `openssl enc -pbkdf2` on OpenSSL 1.1.1+, and uses the same Salted__/PBKDF2-SHA256 format via Python's stdlib plus `openssl enc -K/-iv` so OpenSSL 1.0.2 still works.

SELinux: default targeted policy typically allows these custom systemd units. This project does not install custom SELinux policy and does not set SELinux to permissive. If a site policy blocks the allocator HTTP port or FRP binaries, fix that policy explicitly. Enforcing-mode validation still requires a real Rocky/Alma VM; it was not closed in LXD containers.

---

# Architecture

## Behind a firewall / NAT device

```text
Remote Linux clients
        |
        | FRP TLS control connection :443
        v
203.0.113.10  (example public firewall/NAT IP)
        |
        +-- TCP/443       -> 192.0.2.50:443   (frps control)
        +-- TCP/6000-6098 -> 192.0.2.50:same  (published TCP service ports)
        +-- TCP/80        -> 192.0.2.50:6099  (enrollment allocator)
                                |
                                +-- frps
                                +-- port allocator
```

The public service port range must be DNATed to the same port range on the internal FRP server.

See `examples/pfsense-firewall.md` for firewall/NAT notes.

## Direct public server

```text
Remote Linux clients
        |
        v
203.0.113.10  (FRP server)
        |
        +-- TCP/443        frps control
        +-- TCP/6000-6098  published TCP service ports
        +-- TCP/6099       enrollment allocator
```

No external DNAT device is needed. Open the required ports on the host firewall or cloud security group. For a public enrollment endpoint on port 80, use a local reverse proxy or port-forward from `80` to `6099`.

---

# Security Model

No FRP token or permanent install secret is stored in this Git repository.

- A new server generates `/etc/frp/server_token` locally.
- Installing over an existing FRP server preserves the existing authentication token rather than rotating it.
- Client enrollment uses a short-lived enrollment code as bootstrap/recovery authorization.
- After enrollment, each client has a local ECDSA P-256 management identity. The private key never leaves the client.
- The server stores only the corresponding public key, fingerprint, and revocation status.
- Management requests are signed and bind protocol version, client identity, operation, timestamp, nonce, and payload digest. Replayed and stale requests are rejected.
- The FRP token authenticates the FRP tunnel only. It is not a management API credential.
- The enrollment secret itself is never sent over the enrollment HTTP request.
- Enrollment requests and responses are HMAC authenticated.
- The FRP token is encrypted with AES-256-CBC/PBKDF2 using the enrollment secret before crossing the enrollment HTTP path.
- Enrollment codes are bound to the first `machine-id` that uses them and expire by default after 10 minutes.
- FRP client-to-server control traffic uses FRP TLS on TCP/443.

The enrollment endpoint uses plain HTTP in the tested topology because the original deployment environment reset TLS traffic on non-standard ports. If the environment permits it, placing the enrollment endpoint behind a normal HTTPS reverse proxy is preferable.

Do not publish `/etc/frp/server_token`, enrollment files, generated `frpc.toml`, registry data, or connection-info files.

Where possible, restrict public SSH/service ports by source IP at the firewall, host firewall, or cloud security group.

---

# Existing Server Migration

The server installer can be run over an existing FRP deployment.

## FRP authentication token preservation

If `/etc/frp/server_token` already exists, it is reused unchanged.

If the server uses a legacy inline configuration such as:

```toml
auth.method = "token"
auth.token = "..."
```

the existing token is migrated into `/etc/frp/server_token` without changing its value.

Existing `auth.tokenSource` file-based configurations are also reused when possible.

A new token is generated only for a genuine fresh install where no previous authentication information exists.

Before rewriting `frps.toml`, the old configuration is copied to a timestamped mode-`600` backup.

Re-running the installer is idempotent: it does not rotate the token.

## Existing published port preservation

Before restarting an existing FRP server, the installer scans active listeners in the configured service range and preserves those ports as reserved.

This prevents existing FRP listeners such as `6000`, `6001`, or other active ports from being handed to a newly enrolled client.

## Generic registry schema

The server registry stores each client as a map of named TCP services. Identity for a public port is `machine-id + service-id`.

Optional management-identity fields (`mgmt_status`, `mgmt_pubkey`, `mgmt_fingerprint`, `mgmt_alg`, `mgmt_mac_key`) may appear on a client record. They extend schema v2 without changing `schema_version`. Missing fields mean a legacy client that must establish a management identity with a one-time Enrollment Code. Do not dump those fields in ordinary operator output.

A fresh install writes:

```json
{
  "schema_version": 2,
  "reserved": [],
  "clients": {}
}
```

Existing `schema_version` 1 / SSH-HTTPS registries are not migrated automatically. The installer and allocator fail closed if they find an unsupported schema. They do not delete or overwrite that registry.

See `docs/SCHEMA_V2_DEPLOYMENT.md` for the backup, replace, and re-enroll procedure.

---

# Server Management Commands

## List clients

```bash
sudo frp-clients
```

Example:

```text
HOSTNAME                 SERVICES  STATE     LAST ENROLLED
------------------------------------------------------------------------
dev-dp-mirror            3         online    2026-08-26T01:00:00Z
client-b                 1         offline   2026-08-26T02:00:00Z

dev-dp-mirror
  ssh:6002
  grafana:6003
  admin:6004
```

## Show one client's connection information

```bash
sudo frp-client-info customer-dp
```

## Release a reservation

```bash
sudo frp-release-client customer-dp
```

If the client still appears online, the command refuses by default. `--force` is available for recovery situations.

## Release one service

```bash
sudo frp-release-service customer-dp grafana
```

This frees only that service's reserved public port. Other services on the same client are left unchanged. If the port still appears active, the command refuses unless `--force` is used.

## Revoke a client's management identity

```bash
sudo frp-revoke-client customer-dp
```

This stops the client from making further signed configuration changes. Service port reservations are left in place. The client must re-enroll with a new Enrollment Code to establish trust again. This is not the same as `frp-release-service`.

## Configure the client installer URL

```bash
sudo frp-set-client-installer-url \
  https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh
```

## Server status

```bash
sudo frpctl status
sudo frp-server-status
sudo frp-server-status --check
```

The status command reports the installed FRP binary version, the FRP version tested by this `frp-auto-deploy` release, registry schema readiness, public host / allocator URL configuration, service state, and client/port counts.

`--check` exits non-zero when the registry is not schema v2 or required runtime values are missing. It does not change any files.

## Update FRP

On a server host:

```bash
sudo frpctl update
sudo frp-update
```

Check without changing anything:

```bash
sudo frp-update --check
```

`frpctl update` on a server host runs `frp-update`, which upgrades the FRP server binary only to the version tested by `frp-auto-deploy` and automatically rolls back if the new server fails its health checks.

On a client host, `sudo frpctl update` upgrades `frp-auto-deploy` management tools only. It does not require an Enrollment Code, does not rewrite client state or `frpc.toml`, and does not restart `frpc` when the pinned FRP version is already installed.

Upstream latest FRP releases are not installed automatically. `frp-auto-deploy` updates only to its tested/pinned FRP version. Availability of existing remote clients takes priority over installing the newest upstream binary.

The server FRP update replaces `/usr/local/bin/frps` only. It does not rotate the FRP token, reinitialize the registry, reallocate ports, or change enrollment state. If health checks fail after activation, the previous `frps` binary is restored and restarted.

---

# Important Files

## Server

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
/var/lib/frp-auto-deploy/backups/
/usr/local/lib/frp-auto-deploy/frp-port-allocator.py
/usr/local/sbin/frpctl
```

## Client

```text
/etc/frp/frpc.toml
/etc/frp/client-state.json
/etc/frp/client-identity.key
/etc/frp/client-identity.pub
/etc/frp/client-identity.mac
/etc/frp/access-info.txt
/etc/frp/backups/
/etc/frp-auto-deploy/version
/etc/frp-auto-deploy/allocator-ca.crt
/etc/systemd/system/frpc.service
/usr/local/bin/frpc
/usr/local/bin/frp-client
/usr/local/bin/frpctl
/usr/local/lib/frp-auto-deploy/frp-client-common.sh
/usr/local/lib/frp-auto-deploy/frp_mgmt_auth.py
```

`client-state.json` is the local desired/current service metadata (schema version 1) and must not contain secrets. The management private key is stored only in `client-identity.key`. `frpc.toml` is generated runtime config. The server `registry.json` is the persistent service/port allocation and may include the client's public management identity. Future management UIs should use these structured IDs rather than parsing `frpc.toml`.

---

# Development

Clone the repository:

```bash
git clone https://github.com/datarelay-labs/frp-auto-deploy.git
cd frp-auto-deploy
```

Before committing, verify no local secrets were added:

```bash
git grep -nE 'server_token|FRP_TOKEN=|INSTALL_KEY=' -- ':!README.md'
```

Generated standalone installers live under `dist/`. Rebuild them after changing source files:

```bash
./scripts/build-bundles.sh
```

The repository should never contain real FRP tokens, enrollment secrets, private keys, generated runtime configs, or allocator state.

```bash
./tests/test-server-migration.sh
./tests/test-registry-init.sh
python3 tests/test-allocator.py
python3 tests/test-mgmt-identity.py
./tests/test-client-config.sh
./tests/test-client-allocator-url.sh
./tests/test-client-platform.sh
./tests/test-portability.sh
./tests/test-server-install-config.sh
./tests/test-allocator-ready.sh
./tests/test-create-client.sh
./tests/test-management-commands.sh
./tests/test-frp-client.sh
./tests/test-guided-ux.sh
./tests/test-client-upgrade.sh
./tests/test-frpctl.sh
./tests/test-frpctl-completion.sh
./tests/test-frp-update.sh
./tests/test-frp-server-status.sh
./tests/test-port-architecture.sh
./tests/test-ca-bootstrap.sh
python3 tests/test-pki-https.py
./scripts/secret-scan.sh
```

---

# Notes

- Behind NAT, configure public vs listen ports separately. Published services keep the same port number on both sides (1:1).
- On a direct public server, no DNAT is required; allow the required ports on the host firewall or cloud security group.
- The allocator skips ports already reserved in the registry, ports belonging to any client service, and ports currently bound by another local service.
- Client port reservations survive client uninstall/reinstall unless explicitly released from the server.
- Disable a published service to stop advertising it; the public port stays reserved until `frp-release-service` or `frp-release-client`.
- At least one enabled client service is required.
- SSH is optional; HTTP/HTTPS presets are TCP passthrough, not FRP virtual-host modes.
- Existing FRP clients can remain connected after migration because the existing FRP authentication token is preserved.
- FRP server updates install only the tested/pinned FRP version and roll back automatically if health checks fail.
- Client software updates do not require an Enrollment Code when management trust already exists.
- Replace all documentation/example IP addresses with values appropriate for your environment before deployment.
