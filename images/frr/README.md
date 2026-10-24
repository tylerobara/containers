# frr

[FRRouting](https://frrouting.org) (the FRR routing suite — zebra, bgpd,
vtysh, ...) built from the upstream release tarball by melange, assembled by
apko on Wolfi — no Dockerfile. Drop-in replacement for
`quay.io/frrouting/frr:10.4.3` (the BGP speaker for Cilium and MetalLB in
minilab).

```
docker run --rm --entrypoint /usr/lib/frr/bgpd \
  ghcr.io/tylerobara/containers/frr:latest --version
```

## Startup

Same contract as the upstream container:

- Entrypoint `/sbin/tini --`, CMD `/usr/lib/frr/docker-start`.
- `docker-start` (built into the melange package, from upstream's
  `docker/alpine/docker-start`) takes ownership of `/etc/frr` +
  `/var/run/frr`, sources `/usr/lib/frr/frrcommon.sh` and runs
  `watchfrr $(daemon_list)` — watchfrr supervises every daemon enabled in
  `/etc/frr/daemons` and pushes config via vtysh on restart.
- The container starts as **root** (like upstream): watchfrr runs as root
  and each daemon setuid-drops to the `frr` user (uid/gid **92**, plus
  `frrvty` gid 85 — matching the upstream debian packaging) after taking
  its sockets.
- The shipped `/etc/frr/daemons` has **bgpd enabled** (plus the
  always-on zebra/staticd/mgmtd), so a bare `docker run` comes up speaking
  BGP. Bind-mount your own `/etc/frr/daemons` + `/etc/frr/frr.conf` (or
  the Cilium/MetalLB config) to customize; the daemons listen on
  127.0.0.1 per the default `*_options`, so drive them with `vtysh` inside
  the container, or override the options.

```
docker run -d --name frr --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --cap-add=SYS_ADMIN \
  -v $PWD/frr:/etc/frr ghcr.io/tylerobara/containers/frr:latest
docker exec -it frr vtysh
```

Kubernetes: route programming needs `NET_ADMIN`/`NET_RAW`, and the
daemons' `privs_init` also requires `CAP_SYS_ADMIN` in the bounding set
(Cilium and MetalLB run their frr speakers privileged — same works
here). apko cannot declare supplementary groups, so `docker-start` adds
the `frr` user to `frrvty` at startup — without that membership
`privs_init` refuses to start any daemon.

## Differences from quay.io/frrouting/frr, on purpose

- Wolfi users/groups via apko accounts instead of the deb postinst.
- Built with the config set the archived Wolfi `frr-10.4` package used
  (RPKI/cares+rtrlib, libyang3 northbound, openssl crypto, lua scripting,
  vtysh) — no snmp, no grpc (add them in `melange/frr.yaml` if needed).
- Default daemons file enables bgpd (upstream's default is all-off, but
  then the container idles).

## Signing

Same keyless policy as every image here: signed only when the CI grype scan
reports 0 findings Low+; verify per the command on
<https://tylerobara.github.io/containers/>.

## Updating

`version` + `vars.sha256` in `melange/frr.yaml` (upstream tags releases as
`frr-<ver>`; the update-versions bot opens bump PRs). The melange package
keeps `epoch: 100` + `provider-priority: 100` because the old Wolfi
`frr-10.x` apks `provides: frr=` — ours must keep winning resolution.
