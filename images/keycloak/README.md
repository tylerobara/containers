# keycloak

[Keycloak](https://www.keycloak.org/)'s IAM/SSO server — realms, users,
OIDC/OAuth2 + SAML brokering, admin console — packaged from the official
Apache-2.0 **release distribution** and assembled by apko on Wolfi with the
Wolfi OpenJDK 21 JRE. No Dockerfile, no maven, no node.

**Packaged dist, not source — on purpose.** Keycloak's source build is a
maven+node quarkus assembly that upstream CI runs for hours *before* cutting
the `keycloak-<ver>.tar.gz` release asset; that dist is exactly what
upstream's own container Dockerfile consumes (`ADD keycloak.tar.gz
/opt/keycloak/` + `RUN kc.sh build`). We implement that same contract —
unpack the sha256-pinned dist to `/opt/keycloak`, bake the bundled offline
`kc.sh build` augmentation, assert `kc.sh --version` prints the pinned
version — so rebuilding it with maven would only duplicate upstream CI's
output without producing it more honestly.

```
# try it (dev mode, H2 file db, plain HTTP — mirrors upstream's quickstart):
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=<pw> \
  ghcr.io/tylerobara/containers/keycloak:latest start-dev
# → admin console http://localhost:8080/, health/ready on the MANAGEMENT port
#   :9000 (KC_HEALTH_ENABLED is baked on; the main port 404s /health)

# production shape (per upstream docs): real db + TLS, default cmd `start`
docker run -d -p 8443:8443 \
  -e KC_DB=postgres -e KC_DB_URL=… -e KC_DB_USERNAME=… -e KC_DB_PASSWORD=… \
  -e KC_HTTP_ENABLED=false -v $PWD/certs:/opt/keycloak/conf/certs:ro \
  -e KC_HTTPS_CERTIFICATE_FILE=/opt/keycloak/conf/certs/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/opt/keycloak/conf/certs/tls.key \
  -v kcdata:/opt/keycloak/data \
  ghcr.io/tylerobara/containers/keycloak:latest
```

The entrypoint/cmd are upstream's own: `ENTRYPOINT /opt/keycloak/bin/kc.sh`
+ `CMD start`. Production `start` refuses plain HTTP without TLS — that is
upstream's contract, not an image bug; `start-dev` is the dev-mode override.

## Deliberate deviations from upstream's container image

- **Wolfi JRE, not temurin/ubi.** `openjdk-21-jre` only (Keycloak 26 supports
  Java 17/21; the build-side `kc.sh build` runs on the matching `openjdk-21`
  JDK inside melange, the image ships just the JRE). `JAVA_HOME` is pinned in
  the image env because Wolfi's JRE deliberately puts no `java` on `PATH` and
  `kc.sh` resolves java via `JAVA_HOME` first.
- **run-as 65532** (repo-wide numeric nonroot, gatus/frr precedent) instead
  of upstream's root-or-arbitrary-UID flavors.
- **The runtime-writable dirs ship 0777 from the apk** (melange can't
  chown; the cilium-operator `/home/gops` precedent), **files stay 644
  root-owned**. `data/` needs it for the first-boot H2 db — mount a real
  volume for actual deployments. `lib/quarkus/` needs it because `kc.sh`
  re-runs the augmentation **in place** at start whenever build-time options
  change or `start-dev` is used: quarkus unlink+recreates
  `transformed-bytecode.jar`/`generated-bytecode.jar`, so directory write
  suffices (proven: uid 65532 boots a 644-files tree in ~12s; a
  root-owned-*directory* tree fails that same boot with AccessDenied).
  Upstream's image is likewise group-writable over `/opt/keycloak` for
  arbitrary-UID runs; `bin/`, `conf/`, `themes/` stay root-owned here.
- **No `apk-tools`/`bash` in prod**, busybox shell only (repo-wide), and the
  default `JAVA_HOME`/`PATH` env block instead of shell-profile tricks.

- **`KC_HTTP_HOST=0.0.0.0` and `KC_HEALTH_ENABLED=true` are baked into the
  image env.** Keycloak 26 defaults its HTTP listener to loopback (probed:
  `start-dev` binds `127.0.0.1:8080`, so a published container port is
  unreachable) and ships its health endpoints **off** by default — a sane
  default for a jar on a host, but every other service image in this fleet
  binds `0.0.0.0` and answers probes out of the box because that is the
  container contract. Health is served on the management port **9000**
  (probed: enabling it binds `:9000`; the main port 404s `/health` even in
  dev mode), so `test.sh` — like a k8s probe — hits the bare
  `docker run -p 8080 -p 9000` contract with zero overrides. Deployments
  that want stricter defaults override via `KC_*` env.

## Versioning

`version` + `vars.sha256` track the GitHub release asset
`releases/download/<ver>/keycloak-<ver>.tar.gz`; upstream tags are plain
semver with **no `v` prefix** (`26.8.1`). The update-versions bot row filters
the tag list for strict `X.Y.Z` and computes the new sha256 from that exact
asset. Wolfi ships only stream-named `keycloak-26.5`/`keycloak-26.6` packages
(no bare `keycloak`), so resolution is trivially ours; epoch 100 +
provider-priority and the workflow's apko-lock guard (`keycloak ==
<ver>-r100`) fail loudly the day that changes. Tags published: `<ver>`,
`<major>.<minor>` (e.g. `26.8`), `latest`.

## Verify

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/tylerobara/containers/\.github/workflows/keycloak\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/keycloak:latest
```

Signatures exist only for images that passed the grype gate (0 Low+
findings); scan history is on the [site](https://tylerobara.github.io/containers/).
The smoke test ([`test.sh`](test.sh)) boots `start-dev` as uid 65532 and
requires `health/ready` UP on the management `:9000` plus the welcome page
and master realm document on the published `:8080` — the same strict
permission set the apk actually ships.
