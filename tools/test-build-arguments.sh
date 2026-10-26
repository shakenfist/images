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
# The publish target check is exercised on the stretch of build.sh
# that does it, extracted at run time like tools/test-run-summary.sh
# does: running the whole script with a target would go on to update
# the checkout and start a build.
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

# A publishing run with no target is refused before anything else
# happens. The check is extracted from build.sh and run with
# do_not_push set as the parser would have set it.
sed -n '/^publish_target=/,/^# end of the publish target check$/p' "${BUILD}" \
    > "${WORK}/target.sh"
if ! grep -q '^# end of the publish target check$' "${WORK}/target.sh"; then
    echo "FAIL: could not extract the publish target check from ${BUILD}"
    exit 1
fi

check_target() {
    # $1 name, $2 do_not_push, $3 SF_IMAGES_PUBLISH_TARGET ('' for
    # unset), $4 wanted exit, $5 text the output must contain ('' for
    # none), $6 the publish_target wanted afterwards ('-' to skip)
    local name="$1" nopush="$2" target="$3" want="$4" text="$5" final="$6"
    local got=0 problem="" env_args=()

    [ -n "${target}" ] && env_args=("SF_IMAGES_PUBLISH_TARGET=${target}")
    env -u SF_IMAGES_PUBLISH_TARGET "${env_args[@]}" bash -c \
        "do_not_push=${nopush}; . '${WORK}/target.sh'; echo \"target=[\${publish_target}]\"" \
        > "${WORK}/out" 2>&1 || got=$?
    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif [ -n "${text}" ] && ! grep -qF "${text}" "${WORK}/out"; then
        problem="did not say ${text}"
    elif [ "${final}" != '-' ] && ! grep -qxF "target=[${final}]" "${WORK}/out"; then
        problem="target was not ${final}"
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

check_target "a publish with no target is refused" 0 '' 2 \
    'SF_IMAGES_PUBLISH_TARGET is not set' -
check_target "--no-push with no target passes the check" 1 '' 0 '' ''
check_target "a publish with a target passes" 0 '/srv/www/site/' 0 '' '/srv/www/site/'
check_target "a target without a trailing slash gets one" 0 '/srv/www/site' 0 '' '/srv/www/site/'
check_target "a bare host: is left alone" 0 'host:' 0 '' 'host:'
check_target "a --no-push run keeps a target it was given" 1 'user@host:path' 0 '' 'user@host:path/'

# Refused before the self-update and the build, and --no-push or
# --list-images still run with no target. --list-images is the only
# one that can be run whole here.
check "--list-images needs no target" 0 "debian:13" \
    --list-images debian:13

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
