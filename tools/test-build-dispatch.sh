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
    # '|' not tab: tab is IFS whitespace, so an empty middle argument
    # would collapse on read and misname every later field. No dispatch
    # argument contains '|'.
    printf '%s|%s|%s|%s|%s|%s\n' \
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

# The guard labels and the output-path labels should be the same set:
# every block fires once (all labels are present) and each writes to
# its own label's directory. Comparing the two as sets catches a block
# that writes to another block's directory -- the copy-paste slip that
# published Debian 11 under three Debian 12 names for two years -- which
# a count plus a membership test would both pass. It also subsumes the
# "one call per guard" count.
cut -d'|' -f2 "${CALLS}" \
    | sed -E 's#^/srv/sf-images/output/([^/]+)/.*#\1#' \
    | LC_ALL=C sort > "${WORK}/out_labels"
printf '%s\n' "${LABELS[@]}" | LC_ALL=C sort > "${WORK}/guard_labels"
if diff "${WORK}/guard_labels" "${WORK}/out_labels" > "${WORK}/label_diff"; then
    ok "every guard label built its own output directory (${#LABELS[@]})"
else
    fail "guard labels and output directories disagree (< guard, > output):"
    sed 's/^/          /' "${WORK}/label_diff"
fi

# Three early images predate the agent and legitimately pass none; every
# other block must pass shakenfist-agent, because a dropped agent
# argument does not break the build (build_one guards on $5) -- it
# publishes an agentless image that fails only when the guest is booted.
AGENTLESS=" ubuntu:16.04 debian:8 debian:9 "

while IFS='|' read -r n a1 a2 a3 a4 a5; do
    lbl="${a1#/srv/sf-images/output/}"
    lbl="${lbl%%/*}"

    # $1 is the output path and ends in .qcow2. This is what catches the
    # glued-space regression in every block: for the three agentless
    # ones the glued call also drops to three arguments, but for the 31
    # five-argument ones it still has four and so passes the count check
    # below -- the .qcow2 suffix is the assertion that catches those.
    if [ "${a1}" = "${a1%.qcow2}" ]; then
        fail "${a1}: output path does not end in .qcow2"
        continue
    fi
    # Argument count: four for the agentless images, five for the rest,
    # whose fifth argument is the agent package.
    if [[ "${AGENTLESS}" == *" ${lbl} "* ]]; then
        if [ "${n}" -ne 4 ]; then
            fail "${lbl}: ${n} arguments, expected 4 (agentless)"; continue
        fi
    elif [ "${n}" -ne 5 ]; then
        fail "${lbl}: ${n} arguments, expected 5 with shakenfist-agent"; continue
    elif [ "${a5}" != "shakenfist-agent" ]; then
        fail "${lbl}: 5th argument '${a5}' is not shakenfist-agent"; continue
    fi
    # $2 is the release: non-empty and not a path.
    if [ -z "${a2}" ] || [ "${a2}" != "${a2//\//}" ]; then
        fail "${lbl}: release '${a2}' is empty or contains a slash"; continue
    fi
    # $3 is the python-version marker: '-' or a number.
    if [ "${a3}" != "-" ] && ! [[ "${a3}" =~ ^[0-9]+$ ]]; then
        fail "${lbl}: python marker '${a3}' is not '-' or a number"; continue
    fi
    # $4 is the element list: non-empty.
    if [ -z "${a4}" ]; then
        fail "${lbl}: empty element list"; continue
    fi
    ok "${lbl}"
done < "${CALLS}"

echo
echo "${passed} passed, ${failed} failed."
[ "${failed}" -eq 0 ]
