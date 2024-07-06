#!/bin/bash -e

# Obsolete image builds (not built by default, but still here just in case):
#   centos:7 centos:8-stream
#   debian:10
#   fedora:34 fedora:38 fedora:39
#   ubuntu:16.04 ubuntu:18.04

do_not_push=0
images="$1"
if [ "$images" == "" ]; then
    images="ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 debian:11 centos:9-stream debian-docker:11 debian-gnome:11 debian-xfce:11 debian:12 debian-docker:12 debian-gnome:12 debian-xfce:12 fedora:40 rocky:8 rocky:9"
fi

echo "I will build the following images: ${images}"
echo

# Ensure we're up to date, and have diskimage-builder installed.
apt-get update
apt-get dist-upgrade -y
apt-get install -y git python3 python3-dev python3-pip python3-wheel rsync xz-utils podman
pip3 install bindep

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
    export DIB_GRUB_TIMEOUT=0
    export DIB_IMAGE_CACHE="/srv/sf-images/cache"

    # Note the default here is "nofb nomodeset gfxpayload=text" which breaks
    # graphical consoles if you choose to install one later...
    export DIB_BOOTLOADER_DEFAULT_CMDLINE="earlyprintk=ttyS0,115200 consoleblank=0"

    export build_args="cloud-init cloud-init-datasources sf-agent block-device-efi vm"

    cwd=$(pwd)
    output=$1
    outdir=$(dirname ${output})
    mkdir -p ${outdir}

    echo "${3}"
    if [ "${3}" == "-" ]; then
        unset DIB_PYTHON_VERSION
    else
        export DIB_PYTHON_VERSION=$3
    fi

    set -x
    # Build an uncompressed image first
    DIB_RELEASE=$2 DIB_SF_AGENT_PACKAGE=$5 /usr/local/bin/disk-image-create $4 ${build_args} -u -o temp.qcow2 | tee ${output}.log

    # If we detected a checksum failure, clear the cache. This seems common with
    # upstream Ubuntu images for some reason.
    if [ $(grep -c "computed checksum did NOT match" ${output}.log) -gt 0 ]; then
        rm -rf /srv/sf-images/cache
    fi

    # Why is it so hard to detect a DIB failure?
    if [ $? -gt 0 ]; then
        echo "BUILD FAILED."
        exit 1
    fi

    if [ $(grep -c "Build completed successfully" ${output}.log) -lt 1 ]; then
        echo "BUILD FAILED"
        exit 1
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
}

# Too old for the agent to run, but convenient to have for testing
if [ $(echo $images | grep -c "ubuntu:16.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:16.04/ubuntu-16.04-${datestamp}.qcow2"
    build ${output} xenial "-" "apparmor utilities debian-old-extras ubuntu"
fi

# Images containing the agent
if [ $(echo $images | grep -c "ubuntu:18.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:18.04/ubuntu-18.04-sfagent-${datestamp}.qcow2"
    build ${output} bionic "-" "apparmor utilities debian-old-extras ubuntu" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:20.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:20.04/ubuntu-20.04-sfagent-${datestamp}.qcow2"
    build ${output} focal 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:22.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:22.04/ubuntu-22.04-sfagent-${datestamp}.qcow2"
    build ${output} jammy 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:24.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:24.04/ubuntu-24.04-sfagent-${datestamp}.qcow2"
    build ${output} jammy 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware" shakenfist-agent
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

if [ $(echo $images | grep -c "rocky:8") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:8/rocky-8-sfagent-${datestamp}.qcow2"
    build ${output} 8 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:9") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:9/rocky-9-sfagent-${datestamp}.qcow2"
    build ${output} 9 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:11/debian-11-docker-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:12/debian-12-docker-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian debian-systemd debian-12-extras docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:11/debian-11-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:12/debian-12-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian debian-systemd debian-12-extras gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:11/debian-11-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd xfce-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:12/debian-12-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian debian-systemd debian-12-extras xfce-desktop" shakenfist-agent
fi

# And done
echo
echo "Complete"
