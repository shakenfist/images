Build tooling for images intended for Shaken Fist.

## Overview

This repository contains diskimage-builder elements and a build script
(`build.sh`) for creating VM images used by Shaken Fist. Images are
built daily and published to `images.shakenfist.com`.

## Elements

Custom diskimage-builder elements are in the `elements/` directory:

- **debian-12-extras** - Extras for Debian 12+ (bookworm, trixie).
  Disables predictable network interface naming and configures
  systemd-resolved.
- **debian-old-extras** - Extras for older Debian and Ubuntu releases
  (including Ubuntu 20.04, 22.04, 24.04 and Debian 11). Disables
  predictable network interface naming and installs resolvconf,
  lshw, and pciutils.
- **sf-agent** - Installs the Shaken Fist agent package.
- **docker-host** - Installs Docker for desktop images.
- **gnome-desktop** / **xfce-desktop** - Desktop environment elements.
- **ubuntu-remove-snap** / **ubuntu-remove-firmware** /
  **ubuntu-remove-pollinate** - Remove unnecessary Ubuntu packages.
- **rhel-extras** - Extras for RHEL-based distros (CentOS, Rocky,
  Fedora).

## Network Interface Naming

All images disable systemd's predictable network interface naming by
masking the udev rule `80-net-setup-link.rules`. This ensures
interfaces are named `eth0`, `eth1`, etc., which is required by
downstream tooling such as Kolla-Ansible.

The masking is done via
`elements/*/install.d/10-disable-predictable-ifnames` scripts in
both `debian-12-extras` and `debian-old-extras`.

## Building Images

```bash
# Build all images
sudo ./build.sh

# Build a specific image
sudo ./build.sh "ubuntu:24.04"
```

## Patches

The `diskimage-builder-patches/` directory contains patches applied
to diskimage-builder before building images.