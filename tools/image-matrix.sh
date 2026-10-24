#!/bin/bash

# Print the images a workflow run should build, as a compact JSON
# array for a build matrix.
#
# With no list, or an empty one, this is build.sh --list-images: the
# workflow has no list of its own, for the same reason the freshness
# watchdog has none. A second copy stops covering anything added to
# the real one, and nothing says so.
#
# A list given by hand is taken as it is, split on whitespace. It is
# not checked against build.sh's default list, because a one-off
# rebuild of a retired image is a legitimate request and its build
# block is still in build.sh. Each name is checked for its characters,
# though: only letters, digits, '.', ':' and '-', which is every label
# build.sh has ever had. The names become job names and arguments to a
# command run as root, so anything else is refused rather than passed
# on.
#
# A list that comes out empty is refused too. A matrix with nothing in
# it builds nothing and reports success, which is the shape of the
# outage this repository's watchdog exists to catch.
#
#   tools/image-matrix.sh ["image image ..."]
#
# Exits 0 having printed the array, 1 if build.sh could not list its
# images, and 2 if the list is refused.

set -o errexit
set -o nounset
set -o pipefail

export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${HERE}/build.sh"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [\"image image ...\"]" >&2
    echo "Several images are quoted together as one argument." >&2
    exit 2
fi

list="${1:-}"
if [ -z "${list}" ]; then
    if ! list="$("${BUILD}" --list-images)"; then
        echo "build.sh --list-images failed, so there is no list to build." >&2
        exit 1
    fi
fi

# read stops at the first newline unless told otherwise, and returns
# non-zero at the end of its input, which is the only way -d '' ends.
images=()
read -r -d '' -a images < <(printf '%s' "${list}") || true

if [ "${#images[@]}" -eq 0 ]; then
    echo "The image list is empty, so there is nothing to build." >&2
    exit 2
fi

valid='^[A-Za-z0-9.:-]+$'
for image in "${images[@]}"; do
    if ! [[ "${image}" =~ ${valid} ]]; then
        echo "Refusing image name '${image}': only letters, digits, '.', ':' and '-' are allowed." >&2
        exit 2
    fi
done

python3 -c "import json, sys; print(json.dumps(sys.argv[1:], separators=(',', ':')))" "${images[@]}"
