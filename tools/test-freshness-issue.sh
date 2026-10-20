#!/bin/bash

# Exercise tools/freshness-issue.sh against a stand-in for gh.
#
# The issue's first sentence is what sends a reader looking for the
# fault, so it has to match the check's exit status: "not refreshed"
# for stale images, "could not check" for unreachable ones, and "could
# not run" when the check itself failed. It used to say "not
# refreshed" for all of them.
#
# Runs anywhere, needs no network and no token:
#
#   tools/test-freshness-issue.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

# A gh that records what it was asked to do. "issue list" answers with
# the number in OPEN_ISSUE, so a case can say whether an issue is
# already open.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" << 'EOF'
#!/bin/bash
case "$1 $2" in
    "issue list")
        echo "${OPEN_ISSUE:-}"
        ;;
    "issue create"|"issue comment"|"issue close")
        printf '%s\n' "$@" > "${GH_RECORD}"
        ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/gh"

echo "web.example  STALE        100 hours old" > "${WORK}/report.txt"

run() {
    # $@ arguments for freshness-issue.sh
    local rc=0
    rm -f "${WORK}/record"
    PATH="${WORK}/bin:${PATH}" GITHUB_REPOSITORY="example/images" \
        GH_RECORD="${WORK}/record" GH_TOKEN="unused" \
        "${HERE}/freshness-issue.sh" "$@" > "${WORK}/out" 2>&1 || rc=$?
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

got=$(run file "${WORK}/report.txt" https://example/run 1)
check "stale images say not refreshed" 0 "${got}" \
    "found published images that have"

got=$(run file "${WORK}/report.txt" https://example/run 2)
check "unreachable images say could not check" 0 "${got}" \
    "could not check some published"
if grep -qF "found published images that have" "${WORK}/record"; then
    echo "FAIL: unreachable images do not claim staleness"
    failed=$((failed + 1))
else
    echo "PASS: unreachable images do not claim staleness"
    passed=$((passed + 1))
fi

# A check that could not run has no UNREACHABLE lines to point at, so
# its issue must not send the reader looking for them.
echo "build.sh --list-images returned nothing." > "${WORK}/setup.txt"
got=$(run file "${WORK}/setup.txt" https://example/run 3)
check "a check that could not run says so" 0 "${got}" \
    "could not run its check"
if grep -qF -e "UNREACHABLE" -e "found published images that have" "${WORK}/record"; then
    echo "FAIL: a check that could not run blames no image"
    failed=$((failed + 1))
else
    echo "PASS: a check that could not run blames no image"
    passed=$((passed + 1))
fi

got=$(run file "${WORK}/report.txt" https://example/run 7)
check "an undocumented status says so" 0 "${got}" "exited 7"

got=$(run file "${WORK}/report.txt" https://example/run 1)
check "the report is in the body" 0 "${got}" "STALE        100 hours old"

got=$(OPEN_ISSUE=42 run file "${WORK}/report.txt" https://example/run 1)
check "an open issue is commented on" 0 "${got}" "comment"

got=$(run file "${WORK}/report.txt" https://example/run)
check "the status is required" 2 "${got}" -

got=$(OPEN_ISSUE=42 run resolve https://example/run)
check "resolve closes the open issue" 0 "${got}" "close"

got=$(run resolve https://example/run)
check "resolve with nothing open does nothing" 0 "${got}" -

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
