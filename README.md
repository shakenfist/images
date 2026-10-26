Build tooling for images intended for Shaken Fist.

## Overview

This repository contains diskimage-builder elements and a build script
(`build.sh`) for creating VM images used by Shaken Fist. Images are
built daily and published to `images.shakenfist.com`.

## Documentation

- [The nightly build](https://github.com/shakenfist/images/blob/master/docs/nightly-build.md)
  -- how the nightly build runs, how to rebuild an image by hand, and
  where its logs go.
- [Plans](https://github.com/shakenfist/images/blob/master/docs/plans/index.md)
  -- work in progress on this repository.

## Elements

Custom diskimage-builder elements are in the `elements/` directory:

- **debian-13-extras** - Extras for Debian 13+ (trixie). Depends on
  debian-12-extras and enables systemd-networkd, which Debian 13
  requires because ifupdown is no longer installed by default.
- **debian-12-extras** - Extras for Debian 12 (bookworm). Configures
  systemd-resolved and installs lshw and pciutils.
- **debian-old-extras** - Extras for older Debian and Ubuntu releases
  (including Ubuntu 20.04, 22.04, 24.04 and Debian 11). Disables
  predictable network interface naming and installs resolvconf,
  lshw, and pciutils.
- **sf-agent** - Installs the Shaken Fist agent package.
- **docker-host** - Installs Docker for desktop images.
- **gnome-desktop** / **xfce-desktop** - Desktop environment elements.
  These create a `debian` user, enable auto-login via the display
  manager (gdm3 / lightdm), and disable the screen saver and lock
  screen so graphical sessions start unattended.
- **ubuntu-remove-snap** / **ubuntu-remove-firmware** /
  **ubuntu-remove-pollinate** - Remove unnecessary Ubuntu packages.
- **rhel-extras** - Extras for RHEL-based distros (CentOS, Rocky,
  Fedora).

## Network Interface Naming

All images disable systemd's predictable network interface naming
via kernel command line parameters (`net.ifnames=0 biosdevname=0`).
This ensures interfaces are named `eth0`, `eth1`, etc., which is
required by downstream tooling such as Kolla-Ansible.

## Building Images

```bash
# Build all images, and publish them to the rsync destination in
# SF_IMAGES_PUBLISH_TARGET, which has no default. A remote
# user@host:path target also needs its ssh settings in RSYNC_RSH.
sudo --preserve-env=SF_IMAGES_PUBLISH_TARGET,RSYNC_RSH ./build.sh

# Build a specific image without publishing it
sudo ./build.sh --no-push "ubuntu:24.04"
```

`sudo` drops exported variables, including the two that turn on log
forwarding below; the
[nightly build documentation](https://github.com/shakenfist/images/blob/master/docs/nightly-build.md#building-buildsh-directly)
shows how to pass them through.

## Log Forwarding

When `SF_IMAGES_LOKI_URL` and `SF_IMAGES_LOKI_TENANT` are set in the
build host's environment, `build.sh` pushes each image's build log to
that Loki after the image completes, labelled with `job=image-build`,
the image name, the build host, and success or failure status. Each
run also ships a summary of built, failed and never attempted images
as `job=image-build-summary`, which is the only record of an image
that was never attempted.

Neither variable has a default. With them unset nothing is shipped,
and the run says so only in a warning when it starts, so a deployment
that wants build logs has to set both -- the
[nightly build documentation](https://github.com/shakenfist/images/blob/master/docs/nightly-build.md)
describes where. The destination is deliberately not named here:
this repository is public and the deployment that consumes it is
not.

Query them with the tenant your deployment uses:

```bash
loki-query '{job="image-build"}' --tenant <tenant> --since 24h
loki-query '{job="image-build", image="debian-xfce:12"}' --tenant <tenant> --since 7d
loki-query '{job="image-build-summary"}' --tenant <tenant> --since 24h
```

## Patches

The `diskimage-builder-patches/` directory contains patches applied
to diskimage-builder before building images.
