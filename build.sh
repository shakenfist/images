#!/bin/bash -e

# Obsolete image builds (not built by default, but still here just in case):
#   centos:7 centos:8-stream
#   debian:10
#   fedora:34 fedora:38 fedora:39 fedora:40
#   ubuntu:16.04 ubuntu:18.04
#
# Retired 2026-09-12 because the release is end of life upstream. The
# build blocks below are kept so a one-off rebuild is still possible,
# and what is already published stays on images.shakenfist.com --
# anything pinned to it keeps working, it simply stops being
# refreshed.
#   ubuntu:20.04  EOL 2025-05-31
#   fedora:41     EOL 2025-11
#   fedora:42     EOL 2026-06
#   debian:11, and its -docker, -gnome and -xfce variants. Bullseye
#                 LTS ended 2026-08-31 and the security suite's
#                 Release file expired on 2026-09-08, so these can no
#                 longer be built at all: apt refuses the expired
#                 repository and the build stops there. This is not a
#                 policy choice we could reverse by editing the list.
#
# No Fedora is built at all, which is not a policy choice either.
# fedora:43 and fedora:44 have never built, both dying the same way:
# their python is new enough that grpcio-tools has no wheel, so pip
# falls back to compiling it and the image carries no C++ compiler.
# Loki has fedora:43 failing that way as far back as 2026-08-14 and
# no successful build ever. The newest Fedora that does build is
# fedora:42, which is end of life, so there is no supported Fedora we
# can currently produce.
#
# Fixing this means teaching sf-agent to install a compiler for the
# RHEL family and remove it again afterwards -- the element already
# does the equivalent for old Debian releases, installing
# build-essential and python3-dev -- or waiting for grpcio to publish
# wheels. Until then, putting fedora:43 or fedora:44 in the list above
# only manufactures a nightly failure, which is the noise that hid a
# sixteen day outage.
#
# debian:12 is past standard security support (2026-06-10) and is
# still built deliberately. private-ci bakes the debian-12 runner
# labels that sixteen repositories boot on from it, and Debian LTS
# covers bookworm until 2028. Retire it as the eol-distro audit
# issues are closed, not before.
#
# Two things elsewhere need doing as a result of the above, and
# neither can be done in this repository:
#   * private-ci builds its "dependencies" cache disk from debian:11,
#     and its own comment says a missing dependencies label blocks ALL
#     CI provisioning. That base can no longer be rebuilt, so moving
#     it to debian:13 is now the thing standing between us and an
#     unrecoverable CI outage.
#   * the debian-docker:12, debian-gnome:12 and debian-xfce:12 images
#     were built from bullseye rather than bookworm until 2026-09-12.
#     Anything baked from them before that date -- the debian-12-docker
#     and debian-gnome-12 runner labels especially -- is Debian 11 and
#     needs rebuilding.

do_not_push=0

# --list-images prints the list this script would build and exits.
# tools/check-image-freshness.sh reads the list from here rather than
# keeping its own copy: a watchdog with a second copy of the list
# stops watching anything added to the real one, and does so
# silently.
#
# It is handled here, before the apt-get preamble below, so it runs
# as an unprivileged user on a host with none of the build
# dependencies installed. That is what lets the watchdog run
# anywhere, which is the whole point of the watchdog.
list_images_only=0
if [ "$1" == "--list-images" ]; then
    list_images_only=1
    shift
fi

images="$1"
if [ "$images" == "" ]; then
    images="ubuntu:22.04 ubuntu:24.04 centos:9-stream debian:12 debian-docker:12 debian-gnome:12 debian-xfce:12 debian:13 debian-docker:13 debian-gnome:13 debian-xfce:13 rocky:8 rocky:9 rocky:10"
fi

if [ $list_images_only -eq 1 ]; then
    echo "${images}"
    exit 0
fi

echo "I will build the following images: ${images}"
echo

# Ensure we're up to date, and have diskimage-builder installed.
apt-get update
apt-get dist-upgrade -y
apt-get install -y git python3 python3-dev python3-pip python3-wheel rsync xz-utils podman
pip3 install --break-system-packages bindep

# We have to install diskimage-builder this way because the Ubuntu dependancies
# are wrong for the packaged version.
if [ ! -e diskimage-builder ]; then
    git clone https://github.com/openstack/diskimage-builder
else
    cd diskimage-builder
    git stash
    git pull origin master
    cd ..
fi

cd diskimage-builder

for patch in ../diskimage-builder-patches/*.patch; do
    echo "Applying patch $patch"
    git apply $patch
done

apt-get install -y `bindep --list_all newline`
python3 setup.py develop
cd ..

# diskimage-builder requires the hostname be known, or it gets confused
hostname=$(hostname)
if [ $(grep -c $hostname /etc/hosts) -lt 1 ]; then
    sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost $hostname/" /etc/hosts
fi

# Build images
mkdir -p /srv/sf-images/cache
datestamp=$(date +%Y%m%d)

function push_log_to_loki() {
    # Push build log to Loki for centralized monitoring
    # $1: log file path
    # $2: image label (e.g., "debian-xfce:12")
    # $3: build result ("success" or "failure")

    local log_file="$1"
    local image_label="$2"
    local build_result="$3"

    if [ ! -f "$log_file" ]; then
        return 0
    fi

    echo "Pushing build log to Loki for ${image_label} (${build_result})"

    LOG_FILE="$log_file" IMAGE_LABEL="$image_label" BUILD_RESULT="$build_result" \
        BUILD_HOST="$(hostname)" python3 << 'PYEOF' || true
import json, os, time, urllib.request

log_file = os.environ['LOG_FILE']
image_label = os.environ['IMAGE_LABEL']
build_result = os.environ['BUILD_RESULT']
build_host = os.environ.get('BUILD_HOST', 'unknown')

with open(log_file, 'r', errors='replace') as f:
    lines = f.readlines()

base_ns = int(time.time() * 1e9)
values = [
    [str(base_ns + i), line.rstrip('\n')]
    for i, line in enumerate(lines)
    if line.strip()
]

if not values:
    exit(0)

payload = json.dumps({
    'streams': [{
        'stream': {
            'job': 'image-build',
            'host': build_host,
            'image': image_label,
            'result': build_result,
        },
        'values': values,
    }]
}).encode()

req = urllib.request.Request(
    'http://loki.home.stillhq.com:3100/loki/api/v1/push',
    data=payload,
    headers={
        'Content-Type': 'application/json',
        'X-Scope-OrgID': 'sfyow',
    },
)
try:
    urllib.request.urlopen(req)
    print('Pushed %d log lines to Loki for %s' % (len(values), image_label))
except Exception as e:
    print('Warning: failed to push logs to Loki: %s' % e)
PYEOF
}

function build () {
    # $1: output filename
    # $2: OS release name (bionic, focal, etc)
    # $3: python version (2 or 3)
    # $4: distro specific args
    # $5: name of the shakenfist agent package

    echo
    echo "===================================================================="
    echo "Building $1 (agent package $5)"
    echo "===================================================================="
    echo

    rm -rf /srv/sf-images/output
    export ELEMENTS_PATH=elements:diskimage-builder/diskimage_builder/elements
    export DIB_APT_MINIMAL_CREATE_INTERFACES=0
    export DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack, NoCloud"
    export DIB_CLOUD_INIT_ETC_HOSTS=1
    export DIB_CLOUD_INIT_GROWPART_DEVICES="/dev/vda3"
    export DIB_GRUB_TIMEOUT=0
    export DIB_IMAGE_CACHE="/srv/sf-images/cache"

    # Note the default here is "nofb nomodeset gfxpayload=text" which breaks
    # graphical consoles if you choose to install one later...
    export DIB_BOOTLOADER_DEFAULT_CMDLINE="net.ifnames=0 biosdevname=0 earlyprintk=ttyS0,115200 consoleblank=0"

    export build_args="cloud-init cloud-init-datasources cloud-init-growpart block-device-efi vm"

    cwd=$(pwd)

    # Root filesystem features the guest's grub has to be able to read.
    # See the header of block-device-compat.yaml: without this every
    # image whose release ships grub older than 2.12 fails with
    # "grub-install: error: unknown filesystem". The path is absolute
    # because disk-image-create runs from elsewhere, and this is
    # deliberately not exported once at the top of the script -- ${cwd}
    # is only known inside build().
    export DIB_BLOCK_DEVICE_CONFIG="file://${cwd}/block-device-compat.yaml"
    output=$1
    outdir=$(dirname ${output})
    mkdir -p ${outdir}

    echo "OS release: ${2}"
    export DIB_APT_OPTIONS=""
    if [ $(echo "${2}" | egrep -c "(jessie|stretch|buster)" || true) -gt 0 ]; then
	echo "Debian release which is ancient, overriding the apt mirror."
	export DIB_DISTRIBUTION_MIRROR="https://deb.freexian.com/extended-lts"
	export DIB_APT_SOURCES_CONF="default:deb https://deb.freexian.com/extended-lts ${2} main contrib non-free
lts:deb https://deb.freexian.com/extended-lts ${2}-lts main contrib non-free"
	export DIB_APT_KEYRING=$(pwd)"/debian-release-freexian.gpg"
    fi

    echo "Python version: ${3}"
    if [ "${3}" == "-" ]; then
        unset DIB_PYTHON_VERSION
    else
        export DIB_PYTHON_VERSION=$3
    fi

    echo "Shakenfist agent package: ${5}"
    if [ ! -z ${5} ]; then
	export DIB_SF_AGENT_PACKAGE="${5}"
	export build_args="${build_args} sf-agent"
    fi

    set -x
    # Build an uncompressed image first
    DIB_RELEASE=$2 /usr/local/bin/disk-image-create $4 ${build_args} -u -o temp.qcow2 | tee ${output}.log

    # If we detected a checksum failure, clear the cache. This seems common with
    # upstream Ubuntu images for some reason.
    if [ $(grep -c "computed checksum did NOT match" ${output}.log) -gt 0 ]; then
        rm -rf /srv/sf-images/cache
    fi

    # Why is it so hard to detect a DIB failure?
    if [ $? -gt 0 ]; then
        echo "BUILD FAILED."
        push_log_to_loki "${output}.log" "$(basename ${outdir})" "failure"
        return 1
    fi

    if [ $(grep -c "Build completed successfully" ${output}.log) -lt 1 ]; then
        echo "BUILD FAILED"
        push_log_to_loki "${output}.log" "$(basename ${outdir})" "failure"
        return 1
    fi
    set +x

    # Transcode the image into the preferred format
    qemu-img convert -t none -o cluster_size=2048K -c -O qcow2 temp.qcow2 ${output}
    rm -rf tmp* temp.qcow2

    cd ${outdir}
    rm -f latest.qcow2
    ln -s $(basename ${output}) latest.qcow2

    # Copy images to the repository
    if [ $do_not_push == 0 ]; then
        cd /srv/sf-images/output
        rsync -rcavp --links --progress . /srv/www/images.shakenfist.com/

        # Cleanup old images
	dirname=$(ls)
	cd "/srv/www/images.shakenfist.com/$dirname"
        numimages=$( ls *.qcow2 | grep -v latest | sort | wc -l )
        numextra=$(( $numimages - 7 ))

        for img in $( ls *.qcow2 | grep -v latest | sort | head -$numextra ); do
            echo "Removing $img"
            rm -f $img $img.log
        done
    else
        echo "Skipping push"
    fi
    cd ${cwd}
    push_log_to_loki "${output}.log" "$(basename ${outdir})" "success"
    return 0
}

# Too old for the agent to run, but convenient to have for testing
if [ $(echo $images | grep -c "ubuntu:16.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:16.04/ubuntu-16.04-${datestamp}.qcow2"
    build ${output} xenial "-" "apparmor utilities debian-old-extras ubuntu ubuntu-remove-pollinate"
fi

# Images containing the agent
if [ $(echo $images | grep -c "ubuntu:18.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:18.04/ubuntu-18.04-sfagent-${datestamp}.qcow2"
    build ${output} bionic "-" "apparmor utilities debian-old-extras ubuntu ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:20.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:20.04/ubuntu-20.04-sfagent-${datestamp}.qcow2"
    build ${output} focal 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:22.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:22.04/ubuntu-22.04-sfagent-${datestamp}.qcow2"
    build ${output} jammy 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:24.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:24.04/ubuntu-24.04-sfagent-${datestamp}.qcow2"
    build ${output} noble 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:8") -gt 0 ]; then
    output="/srv/sf-images/output/debian:8/debian-8-${datestamp}.qcow2"
    build ${output} jessie 3 "apparmor utilities debian-old-extras debian debian-systemd"
fi

if [ $(echo $images | grep -c "debian:9") -gt 0 ]; then
    output="/srv/sf-images/output/debian:9/debian-9-${datestamp}.qcow2"
    build ${output} stretch 3 "apparmor utilities debian-old-extras debian debian-systemd"
fi

if [ $(echo $images | grep -c "debian:10") -gt 0 ]; then
    output="/srv/sf-images/output/debian:10/debian-10-sfagent-${datestamp}.qcow2"
    build ${output} buster 3 "apparmor utilities debian-old-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian:11/debian-11-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian:12/debian-12-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian-12-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian:13/debian-13-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian-13-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:7") -gt 0 ]; then
    output="/srv/sf-images/output/centos:7/centos-7-sfagent-${datestamp}.qcow2"
    build ${output} 7 "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:8-stream") -gt 0 ]; then
    output="/srv/sf-images/output/centos:8-stream/centos-8-stream-sfagent-${datestamp}.qcow2"
    build ${output} 8-stream "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:9-stream") -gt 0 ]; then
    output="/srv/sf-images/output/centos:9-stream/centos-9-stream-sfagent-${datestamp}.qcow2"
    build ${output} 9-stream "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:34") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:34/fedora-34-sfagent-${datestamp}.qcow2"
    build ${output} 34 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:38") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:38/fedora-38-sfagent-${datestamp}.qcow2"
    build ${output} 38 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:39") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:39/fedora-39-sfagent-${datestamp}.qcow2"
    build ${output} 39 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:40") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:40/fedora-40-sfagent-${datestamp}.qcow2"
    build ${output} 40 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:41") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:41/fedora-41-sfagent-${datestamp}.qcow2"
    build ${output} 41 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:42") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:42/fedora-42-sfagent-${datestamp}.qcow2"
    build ${output} 42 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:43") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:43/fedora-43-sfagent-${datestamp}.qcow2"
    build ${output} 43 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:44") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:44/fedora-44-sfagent-${datestamp}.qcow2"
    build ${output} 44 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:8") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:8/rocky-8-sfagent-${datestamp}.qcow2"
    build ${output} 8 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:9") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:9/rocky-9-sfagent-${datestamp}.qcow2"
    build ${output} 9 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:10") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:10/rocky-10-sfagent-${datestamp}.qcow2"
    build ${output} 10 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:11/debian-11-docker-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:12/debian-12-docker-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:13/debian-13-docker-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:11/debian-11-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:12/debian-12-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:13/debian-13-gnome-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:11/debian-11-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd xfce-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:12/debian-12-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras xfce-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:13/debian-13-xfce-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras xfce-desktop" shakenfist-agent
fi

# And done
echo
echo "Complete"
