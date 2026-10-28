# cloudflared

[Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/)'s `cloudflared`
— the agent that connects a machine to Cloudflare's edge so services behind it
become reachable without opening any inbound port — built from the release
tarball (date-style tags, no `v` prefix) by melange, assembled by apko on
Wolfi. No Dockerfile.

**One image, one binary, no ports.** `cloudflared` is a pure outbound-connect
tool: it dials Cloudflare's edge; nothing connects in, so the image exposes
nothing. The entrypoint mirrors upstream's Dockerfile exactly —
`["/usr/bin/cloudflared", "--no-autoupdate"]` (self-update makes no sense in a
container; the image tag is the update channel) — and the default cmd is
upstream's `version`, so a bare run just reports the stamped version:

```
docker run --rm ghcr.io/tylerobara/containers/cloudflared:latest          # → cloudflared version 2026.10.5 (built …)
docker run -d ghcr.io/tylerobara/containers/cloudflared:latest \
  tunnel run <your-tunnel-name>                                            # the real usage: args from docker run
docker run --rm ghcr.io/tylerobara/containers/cloudflared:latest \
  access <subcommand>                                                      # the access/token surface too
```

No tunnel args are baked in — a tunnel name/token is per-deployment state and
comes from the command line, exactly as upstream's docs run it. Runs as uid
65532 (upstream's `USER 65532:65532`, distroless nonroot).

## Deviations (deliberate)

- **Version stamp is ours, upstream's mechanism.** Upstream's Makefile stamps
  `-X "main.Version=$(git describe …)"`, which cannot work from the sha-pinned
  tarball (no `.git`) — and losing the stamp silently prints main.go's `DEV`
  default. We stamp `-X main.Version=<pinned version>` ourselves (plus
  upstream's exact `-X main.BuildTime=$(date -u -r RELEASE_NOTES …)` recipe;
  the mtime survives the GitHub archive) and the melange verify step FAILS
  LOUDLY unless `cloudflared --version` prints exactly the pinned version —
  unlike the flux/external-secrets builds, this binary can and must self-report.
- **`CONTAINER_BUILD=1` passed as the ldflag it exists for**: upstream's
  Dockerfile sets that env purely so the Makefile adds
  `-X …/metrics.Runtime=virtual`; we pass that ldflag directly.
- **Wolfi ships its own `cloudflared` package** (through 2026.5.2 at authoring
  time), so `epoch: 100` + `provider-priority: 100` (valkey precedent) keep
  OUR build winning apk resolution, the apko pin floats, and the workflow's
  lock guard + `test.sh` both assert the resolved/installed pkgver is exactly
  `<version>-r100` — a Wolfi win would fail both loudly.
- **`go-1.27` + `GOTOOLCHAIN=local`**: go.mod's `go` directive is exactly
  `1.27.3` (no toolchain line), and Wolfi's `go-1.27` ships 1.27.3-r0 — the
  flux/external-secrets "upstream bumped past Wolfi's default go" handling.
- **No `vendor/`** in the tarball (the Dockerfile runs `go mod download`), so
  modules resolve from the network — same as the flux/external-secrets builds.
- **Non-FIPS build**: upstream's FIPS variant (`GOFIPS140=latest`,
  `check-fips.sh`) is a release-engineering extra; the plain upstream build is
  the contract here, `CGO_ENABLED=0` static (cgo appears only in
  darwin/windows ICMP files).
- **`go get` raise for go-jose**: upstream 2026.10.5 pins `go-jose/v4`
  v4.1.4 (grype High GHSA-mgcc-cww5-fp2q, JWK RSA-parse DoS, patched in
  v4.1.6); the build raises it with `go get` and the verify step asserts the
  bump in the embedded build info — the gatus `*_version` pin pattern,
  retire once upstream ships >= 4.1.6.
- **busybox+ca-certs Wolfi base** instead of upstream's distroless glibc base,
  and `/usr/bin` (FHS) instead of `/usr/local/bin` — the repo-wide
  conventions; the binary content is the same static build.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.
