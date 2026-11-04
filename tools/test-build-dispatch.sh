#!/bin/bash

# Exercise build.sh's image-dispatch table: the blocks at the end of
# the script that, for each label present in the image list, set an
# output path and call build() with the release, python version and
# element list for that image.
#
# These lines are plain argument passing, but there are many of them
# and a nightly only ever runs the handful in the default list, so a
# mistake in a retired or non-default block stays invisible until that
# image is next built by hand. The shellcheck quoting pass made exactly
# that mistake in an early draft: it dropped the space in
# "build ${output} <release>", gluing the release onto the output path
# and shifting every later argument. bash -n, shellcheck and the other
# tests all passed regardless, because none of them runs these lines.
# This one does -- it stubs build() to record its arguments, drives the
# table with every label it names, and checks the shape of each call.
#
# The table is extracted from build.sh at run time rather than copied,
# so this tests what actually ships.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-build-dispatch.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${HERE}/build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

ok()   { printf '  ok    %s\n' "$1"; passed=$(( passed + 1 )); }
fail() { printf '  FAIL  %s\n' "$1"; failed=$(( failed + 1 )); }

# --- the table under test -------------------------------------------

# From the first dispatch block to the finish_run call that ends the
# script: everything between is the if/grep guards and the build calls.
REGION="${WORK}/region.sh"
sed -n '/^# Too old for the agent/,/^finish_run$/p' "${BUILD}" > "${REGION}"

# The labels the table knows about, read from the guards themselves
# (each is `grep -c "<label>"`), so a block added or removed is picked
# up here without editing this test.
mapfile -t LABELS < <(grep -oE 'grep -c "[^"]+"' "${REGION}" \
    | sed -E 's/grep -c "(.*)"/\1/')

if [ "${#LABELS[@]}" -lt 30 ] || ! grep -q '^finish_run$' "${REGION}"; then
    echo "FAIL: could not extract the dispatch table from ${BUILD}."
    echo "If the blocks moved or the guard idiom changed, fix the"
    echo "extraction above rather than deleting this test."
    exit 1
fi

# --- drive it with a recording build() ------------------------------

CALLS="${WORK}/calls"
: > "${CALLS}"

build() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$#" "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" >> "${CALLS}"
}
finish_run() { :; }

# Every label present, so every block fires -- including the retired
# and non-default ones a nightly never reaches. Both are read only by
# the dispatch region sourced below, which shellcheck cannot follow.
# shellcheck disable=SC2034  # read by the sourced dispatch region
images="${LABELS[*]}"
# shellcheck disable=SC2034  # read by the sourced dispatch region
datestamp="TESTSTAMP"

# shellcheck disable=SC1090  # the region is a fragment of build.sh, extracted above
source "${REGION}"

# --- check the shape of every call ----------------------------------

# One build call per guard, no more and no fewer.
calls="$(wc -l < "${CALLS}")"
if [ "${calls}" -eq "${#LABELS[@]}" ]; then
    ok "one build call per dispatch block (${calls})"
else
    fail "expected ${#LABELS[@]} build calls, got ${calls}"
fi

label_known() {
    local want="$1" l
    for l in "${LABELS[@]}"; do
        [ "${l}" = "${want}" ] && return 0
    done
    return 1
}

while IFS=$'\t' read -r n a1 a2 a3 a4 a5; do
    lbl="${a1#/srv/sf-images/output/}"
    lbl="${lbl%%/*}"

    # 4 or 5 arguments. The glued-space regression produced 3.
    if [ "${n}" -ne 4 ] && [ "${n}" -ne 5 ]; then
        fail "${a1}: ${n} arguments, expected 4 or 5"
    # $1 is the output path: ends in .qcow2, with a known label as its
    # directory. A release glued onto it fails both halves.
    elif [ "${a1}" = "${a1%.qcow2}" ]; then
        fail "${a1}: output path does not end in .qcow2"
    elif ! label_known "${lbl}"; then
        fail "${a1}: output directory '${lbl}' is not a known label"
    # $2 is the release: non-empty and not a path.
    elif [ -z "${a2}" ] || [ "${a2}" != "${a2//\//}" ]; then
        fail "${lbl}: release '${a2}' is empty or contains a slash"
    # $3 is the python-version marker: '-' or a number.
    elif [ "${a3}" != "-" ] && ! [[ "${a3}" =~ ^[0-9]+$ ]]; then
        fail "${lbl}: python marker '${a3}' is not '-' or a number"
    # $4 is the element list: non-empty.
    elif [ -z "${a4}" ]; then
        fail "${lbl}: empty element list"
    # $5, when present, is always the agent package.
    elif [ "${n}" -eq 5 ] && [ "${a5}" != "shakenfist-agent" ]; then
        fail "${lbl}: 5th argument '${a5}' is not shakenfist-agent"
    else
        ok "${lbl}"
    fi
done < "${CALLS}"

echo
echo "${passed} passed, ${failed} failed."
[ "${failed}" -eq 0 ]
