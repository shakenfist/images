# Architecture

## Image Build Pipeline

Images are built using OpenStack's
[diskimage-builder](https://docs.openstack.org/diskimage-builder/)
(DIB). The `build.sh` script orchestrates the process:

1. Installs and patches diskimage-builder from source
2. Iterates over requested images
3. Calls `disk-image-create` with distro-specific elements
4. Transcodes the output to compressed QCOW2 with 2MB clusters
5. Pushes the build log to Loki (sfyow tenant)
6. Publishes to the image repository

## Element System

DIB elements are composable units that customise images. Each
element can contain hook scripts in phase directories:

- `install.d/` - Runs inside the chroot during package installation
- `finalise.d/` - Runs inside the chroot after installation

Scripts must be executable and are run in sort order by filename.

## Element Groups

Images use one of three "extras" elements depending on distro age:

- **debian-13-extras**: Debian 13 (trixie). Depends on
  debian-12-extras and additionally enables systemd-networkd.
  Debian 13 dropped ifupdown from the default install, so
  cloud-init uses the systemd-networkd renderer and this service
  must be enabled for network configuration to take effect.
- **debian-12-extras**: Debian 12 (bookworm). Configures
  systemd-resolved and installs lshw and pciutils.
- **debian-old-extras**: Ubuntu 20.04-24.04 and Debian 11.
  Installs legacy networking tools (resolvconf, lshw, pciutils).

## Desktop Elements

The **gnome-desktop** and **xfce-desktop** elements install a full
graphical environment and configure it for unattended use:

1. A `debian` user is created if it does not already exist
2. The display manager is configured for automatic login:
   - GNOME: gdm3 `AutomaticLogin` in `/etc/gdm3/custom.conf`
   - XFCE: lightdm autologin in `/etc/lightdm/lightdm.conf.d/`
3. Screen saver and screen lock are disabled:
   - GNOME: dconf system defaults in `/etc/dconf/db/local.d/`
   - XFCE: xfconf defaults in `/etc/xdg/xfce4/xfconf/`
4. DPMS (display power management) is disabled so the screen
   never blanks

## Key Build Variables

- `DIB_APT_MINIMAL_CREATE_INTERFACES=0` - Prevents DIB from
  creating interface configuration files
- `DIB_BOOTLOADER_DEFAULT_CMDLINE` - Kernel command line
  (serial console, no blank)
- `DIB_CLOUD_INIT_DATASOURCES` - ConfigDrive, OpenStack, NoCloud
- `DIB_CLOUD_INIT_GROWPART_DEVICES=/dev/vda3` - Partition to grow
