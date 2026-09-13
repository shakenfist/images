#!/bin/bash

# Exercise the verify-release element and the label derivation that
# feeds it.
#
# Both are extracted from the shipped files at run time rather than
# copied here, so this tests what actually runs. That matters more
# than usual: the check being tested is the one thing standing
# between us and republishing the Debian-11-as-Debian-12 defect, and
# a test of a stale copy of it would be worse than no test at all.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-verify-release.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELEMENT="${HERE}/elements/verify-release/finalise.d/99-verify-release"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

# --- the element itself -------------------------------------------

check_element() {
    # $1 name, $2 expected exit, $3 os-release body,
    # $4 DIB_RELEASE, $5 DIB_SF_EXPECTED_VERSION
    local name="$1" want="$2" body="$3" release="$4" expected="$5"
    local got=0

    printf '%s\n' "${body}" > "${WORK}/os-release"
    OS_RELEASE_FILE="${WORK}/os-release" \
        DIB_RELEASE="${release}" \
        DIB_SF_EXPECTED_VERSION="${expected}" \
        bash "${ELEMENT}" > "${WORK}/out" 2>&1 || got=$?

    if [ "${got}" -eq "${want}" ]; then
        printf '  ok    %-46s\n' "${name}"
        passed=$(( passed + 1 ))
    else
        printf '  FAIL  %-46s want=%s got=%s\n' \
            "${name}" "${want}" "${got}"
        sed 's/^/          /' "${WORK}/out"
        failed=$(( failed + 1 ))
    fi
}

DEB12='PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"
VERSION_CODENAME=bookworm'
DEB11='PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
VERSION_ID="11"
VERSION_CODENAME=bullseye'
UBUNTU2204='PRETTY_NAME="Ubuntu 22.04.5 LTS"
VERSION_ID="22.04"
VERSION_CODENAME=jammy'
ROCKY9='PRETTY_NAME="Rocky Linux 9.6 (Blue Onyx)"
VERSION_ID="9.6"'
CENTOS9='PRETTY_NAME="CentOS Stream 9"
VERSION_ID="9"'
UNSTABLE='PRETTY_NAME="Debian GNU/Linux trixie/sid"
VERSION_CODENAME=trixie'

echo "Images we actually publish, all of which must pass:"
check_element "debian:12 built from bookworm"      0 "${DEB12}"      bookworm 12
check_element "ubuntu:22.04 built from jammy"      0 "${UBUNTU2204}" jammy    22.04
check_element "rocky:9 reporting a minor version"  0 "${ROCKY9}"     9        9
check_element "centos:9-stream, suffix stripped"   0 "${CENTOS9}"    9-stream 9

echo
echo "The defect this element exists for:"
check_element "debian-docker:12 that is Debian 11" 1 "${DEB11}"      bullseye 12

echo
echo "Everything else that must fail rather than pass quietly:"
check_element "DIB built a different release"      1 "${DEB11}"      bookworm 11
check_element "no VERSION_ID to check against"     1 "${UNSTABLE}"   trixie   13
check_element "nothing said what to expect"        1 "${DEB12}"      bookworm ""
check_element "a major version must not match 10"  1 "${ROCKY9}"     9        10

# --- the label derivation in build.sh -----------------------------

echo
echo "Every label in the default list derives a version:"

# shellcheck disable=SC2016  # the ${label} here is sed's pattern to
# match in build.sh, not something this script wants expanded.
derivation=$(sed -n '/^    case "${label}" in/,/^    esac/p' "${HERE}/build.sh")
if [ -z "${derivation}" ]; then
    echo "  FAIL  could not extract the derivation from build.sh"
    failed=$(( failed + 1 ))
    derivation='return 1'
fi

# Stubs for what the extracted block reaches for on its failure path.
# shellcheck disable=SC2034  # read by the block eval'd in derive().
output=/dev/null
push_log_to_loki() { :; }

derive() {
    local label="$1"
    DIB_SF_EXPECTED_VERSION=""
    eval "${derivation}" > /dev/null 2>&1 || return 1
    echo "${DIB_SF_EXPECTED_VERSION}"
}

check_label() {
    local label="$1" want="$2" got
    got=$(derive "${label}") || got='<rejected>'
    if [ "${got}" == "${want}" ]; then
        printf '  ok    %-22s -> %s\n' "${label}" "${got}"
        passed=$(( passed + 1 ))
    else
        printf '  FAIL  %-22s -> %s (want %s)\n' \
            "${label}" "${got}" "${want}"
        failed=$(( failed + 1 ))
    fi
}

for label in $("${HERE}/build.sh" --list-images); do
    case "${label}" in
        centos:9-stream) check_label "${label}" 9 ;;
        *)               check_label "${label}" "${label##*:}" ;;
    esac
done

echo
echo "A label carrying no version is rejected rather than guessed at:"
check_label 'debian' '<rejected>'

echo
echo "${passed} passed, ${failed} failed."
[ "${failed}" -eq 0 ]
