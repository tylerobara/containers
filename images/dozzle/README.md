# dozzle

[Dozzle](https://github.com/amir20/dozzle) — the real-time web UI for
container logs — built from the release tarball by melange (frontend via
Wolfi's bun, matching upstream's pinned bun 1.4.2; Go binary via go-1.27,
web UI embedded), assembled by apko on Wolfi — no Dockerfile. Mirrors
upstream's image contract (static binary, entrypoint starts the server on
:8080, bundled CA certs) with two deliberate deviations: nonroot uid 65532
and a busybox debug shell instead of bare scratch.

```
docker run --rm -p 127.0.0.1:8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add $(stat -c %g /var/run/docker.sock) \
  ghcr.io/tylerobara/containers/dozzle:latest
```

Then open <http://localhost:8080>.

## Running

The server needs a container runtime: mount `/var/run/docker.sock`
(read-only is fine) and pass the socket's group —
`--group-add $(stat -c %g /var/run/docker.sock)` — since uid 65532 cannot
open the root:docker socket without it (same trick `docker`'s own nonroot
setups use), or point it at remote endpoints with `--remote-host`
(ssh/docker hosts) or `--remote-agent` (dozzle agent targets). Kubernetes:
`DOZZLE_MODE=k8s` with the pod watch RBAC, no socket needed.

Everything runs as uid 65532. The package ships a writable `/data` (the
binary mkdirs `./data` on every start and dies without it; the dir is 0777
because melange packages carry root ownership only), holding the optional
user database and notification rules — bind a volume at `/data` to persist
it across restarts.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/dozzle.yaml`; the melange build also
stamps `internal/cli.Version` via ldflags (the same value upstream's release
TAG build-arg passes), so `dozzle --version` reports the real release. The
update-versions bot opens bump PRs against
[amir20/dozzle releases](https://github.com/amir20/dozzle/releases).
