#!/bin/bash

# Exercise the end of run summary in build.sh, and check that it
# reaches Loki rather than only stdout.
#
# The nightly build runs from cron on a host with no MTA, so anything
# that is only printed is discarded. The summary is the one place the
# run says which images it never attempted, so it has to be shipped.
#
# The run bookkeeping (push_log_to_loki, finish_run and the exit trap),
# the preamble and the end of the script are extracted from build.sh at
# run time rather than copied here, so this tests what actually runs. A
# small HTTP server stands in for Loki and records what it is sent.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-run-summary.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${HERE}/build.sh"
WORK="$(mktemp -d)"
server_pid=""
trap '[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; rm -rf "${WORK}"' EXIT

passed=0
failed=0

# --- the code under test --------------------------------------------

# The bookkeeping block runs from the Loki configuration to the line
# that installs the exit trap; build.sh's comment above the first of
# them says so, so that moving either end is not done blind.
# shellcheck disable=SC2016
sed -n '/^LOKI_URL=/,/^trap on_exit EXIT$/p' "${BUILD}" > "${WORK}/block.sh"
# shellcheck disable=SC2016
sed -n '/^preamble_log=\$(mktemp)$/,/^rm -f "\${preamble_log}"$/p' \
    "${BUILD}" > "${WORK}/preamble.sh"
sed -n '/^finish_run$/,$p' "${BUILD}" > "${WORK}/tail.sh"

if ! grep -q 'image-build-summary' "${WORK}/block.sh" \
        || ! grep -q '^trap on_exit EXIT$' "${WORK}/block.sh" \
        || ! grep -q 'git apply' "${WORK}/preamble.sh" \
        || ! grep -q '^run_finished=1$' "${WORK}/tail.sh"; then
    echo "FAIL: could not extract the run bookkeeping from ${BUILD}"
    exit 1
fi

# What the cases run: the bookkeeping, then the build lists as a run
# that got that far would have left them, then whatever the case is
# about. The lists are set after the block because the block resets
# them, as the real script does.
#
# -e because build.sh's shebang carries it, and the exit trap exists
# for what errexit does.
run_case() {
    # $1 the script to run after the bookkeeping
    # shellcheck disable=SC2016
    bash -ec 'source "$1"; built_images="${TEST_BUILT}"
              failed_images="${TEST_FAILED}"; source "$2"' \
        _ "${WORK}/block.sh" "$1"
}

# --- a fake Loki ----------------------------------------------------

cat > "${WORK}/loki.py" << 'PYEOF'
import http.server, os, sys

out = sys.argv[1]
count = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        body = self.rfile.read(int(self.headers['Content-Length']))
        count += 1
        with open(os.path.join(out, 'push-%03d.json' % count), 'wb') as f:
            f.write(body)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(out, 'port'), 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
PYEOF

mkdir -p "${WORK}/pushes"
python3 "${WORK}/loki.py" "${WORK}/pushes" &
server_pid=$!
for _ in $(seq 50); do
    [ -s "${WORK}/pushes/port" ] && break
    sleep 0.1
done
port="$(cat "${WORK}/pushes/port")"

# --- the cases ------------------------------------------------------

check_summary() {
    # $1 name, $2 expected exit, $3 expected result label,
    # $4 requested, $5 built, $6 failed, $7 a line the summary must hold,
    # $8 optional script to run in place of the end of build.sh
    local name="$1" want="$2" want_result="$3"
    local got=0

    rm -f "${WORK}"/pushes/push-*.json
    images="$4" TEST_BUILT="$5" TEST_FAILED="$6" do_not_push=0 \
        SF_IMAGES_LOKI_URL="http://127.0.0.1:${port}/loki/api/v1/push" \
        run_case "${8:-${WORK}/tail.sh}" > "${WORK}/out" 2>&1 || got=$?

    local summary
    summary="$(grep -l '"image-build-summary"' "${WORK}"/pushes/push-*.json 2>/dev/null || true)"

    local problem=""
    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif [ -z "${summary}" ]; then
        problem="no summary was pushed to Loki"
    elif ! python3 - "${summary}" "${want_result}" "$7" << 'PYEOF'
import json, sys

stream = json.load(open(sys.argv[1]))['streams'][0]
labels = stream['stream']
lines = [v[1] for v in stream['values']]
assert labels['result'] == sys.argv[2], labels
assert 'image' not in labels, labels
assert any(sys.argv[3] in line for line in lines), lines
PYEOF
    then
        problem="the pushed summary was wrong"
    elif ! grep -qF "$7" "${WORK}/out"; then
        problem="the summary was not printed"
    fi

    if [ -z "${problem}" ]; then
        echo "PASS: ${name}"
        passed=$((passed + 1))
    else
        echo "FAIL: ${name}: ${problem}"
        sed 's/^/    /' "${WORK}/out"
        failed=$((failed + 1))
    fi
}

check_summary "everything built" 0 success \
    "debian:13 rocky:9" " debian:13 rocky:9" "" \
    "Built:         debian:13 rocky:9"

check_summary "one failed" 1 failure \
    "debian:13 rocky:9" " debian:13" " rocky:9" \
    "Failed:        rocky:9"

check_summary "one never attempted" 1 failure \
    "debian:13 rocky:9" " debian:13" "" \
    "Not attempted: rocky:9"

check_summary "nothing requested" 0 success \
    "" "" "" \
    "Nothing to do."

# --- a run that stops before its end -------------------------------

# Anything that ends the run under errexit, outside a build, still
# leaves a failed summary naming where it stopped, and every image it
# never reached as not attempted. Before the exit trap, this produced
# nothing at all.
cat > "${WORK}/stop.sh" << 'EOF'
false
echo "MARKER after the failure"
EOF
check_summary "stopped by errexit" 1 failure \
    "debian:13 rocky:9" "" "" \
    "Stopped:       build.sh exited 1 at line 1: false" "${WORK}/stop.sh"
if grep -q 'MARKER' "${WORK}/out"; then
    echo "FAIL: stopped by errexit: the run carried on past the failure"
    failed=$((failed + 1))
fi

# Both images went unattempted, and each says so in its own stream.
not_attempted_pushes=$( { grep -lE '"image": "(debian:13|rocky:9)"' \
    "${WORK}"/pushes/push-*.json 2>/dev/null || true; } | wc -l)
if [ "${not_attempted_pushes}" = 2 ]; then
    echo "PASS: a stopped run records each image as not attempted"
    passed=$((passed + 1))
else
    echo "FAIL: a stopped run records each image as not attempted:" \
        "${not_attempted_pushes} image records, wanted 2"
    failed=$((failed + 1))
fi

# The preamble itself, with an apt-get that fails the way an
# unreachable mirror does. The summary has to carry what apt-get
# printed, not just that the preamble stopped, and nothing after the
# failing command may run.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/apt-get" << 'EOF'
#!/bin/sh
echo "E: stub apt-get refusing to run"
exit 100
EOF
cat > "${WORK}/bin/pip3" << 'EOF'
#!/bin/sh
echo "MARKER pip3 ran after apt-get failed"
EOF
chmod +x "${WORK}/bin/apt-get" "${WORK}/bin/pip3"
PATH="${WORK}/bin:${PATH}" check_summary "stopped in the preamble" 100 failure \
    "debian:13" "" "" \
    "E: stub apt-get refusing to run" "${WORK}/preamble.sh"
if grep -q 'MARKER' "${WORK}/out"; then
    echo "FAIL: stopped in the preamble: it carried on past the failure"
    failed=$((failed + 1))
fi
if grep -qF 'Stopped:       preparing the build host failed (exit 100)' "${WORK}/out"; then
    echo "PASS: the preamble stop is named"
    passed=$((passed + 1))
else
    echo "FAIL: the preamble stop is named"
    sed 's/^/    /' "${WORK}/out"
    failed=$((failed + 1))
fi

# A failure inside the summary itself is not reconciled a second time:
# each unattempted image is recorded once, not once per attempt at a
# summary, and the exit trap says the summary may be cut short instead
# of writing another one that blames the wrong thing.
mkdir -p "${WORK}/nomktemp"
cat > "${WORK}/nomktemp/mktemp" << 'EOF'
#!/bin/sh
echo "mktemp: stub refusing to run" >&2
exit 1
EOF
chmod +x "${WORK}/nomktemp/mktemp"
rm -f "${WORK}"/pushes/push-*.json
got=0
images="rocky:9" TEST_BUILT="" TEST_FAILED="" do_not_push=0 \
    SF_IMAGES_LOKI_URL="http://127.0.0.1:${port}/loki/api/v1/push" \
    PATH="${WORK}/nomktemp:${PATH}" \
    run_case "${WORK}/tail.sh" > "${WORK}/out" 2>&1 || got=$?
rocky_pushes=$( { grep -l '"image": "rocky:9"' \
    "${WORK}"/pushes/push-*.json 2>/dev/null || true; } | wc -l)
if [ "${got}" = 1 ] && [ "${rocky_pushes}" = 1 ] \
        && grep -qF "while writing the run summary" "${WORK}/out" \
        && ! grep -qF "Stopped:" "${WORK}/out"; then
    echo "PASS: a failing summary is not written twice"
    passed=$((passed + 1))
else
    echo "FAIL: a failing summary is not written twice: exit ${got}," \
        "${rocky_pushes} rocky:9 records, wanted 1"
    sed 's/^/    /' "${WORK}/out"
    failed=$((failed + 1))
fi

# --no-push says so in the summary, so a run that published nothing
# is not read as one that published.
rm -f "${WORK}"/pushes/push-*.json
got=0
images="rocky:9" TEST_BUILT=" rocky:9" TEST_FAILED="" do_not_push=1 SF_IMAGES_LOKI_URL="" \
    run_case "${WORK}/tail.sh" > "${WORK}/out" 2>&1 || got=$?
if [ "${got}" = 0 ] && grep -qF "Published:     nothing; --no-push was given" "${WORK}/out"; then
    echo "PASS: --no-push is recorded"
    passed=$((passed + 1))
else
    echo "FAIL: --no-push is recorded"
    sed 's/^/    /' "${WORK}/out"
    failed=$((failed + 1))
fi

# Without a Loki address nothing is shipped, but the summary still
# prints and the exit status is unchanged.
rm -f "${WORK}"/pushes/push-*.json
got=0
images="rocky:9" TEST_BUILT="" TEST_FAILED="" do_not_push=0 SF_IMAGES_LOKI_URL="" \
    run_case "${WORK}/tail.sh" > "${WORK}/out" 2>&1 || got=$?
if [ "${got}" = 1 ] && grep -qF "Not attempted: rocky:9" "${WORK}/out" \
        && ! ls "${WORK}"/pushes/push-*.json > /dev/null 2>&1; then
    echo "PASS: no Loki configured"
    passed=$((passed + 1))
else
    echo "FAIL: no Loki configured"
    sed 's/^/    /' "${WORK}/out"
    failed=$((failed + 1))
fi

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
