#!/usr/bin/python

import jinja2

JOBS = [
    {
        'name': 'debian-10',
        'baseimage': 'sf://label/system/sfci-image-publisher-debian-10',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-debian-10',
        'image': 'debian:10'
    },
    {
        'name': 'debian-11',
        'baseimage': 'sf://label/system/sfci-image-publisher-debian-11',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-debian-11',
        'image': 'debian:11'
    },
    {
        'name': 'ubuntu-1804',
        'baseimage': 'sf://label/system/sfci-image-publisher-ubuntu-1804',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-ubuntu-1804',
        'image': 'ubuntu:18.04'
    },
    {
        'name': 'ubuntu-2004',
        'baseimage': 'sf://label/system/sfci-image-publisher-ubuntu-2004',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-ubuntu-2004',
        'image': 'ubuntu:20.04'
    },
    {
        'name': 'centos-7',
        'baseimage': 'sf://label/system/sfci-image-publisher-centos-7',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-centos-7',
        'image': 'centos:7'
    },
    {
        'name': 'centos-8',
        'baseimage': 'sf://label/system/sfci-image-publisher-centos-8-stream',
        'baseuser': 'debian',
        'label': 'sfci-image-publisher-centos-8-stream',
        'image': 'centos:8-stream'
    }
]


if __name__ == '__main__':
    with open('image-build.tmpl') as f:
        t = jinja2.Template(f.read())

    for job in JOBS:
        with open('image-build-%s.yml' % job['name'], 'w') as f:
            f.write(t.render(job))
