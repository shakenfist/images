#!/bin/bash

# Exercise tools/check-image-freshness.sh against a stand-in web host.
#
# The exit status is the check's whole interface: the workflow files
# an issue from it, and freshness-issue.sh picks the issue's first
# sentence from it. So each status has to mean one thing. A header the
# web host leaves out once ended the check with status 1, "stale",
# from a pipeline that pipefail failed; and a check that could not run
# at all reported status 2, "unreachable images", with none named.
#
# Runs anywhere, needs no network beyond localhost and no token:
#
#   tools/test-check-image-freshness.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${HERE}/tools/check-image-freshness.sh"
WORK="$(mktemp -d)"
server_pid=""
trap '[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; rm -rf "${WORK}"' EXIT

passed=0
failed=0

# --- a fake web host ------------------------------------------------

# Every image answers as a fresh one, except debian:13, which answers
# however the file "mode" says, so a case changes one image and can
# see the others are still reported.
cat > "${WORK}/web.py" << 'PYEOF'
import email.utils, http.server, os, sys, time

work = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        mode = 'fresh'
        if self.path == '/debian:13/latest.qcow2':
            with open(os.path.join(work, 'mode')) as f:
                mode = f.read().strip()

        if mode == 'missing':
            self.send_response(404)
            self.end_headers()
            return

        self.send_response(200)
        if mode == 'fresh':
            self.send_header('Last-Modified', email.utils.formatdate(time.time() - 3600, usegmt=True))
        elif mode == 'stale':
            self.send_header('Last-Modified', email.utils.formatdate(time.time() - 200 * 3600, usegmt=True))
        elif mode == 'garbled':
            self.send_header('Last-Modified', 'not a date')
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(work, 'port'), 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
PYEOF

echo fresh > "${WORK}/mode"
python3 "${WORK}/web.py" "${WORK}" &
server_pid=$!
for _ in $(seq 50); do
    [ -s "${WORK}/port" ] && break
    sleep 0.1
done
BASE_URL="http://127.0.0.1:$(cat "${WORK}/port")"

# --- the cases ------------------------------------------------------

check() {
    # $1 name, $2 wanted exit, $3 a line the output must hold,
    # then the command to run
    local name="$1" want="$2" needle="$3"
    shift 3
    local got=0 problem=""

    "$@" > "${WORK}/out" 2>&1 || got=$?
    if [ "${got}" != "${want}" ]; then
        problem="exit ${got}, wanted ${want}"
    elif ! grep -qE -- "${needle}" "${WORK}/out"; then
        problem="missing '${needle}'"
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

echo fresh > "${WORK}/mode"
check "every image fresh" 0 "0 stale or missing, 0 could not be checked" \
    "${CHECK}" --base-url "${BASE_URL}"

echo stale > "${WORK}/mode"
check "a stale image" 1 "^debian:13 +STALE" \
    "${CHECK}" --base-url "${BASE_URL}"

echo missing > "${WORK}/mode"
check "a missing image" 1 "^debian:13 +MISSING" \
    "${CHECK}" --base-url "${BASE_URL}"

# The case pipefail used to turn into "stale".
echo nolm > "${WORK}/mode"
check "no Last-Modified is unreachable, not stale" 2 \
    "^debian:13 +UNREACHABLE +200 without a Last-Modified" \
    "${CHECK}" --base-url "${BASE_URL}"

echo garbled > "${WORK}/mode"
check "an unparsable Last-Modified is unreachable" 2 \
    "^debian:13 +UNREACHABLE +unparsable" \
    "${CHECK}" --base-url "${BASE_URL}"

# Every image is still reported after the odd one, so the report is
# never one line long.
count=$("${HERE}/build.sh" --list-images | wc -w)
echo nolm > "${WORK}/mode"
check "the other images are still reported" 2 "^${count} images checked, 0 stale" \
    "${CHECK}" --base-url "${BASE_URL}"

# Port 1 refuses the connection, which is what an unreachable web host
# looks like to curl.
check "an unreachable web host" 2 "UNREACHABLE" \
    "${CHECK}" --base-url "http://127.0.0.1:1"

# A check that could not run is 3, whatever stopped it, and never 1.
check "an unknown flag" 3 "Usage" \
    "${CHECK}" --no-such-flag
check "a bad threshold" 3 "positive integer" \
    "${CHECK}" --max-age-hours soon

mkdir -p "${WORK}/nobuild/tools"
cp "${CHECK}" "${WORK}/nobuild/tools/"
check "no build.sh beside it" 3 "No build.sh" \
    "${WORK}/nobuild/tools/check-image-freshness.sh" --base-url "${BASE_URL}"

mkdir -p "${WORK}/badbuild/tools"
cp "${CHECK}" "${WORK}/badbuild/tools/"
printf '#!/bin/sh\nexit 1\n' > "${WORK}/badbuild/build.sh"
chmod +x "${WORK}/badbuild/build.sh"
check "build.sh --list-images failing" 3 "list-images failed" \
    "${WORK}/badbuild/tools/check-image-freshness.sh" --base-url "${BASE_URL}"

printf '#!/bin/sh\nexit 0\n' > "${WORK}/badbuild/build.sh"
check "build.sh --list-images printing nothing" 3 "returned nothing" \
    "${WORK}/badbuild/tools/check-image-freshness.sh" --base-url "${BASE_URL}"

# An unbound variable ends bash with status 1 without running the ERR
# trap, so this is the stop only the EXIT trap can turn into a 3. The
# copy gains one, just before the check begins.
mkdir -p "${WORK}/unbound/tools"
cp "${HERE}/build.sh" "${WORK}/unbound/"
# The ${...} is meant literally: it is the text planted in the copy.
# shellcheck disable=SC2016
sed 's/^max_age_seconds=/: "${no_such_variable}"\n&/' "${CHECK}" \
    > "${WORK}/unbound/tools/check-image-freshness.sh"
chmod +x "${WORK}/unbound/tools/check-image-freshness.sh"
if ! grep -q 'no_such_variable' "${WORK}/unbound/tools/check-image-freshness.sh"; then
    echo "FAIL: could not plant an unbound variable in the check"
    failed=$((failed + 1))
else
    check "an unbound variable is 3, not stale" 3 "stopped unexpectedly with status 1" \
        "${WORK}/unbound/tools/check-image-freshness.sh" --base-url "${BASE_URL}"
fi

echo
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
