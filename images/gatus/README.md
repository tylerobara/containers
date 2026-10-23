# gatus

[Gatus](https://github.com/TwiN/gatus) — health monitor with a status page and
prometheus metrics — built from the release tarball by melange, assembled by
apko on Wolfi. No Dockerfile. Mirrors upstream's image contract (`/usr/bin/
gatus`, embedded web assets, :8080, nonroot) with deliberate deviations: the
debug shell is Wolfi busybox instead of scratch, nonroot is uid 65532, and
upstream's demo config ships as `/etc/gatus/config.yaml.example` rather than
as the live config.

```
docker run --rm -v "$PWD/config.yaml:/etc/gatus/config.yaml:ro" \
  ghcr.io/tylerobara/containers/gatus:latest
```

Then open `http://<host>:8080`. Copy the bundled example to get started:

```
docker run --rm --entrypoint /bin/sh ghcr.io/tylerobara/containers/gatus:latest \
  -c 'cat /etc/gatus/config.yaml.example' > my-config.yaml
```

## Configuration

gatus has no `-config` flag — the config path comes from `GATUS_CONFIG_PATH`
only, which this image defaults to `/etc/gatus/config.yaml`. Mount your own
file there (or override the env var) and just run the image; a bare run with
nothing mounted exits with a clear config-missing error. Everything runs as
uid 65532 — chown bind mounts accordingly. Storage defaults to in-memory;
for anything persistent mount a `storage:` config (sqlite at a writable path,
or postgres) — see upstream docs.

The status page listens on `0.0.0.0:8080` (gatus defaults; `web.address` /
`web.port` in the config override). Like the other images here, endpoints
making outbound TLS need the bundled `ca-certificates`.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/gatus.yaml`; the update-versions bot
opens bump PRs against [TwiN/gatus
releases](https://github.com/TwiN/gatus/releases). Note gatus self-reports no
version (no `--version` flag, no banner — upstream stamps no ldflags either),
so the pin *is* the version: the melange build verifies the tarball sha,
asserts the binary embeds module `github.com/TwiN/gatus/v5`, bumps known
vulnerable Go deps (`vars.xnet_version`/`xcrypto_version`/`otel_version`/
`grpc_version` — no-op `go get`s once upstream ships >= them) and boots the
server as its verify step. The pin must stay at or above Wolfi's live-index
gatus (5.36.0) or apko resolves Wolfi's binary instead — the workflow's
version guard fails the build when that happens.
