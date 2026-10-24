#!/bin/bash

# Exercise build.sh's publishing and retention.
#
# Publishing has to work when the site is on another host, where the
# only tool is rsync, so both halves are written as rsync and nothing
# else. That is what lets this drive them against a temporary
# directory standing in for the site: the code is the same whether the
# target is a local path or user@host:path.
#
# The two failures worth testing for are a latest.qcow2 that points at
# an image still in transit, and a retention sweep that deletes
# published images because it misread what was there. The second is
# the one nobody can undo, so most of the cases are about it.
#
# The publish target handling and the publishing functions are
# extracted from build.sh at run time rather than copied here, so this
# tests what actually runs. rsync is wrapped in a shim that records
# each call and what the label's directory held after it.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-publish.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${HERE}/build.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

# --- the code under test --------------------------------------------

# Each function runs from its "function name () {" line to the first
# closing brace in column zero, which is its own: everything nested
# inside it is indented.
extract_function() {
    sed -n "/^function $1 () {\$/,/^}\$/p" "${BUILD}"
}

CODE="${WORK}/code.sh"
{
    sed -n '/^publish_target=/,/^esac$/p' "${BUILD}"
    extract_function publish_image
    extract_function prune_published
    extract_function prune_published_in
} > "${CODE}"

if ! grep -q '^publish_target=' "${CODE}" \
        || ! grep -q '^function publish_image () {$' "${CODE}" \
        || ! grep -q '^function prune_published () {$' "${CODE}" \
        || ! grep -q 'rsync --list-only' "${CODE}" \
        || ! grep -q -- '--delete' "${CODE}"; then
    echo "FAIL: could not extract the publishing code from ${BUILD}."
    echo "If it was renamed or reindented, fix the extraction above rather"
    echo "than deleting this test."
    exit 1
fi

# --- an rsync that says what it did ---------------------------------

REAL_RSYNC="$(command -v rsync)"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/rsync" << 'EOF'
#!/bin/bash
# One CALL line per invocation, with its arguments, then an AFTER line
# listing what the watched directory held once it finished.
#
# RSYNC_SHIM_FAIL_CALL=n makes the nth call fail without doing
# anything, the way a dropped connection would. RSYNC_SHIM_EMPTY_LISTING
# makes --list-only succeed and print nothing. RSYNC_SHIM_LIST_LINKS
# adds -l to --list-only, which makes rsync show a symlink with its
# target, as "latest.qcow2 -> image.qcow2". What a --list-only
# printed is copied to the log as LISTED lines.
count=$(( $(grep -c '^CALL' "${RSYNC_SHIM_LOG}" 2>/dev/null || true) + 1 ))
{
    printf 'CALL'
    printf ' %q' "$@"
    echo
} >> "${RSYNC_SHIM_LOG}"
if [ "${RSYNC_SHIM_FAIL_CALL:-0}" = "${count}" ]; then
    echo "rsync shim: failing call ${count}" >&2
    exit 12
fi
rc=0
case " $* " in
    *' --list-only '*)
        if [ -n "${RSYNC_SHIM_EMPTY_LISTING:-}" ]; then
            exit 0
        fi
        if [ -n "${RSYNC_SHIM_LIST_LINKS:-}" ]; then
            set -- -l "$@"
        fi
        "${REAL_RSYNC}" "$@" > "${RSYNC_SHIM_LOG}.out" || rc=$?
        cat "${RSYNC_SHIM_LOG}.out"
        sed 's/^/LISTED /' "${RSYNC_SHIM_LOG}.out" >> "${RSYNC_SHIM_LOG}"
        exit "${rc}"
        ;;
esac
"${REAL_RSYNC}" "$@" || rc=$?
echo "AFTER $(ls -A "${RSYNC_SHIM_WATCH}" 2>/dev/null | tr '\n' ' ')" >> "${RSYNC_SHIM_LOG}"
exit "${rc}"
EOF
chmod +x "${WORK}/bin/rsync"

SITE="${WORK}/site"
LABEL_DIR="${SITE}/debian:13"
OUTPUT_DIR="${WORK}/output/debian:13"
SHIM_LOG="${WORK}/rsync.log"

reset() {
    rm -rf "${SITE}" "${WORK}/output" "${WORK}/tmp" "${SHIM_LOG}" "${SHIM_LOG}.out"
    mkdir -p "${SITE}" "${OUTPUT_DIR}" "${WORK}/tmp"
}

# Call one of the functions the way build_one does: from the condition
# of an "if", which turns errexit off inside it, under a shell started
# with -e as build.sh's shebang is. The target is given without its
# trailing slash, so the normalisation is exercised every time.
run() {
    # $1 function, $2 output filename
    local rc=0
    SF_IMAGES_PUBLISH_TARGET="${SITE}" PATH="${WORK}/bin:${PATH}" \
        TMPDIR="${WORK}/tmp" REAL_RSYNC="${REAL_RSYNC}" \
        RSYNC_SHIM_LOG="${SHIM_LOG}" RSYNC_SHIM_WATCH="${LABEL_DIR}" \
        bash -ec 'source "$1"; if "$2" "$3"; then exit 0; fi; exit 1' \
        _ "${CODE}" "$1" "$2" > "${WORK}/out" 2>&1 || rc=$?
    echo "${rc}"
}

result() {
    # $1 name, $2 problem, or empty for a pass
    if [ -z "$2" ]; then
        echo "PASS: $1"
        passed=$((passed + 1))
    else
        echo "FAIL: $1: $2"
        sed 's/^/    /' "${WORK}/out"
        if [ -e "${SHIM_LOG}" ]; then
            echo "    rsync calls:"
            sed 's/^/      /' "${SHIM_LOG}"
        fi
        failed=$((failed + 1))
    fi
}

# What the label's directory at the site holds, names only, sorted.
listing() {
    find "${LABEL_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '
}

# --- publishing -----------------------------------------------------

IMAGE="debian-13-sfagent-20261025.qcow2"

make_build() {
    echo "image 20261025" > "${OUTPUT_DIR}/${IMAGE}"
    echo "log 20261025" > "${OUTPUT_DIR}/${IMAGE}.log"
    ln -s "${IMAGE}" "${OUTPUT_DIR}/latest.qcow2"
    # Neither of these was built by this call, so neither is published:
    # an earlier image of the same label, and another label entirely.
    echo "stale" > "${OUTPUT_DIR}/debian-13-sfagent-20261020.qcow2"
    mkdir -p "${WORK}/output/rocky:9"
    echo "other" > "${WORK}/output/rocky:9/rocky-9-sfagent-20261025.qcow2"
}

# One publish lands the image, its log and the symlink, and nothing
# else.
reset
make_build
rc=$(run publish_image "${OUTPUT_DIR}/${IMAGE}")
problem=""
want="${IMAGE} ${IMAGE}.log latest.qcow2 "
if [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
elif [ ! -d "${LABEL_DIR}" ]; then
    problem="nothing arrived at ${LABEL_DIR}"
elif [ "$(listing)" != "${want}" ]; then
    problem="the site holds '$(listing)', wanted '${want}'"
elif [ "$(readlink "${LABEL_DIR}/latest.qcow2")" != "${IMAGE}" ]; then
    problem="latest.qcow2 is not a symlink to ${IMAGE}"
elif [ "$(cat "${LABEL_DIR}/latest.qcow2")" != "image 20261025" ]; then
    problem="latest.qcow2 does not lead to the image"
elif [ -e "${SITE}/rocky:9" ]; then
    problem="another label's output was published"
fi
result "one publish lands the image, its log and latest.qcow2" "${problem}"

# The symlink arrives in a later rsync than the image. Judged by what
# the site held after each call, not by how the arguments are spelt,
# so it is the ordering itself that is tested.
problem=""
first_after="$(grep -m1 '^AFTER' "${SHIM_LOG}" || true)"
calls="$(grep -c '^CALL' "${SHIM_LOG}" || true)"
case "${first_after}" in
    *latest.qcow2*)
        problem="latest.qcow2 arrived in the same rsync as the image"
        ;;
    *"${IMAGE} "*)
        if [ "${calls}" -lt 2 ]; then
            problem="only ${calls} rsync call"
        fi
        ;;
    *)
        problem="the first rsync did not send the image: '${first_after}'"
        ;;
esac
result "latest.qcow2 is sent after the image, in its own rsync" "${problem}"

# An image that did not arrive is never made latest. The first rsync
# fails; the symlink must not be sent and the publish must fail.
reset
make_build
rc=$(RSYNC_SHIM_FAIL_CALL=1 run publish_image "${OUTPUT_DIR}/${IMAGE}")
problem=""
if [ "${rc}" = 0 ]; then
    problem="the publish reported success"
elif [ -e "${LABEL_DIR}/latest.qcow2" ] || [ -L "${LABEL_DIR}/latest.qcow2" ]; then
    problem="latest.qcow2 was sent although the image was not"
elif [ "$(grep -c '^CALL' "${SHIM_LOG}")" != 1 ]; then
    problem="rsync was called again after the image failed"
fi
result "a failed image rsync sends no latest.qcow2" "${problem}"

# --- retention ------------------------------------------------------

# A site holding one dated image a day, each with its log, the newest
# as latest.qcow2, and a file that is not an image at all. Each image
# holds its own name, so a keeper overwritten by a staging placeholder
# shows up as an empty file.
make_site() {
    # $@ the dates to publish, oldest first; the last is latest
    local d
    mkdir -p "${LABEL_DIR}"
    for d in "$@"; do
        echo "image ${d}" > "${LABEL_DIR}/debian-13-sfagent-${d}.qcow2"
        echo "log ${d}" > "${LABEL_DIR}/debian-13-sfagent-${d}.qcow2.log"
    done
    ln -s "debian-13-sfagent-${d}.qcow2" "${LABEL_DIR}/latest.qcow2"
    echo "not an image" > "${LABEL_DIR}/README"
}

names() {
    # $@ dates; prints the image and log names for each, sorted as ls does
    local d
    for d in "$@"; do
        printf 'debian-13-sfagent-%s.qcow2 debian-13-sfagent-%s.qcow2.log ' "${d}" "${d}"
    done
}

NINE=(20261017 20261018 20261019 20261020 20261021 20261022 20261023 20261024 20261025)

# Nine images: the oldest two go with their logs, and the newest
# seven, their logs, latest.qcow2 and the README stay untouched. One
# keeper has no log, and retention must not make it one.
reset
make_site "${NINE[@]}"
rm "${LABEL_DIR}/debian-13-sfagent-20261021.qcow2.log"
rc=$(run prune_published "${OUTPUT_DIR}/${IMAGE}")
problem=""
want="README $(names "${NINE[@]:2}")latest.qcow2 "
want="${want/debian-13-sfagent-20261021.qcow2.log /}"
if [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
elif [ "$(listing)" != "${want}" ]; then
    problem="the site holds '$(listing)', wanted '${want}'"
elif [ "$(readlink "${LABEL_DIR}/latest.qcow2")" != "${IMAGE}" ]; then
    problem="latest.qcow2 is no longer a symlink to ${IMAGE}"
else
    for d in "${NINE[@]:2}"; do
        if [ "$(cat "${LABEL_DIR}/debian-13-sfagent-${d}.qcow2")" != "image ${d}" ]; then
            problem="the kept image for ${d} was overwritten"
            break
        fi
    done
fi
if [ -z "${problem}" ] && [ -n "$(ls -A "${WORK}/tmp")" ]; then
    problem="the staging directory was left behind"
fi
result "nine images keep the newest seven, their logs and latest.qcow2" "${problem}"

# The same, with the listing showing latest.qcow2 as a symlink with
# its target, as rsync does under -l or -a. The sweep still finds
# latest.qcow2 and prunes as before.
reset
make_site "${NINE[@]}"
rc=$(RSYNC_SHIM_LIST_LINKS=1 run prune_published "${OUTPUT_DIR}/${IMAGE}")
problem=""
want="README $(names "${NINE[@]:2}")latest.qcow2 "
if ! grep -q '^LISTED l.* latest\.qcow2 -> ' "${SHIM_LOG}"; then
    problem="the listing did not show latest.qcow2 with its target, so this tests nothing"
elif [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
elif [ "$(listing)" != "${want}" ]; then
    problem="the site holds '$(listing)', wanted '${want}'"
elif [ "$(readlink "${LABEL_DIR}/latest.qcow2")" != "${IMAGE}" ]; then
    problem="latest.qcow2 is no longer a symlink to ${IMAGE}"
fi
result "a listing showing latest.qcow2's target still prunes to seven" "${problem}"

# Three images: nothing to prune, and nothing pruned.
reset
make_site 20261023 20261024 20261025
rc=$(run prune_published "${OUTPUT_DIR}/${IMAGE}")
problem=""
want="README $(names 20261023 20261024 20261025)latest.qcow2 "
if [ "${rc}" != 0 ]; then
    problem="exit ${rc}, wanted 0"
elif [ "$(listing)" != "${want}" ]; then
    problem="the site holds '$(listing)', wanted '${want}'"
fi
result "three images delete nothing" "${problem}"

# The refusals. Each starts from nine images, where a working sweep
# would delete two, so a refusal that did not happen shows up as
# missing files.
refusal() {
    # $1 name, then the dates the site was made with
    local name="$1" problem="" want
    shift
    want="README $(names "$@")"
    if [ -L "${LABEL_DIR}/latest.qcow2" ]; then
        want="${want}latest.qcow2 "
    fi
    if [ "${rc}" = 0 ]; then
        problem="the sweep reported success"
    elif [ "$(listing)" != "${want}" ]; then
        problem="the site holds '$(listing)', wanted '${want}'"
    elif ! grep -q 'WARNING: not pruning debian:13' "${WORK}/out"; then
        problem="no warning was printed"
    fi
    result "${name}" "${problem}"
}

# A listing that yields nothing -- an rsync that changed its output, or
# a far end that answered with something else -- deletes nothing, and
# says so.
reset
make_site "${NINE[@]}"
rc=$(RSYNC_SHIM_EMPTY_LISTING=1 run prune_published "${OUTPUT_DIR}/${IMAGE}")
refusal "a listing that yields nothing deletes nothing and warns" "${NINE[@]}"

# Eight images that sort after today's, as a build host with its clock
# a year fast would leave behind. The newest seven by name do not
# include what this run just published.
SKEWED=(20261025 20271001 20271002 20271003 20271004 20271005 20271006 20271007 20271008)
reset
make_site "${SKEWED[@]}"
rm "${LABEL_DIR}/latest.qcow2"
ln -s "${IMAGE}" "${LABEL_DIR}/latest.qcow2"
rc=$(run prune_published "${OUTPUT_DIR}/${IMAGE}")
refusal "a keep set missing the image just published deletes nothing" "${SKEWED[@]}"

# No latest.qcow2 in the listing, although it was sent moments ago.
reset
make_site "${NINE[@]}"
rm "${LABEL_DIR}/latest.qcow2"
rc=$(run prune_published "${OUTPUT_DIR}/${IMAGE}")
refusal "a listing without latest.qcow2 deletes nothing" "${NINE[@]}"

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
