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
# so a case can say which image already has an open issue. The mutating
# calls, including "label create", are appended, so a single reconcile
# run's several calls can all be inspected -- recording the label create
# is what lets a test pin the guard that files it before the issue. If
# GH_FAIL_MATCH is set and an argument contains it, the call fails after
# being recorded, which stands in for a transient gh error on one image.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" << 'EOF'
#!/bin/bash
# Save the subcommand and the full argument line before the issue-list
# branch shifts the positional parameters away, so the failure hooks
# below still see what was called.
sub="$1 $2"
all="$*"
case "${sub}" in
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
    "issue create"|"issue comment"|"issue close"|"label create")
        printf '%s\n' "$@" >> "${GH_RECORD}"
        ;;
esac
if [ -n "${GH_FAIL_LIST:-}" ] && [ "${sub}" = "issue list" ]; then
    exit 1
fi
if [ -n "${GH_FAIL_MATCH:-}" ] && [[ "${all}" == *"${GH_FAIL_MATCH}"* ]]; then
    exit 1
fi
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

# the label is created, with --force, before the issue is filed: gh
# issue create fails outright on a missing label, so without this the
# first report of an outage is lost. The suite could not break this
# guard until the stub recorded label create.
got=$(run file debian:13 https://example/run)
check "file forces the per-image label create" 0 "${got}" "--force"
record_has "the label create names the image" "The debian:13 image is failing to build"

# file comments when the image already has an open issue, and does not
# file a second one -- the title text is unique to the create path, so
# its absence is what proves one issue per outage rather than seven.
got=$(OPEN_LABEL="build-failure:debian:13" OPEN_ISSUE=42 \
    run file debian:13 https://example/run)
check "file comments when one is open" 0 "${got}" "comment"
record_lacks "file does not open a second issue" "debian:13 is failing to build"

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
# The null conclusion is what the API reports for a job that never
# reached one -- the closest shape to the died-runner incident this
# design exists to catch -- so it is pinned rather than left riding on
# the generic not-success branch.
cat > "${WORK}/jobs.json" << 'EOF'
{
  "jobs": [
    {"name": "Build broken:img", "conclusion": "failure"},
    {"name": "Build ok:img", "conclusion": "success"},
    {"name": "Build cancelled:img", "conclusion": "cancelled"},
    {"name": "Build stalled:img", "conclusion": null},
    {"name": "List the images to build", "conclusion": "success"}
  ]
}
EOF
images='["broken:img","ok:img","cancelled:img","stalled:img","absent:img"]'

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
record_has "reconcile files the null-conclusion image" "stalled:img is failing to build"
record_has "reconcile files the image with no job" "absent:img is failing to build"
record_has "reconcile closes the succeeded image" "ok:img built successfully again"
record_lacks "reconcile does not file the succeeded image" "ok:img is failing to build"

# An empty image list reconciles nothing and makes no gh call.
got=$(run reconcile '[]' "${WORK}/jobs.json" https://example/run)
check "an empty image list reconciles nothing" 0 "${got}" -

# An unparseable image list is treated the same way.
got=$(run reconcile 'not json' "${WORK}/jobs.json" https://example/run)
check "an unparseable image list reconciles nothing" 0 "${got}" -

# A jobs file that will not parse is loud, not silent: the run exits
# non-zero and goes red rather than green with nothing reported.
printf '%s' '{ "jobs": [' > "${WORK}/truncated.json"
got=$(run reconcile '["debian:13"]' "${WORK}/truncated.json" https://example/run)
check "an unparseable jobs file fails loudly" 2 "${got}" -

# A jobs file that parses but is not the object the API returns is the
# same kind of error.
echo '[]' > "${WORK}/notobject.json"
got=$(run reconcile '["debian:13"]' "${WORK}/notobject.json" https://example/run)
check "a jobs file that is not an object fails loudly" 2 "${got}" -

# A jobs file that is not there is an error before any gh call.
got=$(run reconcile '[]' "${WORK}/nope.json" https://example/run)
check "a missing jobs file is an error" 2 "${got}" -

# reconcile wants exactly three arguments.
got=$(run reconcile '[]' "${WORK}/jobs.json")
check "reconcile wants three arguments" 2 "${got}" -

# A gh failure for one image does not abandon the images after it, and
# the run still exits non-zero so the failure is seen.
cat > "${WORK}/two-failed.json" << 'EOF'
{
  "jobs": [
    {"name": "Build first:img", "conclusion": "failure"},
    {"name": "Build second:img", "conclusion": "failure"}
  ]
}
EOF
got=$(GH_FAIL_MATCH="first:img" \
    run reconcile '["first:img","second:img"]' "${WORK}/two-failed.json" https://example/run)
if [ "${got}" = 0 ]; then
    echo "FAIL: a gh failure makes reconcile exit non-zero: got exit 0"
    sed 's/^/    /' "${WORK}/out" 2>/dev/null || true
    failed=$((failed + 1))
else
    echo "PASS: a gh failure makes reconcile exit non-zero"
    passed=$((passed + 1))
fi
record_has "the image after a gh failure is still processed" \
    "second:img is failing to build"

# A truncated jobs page -- more jobs than this page returned -- fails
# loudly rather than filing an issue for every image that fell off it.
cat > "${WORK}/truncated-page.json" << 'EOF'
{
  "total_count": 200,
  "jobs": [
    {"name": "Build debian:13", "conclusion": "success"}
  ]
}
EOF
got=$(run reconcile '["debian:13"]' "${WORK}/truncated-page.json" https://example/run)
check "a truncated jobs page fails loudly" 2 "${got}" -

# A failed "issue list" is not read as "nothing open": reconcile does
# not file a duplicate, and the run exits non-zero. The image has an
# open issue, so a silent misread would comment; a wrong read as empty
# would create a second one.
cat > "${WORK}/one-failed.json" << 'EOF'
{
  "total_count": 1,
  "jobs": [
    {"name": "Build dup:img", "conclusion": "failure"}
  ]
}
EOF
got=$(OPEN_LABEL="build-failure:dup:img" OPEN_ISSUE=7 GH_FAIL_LIST=1 \
    run reconcile '["dup:img"]' "${WORK}/one-failed.json" https://example/run)
if [ "${got}" = 0 ]; then
    echo "FAIL: a failed issue list makes reconcile exit non-zero: got exit 0"
    sed 's/^/    /' "${WORK}/out" 2>/dev/null || true
    failed=$((failed + 1))
else
    echo "PASS: a failed issue list makes reconcile exit non-zero"
    passed=$((passed + 1))
fi
record_lacks "a failed issue list files no duplicate" "dup:img is failing to build"

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
