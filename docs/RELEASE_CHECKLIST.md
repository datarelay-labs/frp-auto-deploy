# Release checklist

Use this list before tagging a release. Automated items are required before a
release candidate or stable tag. Real-environment policy and evidence live in
`docs/RELEASE_VALIDATION.md` (authoritative for which real gates are mandatory).

## Automated gate (required for any tag)

- [ ] `VERSION` matches intended project version; `FRP_VERSION=0.70.1`
- [ ] README, CHANGELOG, and `docs/SECURITY.md` match that version
- [ ] Support matrix claims match evidence (no SELinux/real-VM overclaim)
- [ ] `./tests/run-all.sh` PASS
- [ ] `./tests/run-distro-matrix.sh` PASS (six vendor images)
- [ ] `./scripts/secret-scan.sh` PASS (includes forbidden real-IP literals)
- [ ] `./scripts/build-bundles.sh` then `git diff --exit-code dist/`
- [ ] `./scripts/verify-sha256sums.sh` PASS
- [ ] `git diff --check HEAD` PASS
- [ ] Worktree clean after the release commit
- [ ] Commit is on `main`
- [ ] Stable release URLs resolve to immutable `vPROJECT_VERSION` (not `main`)

## Real-environment gate (authoritative policy)

**Authoritative classification** is the Gate classification table in
`docs/RELEASE_VALIDATION.md`.

For stable **2.1.0**, the required real gates are the Ubuntu 24.04 x86_64
single-443 topology recorded PASS in that file. The following remain
**RECOMMENDED / NOT_TESTED** and must **not** be advertised as field-validated:

- Rocky Linux 9 real VM / SELinux Enforcing
- AlmaLinux 9 real VM / SELinux Enforcing
- Amazon Linux 2023 / Amazon Linux 2 real VM
- Native ARM64 systemd
- Real OpenSSL 1.0.2 TLS enrollment
- Firewall DNAT / private FRP-server topology

Do not convert Docker, LXD, or QEMU TCG into `REAL_VM=PASS`.

## Tag policy

- [ ] `RELEASE_CANDIDATE_READY=YES` only if the automated gate PASS
- [ ] `STABLE_TAG_READY=YES` only if the chosen required real gates PASS
  (see `docs/RELEASE_VALIDATION.md`)
- [ ] Do **not** create a stable tag while required real gates are `NOT_TESTED`
- [ ] Do **not** claim Rocky/Alma SELinux, Amazon Linux real VM, ARM64 systemd,
  or OpenSSL 1.0.2 real TLS unless those columns are PASS

For **2.1.0**, the required real gates that were chosen for this tag (Ubuntu
24.04 x86_64, direct public-IP server, enterprise-restricted client, single-443
HTTPS/WSS/SSH, reboot recovery) are recorded PASS in
`docs/RELEASE_VALIDATION.md`. Remaining recommended gates stay `NOT_TESTED`.

## After OCI acceptance: 2.1.1

Do **not** tag the current `PROJECT_VERSION=2.1.0` `main` tree as `v2.1.1`.
`./scripts/validate-release-tag.sh` rejects that mismatch automatically.

A dedicated release commit must, in order:

1. Set `PROJECT_VERSION=2.1.1` in `VERSION` and `lib/frp-common.sh` default
2. Set `release-manifest.json` `channel=stable` and `git_ref=v2.1.1`
3. Rebuild bundles and regenerate `SHA256SUMS`
4. Run all automated gates in this checklist
5. Only then create the immutable `v2.1.1` tag

Until that commit exists, `main` may continue to report `PROJECT_VERSION=2.1.0`
with `channel=dev` / `source_ref=main` during OCI acceptance.
