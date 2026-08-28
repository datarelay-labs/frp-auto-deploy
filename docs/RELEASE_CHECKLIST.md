# Release checklist

Use this list before tagging a release. Automated items are required for a
release candidate. Real-environment items are recorded in
`docs/RELEASE_VALIDATION.md` and are **not** implied by Docker PASS.

## Automated gate

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

## Real-environment gate

Record results in `docs/RELEASE_VALIDATION.md`. Do not convert Docker, LXD, or
QEMU TCG into `REAL_VM=PASS`.

- [ ] Rocky Linux 9 real VM
- [ ] Rocky Linux 9 SELinux Enforcing
- [ ] AlmaLinux 9 real VM
- [ ] AlmaLinux 9 SELinux Enforcing
- [ ] Amazon Linux 2023 real VM
- [ ] Amazon Linux 2 real VM / systemd 219 / TTY
- [ ] Native ARM64 systemd
- [ ] Real OpenSSL 1.0.2 TLS enrollment

## Tag policy

- [ ] `RELEASE_CANDIDATE_READY=YES` only if the automated gate PASS
- [ ] `STABLE_TAG_READY=YES` only if the chosen required real gates PASS
- [ ] Do **not** create `v2.1.0` automatically while required real gates are `NOT_TESTED`

For 2.1.0, automated gates can make a **release candidate**. Remaining real
gates are **required** before a stable tag. Until those gates pass:

```text
RELEASE_CANDIDATE_READY=YES   # only if the automated gate PASS
STABLE_TAG_READY=NO
```

Do not create `v2.1.0` in the same task that only lands the RC commit.
