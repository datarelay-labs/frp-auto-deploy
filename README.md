# frp-auto-deploy

`frp-auto-deploy` is a lightweight deployment and management layer for the official [fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or modify FRP.

It automates FRP server/client installation, persistent public port assignment for SSH, web, and custom TCP services, short-lived client enrollment, systemd startup, migration from an existing FRP deployment, and connection-info output.

> **Note**
> The IP addresses `203.0.113.10` and `192.0.2.50` used in this README are documentation-only example addresses (RFC 5737). Replace them with your own public and internal addresses when deploying.

Current pinned FRP version: **v0.70.1**

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
sudo frp-server-status
sudo frp-server-status --check
sudo frp-update
```

`frp-server-status --check` confirms registry schema v2 and that the public host and allocator URL are configured. It does not change the server.

`frp-update` upgrades the FRP server only to the version tested by `frp-auto-deploy` and automatically rolls back if the new server fails its health checks. On a fresh install it is a no-op.

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

The installer asks for an enrollment code, then lets you add one or more TCP services:

```text
Enrollment Code:

Add service

1) SSH
2) HTTP
3) HTTPS
4) Custom TCP
5) Finish
```

SSH is optional. Any TCP service can be published. Each service receives a persistent public port.

Built-in presets:

- SSH (`127.0.0.1:22` by default)
- HTTP (`127.0.0.1:80` by default)
- HTTPS (`127.0.0.1:443` by default) — TCP passthrough, no TLS termination
- Custom TCP (any host:port)

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

Published services:

SSH
  ssh -p 6002 aella@203.0.113.10

Grafana
  http://203.0.113.10:6003

Admin Web
  https://203.0.113.10:6004

Connection information:
cat /etc/frp/access-info.txt
```

The assigned ports are persistent. Reinstalling the same service on the same machine reuses the previous public port based on `/etc/machine-id` plus the service ID. Changing a service's local target does not reallocate its public port.

A successful install writes `/etc/frp/client-state.json` (mode 600, no secrets). `frpc.toml` and `access-info.txt` are generated from that state. Do not treat `frpc.toml` as the document to edit.

## 5. Manage an installed client

Need to expose another service later? Do not reinstall FRP.

```bash
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
Enrollment Code:
```

Read-only commands do not require an Enrollment Code and do not contact the allocator:

```bash
sudo frp-client status
sudo frp-client info
```

Applying add/edit/enable/disable changes that update server-side allocations requires a new short-lived Enrollment Code from `sudo frp-create-client` on the FRP server. No permanent client management password is used.

Disable a service to stop publishing it. The public port stays reserved. Re-enable to get the same port back. Permanent per-service release is done on the server with `sudo frp-release-service <client> <service-id>`. `frp-release-client` still releases the whole client.

At least one enabled service is required. Clients installed before this management state must be re-enrolled once with the current bootstrap installer.

## 6. Manage clients on the server

List registered clients:

```bash
sudo frp-clients
```

Show connection information for one client:

```bash
sudo frp-client-info customer-dp
```

Release a client's reserved ports after its remote `frpc` has been stopped or uninstalled:

```bash
sudo frp-release-client customer-dp
```

Release one service reservation while leaving the rest of the client intact:

```bash
sudo frp-release-service customer-dp grafana
```

Create a longer-lived enrollment code when needed:

```bash
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
- post-install `frp-client` service add/edit/disable/re-enable without reinstalling FRP
- persistent public port assignment for SSH, HTTP, HTTPS, and custom TCP services
- short-lived enrollment codes
- HMAC-authenticated enrollment requests and responses
- systemd service creation and restart handling
- central client/port registry (generic multi-service schema)
- migration from an existing manually configured FRP server
- client list, connection-info, and reservation management commands
- uninstall helpers and standalone bootstrap bundles
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
- Client enrollment uses a short-lived enrollment code.
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

## Configure the client installer URL

```bash
sudo frp-set-client-installer-url \
  https://raw.githubusercontent.com/datarelay-labs/frp-auto-deploy/main/dist/bootstrap-client.sh
```

## Server status

```bash
sudo frp-server-status
sudo frp-server-status --check
```

The status command reports the installed FRP binary version, the FRP version tested by this `frp-auto-deploy` release, registry schema readiness, public host / allocator URL configuration, service state, and client/port counts.

`--check` exits non-zero when the registry is not schema v2 or required runtime values are missing. It does not change any files.

## Update FRP

```bash
sudo frp-update
```

Check without changing anything:

```bash
sudo frp-update --check
```

`frp-update` upgrades the FRP server only to the version tested by `frp-auto-deploy` and automatically rolls back if the new server fails its health checks.

Upstream latest FRP releases are not installed automatically. `frp-auto-deploy` updates only to its tested/pinned FRP version. Availability of existing remote clients takes priority over installing the newest upstream binary.

The update replaces `/usr/local/bin/frps` only. It does not rotate the FRP token, reinitialize the registry, reallocate ports, or change enrollment state. If health checks fail after activation, the previous `frps` binary is restored and restarted.

---

# Important Files

## Server

```text
/etc/frp/server_token
/etc/frp/frps.toml
/etc/frp-auto-deploy/config.json
/etc/frp-auto-deploy/version
/var/lib/frp-auto-deploy/registry.json
/var/lib/frp-auto-deploy/enrollments/
/var/lib/frp-auto-deploy/backups/
/usr/local/lib/frp-auto-deploy/frp-port-allocator.py
```

## Client

```text
/etc/frp/frpc.toml
/etc/frp/client-state.json
/etc/frp/access-info.txt
/etc/frp/backups/
/etc/systemd/system/frpc.service
/usr/local/bin/frpc
/usr/local/bin/frp-client
/usr/local/lib/frp-auto-deploy/frp-client-common.sh
```

`client-state.json` is the local desired/current service metadata (schema version 1). `frpc.toml` is generated runtime config. The server `registry.json` is the persistent service/port allocation. Future management UIs should use these structured IDs rather than parsing `frpc.toml`.

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
python3 tests/test-enrollment-security.py
./tests/test-client-config.sh
./tests/test-client-allocator-url.sh
./tests/test-client-platform.sh
./tests/test-server-install-config.sh
./tests/test-create-client.sh
./tests/test-management-commands.sh
./tests/test-frp-client.sh
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
- Replace all documentation/example IP addresses with values appropriate for your environment before deployment.
