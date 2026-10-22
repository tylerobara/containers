# os-shell

Wolfi counterpart to [bitnami/containers os-shell](https://github.com/bitnami/containers/tree/main/bitnami/os-shell):
a tiny nonroot helper image for Kubernetes init containers, sidecars and
one-off shell tasks. Assembled by apko on Wolfi — no Dockerfile, and nothing
built from source: the entire image is signed Wolfi packages, so the daily
rebuild picks up security updates without a commit.

```
docker run --rm ghcr.io/tylerobara/containers/os-shell:latest \
  -c 'echo "{\"a\":1}" | jq .a'
```

## What's in it

| tool | note |
|------|------|
| busybox | `sh` + coreutils |
| netcat-openbsd | the wait-for-port replacement: `until nc -z host port; do sleep 1; done` |
| bash | bitnami's os-shell scripts assume it; so does everyone's `command: ["bash", "-c", ...]` |
| curl | HTTP/TLS probes, downloads (ca-certificates included) |
| jq / yq | JSON / YAML munging (yq 4.x, same line bitnami ships) |
| procps | `ps` etc. |

Deliberately **not** shipped: bitnami's `render-template`, `ini-file`,
`scuttle` (env-templating and proxy wrappers minideb apps needed; k8s gives
you `env`/`envFrom` and every tool here already speaks `HTTP_PROXY`), and the
DB clients some bitnami variants bundle — run a real client image for that.
`apk` is absent at runtime, as in every image here.

Runs as uid/gid 65532 (`nonroot`). Like bitnami's image there is no HOME to
write into — mount an `emptyDir` if your script needs one.

## Versioning

`VERSION` in this directory is the tag source (also `MAJOR.MINOR` + `latest`
tags). Bump it when the *composition* changes; Wolfi package updates flow in
without one. No update-versions bot row — nothing here pins an upstream
release.

## Verify

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/tylerobara/containers/\.github/workflows/os-shell\.yml@refs/heads/main$' \
  ghcr.io/tylerobara/containers/os-shell:latest
```

Only signed when the grype scan in the same run found zero Low+ findings;
current digests, scans and signatures are on the [Pages catalog](https://tylerobara.github.io/containers/).
