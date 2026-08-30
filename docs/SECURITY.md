# Security architecture

This document describes the security model of `frp-auto-deploy` **2.1.1**.
It is not a certification, audit report, or guarantee against a compromised
root account.

Pinned FRP version: **0.70.1**. Product version is independent of the
management protocol version (`schema: 1` in signed requests) and of FRP.

## 1. FRP tunnel authentication

The FRP control/data tunnel uses:

- FRP native TLS on Direct mode (`transport.protocol = tcp`, `transport.tls.enable = true`)
- FRP WSS on Enterprise single-443 (`transport.protocol = wss` plus `trustedCaFile` pinning the allocator CA)
- the FRP server token (`/etc/frp/server_token`)

In single-443 mode nginx terminates TLS on public TCP/443 with the project
leaf certificate. The frontend proxies allocator paths to loopback HTTPS
and verifies that backend with `proxy_ssl_verify on` as `DNS:localhost`.
The frps backend on localhost does not use `tls.force`;
authentication remains the FRP token. Plain WebSocket (`websocket` without
TLS) is not a supported production transport.

The FRP token authenticates the **tunnel only**. It is not a management API
credential, not an Enrollment Code, and not a Bootstrap Ticket.

## 2. Management-plane transport

Enrollment and signed client management use **HTTPS only**.

- There is no plain HTTP allocator mode.
- There is no HTTP fallback.
- There is no mutual TLS (mTLS).

Clients authenticate to the allocator with a one-time Enrollment Code (or a
short-lived Bootstrap Ticket that redeems into the same enrollment flow), then
with a persistent ECDSA P-256 identity.

## 3. Private CA

The server installer creates a project-managed private CA:

```text
/etc/frp-auto-deploy/pki/ca.key     # secret
/etc/frp-auto-deploy/pki/ca.crt     # public certificate
/etc/frp-auto-deploy/pki/server.key # secret
/etc/frp-auto-deploy/pki/server.crt # public certificate
```

The allocator presents `server.crt`. Clients verify it with the pinned CA.
Software update is **not** CA rotation. A public-host / SAN change may reissue
the **leaf** certificate under the same CA. Rotating or replacing the CA itself
is an advanced manual recovery scenario; this release does not implement CA
rotation.

## 4. CA fingerprint bootstrap

First client install downloads `/ca.crt` once over the configured HTTPS
allocator URL **without** using a `--cacert` file that does not exist yet.
It parses the body as X.509 and checks the SHA256 fingerprint of the
**canonical DER** encoding against `FRP_ALLOCATOR_CA_SHA256`. That hash is the
**CA** certificate, not the nginx/allocator leaf. On success it stores
`/etc/frp-auto-deploy/allocator-ca.crt`. Later allocator calls use
verified HTTPS (`curl --cacert` with that stored CA). This is not TOFU and not
self-verification of a file against itself.

The fingerprint is public trust metadata. It does **not** prove that a
`curl | sudo bash` bootstrap script from GitHub is authentic. Those are
separate trust domains (see below).

## 5. Enrollment Code

A short-lived secret created on the server (`sudo frp-create-client`).

- Default TTL: 10 minutes
- Bound to the first machine (`machine-id`) that uses it
- Entered interactively on manual install; not placed on the command line
- Not the FRP token
- Enrollment requests/responses are HMAC-authenticated
- The enrollment secret is not sent in the HTTPS request body
- The FRP token is returned encrypted (AES-256-CBC / PBKDF2) over verified HTTPS
- Server storage: root-owned mode-0600 JSON under
  `/var/lib/frp-auto-deploy/enrollments/*.json` (secret field stored as issued;
  not hashed or wrapped at rest in the current release)

Needed again only to enroll a new client, recover a lost local identity, or
re-establish trust after `frp-revoke-client`.

## 6. Bootstrap Ticket

Zero-touch (`--one-line`) issues a short-lived ticket that the client redeems
over verified HTTPS **after** CA pinning.

- High-entropy secret; hashed at rest on the server
- First-machine bound; same-machine retry is safe until enrollment completes
- After successful enrollment the ticket is marked completed; further redeem
  attempts fail with `BOOTSTRAP_TICKET_USED`
- A different machine is rejected with `BOOTSTRAP_TICKET_BOUND`
- TTL enforced
- Not placed in the HTTP URL path/query
- Not persisted on the client as the raw ticket
- Must not be logged
- Has no management authority after enrollment completes
- Not the FRP token

Treat the generated one-line command as sensitive until used or expired.

## 7. ECDSA management identity

After enrollment, the client keeps a local ECDSA P-256 key:

```text
/etc/frp/client-identity.key   # secret, 0600
/etc/frp/client-identity.pub   # public
/etc/frp/client-identity.mac   # secret MAC material, 0600
```

The private key never leaves the client. The server stores the public key,
fingerprint, MAC secret, and revocation status. Signed management requests use
management schema **1** (independent of project version 2.0.0).

## 8. Nonce and timestamp replay defense

Signed objects bind protocol schema, algorithm, client/machine identity,
operation, timestamp, nonce, and payload digest.

```text
MAX_CLOCK_SKEW=300          # seconds
MGMT_NONCE_TTL=900          # seconds
MAX_NONCES_PER_CLIENT=256
```

Replayed nonces and stale timestamps are rejected. A retry of the same logical
Apply uses a new timestamp/nonce/signature and reuses existing public ports.

`frpctl doctor` is read-only and does not consume a nonce.

## 9. Revoke vs release

| Action | Management identity | Port reservations |
| --- | --- | --- |
| `frp-revoke-client` | blocked | kept |
| `frp-release-client` / `frp-release-service` | unchanged | freed |

Revoke is not release. An administrator can still release after revoke.

## 10. Disable vs release

| Action | Publication | Public port |
| --- | --- | --- |
| Disable | stopped | reserved |
| Re-enable | resumed | **same** port |
| Edit (local target) | may change target | **same** port |
| Release | removed | freed for reuse |

Disable is not release.

## 11. Secret vs public inventory

**Secrets**

| Item | Typical path |
| --- | --- |
| FRP server token | `/etc/frp/server_token` |
| Enrollment Code secret | `/var/lib/frp-auto-deploy/enrollments/*.json` (root-owned `0600`; secret stored as issued, not hashed/wrapped) |
| Bootstrap Ticket while valid | `/var/lib/frp-auto-deploy/bootstrap/` (hashed at rest) |
| Client management private key | `/etc/frp/client-identity.key` |
| Management MAC secret | `/etc/frp/client-identity.mac` (server copy on the client record) |
| CA private key | `/etc/frp-auto-deploy/pki/ca.key` |
| TLS server private key | `/etc/frp-auto-deploy/pki/server.key` |
| Generated `frps.toml` / `frpc.toml` | contain the FRP token |

**Public / non-secret metadata**

| Item | Typical path |
| --- | --- |
| CA certificate | `/etc/frp-auto-deploy/pki/ca.crt` |
| CA SHA256 fingerprint | printed by `frp-create-client` |
| Server certificate | `/etc/frp-auto-deploy/pki/server.crt` |
| Management public key | `/etc/frp/client-identity.pub` |
| Service ID, public service port, public hostname | `frp-client-info`, `access-info.txt` |
| Client desired state (no secrets) | `/etc/frp/client-state.json` |

`client-state.json` is the canonical local desired state. `frpc.toml` and
`access-info.txt` are generated artifacts. Do not treat `frpc.toml` as the
document to edit.

## 12. Expected file modes

| Path | Mode |
| --- | --- |
| `/etc/frp/server_token` | `0600` |
| `/etc/frp-auto-deploy/pki/` | `0700` |
| `/etc/frp-auto-deploy/pki/ca.key` | `0600` |
| `/etc/frp-auto-deploy/pki/ca.crt` | `0644` |
| `/etc/frp-auto-deploy/pki/server.key` | `0600` |
| `/etc/frp-auto-deploy/pki/server.crt` | `0644` |
| `/etc/frp/client-identity.key` | `0600` |
| `/etc/frp/client-identity.mac` | `0600` |
| `/etc/frp/client-state.json` | `0600` |
| `/etc/frp/frpc.toml` | `0600` |
| `/etc/frp/frps.toml` | `0600` |
| `/var/lib/frp-auto-deploy/registry.json` | `0600` |
| `/etc/frp-auto-deploy/allocator-ca.crt` | `0644` |
| `/etc/frp/access-info.txt` | `0644` |
| `/etc/frp-auto-deploy/version` | `0644` |

Do not manually edit the registry, `client-state.json`, `frpc.toml`, or
identity files unless performing advanced recovery.

## 13. Trust domains

`curl … | sudo bash` fetches the **installer bundle** from the configured
installer URL (often GitHub `raw.githubusercontent.com`). Integrity of that
script is a GitHub/HTTPS and operator-process concern.

Allocator **CA fingerprint** pins the management CA. It does not attest the
bootstrap script.

Checksums:

- Official FRP archives are checked against pinned SHA256 values
- Repository `SHA256SUMS` covers tracked source/release files

This project does **not** currently ship cryptographic signatures of its own
bundles. Checksum verification is not the same as signature verification.

## 14. Threat boundaries

| Situation | Boundary |
| --- | --- |
| MITM on allocator before CA pin | Fingerprint mismatch; install must fail closed |
| MITM after CA pin | TLS verification with pinned CA |
| Stolen Enrollment Code | Usable until expiry / first-machine bind |
| Stolen Bootstrap Ticket | Same; one-line command is sensitive |
| Windows Zero-touch command | Downloads `bootstrap-client.ps1`, verifies SHA256 against `SHA256SUMS`, then `-File` (no `irm|iex`); ticket still short-lived/one-time |
| Replayed management request | Rejected (nonce/timestamp) |
| Compromised client local root | **Outside** the protection boundary |
| Compromised server root | **Outside** the protection boundary |
| Lost response / retry | New nonce; ports reused, not duplicated |
| Registry corruption | Fail closed; restore from backup |
| Malicious FRP archive | Version/arch/checksum/path-traversal checks |
| Shell metacharacters in zero-touch fields | Values are `shlex`-quoted; control characters rejected |

Local root compromise on the FRP server or client is outside the protection
boundary. File modes reduce accidental exposure; they do not protect secrets
from root.

## 15. Backup and disaster recovery

**Server backup (minimum)**

```text
/etc/frp-auto-deploy/pki/
/etc/frp/server_token
/etc/frp-auto-deploy/config.json
/var/lib/frp-auto-deploy/registry.json
```

Also consider enrollments, bootstrap tickets, and `mgmt-nonces.json`. Store
backups mode `600`. Losing the private CA means existing clients cannot
validate a replacement allocator until trust is re-established (typically
re-enrollment).

**Client**

Client uninstall **intentionally** removes local identity and state. Do not
copy `client-identity.key` over insecure channels. A replacement host is a new
enrollment (or Enrollment Code recovery) even if the server still holds the
old reservation.

| Loss | Supported recovery |
| --- | --- |
| Server software lost, state preserved | Re-run the server installer; CA/token/registry reused |
| Server host completely lost | Restore the backups above, then reinstall |
| Client local state lost | New enrollment or Enrollment Code recovery |
| Client identity lost | Enrollment Code recovery (`frp-revoke-client` if the old key must be blocked) |
| CA lost or compromised | Advanced manual recovery; **not** solved by `frpctl update` |
| Registry lost | Restore `registry.json` from backup; the installer will not invent reservations |

Token rotation is not automatic. Reinstall preserves the existing FRP token.

## 16. Mixed product versions

Project **2.1.0** does not change management protocol schema `1`. An already
enrolled **1.9.1** or **2.0.0** client is expected to keep its tunnel and signed
management against a **2.1.0** Direct-mode server. Product version is not
management protocol version. There is no forced client re-enrollment on this
upgrade.

A **2.0.0** client cannot speak FRP WSS. Switching the server to single-443
requires **2.1.0+** clients and an Apply after cutover; it is not a silent
transport upgrade.
