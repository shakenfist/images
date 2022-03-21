#!/bin/bash -e

# Ensure we're up to date, and have diskimage-builder installed.
apt-get update
apt-get dist-upgrade -y
apt-get install -y git python3 python3-dev python3-pip python3-wheel

# We have to install diskimage-builder this way because the Ubuntu dependancies
# are wrong for the packaged version.
if [ ! -e diskimage-builder ]; then
    git clone https://github.com/openstack/diskimage-builder
else
    cd diskimage-builder
    git pull origin master
    cd ..
fi

cd diskimage-builder
apt-get install -y `bindep --list_all newline` kpartx
python3 setup.py develop
cd ..

export ELEMENTS_PATH=elements:diskimage-builder/diskimage_builder/elements

# Build images
build_args="cloud-init cloud-init-datasources sf-agent vm"
export DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack, NoCloud"

echo
echo "Building Ubuntu 18.04"
echo
DIB_RELEASE=bionic disk-image-create ubuntu ${build_args} -o ubuntu-18.04-sfagent.qcow2

echo
echo "Building Ubuntu 20.04"
echo
DIB_RELEASE=focal disk-image-create ubuntu ${build_args} -o ubuntu-20.04-sfagent.qcow2

echo
echo "Building Debian 10"
echo
DIB_RELEASE=buster disk-image-create debian debian-systemd ${build_args} -o debian-10-sfagent.qcow2

echo
echo "Building Debian 11"
echo
DIB_RELEASE=bullseye disk-image-create debian debian-systemd ${build_args} -o debian-11-sfagent.qcow2

echo
echo "Building CentOS 7"
echo
DIB_RELEASE=7 disk-image-create centos ${build_args} -o centos-7-sfagent.qcow2

echo
echo "Building CentOS 8"
echo
DIB_RELEASE=8-stream disk-image-create centos ${build_args} -o centos-8-stream-sfagent.qcow2

# And done
echo
echo "Complete"