# frp-auto-deploy

`frp-auto-deploy` is a small management layer around the official [fatedier/frp](https://github.com/fatedier/frp) binaries. It does **not** fork or modify FRP. It automates server/client installation, persistent port allocation, short-lived enrollment, systemd startup, and connection-info output.

The package is designed around this tested topology:

```text
Remote Linux clients
        |
        | FRP TLS control connection :443
        v
221.139.249.110  (public firewall/NAT)
        |
        +-- TCP/443       -> 10.10.10.50:443   (frps control)
        +-- TCP/6000-6098 -> 10.10.10.50:same  (SSH/HTTPS published ports)
        +-- TCP/80        -> 10.10.10.50:6099  (enrollment allocator)
                                |
                                +-- frps
                                +-- port allocator
```

## Why a separate project instead of forking FRP?

FRP remains upstream and is downloaded from the official release at install time. This project only manages deployment and lifecycle. Updating FRP therefore does not require maintaining a long-lived fork.

Current pinned FRP: **v0.70.1**.

## Security model

No FRP token or permanent install secret is stored in this Git repository.

- On a new server, `install-server.sh` generates `/etc/frp/server_token` locally. Installing over an existing FRP server reuses the current token (including a legacy inline `auth.token`) and does not rotate it.
- A client first receives a short-lived enrollment code from `frp-create-client`.
- The enrollment secret itself is never sent over the enrollment HTTP request.
- Requests and responses are HMAC authenticated.
- The FRP token is encrypted with AES-256-CBC/PBKDF2 using the enrollment secret before it crosses the enrollment HTTP path.
- An enrollment code is bound to the first `machine-id` that uses it and expires by default after 10 minutes.
- FRP client-to-server control traffic uses FRP TLS on TCP/443.

The enrollment endpoint is intentionally plain HTTP because the tested remote network reset TLS on non-standard ports. If your environment permits HTTPS on the enrollment path, placing it behind a normal HTTPS reverse proxy is preferable.

## Supported OS

- Server: Debian/Ubuntu Linux, x86_64 or arm64
- Client: Debian/Ubuntu Linux, x86_64 or arm64
- Windows: FRP supports Windows, but automated PowerShell enrollment is not included in v1.0. See `windows/README.md`.

---

# 1. Build/push the repository

This project is published at https://github.com/RickLee-kr/frp-auto-deploy. Before pushing, verify no local secrets were added:

```bash
git grep -nE 'server_token|FRP_TOKEN=|INSTALL_KEY=' -- ':!README.md'
```

The repository should contain no real token values.

Generated one-file installers are under `dist/`. Rebuild them after changing source files:

```bash
./scripts/build-bundles.sh
```

---

# 2. Install the FRP server

## Option A: clone the repository

```bash
git clone https://github.com/RickLee-kr/frp-auto-deploy.git
cd frp-auto-deploy
sudo ./install-server.sh
```

## Option B: one-line bootstrap after pushing to GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-server.sh | sudo bash
```

The installer asks for values with defaults. For the tested deployment use:

```text
Public firewall/NAT IP:      221.139.249.110
Internal FRP server IP:      10.10.10.50
FRP control port:            443
Service range start:         6000
Service range end:           6098
Allocator internal port:     6099
Allocator public URL:        http://221.139.249.110/enroll
```

If this is being installed over an existing FRP server, the installer scans active service ports in the configured range before restarting FRP and preserves those ports as reserved in the initial registry. This is useful when `6000` and `6001` are already in use.

Installing over an existing FRP server preserves the existing FRP authentication token and active published ports. Existing frpc clients therefore do not need to be reconfigured.

Legacy inline `auth.token` values are migrated into `/etc/frp/server_token` without changing the secret. The previous `frps.toml` is copied to a timestamped backup with mode `600` before the file is rewritten. Re-running the installer is idempotent: it will not rotate the token, reset the registry, or drop existing client allocations.

## Firewall/NAT

See `examples/pfsense-firewall.md`. In the tested topology:

```text
221.139.249.110:443       -> 10.10.10.50:443
221.139.249.110:6000-6098 -> 10.10.10.50:6000-6098
221.139.249.110:80        -> 10.10.10.50:6099
```

## Verify server

```bash
sudo systemctl status frps --no-pager
sudo systemctl status frp-port-allocator --no-pager
curl -fsS http://127.0.0.1:6099/healthz
```

---

# 3. Configure the client installer URL

After pushing the repository, set the raw GitHub URL once on the FRP server:

```bash
sudo frp-set-client-installer-url \
  https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh
```

---

# 4. Create a client enrollment

On the FRP server:

```bash
sudo frp-create-client
```

Example output:

```text
Enrollment Code:
7e41d99163a5c410.73f36d...

Expires: 2026-08-26T11:10:00Z (600 seconds)

Client install:
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo bash
```

The code expires after 10 minutes by default and is bound to the first machine that uses it.

Custom TTL:

```bash
sudo frp-create-client --ttl 1800 --note customer-dp
```

---

# 5. Install a remote Linux client

On the remote Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/bootstrap-client.sh | sudo bash
```

The installer asks only:

```text
Enrollment Code:
HTTPS server IP/host [Enter = SSH only]:
```

Press Enter at the HTTPS prompt for SSH only.

For SSH + HTTPS, enter for example:

```text
192.168.122.2
```

The allocator permanently assigns unused ports from the configured range. A reinstall on the same machine uses `/etc/machine-id` and receives the same reserved ports.

Example completion output:

```text
=========================================
 FRP Installation Complete
=========================================

SSH:
ssh -p 6003 aella@221.139.249.110

HTTPS:
https://221.139.249.110:6004

Connection information:
cat /etc/frp/access-info.txt
```

`frpc` is installed as a systemd service and starts automatically after reboot.

---

# 6. Server management commands

List clients:

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

Show one client's connection commands:

```bash
sudo frp-client-info customer-dp
```

Release a client reservation after its remote `frpc` has been stopped/uninstalled:

```bash
sudo frp-release-client customer-dp
```

If the client still appears online the command refuses by default. `--force` exists for recovery situations.

---

# 7. Uninstall

## Linux client

From the repository:

```bash
sudo ./uninstall-client.sh
```

Or after pushing:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/uninstall-client.sh | sudo bash
```

The local client is removed, but the central port reservation is deliberately preserved. Release it separately on the server only when you want those ports reused.

## FRP server

From the repository:

```bash
sudo ./uninstall-server.sh
```

Or after pushing:

```bash
curl -fsSL https://raw.githubusercontent.com/RickLee-kr/frp-auto-deploy/main/dist/uninstall-server.sh | sudo bash
```

Binaries and systemd units are removed. Token, configuration, and registry are preserved unless you pass `--purge`.

---

# 8. Important files on the server

```text
/etc/frp/server_token
/etc/frp/frps.toml
/etc/frp-auto-deploy/config.json
/var/lib/frp-auto-deploy/registry.json
/var/lib/frp-auto-deploy/enrollments/
/usr/local/lib/frp-auto-deploy/frp-port-allocator.py
```

Important files on a client:

```text
/etc/frp/frpc.toml
/etc/frp/access-info.txt
/etc/systemd/system/frpc.service
/usr/local/bin/frpc
```

---

# 9. Notes

- The public service port range must be DNATed to the same port range on the internal FRP server.
- Do not publish `/etc/frp/server_token`, enrollment files, or generated client configuration files to GitHub.
- Where possible, restrict public SSH/service ports by source IP at the firewall.
- The allocator skips ports already reserved in its registry and ports currently bound by another local service.
