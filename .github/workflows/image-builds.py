#!/usr/bin/python

import jinja2

JOBS = [
    {
        'name': 'debian-10',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    },
    {
        'name': 'debian-11',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    },
    {
        'name': 'ubuntu-1804',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    },
    {
        'name': 'ubuntu-2004',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    },
    {
        'name': 'centos-7',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    },
    {
        'name': 'centos-8',
        'baseimage': 'debian:11',
        'baseuser': 'debian'
    }
]


if __name__ == '__main__':
    with open('image-build.tmpl') as f:
        t = jinja2.Template(f.read())

    for job in JOBS:
        with open('image-build-%s.yml' % job['name'], 'w') as f:
            f.write(t.render(job))
