#!/bin/bash

# Set up, or remove, what a build workflow job needs to publish to the
# image site over SSH.
#
# build.sh knows nothing about SSH. rsync takes RSYNC_RSH from the
# environment, so this writes the key and the pinned host key into the
# job's temporary directory and hands later steps RSYNC_RSH and the
# rsync destination through GITHUB_ENV. Split out of the workflow so it
# can be linted and run by hand rather than trusted as YAML.
#
#   tools/publish-credentials.sh setup
#   tools/publish-credentials.sh cleanup
#
# "setup" reads three variables, all from the workflow's secrets, and
# never takes them as arguments, where they would show in a process
# listing:
#
#   IMAGES_PUBLISH_SSH_KEY      the private key, which can do nothing but
#                               rsync into the site's document root
#   IMAGES_PUBLISH_KNOWN_HOSTS  the site host's key line, taken from the
#                               host itself
#   SF_IMAGES_PUBLISH_TARGET    the rsync destination, user@host:path
#
# The host key is pinned rather than fetched with ssh-keyscan at run
# time, which would trust whoever answered. ssh is told to read no
# other known_hosts file, so the pin is the only key it will accept.
#
# Every check runs before anything is built. A key that does not parse
# or a missing target would otherwise surface only at the publish, an
# hour later. A target with no host in it is refused too: on a
# throwaway VM a local path publishes into a disk that is deleted when
# the job ends. So is a target starting with '-', which rsync would
# read as one of its own options rather than as the destination.
#
# Nothing here prints a secret, and it must not run under "set -x".
#
# "cleanup" shreds the key and the host key. The VM is deleted after
# the job anyway, so this is for the case where that assumption stops
# holding, and it succeeds with nothing to do if setup never ran.
#
# Requires RUNNER_TEMP, and for setup GITHUB_ENV, which Actions sets.
# Exits 0 on success, 1 if the key does not parse, and 2 if anything
# required is missing or malformed.

set -o errexit
set -o nounset
set -o pipefail

usage() {
    echo "Usage: $0 setup|cleanup" >&2
    exit 2
}

[ $# -eq 1 ] || usage

if [ -z "${RUNNER_TEMP:-}" ]; then
    echo "RUNNER_TEMP is not set; this is meant to run in an Actions job." >&2
    exit 2
fi

# rsync splits RSYNC_RSH on whitespace, so a path containing any would
# break the command it names.
DIR="${RUNNER_TEMP}/images-publish"
case "${DIR}" in
    *[[:space:]]*)
        echo "RUNNER_TEMP contains whitespace, which RSYNC_RSH cannot carry." >&2
        exit 2
        ;;
esac
KEY="${DIR}/id"
KNOWN_HOSTS="${DIR}/known_hosts"

case "$1" in
    setup)
        if [ -z "${GITHUB_ENV:-}" ]; then
            echo "GITHUB_ENV is not set; this is meant to run in an Actions job." >&2
            exit 2
        fi
        for var in IMAGES_PUBLISH_SSH_KEY IMAGES_PUBLISH_KNOWN_HOSTS SF_IMAGES_PUBLISH_TARGET; do
            if [ -z "${!var:-}" ]; then
                echo "${var} is empty. Is the job running in the images-publish environment?" >&2
                exit 2
            fi
        done

        # The target goes into GITHUB_ENV as one NAME=value line, so a
        # newline in it would let it set other variables.
        target="${SF_IMAGES_PUBLISH_TARGET}"
        case "${target}" in
            *[[:space:]]*)
                echo "SF_IMAGES_PUBLISH_TARGET contains whitespace." >&2
                exit 2
                ;;
            -*)
                echo "SF_IMAGES_PUBLISH_TARGET starts with '-', which rsync would read as an option." >&2
                exit 2
                ;;
            *:*)
                ;;
            *)
                echo "SF_IMAGES_PUBLISH_TARGET names no host; it should be user@host:path." >&2
                exit 2
                ;;
        esac

        umask 077
        mkdir -p "${DIR}"
        printf '%s\n' "${IMAGES_PUBLISH_SSH_KEY}" > "${KEY}"
        printf '%s\n' "${IMAGES_PUBLISH_KNOWN_HOSTS}" > "${KNOWN_HOSTS}"
        chmod 600 "${KEY}" "${KNOWN_HOSTS}"

        # Deriving the public half proves the private half parses,
        # without printing either. An empty passphrase is given so a
        # key that has one fails here instead of prompting.
        if ! ssh-keygen -y -P '' -f "${KEY}" > /dev/null 2>&1; then
            echo "IMAGES_PUBLISH_SSH_KEY is not a usable private key without a passphrase." >&2
            exit 1
        fi

        rsh="ssh -i ${KEY} -o IdentitiesOnly=yes -o BatchMode=yes"
        rsh="${rsh} -o UserKnownHostsFile=${KNOWN_HOSTS} -o GlobalKnownHostsFile=/dev/null"
        rsh="${rsh} -o StrictHostKeyChecking=yes"
        {
            echo "RSYNC_RSH=${rsh}"
            echo "SF_IMAGES_PUBLISH_TARGET=${target}"
        } >> "${GITHUB_ENV}"
        echo "Publishing credentials written under ${DIR}."
        ;;
    cleanup)
        if [ -d "${DIR}" ]; then
            for file in "${KEY}" "${KNOWN_HOSTS}"; do
                if [ -f "${file}" ]; then
                    shred -u "${file}"
                fi
            done
            rm -rf "${DIR}"
            echo "Publishing credentials removed."
        else
            echo "No publishing credentials to remove."
        fi
        ;;
    *)
        usage
        ;;
esac
