#!/bin/bash

# Check that every image we publish has actually been rebuilt
# recently.
#
# The nightly build ran and published nothing for sixteen days in
# August and September 2026 and nobody noticed, because the only
# signal it produced was a non-zero exit into cron mail that nobody
# reads. This asks the question from the other end: not "did the
# build work" but "is what a consumer downloads today any newer than
# what they downloaded last week".
#
# Asking it that way round matters. It is deliberately blind to how
# the images are built, so it keeps working when that changes, and it
# sees failures the builder cannot report on -- a broken publish
# step, a full disk on the web host, an nginx serving a stale
# directory. What it cannot see is an image that is fresh and wrong.
# That is a different control: the verify-release element checks, as
# each image is assembled, that it is the release it will be
# published as. Nothing yet boots a published image to test it.
#
#   tools/check-image-freshness.sh [--max-age-hours N] [--base-url URL]
#
# Exit status:
#   0  every image is fresh
#   1  at least one image is stale or missing
#   2  at least one image could not be checked, and none were stale
#   3  the check itself could not run, so it says nothing about the
#      images
#
# 3 is kept apart from 2 because they send the reader to different
# places: 2 to the web host or the network, 3 to this script or the
# checkout it runs in. Anything that stops the script unexpectedly is
# a 3 as well, so a bug here can never be reported as a stale image.
# The ERR trap below names the failing line when errexit fires; the
# EXIT trap catches what bypasses it -- an unbound variable, or an
# arithmetic error -- which bash otherwise ends with status 1, the
# status for "stale". Only the verdict at the end sets finished.

set -o errexit
set -o nounset
set -o pipefail

finished=0
trap 'echo "The freshness check failed at line ${LINENO}: ${BASH_COMMAND}"; exit 3' ERR
trap 'status=$?
      if [ "${finished}" = 0 ] && [ "${status}" != 0 ] && [ "${status}" != 3 ]; then
          echo "The freshness check stopped unexpectedly with status ${status}."
          exit 3
      fi' EXIT

# Parsing an RFC 1123 date with date(1) depends on the locale, and
# the runner's locale is not ours to assume.
export LC_ALL=C

# Nightly builds mean a healthy image is a few hours old, so almost
# any threshold detects a stopped build eventually. 72 hours is
# chosen to tolerate two consecutive misses before it speaks: long
# enough that one bad night is not an alert anybody has to triage,
# short enough that the sixteen day outage would have been reported
# on the morning of day three rather than a fortnight later.
MAX_AGE_HOURS=72

# The published location, which is what a consumer actually fetches.
# Checking the origin filesystem instead would pass while every
# consumer received nothing.
BASE_URL="https://images.shakenfist.com"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 [--max-age-hours N] [--base-url URL]"
    exit 3
}

while [ $# -gt 0 ]; do
    case "$1" in
        --max-age-hours)
            [ $# -ge 2 ] || usage
            MAX_AGE_HOURS="$2"
            shift 2
            ;;
        --base-url)
            [ $# -ge 2 ] || usage
            BASE_URL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

if ! [ "${MAX_AGE_HOURS}" -gt 0 ] 2>/dev/null; then
    echo "--max-age-hours must be a positive integer."
    exit 3
fi

if [ ! -x "${HERE}/build.sh" ]; then
    echo "No build.sh beside ${HERE}/tools, so there is no image list"
    echo "to check. Run this from a checkout of shakenfist/images."
    exit 3
fi

if ! images="$("${HERE}/build.sh" --list-images)"; then
    echo "build.sh --list-images failed."
    exit 3
fi
if [ -z "${images}" ]; then
    echo "build.sh --list-images returned nothing."
    exit 3
fi

max_age_seconds=$(( MAX_AGE_HOURS * 3600 ))
now=$(date +%s)

stale=0
unreachable=0
checked=0

echo "Checking ${BASE_URL} against a ${MAX_AGE_HOURS} hour threshold."
echo

for image in ${images}; do
    checked=$(( checked + 1 ))
    url="${BASE_URL}/${image}/latest.qcow2"

    if ! headers=$(curl -sS -I -m 30 "${url}" 2>&1); then
        printf '%-20s UNREACHABLE  %s\n' "${image}" "${headers}"
        unreachable=$(( unreachable + 1 ))
        continue
    fi

    status=$(printf '%s' "${headers}" | head -1 | tr -d '\r')
    case "${status}" in
        *' 200'*)
            ;;
        *)
            printf '%-20s MISSING      %s\n' "${image}" "${status}"
            stale=$(( stale + 1 ))
            continue
            ;;
    esac

    # grep finding nothing is an answer, not a failure: without the
    # "|| true" pipefail made it end the whole check with status 1,
    # reporting a stale image instead of reaching the branch below.
    modified=$(printf '%s' "${headers}" \
        | { grep -i '^last-modified:' || true; } \
        | head -1 \
        | cut -d' ' -f2- \
        | tr -d '\r')

    if [ -z "${modified}" ]; then
        # A 200 with no Last-Modified is a server we cannot reason
        # about rather than an image we know to be old, so it is not
        # counted as stale.
        printf '%-20s UNREACHABLE  200 without a Last-Modified header\n' \
            "${image}"
        unreachable=$(( unreachable + 1 ))
        continue
    fi

    if ! built=$(date -d "${modified}" +%s 2>/dev/null); then
        printf '%-20s UNREACHABLE  unparsable Last-Modified: %s\n' \
            "${image}" "${modified}"
        unreachable=$(( unreachable + 1 ))
        continue
    fi

    age=$(( now - built ))
    age_hours=$(( age / 3600 ))

    if [ "${age}" -gt "${max_age_seconds}" ]; then
        printf '%-20s STALE        %s hours old (%s)\n' \
            "${image}" "${age_hours}" "${modified}"
        stale=$(( stale + 1 ))
    else
        printf '%-20s ok           %s hours old\n' \
            "${image}" "${age_hours}"
    fi
done

echo
echo "${checked} images checked, ${stale} stale or missing," \
     "${unreachable} could not be checked."

# Every image is reported before any exit, so one stale image does
# not hide the state of the others -- an alarm that names one image
# when fourteen are down teaches people the wrong thing.
finished=1
if [ "${stale}" -gt 0 ]; then
    exit 1
fi
if [ "${unreachable}" -gt 0 ]; then
    exit 2
fi
exit 0
