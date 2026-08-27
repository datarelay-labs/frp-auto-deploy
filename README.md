# frp-auto-deploy

`frp-auto-deploy` is a lightweight deployment and management layer for the official [fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or modify FRP.

It automates FRP server/client installation, persistent public port assignment for SSH, web, and custom TCP services, short-lived client enrollment, systemd startup, migration from an existing FRP deployment, and connection-info output.

> **Note**
> The IP addresses `203.0.113.10` and `192.0.2.50` used in this README are documentation-only example addresses (RFC 5737). Replace them with your own public and internal addresses when deploying.

Current pinned FRP version: **v0.70.1**
Current project version: **1.3.0**

---

# Everyday command

For normal operation, this is the only command you need to remember:

```bash
sudo frpctl
```

That starts the persistent interactive management CLI. Then type `help` or `?` for the commands that apply to this host.

```text
$ sudo frpctl

FRP Auto Deploy CLI
===================

Role            : Server
Project version : 1.3.0
FRP version     : 0.70.1

Type 'help' or '?' for available commands.

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
Project version : 1.3.0
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

1. **FRP server behind a firewall/NAT device** — public ports are DNATed to an internal FRP server.
2. **FRP server directly on a public IP** — no external firewall/NAT device is required; the FRP server itself owns the public IP.

## 1. Choose your network topology

### Option A — FRP server behind firewall / NAT

Example topology:

```text
Internet / Remote Linux clients
        |
        | FRP TLS control :443
        v
203.0.113.10  (public firewall/NAT)
        |
        +-- TCP/443       -> 192.0.2.50:443
        +-- TCP/6000-6098 -> 192.0.2.50:6000-6098
        +-- TCP/80        -> 192.0.2.50:6099
                                |
                                +-- frps
                                +-- port allocator
```

Required DNAT example:

```text
203.0.113.10:443       -> 192.0.2.50:443
203.0.113.10:6000-6098 -> 192.0.2.50:6000-6098
203.0.113.10:80        -> 192.0.2.50:6099
```

Server installer values:

```text
Public firewall/NAT IP:      203.0.113.10
Internal FRP server IP:      192.0.2.50
FRP control port:            443
Service range start:         6000
Service range end:           6098
Allocator internal port:     6099
Allocator public URL:        http://203.0.113.10/enroll
```

This model is useful when the FRP server has only a private address and a separate firewall/router owns the public IP.

### Option B — FRP server directly on a public IP (no external firewall/NAT)

If the FRP server itself owns the public IP, no DNAT device is required.

```text
Internet / Remote Linux clients
        |
        v
203.0.113.10  (FRP server public IP)
        |
        +-- TCP/443        frps control
        +-- TCP/6000-6098  published TCP service ports
        +-- TCP/6099       enrollment allocator
```

Use values like:

```text
Public firewall/NAT IP:      203.0.113.10
Internal FRP server IP:      203.0.113.10
FRP control port:            443
Service range start:         6000
Service range end:           6098
Allocator internal port:     6099
Allocator public URL:        http://203.0.113.10:6099/enroll
```

`Internal FRP server IP` is currently used for display/documentation purposes, so when the server directly owns the public address it is fine to enter the same public IP.

Make sure the server or cloud security group allows inbound TCP traffic for:

```text
443
6000-6098
6099
```

If you prefer the enrollment URL to use normal HTTP port 80 instead of exposing `6099`, place a reverse proxy or local port-forward in front of the allocator:

```text
203.0.113.10:80 -> 127.0.0.1:6099
```

Then you can use:

```text
Allocator public URL:        http://203.0.113.10/enroll
```

This is equivalent to the firewall/NAT deployment from the client's point of view, but the port forwarding happens locally on the FRP server rather than on a separate firewall.

## 2. Install the FRP server

Run on the FRP server:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-server.sh | sudo bash
```

The installer asks for the deployment values shown in the examples above. There is no hard-coded public or internal address; values are stored in `/etc/frp-auto-deploy/config.json`.

Non-interactive install uses environment variables, for example `FRP_PUBLIC_HOST` and `FRP_ALLOCATOR_URL` (aliases: `FRP_PUBLIC_IP`, `FRP_ALLOCATOR_PUBLIC_URL`). Optional project defaults remain `FRP_CONTROL_PORT=443`, `FRP_PORT_START=6000`, `FRP_PORT_END=6098`, and `FRP_ALLOCATOR_PORT=6099`. Re-running the installer reuses the existing runtime config unless those variables are set.

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
curl -fsS http://127.0.0.1:6099/healthz
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

Client install:
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo env FRP_ALLOCATOR_URL='http://203.0.113.10/enroll' bash
```

Enrollment codes expire after 10 minutes by default and are bound to the first machine that uses them. The enrollment secret is entered interactively; it is not placed on the command line.

`sudo env` is required so `FRP_ALLOCATOR_URL` reaches the installer after `sudo` resets the environment.

## 4. Install a remote Linux client

Run the command printed by `frp-create-client` on the remote Linux server. Example:

```bash
curl -fsSL https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh \
| sudo env FRP_ALLOCATOR_URL='http://203.0.113.10/enroll' bash
```

`FRP_ALLOCATOR_URL` is required. There is no hard-coded allocator address in the installer. If it is missing, the client bootstrap exits with a clear error and does not install FRP.

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

A software update preserves client state, `frpc.toml`, access information, management identity files, service IDs, enabled/disabled state, and public port assignments. It does **not** require an Enrollment Code when trust already exists. It does not regenerate a valid management identity, does not rewrite a working `frpc.toml`, and does not restart `frpc` unless the runtime FRP binary actually changes. Existing clients without `/etc/frp-auto-deploy/version` are treated as legacy/pre-version-tracking installs and are migrated into version tracking.

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

### Server

- Debian/Ubuntu Linux, systemd, x86_64 or arm64

### Supported Linux clients

First-class:

- Ubuntu
- Debian
- RHEL
- Rocky Linux
- AlmaLinux
- CentOS Stream
- Fedora
- Amazon Linux

Requirements:

- systemd
- x86_64 or arm64
- network access to the FRP server and GitHub releases

Automatic dependency installation uses `apt`, `dnf`, or `yum`. It is tested with apt, dnf, and yum systems. Other systemd-based Linux distributions can work when required dependencies are already installed.

Internet access is currently required for client bootstrap and the official FRP download. Local/offline package mirrors are not part of this release.

The client installer does not disable SELinux, load custom SELinux policy, or change firewalld, ufw, iptables, or nftables. Opening local inbound ports for published services remains the administrator's responsibility. `frpc` needs outbound connectivity to the FRP server.

- Windows: FRP supports Windows, but automated PowerShell enrollment is not included in v1.0. See `windows/README.md`.

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
./tests/test-server-install-config.sh
./tests/test-create-client.sh
./tests/test-management-commands.sh
./tests/test-frp-client.sh
./tests/test-guided-ux.sh
./tests/test-client-upgrade.sh
./tests/test-frpctl.sh
./tests/test-frp-update.sh
./tests/test-frp-server-status.sh
./scripts/secret-scan.sh
```

---

# Notes

- Behind a firewall/NAT device, FRP service ports must be forwarded to the same ports on the internal FRP server.
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
