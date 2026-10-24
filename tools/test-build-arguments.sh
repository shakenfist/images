#!/bin/bash

# Exercise build.sh's argument parsing.
#
# The failure worth testing for is a run that publishes when it was
# told not to: a mistyped --no-push taken as the image list, or a
# --no-push written after the list and ignored. Both are refused.
#
# Every case carries --list-images, which exits before the build
# does anything, so a parser that regressed prints a list here rather
# than starting a build.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-build-arguments.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${HERE}/build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

check() {
    # $1 name, $2 wanted exit, $3 the output wanted exactly ('-' to
    # require only that it does not look like an image list), then the
    # arguments for build.sh
    local name="$1" want="$2" output="$3"
    shift 3
    local got=0 problem=""

    "${BUILD}" "$@" > "${WORK}/out" 2>&1 || got=$?
    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif [ "${output}" != '-' ] && [ "$(cat "${WORK}/out")" != "${output}" ]; then
        problem="printed something else"
    fi

    if [ -z "${problem}" ]; then
        echo "PASS: ${name}"
        passed=$((passed + 1))
    else
        echo "FAIL: ${name}: ${problem}"
        sed 's/^/    /' "${WORK}/out"
        failed=$((failed + 1))
    fi
}

check "the image list is taken" 0 "debian:13" \
    --list-images debian:13
check "several images quoted together" 0 "debian:13 rocky:9" \
    --list-images --no-push "debian:13 rocky:9"
check "a mistyped flag is refused" 2 - \
    --list-images --nopush debian:13
# Alone, so it is the flag check that refuses it and not the check
# for arguments after the list.
check "a mistyped flag alone is not an image list" 2 - \
    --list-images --nopush
check "a flag after the image list is refused" 2 - \
    --list-images debian:13 --no-push
check "several unquoted images are refused" 2 - \
    --list-images debian:13 rocky:9
# --no-self-update is what a CI checkout passes, beside --no-push when
# it is not publishing, so it has to be accepted in any order among
# the flags and refused after the list like the others.
check "--no-self-update is taken" 0 "debian:13" \
    --list-images --no-self-update debian:13
check "--no-self-update in any order among the flags" 0 "debian:13 rocky:9" \
    --no-self-update --no-push --list-images "debian:13 rocky:9"
check "--no-self-update after the image list is refused" 2 - \
    --list-images debian:13 --no-self-update

if "${BUILD}" --list-images | grep -q 'debian:13'; then
    echo "PASS: the default list is printed"
    passed=$((passed + 1))
else
    echo "FAIL: the default list is printed"
    failed=$((failed + 1))
fi

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
