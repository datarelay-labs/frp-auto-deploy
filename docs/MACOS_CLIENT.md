# macOS Client (Apple Silicon)

The macOS client publishes services from a Mac through an FRP server using the
same enrollment protocol, the same allocator API, and the same pinned FRP
release as the Linux client. Nothing server-side changes to support a Mac.

## Requirements

| Requirement | Value |
| --- | --- |
| Architecture | Apple Silicon (`arm64`) — M1 or newer |
| macOS | 11 Big Sur or newer |
| Service manager | launchd (native, not a systemd shim) |
| Privileges | `sudo` for enrollment, uninstall, and service control |
| Tools | `curl`, `openssl`, `python3`, `tar`, `shasum`, `launchctl` |

Intel Macs are **not supported**. The installer refuses to continue on
`x86_64` Darwin and says so explicitly. If you are on Apple Silicon but running
a Rosetta 2 shell, `uname -m` reports `x86_64`; the installer detects that case
and tells you to re-run from a native shell:

```bash
arch -arm64 /bin/bash
```

Dependencies are **required, never installed**. The installer does not run
`brew install`, does not touch system packages, and does not modify anything
outside the paths listed below. If a tool is missing it stops and tells you to
run `xcode-select --install`.

## What the installer does not do

These are hard product boundaries, not defaults:

- It does **not** enable Remote Login (SSH) or Screen Sharing.
- It does **not** change the macOS firewall.
- It does **not** create, modify, or delete any macOS user account.
- It does **not** offer an RDP preset. Available presets are SSH, HTTP, HTTPS,
  and Custom TCP.

For the SSH preset, SSH must already be working on the Mac. The installer
verifies that the named account exists and that the local SSH port accepts a
connection *before* it allocates a public port, so a misconfigured Mac fails
without consuming a port reservation.

## Filesystem layout

| Purpose | Path |
| --- | --- |
| State root | `/Library/Application Support/frp-auto-deploy` |
| FRP config | `/Library/Application Support/frp-auto-deploy/frpc.toml` |
| Client state | `/Library/Application Support/frp-auto-deploy/client-state.json` |
| Management identity | `/Library/Application Support/frp-auto-deploy/client-identity.key` |
| Pinned CA | `/Library/Application Support/frp-auto-deploy/allocator-ca.crt` |
| `frpc` binary | `/Library/Application Support/frp-auto-deploy/bin/frpc` |
| Project libraries | `/Library/Application Support/frp-auto-deploy/lib` |
| Daemon logs | `/Library/Application Support/frp-auto-deploy/logs/frpc.{out,err}.log` |
| LaunchDaemon | `/Library/LaunchDaemons/com.datarelay.frp-auto-deploy.frpc.plist` |
| CLI entry points | `<brew --prefix>/bin/frpctl`, `<brew --prefix>/bin/frp-client` |

`<brew --prefix>` is discovered at runtime from `brew --prefix`, or from the
location of the `brew` executable when Homebrew declines to answer (it refuses
to run as root, which is the normal case under `sudo`). It falls back to
`/usr/local`. `/opt/homebrew` is never hardcoded.

### Why `frpc` is not in the Homebrew prefix

The LaunchDaemon runs `frpc` as root at boot. A Homebrew prefix is writable by
any admin user, so placing a root-executed binary there would create a local
privilege-escalation path. The pinned `frpc` and all project libraries live
under the root-owned state root instead. Only the user-invoked CLI wrappers go
into the Homebrew prefix, so `frpctl` is on `PATH`.

## Machine identity

The client identity is derived from `IOPlatformUUID`:

```
machine_id = sha256("frp-auto-deploy:macos:" + IOPlatformUUID)[:32]
```

This is stable and immutable across renames, user changes, and OS upgrades, and
has the same 32-lowercase-hex shape as a Linux `/etc/machine-id`. The raw
hardware UUID is hashed with a domain separator, so it is never transmitted to
the server or written into the registry.

The hostname remains **mutable metadata**. It is reported for display and can
change freely without affecting identity, port reservations, or the management
identity binding.

## Enrollment

On the server, generate a macOS zero-touch command:

```bash
sudo frpctl
# create zero-touch -> 3) macOS (Apple Silicon)
```

or non-interactively:

```bash
sudo frp-create-client --one-line --platform macos --ssh --ssh-user alice
```

The Mac is enrolled with either of two equivalent commands.

### One-line install (no prerequisites)

```bash
curl -fsSL <installer-url> | sudo env \
  FRP_ALLOCATOR_URL=... FRP_ALLOCATOR_CA_SHA256=... \
  FRP_BOOTSTRAP_TICKET=... FRP_ZERO_TOUCH=1 FRP_PLATFORM=macos bash
```

This uses the same Darwin-aware `dist/bootstrap-client.sh` as Linux, so there
is no second installer artifact to keep in sync. `FRP_PLATFORM=macos` is an
operator assertion only: the installer independently detects Darwin and `arm64`
and refuses to continue if the host disagrees.

### Compact join (Homebrew)

```bash
brew install datarelay-labs/tap/frp-auto-deploy
sudo frpctl join '<descriptor>'
```

`frpctl join` decodes and validates the descriptor locally, then runs the
installer that shipped with the formula. The one-time ticket is passed through
the environment rather than `argv`, so it never appears in `ps` output. The
descriptor is the same `frpj1.` wire format the Windows launcher consumes.

Installing the formula enrolls nothing and starts no daemon. Enrollment is
always a separate, explicit, root-privileged step.

## Security properties

These match the Linux and Windows clients and are not relaxed on macOS:

- The allocator CA is pinned by SHA-256 fingerprint and the certificate SAN is
  verified. There is no `-k` / `--insecure` path anywhere in the client.
- The FRP release is pinned to `0.70.1` with the official
  `frp_0.70.1_darwin_arm64.tar.gz` SHA-256
  (`cfa733b5a261c1647edee3c1fc4133d2542989b28f5602e81d47fc821d25c55f`), verified
  with `shasum -a 256` before the binary is installed.
- The bootstrap ticket is one-time, short-lived, and bound to the first machine
  that redeems it. It is not the FRP token and cannot manage the client after
  enrollment.
- The rendered LaunchDaemon plist is validated before it is loaded: the label
  must match, `ProgramArguments` must be exactly the pinned `frpc -c <config>`
  invocation, and any unresolved template placeholder is a hard failure.
- `client-state.json` never contains secrets.

## Service control

`frpctl` is the everyday interface and works the same as on Linux:

```bash
sudo frpctl status
sudo frpctl restart
sudo frpctl pause
sudo frpctl resume
sudo frpctl logs
```

Under the hood, macOS uses launchd rather than systemd:

| Action | Linux | macOS |
| --- | --- | --- |
| Autostart | `systemctl enable` | plist `RunAtLoad` + `launchctl enable` |
| Start | `systemctl start` | `launchctl bootstrap` / `kickstart` |
| Stop | `systemctl stop` | `launchctl bootout` |
| Status | `systemctl is-active` | `launchctl print` (non-zero `pid`) |
| Logs | `journalctl -u frpc` | `frpc.out.log` / `frpc.err.log` |

`pause` uses `launchctl disable`, which persists in the launchd service
database, so a paused Mac stays paused across reboots. `resume` re-enables it.

macOS has no `/proc`, so process-ownership checks use `pgrep` plus `ps -o
command=` and match both the pinned binary path and the project config. An
unrelated `frpc` running on the same Mac is never signalled.

Direct launchd inspection, if you need it:

```bash
sudo launchctl print system/com.datarelay.frp-auto-deploy.frpc
```

## Uninstall

Client uninstall is **local only**. It stops and unloads the daemon, removes the
LaunchDaemon plist, the pinned `frpc`, the project libraries, the local
management identity, and all local configuration and state.

```bash
sudo frpctl uninstall
```

It does **not** contact the server, delete the server-side client record, or
release public port reservations. Release ports from the server explicitly:

```bash
sudo frpctl        # revoke client <id>
```

If the CLI came from Homebrew, remove it afterwards with
`brew uninstall frp-auto-deploy`.

## Known limitations

- `frpctl update` in-place software upgrade is not yet exercised on macOS.
  Re-run the installer, or `brew upgrade` for a Homebrew install.
- `frpctl doctor` reports the systemd-specific runtime checks as *not tested* on
  macOS. Configuration, identity, TLS, and connectivity checks still run.
- Support-bundle collection has not been validated against launchd log paths.
- The client is not code-signed or notarized. It is installed by an explicit
  root-privileged command, not by a downloaded `.app` or `.pkg`, so Gatekeeper
  is not involved.
