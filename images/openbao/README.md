# openbao

[OpenBao](https://github.com/openbao/openbao) (community fork of Vault) built
from the release tarball by melange, assembled by apko on Wolfi — no
Dockerfile. Mirrors upstream's image contract (`/usr/bin/bao`, `vault` compat
symlink, nonroot, :8200) with two deliberate deviations: nonroot is uid
65532 and the default CMD is `server` (production posture — mount your own
`/openbao/config`), not upstream's `-dev` default.

```
docker run --rm ghcr.io/tylerobara/containers/openbao:latest version
```

## Running a server

The base has no `libcap`/setcap (and rootless containers can't mlock
anyway), so pick one:

- grant the capability: `securityContext.capabilities.add: ["IPC_LOCK"]`
  (or `docker run --cap-add=IPC_LOCK`), or
- disable mlock: `mlock = false` in server config or
  `OPENBAO_DISABLE_MLOCK=1` in the environment.

Data/config live on volumes you own: `/openbao/config` (drop-in config
files), `/openbao/file` (file storage backend), `/openbao/logs` (audit
device). Everything runs as uid 65532 — chown your volumes accordingly.

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/openbao.yaml`; the update-versions bot
opens bump PRs against
[openbao/openbao releases](https://github.com/openbao/openbao/releases).
