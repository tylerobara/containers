# traefik-fips

[Traefik](https://traefik.io) built exactly like [`images/traefik`](../traefik)
(same tarball, same melange build contract, same Wolfi apko assembly) but in
**FIPS 140-3 mode**: the binary links the frozen, CMVP-validated **Go
Cryptographic Module v1.0.0** and boots with `fips140=on` baked in —
approved-only crypto with zero runtime configuration.

This is research-validated, not (yet) published: no workflow, not in
`catalog.json`, not signed. See [Next steps](#next-steps).

## Why the recipe looks the way it does

Traefik is a **static `CGO_ENABLED=0` Go binary**: every crypto operation
(TLS termination, ACME, OCSP) goes through Go's stdlib, never through a
system OpenSSL. So the FIPS boundary must live in the compiled-in crypto
module — the base image contributes no cryptography either way.

This is the key difference from the two reference projects:

| Reference | Crypto stack | What makes it FIPS |
| --- | --- | --- |
| [taha2samy/openjdk](https://github.com/taha2samy/openjdk) (Wolfi Java FIPS) | JVM + Bouncy Castle (native/Java crypto) | Inject the **BC-FIPS provider**, lock JVM security properties, convert keystores to BCFKS — OS/runtime-level enforcement |
| [chainguard-base-fips](https://images.chainguard.dev/directory/image/chainguard-base-fips/overview) | Native apps calling **OpenSSL** | A FIPS-validated OpenSSL *provider* in the base image (STIG-hardened, CMVP-certified) |
| **This image (Go)** | Compiled-in `crypto/internal/fips140` | `GOFIPS140=v1.0.0` at **build time** — nothing needed from the base image |

A chainguard-base-fips style base would add packages and add **nothing** to
Traefik's validated-crypto story (same reasoning behind Chainguard's own
`go-fips` product: the Go module is self-contained, no cgo, no OpenSSL).
The Wolfi base from `images/traefik` is kept as-is.

### The build (the whole trick)

```sh
GOFIPS140=v1.0.0 CGO_ENABLED=0 go build ./cmd/traefik
```

`GOFIPS140=v1.0.0` links the frozen module snapshot submitted to CMVP
(**certificate #5247**, CAVP A6650 — the same certificate Traefik Labs cites
for its commercial [Hub/Enterprise FIPS images](https://doc.traefik.io/traefik-hub/api-gateway/reference/install/ref-fips-overview),
which "use the official Go Cryptographic Module") and records
`DefaultGODEBUG=fips140=on` in the binary. In FIPS mode, per
[go.dev/doc/security/fips140](https://go.dev/doc/security/fips140):

- `crypto/tls` refuses to negotiate any version/cipher/curve/signature
  outside the approved set (≈ `fipsonly`: TLS ≥1.2, AEAD+PFS suites only);
- known-answer + integrity self-tests at init, pairwise tests on keygen;
- `crypto/rand` runs through the validated NIST SP 800-90A DRBG.

Choices made vs. the alternatives:

- **Literal `v1.0.0`**, not `certified`/`inprocess` — those aliases resolve
  toolchain-dependently (module v1.26.0 is still CMVP *pending review*; the
  flagd project documents getting bitten by exactly this).
- **Not `GOEXPERIMENT=boringcrypto`** — the legacy Go+BoringCrypto path needs
  cgo + a BoringSSL build, was never officially supported, and is being
  removed from Go.
- **Not the [golang-fips](https://github.com/golang-fips/go) fork**
  (RHEL/Red Hat, OpenSSL-backed) — that *is* the pattern where
  chainguard-base-fips would matter, but it needs `CGO_ENABLED=1`, breaks the
  static-binary contract, and ships a downstream fork; the native module has
  the better compliance profile and keeps this repo's build unchanged
  apart from one env var.
- **`-w` but not `-s`** in ldflags (non-FIPS image strips both): Chainguard's
  go-fips guidance keeps the symbol table for grype/govulncheck symbol-level
  analysis and FIPS-module verification — relevant here because of the
  repo-wide 0-Low+ grype signing gate.
- **No `-tags fips140`**: flagd-style tag enforcement is that app's own code;
  Traefik has no such tag, so faking one would be cargo-cult.

### Gotcha found in testing: Wolfi's `go-1.27` strips the FIPS snapshots

The first build attempt failed with `go: unknown GOFIPS140 version "v1.0.0"`:
Wolfi's `go` package ships `/usr/lib/go/lib/fips140/` with the frozen-module
**zips and alias files removed** (only `fips140.sum`, with the official
checksums, survives — verified against go1.27.3, which in GOTOOLCHAIN terms
still ships `v1.0.0-c2097c7c.zip` **and** `v1.26.0.zip`, with
`certified.txt → v1.0.0-c2097c7c`, i.e. #5247 is still the certified module).
The build therefore pins and downloads the matching **upstream** Go tarball,
checks its `fips140.sum` is byte-identical to the Wolfi toolchain's (proving
the zips belong to this exact toolchain), and restores `lib/fips140` into
GOROOT — the go tool then checksums the zip against `fips140.sum` again at
build time. Keep `vars.go_version`/`go_sha256_*` in sync with the `go-1.27`
patch version in `environment`.

## Runtime caveats

- FIPS mode is fixed at process start. A `GODEBUG=fips140=off` environment
  override **would** drop a vanilla Go binary out of FIPS mode (Traefik has
  no built-in refusal, unlike flagd's tag trick — we did not patch it in).
  Don't set it; same posture as HashiCorp's Consul FIPS docs.
- `fips140=only` exists for *testing* (makes unapproved-algorithm use panic)
  — don't run production with it. A one-shot soak with `GODEBUG=fips140=only`
  is a cheap way to surface hidden MD5/SHA-1/RC4 use in dependencies; the
  ACME/k8s code paths exercised in `test.sh` run clean in `on`.
- MD5/SHA-1 *digests* (non-security use) remain available — permitted under
  FIPS 140-3 I.G. 2.4.A, same as Chainguard's go-fips.
- The OS-level `fips=1` kernel boot / `/proc/sys/crypto/fips_enabled` is
  **not** required: the module is pure Go and self-contained (unlike the
  OpenSSL-backend forks).

## Verification (`test.sh`)

Beyond the `images/traefik` smoke battery (version stamp, entrypoint,
nonroot, prod restraint, ping boot):

1. **Build-info proof** — extract the binary (`docker cp`) and assert
   `go version -m` reports `GOFIPS140=v1.0.0` + `DefaultGODEBUG=fips140=on`
   (settings survive `-trimpath` and `-w`). Melange also asserts this in the
   build pipeline, so a non-FIPS build can't produce the package.
2. **TLS boundary battery** against the FIPS binary (OpenSSL client in a
   wolfi container sharing traefik's netns), **control-tested** against the
   published non-FIPS image (2026-11-02):

   | handshake | non-FIPS image | FIPS image | tested |
   | --- | --- | --- | --- |
   | TLS 1.3 `TLS_AES_*_GCM` | accept | accept | ✅ must negotiate |
   | TLS 1.2 `ECDHE-RSA-AES256-GCM-SHA384` | accept | accept | ✅ must negotiate |
   | TLS 1.2 `ECDHE-RSA-CHACHA20-POLY1305` | **accept** | **refuse** | ✅ must refuse |
   | TLS 1.3 `TLS_CHACHA20_POLY1305_SHA256` | **accept** | **refuse** | ✅ must refuse |
   | TLS 1.2 `AES128-SHA` (static-RSA) | refuse | refuse | ❌ not tested |

   The ChaCha20-Poly1305 suites are the true discriminators: stock Go
   supports them and they're in Traefik's *default* cipher policy, so refusing
   them can only come from FIPS mode. `AES128-SHA` is refused by both images —
   Traefik's own default TLS policy already excludes static-RSA suites — which
   is why the naive "non-approved suite refused" test is misleading and was
   replaced (this was caught by running the control, exactly why the control
   exists).
3. Traefik's auto-generated default cert (RSA keygen + self-sign) doubles as
   a live exercise of the module's pairwise/keygen self-tests at boot.

## Next steps (to productize)

- Copy `.github/workflows/traefik.yml` → `traefik-fips.yml` (same keygen →
  melange ×2 arch → apko lock/publish → test → grype 0-gate → cosign chain),
  add the `catalog.json` row so the site/scan pages pick it up, and mirror
  the `bump-traefik-*` bot PRs onto this config (tarball sha + pins are
  shared with `images/traefik` by design).
- Consider publishing `:3.x-fips` tags on the same `traefik` image instead of
  a separate image name, and pinning whichever module version holds the CMVP
  certificate when v1.26.0 completes review (it's been pending since
  2026-04-28 — check before switching).
