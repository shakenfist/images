#!/bin/bash

# Exercise tools/build-failure-issue.sh against a stand-in for gh.
#
# There is one issue per image, labelled build-failure:<image>, so the
# label on every gh call has to carry the image that failed -- a global
# label would hide a second broken image behind the first. "reconcile"
# maps a run's "Build <image>" job conclusions onto file and resolve,
# so a build leg that never finished still files an issue; the job
# name it keys on is asserted here, so a rename of the build job breaks
# this suite rather than quietly filing nothing.
#
# Runs anywhere, needs no network and no token:
#
#   tools/test-build-failure-issue.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

# A gh that records what it was asked to do. "issue list" answers with
# the number in OPEN_ISSUE, but only for the label named in OPEN_LABEL,
# so a case can say which image already has an open issue. The
# mutating calls are appended, so a single reconcile run's several
# calls can all be inspected.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" << 'EOF'
#!/bin/bash
case "$1 $2" in
    "issue list")
        label=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "--label" ]; then
                label="$2"
            fi
            shift
        done
        if [ -n "${OPEN_LABEL:-}" ] && [ "${label}" = "${OPEN_LABEL}" ]; then
            echo "${OPEN_ISSUE:-}"
        fi
        ;;
    "issue create"|"issue comment"|"issue close")
        printf '%s\n' "$@" >> "${GH_RECORD}"
        ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/gh"

run() {
    # $@ arguments for build-failure-issue.sh
    local rc=0
    rm -f "${WORK}/record"
    PATH="${WORK}/bin:${PATH}" GITHUB_REPOSITORY="example/images" \
        GH_RECORD="${WORK}/record" GH_TOKEN="unused" \
        "${HERE}/build-failure-issue.sh" "$@" > "${WORK}/out" 2>&1 || rc=$?
    echo "${rc}"
}

check() {
    # $1 name, $2 wanted exit, $3 got exit, $4 text the gh call must
    # carry ('-' for no gh call at all)
    local name="$1" want="$2" got="$3" needle="$4"
    local problem=""

    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif [ "${needle}" = '-' ]; then
        [ ! -e "${WORK}/record" ] || problem="gh was called"
    elif [ ! -e "${WORK}/record" ]; then
        problem="gh was not called"
    elif ! grep -qF -- "${needle}" "${WORK}/record"; then
        problem="missing '${needle}'"
    fi

    if [ -z "${problem}" ]; then
        echo "PASS: ${name}"
        passed=$((passed + 1))
    else
        echo "FAIL: ${name}: ${problem}"
        sed 's/^/    /' "${WORK}/out" "${WORK}/record" 2>/dev/null || true
        failed=$((failed + 1))
    fi
}

record_has() {
    # $1 name, $2 text the recorded gh calls must carry
    if grep -qF -- "$2" "${WORK}/record" 2>/dev/null; then
        echo "PASS: $1"
        passed=$((passed + 1))
    else
        echo "FAIL: $1: missing '$2'"
        sed 's/^/    /' "${WORK}/out" "${WORK}/record" 2>/dev/null || true
        failed=$((failed + 1))
    fi
}

record_lacks() {
    # $1 name, $2 text the recorded gh calls must not carry
    if grep -qF -- "$2" "${WORK}/record" 2>/dev/null; then
        echo "FAIL: $1: unexpected '$2'"
        sed 's/^/    /' "${WORK}/out" "${WORK}/record" 2>/dev/null || true
        failed=$((failed + 1))
    else
        echo "PASS: $1"
        passed=$((passed + 1))
    fi
}

# file creates an issue when none is open.
got=$(run file debian:13 https://example/run)
check "file creates when none open" 0 "${got}" "debian:13 is failing to build"

# the per-image label travels on the create call.
got=$(run file debian:13 https://example/run)
check "file labels the issue per image" 0 "${got}" "build-failure:debian:13"

# file comments when the image already has an open issue.
got=$(OPEN_LABEL="build-failure:debian:13" OPEN_ISSUE=42 \
    run file debian:13 https://example/run)
check "file comments when one is open" 0 "${got}" "comment"

# resolve closes the open issue for that image.
got=$(OPEN_LABEL="build-failure:debian:13" OPEN_ISSUE=42 \
    run resolve debian:13 https://example/run)
check "resolve closes the open issue" 0 "${got}" "close"

# resolve does nothing when the image has no open issue.
got=$(run resolve debian:13 https://example/run)
check "resolve with nothing open does nothing" 0 "${got}" -

# both modes want an image and a run URL.
got=$(run file debian:13)
check "file wants an image and a run URL" 2 "${got}" -

# reconcile maps per-job conclusions onto file and resolve. The jobs
# JSON is the shape gh api .../runs/<id>/jobs returns: one failed, one
# succeeded, one cancelled, and a fourth image whose Build job never
# appears at all.
cat > "${WORK}/jobs.json" << 'EOF'
{
  "jobs": [
    {"name": "Build broken:img", "conclusion": "failure"},
    {"name": "Build ok:img", "conclusion": "success"},
    {"name": "Build cancelled:img", "conclusion": "cancelled"},
    {"name": "List the images to build", "conclusion": "success"}
  ]
}
EOF
images='["broken:img","ok:img","cancelled:img","absent:img"]'

# ok:img has an open issue so its success has something to close.
got=$(OPEN_LABEL="build-failure:ok:img" OPEN_ISSUE=99 \
    run reconcile "${images}" "${WORK}/jobs.json" https://example/run)
if [ "${got}" != 0 ]; then
    echo "FAIL: reconcile exits 0: exit ${got}"
    sed 's/^/    /' "${WORK}/out" 2>/dev/null || true
    failed=$((failed + 1))
else
    echo "PASS: reconcile exits 0"
    passed=$((passed + 1))
fi
record_has "reconcile files the failed image" "broken:img is failing to build"
record_has "reconcile files the cancelled image" "cancelled:img is failing to build"
record_has "reconcile files the image with no job" "absent:img is failing to build"
record_has "reconcile closes the succeeded image" "ok:img built successfully again"
record_lacks "reconcile does not file the succeeded image" "ok:img is failing to build"

# An empty image list reconciles nothing and makes no gh call.
got=$(run reconcile '[]' "${WORK}/jobs.json" https://example/run)
check "an empty image list reconciles nothing" 0 "${got}" -

# An unparseable image list is treated the same way.
got=$(run reconcile 'not json' "${WORK}/jobs.json" https://example/run)
check "an unparseable image list reconciles nothing" 0 "${got}" -

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
