#!/bin/bash

# Exercise the end of run summary in build.sh, and check that it
# reaches Loki rather than only stdout.
#
# The nightly build runs from cron on a host with no MTA, so anything
# that is only printed is discarded. The summary is the one place the
# run says which images it never attempted, so it has to be shipped.
#
# push_log_to_loki and the summary section are extracted from build.sh
# at run time rather than copied here, so this tests what actually
# runs. A small HTTP server stands in for Loki and records what it is
# sent.
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

{
    # The function embeds python, which has closing braces of its own,
    # so it ends at the first one after the heredoc rather than the
    # first one.
    awk '/^function push_log_to_loki\(\) \{$/ { on = 1 }
         on { print }
         on && /^PYEOF$/ { heredoc_done = 1 }
         heredoc_done && /^}$/ { exit }' "${BUILD}"
    sed -n '/^not_attempted=""$/,$p' "${BUILD}"
} > "${WORK}/summary.sh"

if ! grep -q 'image-build-summary' "${WORK}/summary.sh"; then
    echo "FAIL: could not extract the summary from ${BUILD}"
    exit 1
fi

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
    # $4 requested, $5 built, $6 failed, $7 a line the summary must hold
    local name="$1" want="$2" want_result="$3"
    local got=0

    rm -f "${WORK}"/pushes/push-*.json
    images="$4" built_images="$5" failed_images="$6" \
        LOKI_URL="http://127.0.0.1:${port}/loki/api/v1/push" LOKI_TENANT="" \
        bash -c 'source "$1"' _ "${WORK}/summary.sh" > "${WORK}/out" 2>&1 || got=$?

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

# Without a Loki address nothing is shipped, but the summary still
# prints and the exit status is unchanged.
rm -f "${WORK}"/pushes/push-*.json
got=0
images="rocky:9" built_images="" failed_images="" LOKI_URL="" LOKI_TENANT="" \
    bash -c 'source "$1"' _ "${WORK}/summary.sh" > "${WORK}/out" 2>&1 || got=$?
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
