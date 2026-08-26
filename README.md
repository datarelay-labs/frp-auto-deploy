# frp-auto-deploy

`frp-auto-deploy` is a lightweight deployment and management layer for the official [fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or modify FRP.

It automates FRP server/client installation, persistent SSH/HTTPS port assignment, short-lived client enrollment, systemd startup, migration from an existing FRP deployment, and connection-info output.

> **Note**
> The IP address `203.0.113.10` used in this README is a documentation-only example address. Replace it with your own public IP when deploying.

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
        +-- TCP/443       -> 10.10.10.50:443
        +-- TCP/6000-6098 -> 10.10.10.50:6000-6098
        +-- TCP/80        -> 10.10.10.50:6099
                                |
                                +-- frps
                                +-- port allocator
```

Required DNAT example:

```text
203.0.113.10:443       -> 10.10.10.50:443
203.0.113.10:6000-6098 -> 10.10.10.50:6000-6098
203.0.113.10:80        -> 10.10.10.50:6099
```

Server installer values:

```text
Public firewall/NAT IP:      203.0.113.10
Internal FRP server IP:      10.10.10.50
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
        +-- TCP/6000-6098  SSH/HTTPS published ports
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
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-server.sh | sudo bash
```

The installer asks for the deployment values shown in the examples above.

Verify the server:

```bash
sudo frp-server-status
```

or:

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
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo bash
```

Enrollment codes expire after 10 minutes by default and are bound to the first machine that uses them.

## 4. Install a remote Linux client

Run on the remote Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo bash
```

The installer asks only:

```text
Enrollment Code:
HTTPS server IP/host [Enter = SSH only]:
```

Press Enter at the HTTPS prompt for SSH only.

To publish HTTPS as well, enter the internal HTTPS target, for example:

```text
192.168.122.2
```

Example completion output:

```text
=========================================
 FRP Installation Complete
=========================================

SSH:
ssh -p 6003 aella@203.0.113.10

HTTPS:
https://203.0.113.10:6004

Connection information:
cat /etc/frp/access-info.txt
```

The assigned ports are persistent. Reinstalling the client on the same machine reuses the previous allocation based on `/etc/machine-id`.

## 5. Manage clients

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

Create a longer-lived enrollment code when needed:

```bash
sudo frp-create-client --ttl 1800 --note customer-dp
```

---

# Uninstall

## Client

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/uninstall-client.sh | sudo bash
```

The local FRP client is removed, but the central port reservation is intentionally preserved. Release it on the FRP server only when you want those ports reused.

## Server

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/uninstall-server.sh | sudo bash
```

Binaries and systemd units are removed. Token, configuration, and registry are preserved unless `--purge` is used.

---

# Project Details

## What this project provides

`frp-auto-deploy` adds an operational layer around upstream FRP:

- automatic FRP server installation
- automatic FRP client installation
- persistent SSH/HTTPS public port assignment
- short-lived enrollment codes
- HMAC-authenticated enrollment requests and responses
- systemd service creation and restart handling
- central client/port registry
- migration from an existing manually configured FRP server
- migration from the legacy manual port allocator
- client list, connection-info, and reservation management commands
- uninstall helpers and standalone bootstrap bundles

FRP itself remains upstream and is downloaded from the official release during installation.

## Why not fork FRP?

This project does not need to change the FRP protocol or core FRP code. Keeping FRP upstream avoids maintaining a long-lived fork and makes FRP upgrades simpler. This repository focuses only on deployment, enrollment, persistence, migration, and management.

## Supported operating systems

- Server: Debian/Ubuntu Linux, x86_64 or arm64
- Client: Debian/Ubuntu Linux, x86_64 or arm64
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
        +-- TCP/443       -> 10.10.10.50:443   (frps control)
        +-- TCP/6000-6098 -> 10.10.10.50:same  (SSH/HTTPS published ports)
        +-- TCP/80        -> 10.10.10.50:6099  (enrollment allocator)
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
        +-- TCP/6000-6098  SSH/HTTPS published ports
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

## Legacy allocator registry migration

If the new registry does not yet exist and the previous manual allocator registry is found at:

```text
/var/lib/frp-port-allocator/registry.json
```

it is migrated into:

```text
/var/lib/frp-auto-deploy/registry.json
```

Migration preserves:

- existing `reserved` ports
- every existing client entry
- SSH port assignments
- HTTPS port assignments
- hostnames
- ports belonging to clients that are currently offline

Current active listeners are merged into the reserved set as well.

Allocator-only ports such as `6099` may remain in `reserved`, but they are outside the `6000-6098` service allocation range and are never assigned as client service ports.

Before migration, the legacy registry is copied to a timestamped backup with mode `600`.

If `/var/lib/frp-auto-deploy/registry.json` already exists, it is never overwritten and the legacy registry is not imported again.

---

# Server Management Commands

## List clients

```bash
sudo frp-clients
```

Example:

```text
HOSTNAME                 USER         SSH    HTTPS  STATE    HTTPS_TARGET
--------------------------------------------------------------------------------------------
dp-os-upgrade            aella        6002   -      online
customer-dp              aella        6003   6004   online   192.168.122.2
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

## Configure the client installer URL

```bash
sudo frp-set-client-installer-url \
  https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh
```

## Server status

```bash
sudo frp-server-status
```

---

# Important Files

## Server

```text
/etc/frp/server_token
/etc/frp/frps.toml
/etc/frp-auto-deploy/config.json
/var/lib/frp-auto-deploy/registry.json
/var/lib/frp-auto-deploy/enrollments/
/usr/local/lib/frp-auto-deploy/frp-port-allocator.py
```

## Client

```text
/etc/frp/frpc.toml
/etc/frp/access-info.txt
/etc/systemd/system/frpc.service
/usr/local/bin/frpc
```

---

# Development

Clone the repository:

```bash
git clone https://github.com/RickLee-kr/frp-auto-deploy.git
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

---

# Notes

- Behind a firewall/NAT device, FRP service ports must be forwarded to the same ports on the internal FRP server.
- On a direct public server, no DNAT is required; allow the required ports on the host firewall or cloud security group.
- The allocator skips ports already reserved in the registry and ports currently bound by another local service.
- Client port reservations survive client uninstall/reinstall unless explicitly released from the server.
- Existing FRP clients can remain connected after migration because the existing FRP authentication token is preserved.
- Replace all documentation/example IP addresses with values appropriate for your environment before deployment.
