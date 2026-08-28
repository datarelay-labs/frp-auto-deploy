# Changelog

## 2.1.0 — 2026-08-28 (release candidate / current source version)

This is the current source version. It is **not** a tagged stable release until
`v2.1.0` exists after real-environment gates.

Optional **Enterprise single-443** mode: public TCP/443 carries allocator HTTPS
and FRP control over WSS (nginx frontend, project CA). Direct mode (443 frps +
6099 allocator HTTPS) remains the default. Published services stay TCP/6000-6098.
FRP remains pinned at **0.70.1**.

- Installer: `FRP_DEPLOYMENT_MODE=direct|single443` and TTY mode prompt
- Enrollment returns `frp_transport` (`tcp` or `wss`); clients pin the stored CA for WSS
- `frpctl status` / `frpctl doctor` show topology and TLS-reset vs closed-port
- Mode switch is an explicit maintenance-window cutover (`FRP_CONFIRM_MODE_SWITCH`)
- HTTP allocator, `curl -k`, and plaintext WebSocket are not used

See [docs/DEPLOYMENT_MODES.md](docs/DEPLOYMENT_MODES.md).

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
