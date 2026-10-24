#!/bin/bash

# Exercise tools/image-matrix.sh, which turns the image list into the
# build workflow's matrix.
#
# The failures worth testing for are a matrix that quietly builds
# nothing, and a hand-typed name carrying something other than an
# image label into a job that runs as root. Both are refused.
#
# The cases that need build.sh to list nothing, or to fail, run a copy
# of the script beside a stand-in build.sh, because the script finds
# build.sh relative to itself. Everything else runs the real pair.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-image-matrix.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX="${HERE}/tools/image-matrix.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

check() {
    # $1 name, $2 wanted exit, $3 the stdout wanted exactly ('-' to
    # require only that stdout is empty), then the command to run
    local name="$1" want="$2" output="$3"
    shift 3
    local got=0 problem=""

    "$@" > "${WORK}/out" 2> "${WORK}/err" || got=$?
    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif [ "${output}" = '-' ] && [ -s "${WORK}/out" ]; then
        problem="printed a matrix when it should have refused"
    elif [ "${output}" != '-' ] && [ "$(cat "${WORK}/out")" != "${output}" ]; then
        problem="printed something else"
    fi

    if [ -z "${problem}" ]; then
        echo "PASS: ${name}"
        passed=$((passed + 1))
    else
        echo "FAIL: ${name}: ${problem}"
        sed 's/^/    out: /' "${WORK}/out"
        sed 's/^/    err: /' "${WORK}/err"
        failed=$((failed + 1))
    fi
}

# A tree holding a copy of the script and a build.sh whose
# --list-images prints $2, with backslash escapes expanded, and exits
# $3.
fake_tree() {
    local dir="${WORK}/$1"
    mkdir -p "${dir}/tools"
    cp "${MATRIX}" "${dir}/tools/"
    printf '#!/bin/bash\nprintf %%b "%s"\nexit %s\n' "$2" "$3" > "${dir}/build.sh"
    chmod +x "${dir}/build.sh"
    echo "${dir}/tools/image-matrix.sh"
}

# The default list is whatever build.sh says, encoded independently
# here so the two cannot share a mistake.
default="$("${HERE}/build.sh" --list-images)"
read -r -a default_words <<< "${default}"
want_default="$(python3 -c "import json, sys; print(json.dumps(sys.argv[1:], separators=(',', ':')))" \
    "${default_words[@]}")"

check "no list means build.sh's default list" 0 "${want_default}" \
    "${MATRIX}"
check "an empty list means build.sh's default list" 0 "${want_default}" \
    "${MATRIX}" ''
check "an explicit list is taken as it is" 0 '["debian:13","rocky:9"]' \
    "${MATRIX}" 'debian:13 rocky:9'
check "an explicit list is split on any whitespace" 0 '["debian:13","rocky:9","ubuntu:24.04"]' \
    "${MATRIX}" "$(printf ' debian:13\trocky:9\nubuntu:24.04 ')"
# Retired images are still built on request; the list is not checked
# against the default one.
check "a retired image can be asked for" 0 '["fedora:42"]' \
    "${MATRIX}" 'fedora:42'
check "a list that is only whitespace is refused" 2 - \
    "${MATRIX}" '   '
check "an empty default list is refused" 2 - \
    "$(fake_tree empty '' 0)"
check "a default list of only whitespace is refused" 2 - \
    "$(fake_tree blank ' \n ' 0)"
check "a failing build.sh is reported, not turned into a list" 1 - \
    "$(fake_tree broken 'debian:13' 3)"
check "a bad character in the default list is refused" 2 - \
    "$(fake_tree badchar 'debian:13 rocky;9' 0)"
# The $(id) is meant literally: it is what a hostile input would hold.
# shellcheck disable=SC2016
check "a shell metacharacter is refused" 2 - \
    "${MATRIX}" 'debian:13 $(id)'
check "a semicolon is refused" 2 - \
    "${MATRIX}" 'debian:13;rocky:9'
check "a path is refused" 2 - \
    "${MATRIX}" '../debian:13'
check "a quote is refused" 2 - \
    "${MATRIX}" 'debian:13"'
check "a non-ASCII letter is refused" 2 - \
    "${MATRIX}" 'débian:13'
# build.sh reads its flags before its image list, so a name starting
# with '-' would be taken as a flag rather than built.
check "a name that is a build.sh flag is refused" 2 - \
    "${MATRIX}" '--list-images'
check "--no-push as a name is refused" 2 - \
    "${MATRIX}" '--no-push'
check "a name starting with a single '-' is refused" 2 - \
    "${MATRIX}" '-x'
check "a flag among real names is refused" 2 - \
    "${MATRIX}" 'debian:13 --no-push'
check "several arguments are refused" 2 - \
    "${MATRIX}" 'debian:13' 'rocky:9'

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
