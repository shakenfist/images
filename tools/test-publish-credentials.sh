#!/bin/bash

# Exercise tools/publish-credentials.sh, which writes the build
# workflow's publishing key and pinned host key and hands RSYNC_RSH and
# the rsync target to later steps through GITHUB_ENV.
#
# The guard that matters most is the one on the target. It goes into
# GITHUB_ENV as a NAME=value line, so a newline in it would let a
# secret set any other variable for the rest of the job; it is checked
# here by whether GITHUB_ENV changed at all. The others are a target
# with no host, which on a throwaway VM publishes into a disk that is
# about to be deleted, a target rsync would read as an option, a key
# that does not parse or needs a passphrase, and files a mode other
# than 600.
#
# RUNNER_TEMP and GITHUB_ENV point into a temporary directory, and the
# keys are generated for the run. The script runs under env -i, so
# nothing from the caller's environment leaks into a case. Nothing here
# prints key material: on a failure it shows what the script printed,
# and the script never prints a secret.
#
# Runs anywhere with ssh-keygen, needs no build host and no root:
#
#   tools/test-publish-credentials.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${HERE}/tools/publish-credentials.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

RUNNER="${WORK}/runner"
GH_ENV="${WORK}/github_env"
DIR="${RUNNER}/images-publish"
SENTINEL="EXISTING=line"
TARGET="images@images.example.org:/srv/www/images/"

mkdir -p "${WORK}/keys"
ssh-keygen -q -t ed25519 -N '' -C test -f "${WORK}/keys/good"
ssh-keygen -q -t ed25519 -N 'a passphrase' -C test -f "${WORK}/keys/locked"
ssh-keygen -q -t ed25519 -N '' -C test -f "${WORK}/keys/host"
GOOD_KEY="$(cat "${WORK}/keys/good")"
LOCKED_KEY="$(cat "${WORK}/keys/locked")"
KNOWN_HOSTS_LINE="images.example.org $(cat "${WORK}/keys/host.pub")"

reset() {
    rm -rf "${RUNNER}"
    mkdir -p "${RUNNER}"
    echo "${SENTINEL}" > "${GH_ENV}"
}

# Run the script with only the variables named. $1 is the action; the
# rest are NAME=value pairs. Prints the exit code.
run() {
    local action="$1" rc=0
    shift
    env -i PATH="${PATH}" RUNNER_TEMP="${RUNNER}" GITHUB_ENV="${GH_ENV}" "$@" \
        "${SCRIPT}" "${action}" > "${WORK}/out" 2>&1 || rc=$?
    echo "${rc}"
}

# Run setup with the three secrets, each overridable: $1 key, $2 known
# hosts, $3 target. An argument of '-' leaves that variable unset.
setup() {
    local vars=()
    [ "$1" = '-' ] || vars+=("IMAGES_PUBLISH_SSH_KEY=$1")
    [ "$2" = '-' ] || vars+=("IMAGES_PUBLISH_KNOWN_HOSTS=$2")
    [ "$3" = '-' ] || vars+=("SF_IMAGES_PUBLISH_TARGET=$3")
    run setup "${vars[@]}"
}

result() {
    # $1 name, $2 problem, or empty for a pass
    if [ -z "$2" ]; then
        echo "PASS: $1"
        passed=$((passed + 1))
    else
        echo "FAIL: $1: $2"
        sed 's/^/    /' "${WORK}/out"
        failed=$((failed + 1))
    fi
}

# A refusal: the wanted exit, and GITHUB_ENV exactly as it was.
refused() {
    # $1 name, $2 wanted exit, $3 the exit got
    local problem=""
    if [ "$3" != "$2" ]; then
        problem="exit $3, wanted $2"
    elif [ "$(cat "${GH_ENV}")" != "${SENTINEL}" ]; then
        problem="GITHUB_ENV was changed"
    fi
    result "$1" "${problem}"
}

# --- the target -----------------------------------------------------

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "$(printf '%s\nRSYNC_RSH=evil' "${TARGET}")")
refused "a target with a newline in it is refused" 2 "${rc}"
if [ -e "${DIR}/id" ]; then
    result "a target with a newline writes no key" "the key was written"
else
    result "a target with a newline writes no key" ""
fi

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "images@images.example.org:/srv/www/my images/")
refused "a target with a space in it is refused" 2 "${rc}"

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "/srv/www/images/")
refused "a target with no host is refused" 2 "${rc}"

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "--rsync-path=evil:/srv/www/images/")
refused "a target starting with '-' is refused" 2 "${rc}"

# --- the secrets ----------------------------------------------------

reset
rc=$(setup - "${KNOWN_HOSTS_LINE}" "${TARGET}")
refused "a missing key is refused" 2 "${rc}"

reset
rc=$(setup "${GOOD_KEY}" - "${TARGET}")
refused "missing known hosts are refused" 2 "${rc}"

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" -)
refused "a missing target is refused" 2 "${rc}"

reset
rc=$(setup "not a key at all" "${KNOWN_HOSTS_LINE}" "${TARGET}")
refused "a key that does not parse is refused" 1 "${rc}"

reset
rc=$(setup "${LOCKED_KEY}" "${KNOWN_HOSTS_LINE}" "${TARGET}")
refused "a key with a passphrase is refused" 1 "${rc}"

# --- a working setup ------------------------------------------------

check_setup() {
    # $1 name, $2 the exit got
    local problem="" mode added rsh
    added="$(tail -n +2 "${GH_ENV}")"
    rsh="$(sed -n 's/^RSYNC_RSH=//p' "${GH_ENV}")"
    if [ "$2" != 0 ]; then
        problem="exit $2, wanted 0"
    elif [ "$(head -n 1 "${GH_ENV}")" != "${SENTINEL}" ]; then
        problem="the existing GITHUB_ENV line was lost"
    elif [ "$(printf '%s\n' "${added}" | wc -l)" != 2 ]; then
        problem="GITHUB_ENV gained $(printf '%s\n' "${added}" | wc -l) lines, wanted 2"
    elif [ "$(printf '%s\n' "${added}" | head -n 1 | cut -d= -f1)" != RSYNC_RSH ]; then
        problem="the first line added is not RSYNC_RSH"
    elif [ "$(printf '%s\n' "${added}" | tail -n 1)" != "SF_IMAGES_PUBLISH_TARGET=${TARGET}" ]; then
        problem="the second line added is not the target"
    elif [[ "${rsh}" != *'-o StrictHostKeyChecking=yes'* ]]; then
        problem="RSYNC_RSH does not insist on the pinned host key"
    elif [[ "${rsh}" != *'-o GlobalKnownHostsFile=/dev/null'* ]]; then
        problem="RSYNC_RSH lets ssh read the global known_hosts"
    elif [[ "${rsh}" != *"-o UserKnownHostsFile=${DIR}/known_hosts"* ]]; then
        problem="RSYNC_RSH does not use the pinned known_hosts"
    elif [[ "${rsh}" != *"-i ${DIR}/id "* ]]; then
        problem="RSYNC_RSH does not use the key written"
    elif ! cmp -s "${DIR}/id" "${WORK}/keys/good"; then
        problem="the key written is not the key given"
    elif [ "$(cat "${DIR}/known_hosts")" != "${KNOWN_HOSTS_LINE}" ]; then
        problem="the known_hosts written is not the line given"
    else
        for file in id known_hosts; do
            mode="$(stat -c %a "${DIR}/${file}")"
            if [ "${mode}" != 600 ]; then
                problem="${file} has mode ${mode}, wanted 600"
            fi
        done
    fi
    result "$1" "${problem}"
}

reset
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "${TARGET}")
check_setup "a usable key is written, mode 600, with two GITHUB_ENV lines" "${rc}"

# A second setup over files left readable, as a job reusing its
# temporary directory would find them. Writing to an existing file
# keeps its mode whatever the umask, so only the chmod makes them 600.
reset
mkdir -p "${DIR}"
touch "${DIR}/id" "${DIR}/known_hosts"
chmod 644 "${DIR}/id" "${DIR}/known_hosts"
rc=$(setup "${GOOD_KEY}" "${KNOWN_HOSTS_LINE}" "${TARGET}")
check_setup "setup over readable files leaves them mode 600" "${rc}"

# --- cleanup --------------------------------------------------------

rc=$(run cleanup)
problem=""
if [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
elif [ -e "${DIR}/id" ] || [ -e "${DIR}/known_hosts" ]; then
    problem="a file was left behind"
elif [ -e "${DIR}" ]; then
    problem="the directory was left behind"
fi
result "cleanup after setup removes both files and the directory" "${problem}"

reset
rc=$(run cleanup)
problem=""
if [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
fi
result "cleanup with nothing set up succeeds" "${problem}"

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
