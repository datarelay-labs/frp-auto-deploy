# Future upstream FRP upgrades

frp-auto-deploy pins a **tested** FRP version. It never installs GitHub
`latest` automatically.

Current pin: see `VERSION` (`FRP_VERSION`) and `lib/frp-common.sh`
(`FRP_SHA256_AMD64`, `FRP_SHA256_ARM64`, `FRP_WEBSOCKET_PATH=/~!frp`).
`release-manifest.json` records the same pin under `supported_frp_versions`.

## When NOT to upgrade

- A new FRP release exists but this project has not run the compatibility gate.
- The candidate changes `FrpWebsocketPath` away from `/~!frp`.
- Config verify, token file auth, allowPorts, Direct mode, or single443 WSS fails.
- You only want "whatever is newest".

## When to consider upgrading

- The pinned version has a security fix that affects this deployment.
- A required protocol or bugfix is only in a newer tested release.
- You can run the full automated suite plus OCI acceptance afterward.

## How to test a new upstream version

```bash
./scripts/check-frp-compatibility.sh 0.xx.x
```

The script:

1. downloads linux amd64 and arm64 release archives (HTTPS)
2. records SHA256
3. fetches `pkg/util/net/websocket.go` from the same tag
4. **fails** if `/~!frp` is missing
5. runs `frps verify` when a candidate binary is present

It does **not** change production version numbers.

Minimum checks before `--apply`:

- frps/frpc config verify
- token file authentication
- allowPorts
- TLS / Direct / single443 / WSS `/~!frp`
- proxy registration, SSH TCP, multiple services
- zero-service client behavior
- reconnect

## How to update checksums and the pin

```bash
export FRP_NEW_SHA256_AMD64=...
export FRP_NEW_SHA256_ARM64=...
./scripts/bump-frp-version.sh 0.xx.x --apply
./tests/run-all.sh
./tests/run-distro-matrix.sh
./scripts/build-bundles.sh
./scripts/update-sha256sums.sh
./scripts/verify-sha256sums.sh
./scripts/secret-scan.sh
```

Install on a server only with `sudo frpctl frp-update`, which installs the
**pinned** version, never upstream latest.

Informational check:

```bash
sudo frpctl upstream
# or: frp-upstream
```

## How to perform OCI E2E

Follow `docs/OCI_ACCEPTANCE.md`. Do not claim production-ready until that
operator cycle PASSes.

## How to publish a new project release

Follow `docs/RELEASE_CHECKLIST.md` and `docs/RELEASE_VALIDATION.md`.
Do not move or rewrite the frozen `v2.1.0` tag.

## Rollback

- Server FRP binary: `frp-update` restores the previous binary on health failure.
- Server project tools: use `frp-project-update` rollback / restore from backup.
- Disaster recovery: `sudo frpctl restore <backup>` after a validated backup.
