# Changelog

## 2.1.1 — 2026-09-04

Stable release. FRP remains pinned at **0.70.1**.

- Optional public hostname access alias for client/service display and operator
  access hints (falls back to Public IP when unset)
- First-class `create zero-touch` in `frpctl` (guided SSH-only and multi-service
  workflows, including remote LAN targets)
- Zero-touch guided menu shows SSH only / Configure services / Back;
  Management-only remains available to the backend but is hidden from the
  guided menu
- CLI discoverability and Tab completion behavior retained (first-press
  candidates, no command dispatch on Back)
- `frpctl` verb/resource grammar, enrollment listing without secrets, and
  CLIENT ID as the canonical selector (continued from post-2.1.0 main work)
- Same-version client/server updates compare verified bundle SHA256, not only
  `PROJECT_VERSION`
- Legacy clients without persisted release metadata fail closed on remote
  update until a one-time verified bridge (`docs/FRP_UPGRADE.md`)
- Server install/rerun and project-update migrate official project-managed
  `client_installer_url` values to the current release-line canonical installer
  (`v2.1.1` on stable; `main` on explicit dev). Custom, third-party, look-alike,
  and explicit `FRP_CLIENT_INSTALLER_URL` overrides are preserved
- Manual enrollment and legacy one-line client creation continue to use the
  same persisted installer URL release-line semantics
- Allocator/restore readiness hardening and released-service client-state
  reconciliation

### Compatibility

Already enrolled 2.1.0 clients remain compatible. After a server project update
from 2.1.0, newly generated Zero-touch / enrollment installer commands use the
`v2.1.1` bootstrap URL when the persisted URL was an official managed ref.

## Unreleased (post-2.1.1 / main)

_None yet._

## 2.1.0 — 2026-08-29

Stable release. Optional **Enterprise single-443** mode: public TCP/443 carries
allocator HTTPS and FRP control over WSS (nginx frontend, project CA). Direct
mode (443 frps + 6099 allocator HTTPS) remains the default. Published services
stay TCP/6000-6098. FRP remains pinned at **0.70.1**.

- Installer: `FRP_DEPLOYMENT_MODE=direct|single443` and TTY mode prompt
- Enrollment returns `frp_transport` (`tcp` or `wss`); clients pin the stored CA for WSS
- `frpctl status` / `frpctl doctor` show topology and TLS-reset vs closed-port
- Mode switch is an explicit maintenance-window cutover (`FRP_CONFIRM_MODE_SWITCH`)
- HTTP allocator, `curl -k`, and plaintext WebSocket are not used
- Single-443 frontend verifies the loopback allocator as `DNS:localhost`
  (`proxy_ssl_verify on`); distro `nginx.service` autostart is disabled when
  this project installs nginx, and a pre-existing active nginx unit is a
  conflict rather than silently stopped
- `frpctl doctor` checks frontend-proxied `/healthz` and `/ca.crt`, not only
  the allocator backend

See [docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

### Real-environment acceptance

Field-validated on Ubuntu 24.04 x86_64 (direct public-IP server, enterprise-restricted
client, FRP 0.70.1): 1.9.1→2.1.0 server migration, single-443 cutover, HTTPS/443
enrollment, WSS/443 control, published SSH TCP/6000, and client/server reboot
recovery. Before single-443, TLS on non-443 ports was reset; after cutover,
HTTPS and WSS succeeded on TCP/443.

Not field-validated: firewall DNAT / private FRP-server topology, SELinux
Enforcing, ARM64 hosts, OpenSSL 1.0.2 hosts. Details:
[docs/RELEASE_VALIDATION.md](docs/RELEASE_VALIDATION.md).

## 2.0.0 — 2026-08-28

Stable product milestone for `frp-auto-deploy`. This is **not** an upstream FRP
change. FRP remains pinned at **0.70.1**.

### Capabilities

- Secure HTTPS enrollment with a project-managed private CA and DER SHA256 fingerprint bootstrap
- Persistent ECDSA P-256 client management identity after one-time enrollment
- NAT-aware public vs listen port model (public control/allocator ports may differ from listen ports; published services stay 1:1)
- Multi-service TCP clients (SSH, HTTP, HTTPS passthrough, custom TCP)
- Lifecycle hardening: add / edit / disable / re-enable / release, with port preservation on edit/disable
- Install and update rollback where the operation can be verified
- Read-only `frpctl doctor` / `frpctl doctor --json`
- Docker userspace distro matrix (Ubuntu 22.04/24.04, Rocky 9, AlmaLinux 9, Amazon Linux 2023, Amazon Linux 2)
- Zero-touch SSH bootstrap (`frp-create-client --one-line --ssh`) using a short-lived Bootstrap Ticket
- Manual Enrollment Code flow remains fully supported

### Security

- No plain HTTP management or enrollment
- CA pinning and X.509 validation; canonical DER fingerprint
- Nonce and timestamp replay protection
- Hashed bootstrap tickets at rest; first-machine bind; no ticket in the HTTP URL
- FRP archive path-traversal, version, and architecture checks
- Safe uninstall paths (client uninstall does not release server ports; server purge is explicit `--purge --yes`)

### Compatibility

| Area | Status |
| --- | --- |
| FRP | 0.70.1 pinned |
| Ubuntu 22.04 / 24.04 | container PASS; real VM live baseline PASS |
| Rocky Linux 9 | container PASS; LXD systemd PASS; real VM / SELinux Enforcing **NOT_TESTED** |
| AlmaLinux 9 | container PASS; LXD systemd PASS; real VM / SELinux Enforcing **NOT_TESTED** |
| Amazon Linux 2023 | container PASS; LXD systemd PASS; real VM **NOT_TESTED** |
| Amazon Linux 2 | container PASS (including OpenSSL 1.0.2 userspace); real VM / systemd 219 / TTY **NOT_TESTED** |

Already enrolled 1.9.1 clients remain compatible with a 2.0.0 server (management protocol schema 1 is unchanged).

### Known limitations

- TCP services only
- Service NAT is 1:1 port-number mapping
- No automatic firewall, SELinux policy, or SSH account/key management
- Windows client automation is not included
- Real VM / SELinux Enforcing / ARM64 systemd / real OpenSSL 1.0.2 TLS enrollment remain `NOT_TESTED` where listed
- Bundles are checksummed (`SHA256SUMS`); this project does not ship cryptographic signatures of its own installer scripts
