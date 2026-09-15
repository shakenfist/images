#!/bin/bash

# Exercise build.sh's self-update block.
#
# The block is extracted from build.sh at run time rather than copied
# here, so this tests what actually runs. It is worth testing more
# than most twenty lines in this repository: it runs as root from
# cron, and it calls exec on itself. A wrong guard does not fail, it
# rebuilds fourteen images in a loop forever.
#
# Runs anywhere, needs no build host and no root:
#
#   tools/test-self-update.sh

set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passed=0
failed=0

# The block, taken from the file that ships. The opening line is
# matched on the guard variable and the close on a "fi" in column
# zero, which is the block's own -- everything nested inside it is
# indented.
BLOCK="${WORK}/block.sh"
sed -n '/^if \[ "\${SF_IMAGES_SELF_UPDATED/,/^fi$/p' \
    "${HERE}/build.sh" > "${BLOCK}"

if [ ! -s "${BLOCK}" ]; then
    echo "Could not find the self-update block in build.sh. If it was"
    echo "renamed or reindented, fix the sed above rather than deleting"
    echo "this test."
    exit 2
fi

# A stand-in for build.sh: the real block, wrapped in enough of a
# script to see which copy of it ran. Writing the marker after the
# block is what distinguishes "restarted and ran the new code" from
# "restarted and ran the old code again".
make_script() {
    # $1 destination, $2 marker text
    {
        echo '#!/bin/bash -e'
        cat "${BLOCK}"
        echo "echo \"MARKER $2\""
    } > "$1"
    chmod +x "$1"
}

# origin, and a clone of it standing in for /srv/sf-images/images.
setup() {
    rm -rf "${WORK}/origin" "${WORK}/checkout"
    git init -q --bare "${WORK}/origin"
    # init.defaultBranch varies between hosts, and a bare repository
    # whose HEAD names a branch that is never pushed clones as an
    # empty working tree.
    git -C "${WORK}/origin" symbolic-ref HEAD refs/heads/master
    git init -q "${WORK}/seed"
    git -C "${WORK}/seed" config user.email t@example.com
    git -C "${WORK}/seed" config user.name Test
    make_script "${WORK}/seed/build.sh" 'v1'
    git -C "${WORK}/seed" add build.sh
    git -C "${WORK}/seed" commit -qm 'v1'
    git -C "${WORK}/seed" branch -M master
    git -C "${WORK}/seed" push -q "${WORK}/origin" master
    git clone -q "${WORK}/origin" "${WORK}/checkout"
    git -C "${WORK}/checkout" config user.email t@example.com
    git -C "${WORK}/checkout" config user.name Test
    rm -rf "${WORK}/seed"
}

# Push a new build.sh to origin, so the checkout is behind.
advance_origin() {
    git clone -q "${WORK}/origin" "${WORK}/push"
    git -C "${WORK}/push" config user.email t@example.com
    git -C "${WORK}/push" config user.name Test
    make_script "${WORK}/push/build.sh" 'v2'
    git -C "${WORK}/push" commit -qam 'v2'
    git -C "${WORK}/push" push -q origin master
    rm -rf "${WORK}/push"
}

# The exit status is recorded rather than propagated. The block is
# there to keep the build running whatever git does, so a regression
# shows up as a script that died, and a test harness that dies with it
# reports nothing.
run_in_checkout() {
    local rc=0
    ( cd "${WORK}/checkout" && timeout 30 ./build.sh ) > "${WORK}/out" 2>&1 || rc=$?
    echo "${rc}" > "${WORK}/rc"
}

# The same, with a git on PATH that refuses everything the way the
# real one refuses a checkout it thinks belongs to somebody else.
# Ownership cannot be faked without root, and the block does not care
# which git command failed or why -- only that one did.
run_in_checkout_with_broken_git() {
    mkdir -p "${WORK}/bin"
    cat > "${WORK}/bin/git" <<'STUB'
#!/bin/sh
echo "fatal: detected dubious ownership in repository at '$(pwd)'" >&2
exit 128
STUB
    chmod +x "${WORK}/bin/git"
    local rc=0
    ( cd "${WORK}/checkout" && PATH="${WORK}/bin:${PATH}" timeout 30 ./build.sh ) \
        > "${WORK}/out" 2>&1 || rc=$?
    echo "${rc}" > "${WORK}/rc"
}

check() {
    # $1 name, $2 expected marker, $3 expected marker count,
    # $4 substring the output must contain ('-' for none)
    local name="$1" marker="$2" count="$3" needle="$4"
    local got_count
    got_count=$(grep -c "^MARKER ${marker}$" "${WORK}/out" || true)

    if [ "${got_count}" != "${count}" ]; then
        printf '  FAIL  %-44s want %s x%s, got x%s (exit %s)\n' \
            "${name}" "${marker}" "${count}" "${got_count}" \
            "$(cat "${WORK}/rc")"
        sed 's/^/          /' "${WORK}/out"
        failed=$(( failed + 1 ))
        return
    fi
    if [ "${needle}" != '-' ] && ! grep -q -- "${needle}" "${WORK}/out"; then
        printf '  FAIL  %-44s missing %q\n' "${name}" "${needle}"
        sed 's/^/          /' "${WORK}/out"
        failed=$(( failed + 1 ))
        return
    fi
    printf '  ok    %-44s\n' "${name}"
    passed=$(( passed + 1 ))
}

echo "Testing the build.sh self-update block."
echo

# Already current: one run of v1, and no restart announced.
setup
run_in_checkout
check 'up to date runs once' v1 1 -
if grep -q 'Restarting' "${WORK}/out"; then
    printf '  FAIL  %-44s restarted with nothing to update\n' \
        'up to date does not restart'
    failed=$(( failed + 1 ))
else
    printf '  ok    %-44s\n' 'up to date does not restart'
    passed=$(( passed + 1 ))
fi

# Behind origin: pulls, restarts, and the NEW code is what runs. v1
# must not appear at all -- the marker is written after the block, so
# the pre-exec pass never reaches it.
setup
advance_origin
run_in_checkout
check 'behind origin runs the new code' v2 1 'Restarting'
check 'behind origin does not rerun the old' v1 0 -

# ... and exactly once. A missing guard would exec forever; the
# timeout in run_in_checkout is the backstop if this ever regresses.
setup
advance_origin
run_in_checkout
check 'restart happens once, not in a loop' v2 1 -

# A checkout that cannot fast-forward warns and builds anyway. An
# unrelated local commit on master is the realistic shape of this:
# somebody edited build.sh on the build host.
setup
advance_origin
( cd "${WORK}/checkout" \
    && echo '# local edit' >> build.sh \
    && git commit -qam 'local' )
run_in_checkout
check 'diverged checkout still builds' v1 1 'WARNING'

# Not a git checkout at all: skip quietly rather than dying under
# errexit on a failed rev-parse.
setup
rm -rf "${WORK}/checkout/.git"
run_in_checkout
check 'no .git skips the update' v1 1 -

# A .git that is there but is not a repository. The "-d .git" guard
# waves this through, so the block itself has to survive git failing.
setup
rm -rf "${WORK}/checkout/.git"
mkdir "${WORK}/checkout/.git"
run_in_checkout
check 'unusable .git still builds' v1 1 'WARNING'

# The 2026-09-15 outage, as a test. git exited 128 on the first
# command in the block -- the checkout on the build host belonged to a
# different user than the root cron job reading it -- and the run
# ended there, silently, having built nothing. Before the fix this
# case produces no marker at all.
setup
run_in_checkout_with_broken_git
check 'git refusing the repository still builds' v1 1 'WARNING'

# The guard variable stops a second pass pulling again.
setup
advance_origin
guard_rc=0
( cd "${WORK}/checkout" && SF_IMAGES_SELF_UPDATED=1 timeout 30 ./build.sh ) \
    > "${WORK}/out" 2>&1 || guard_rc=$?
echo "${guard_rc}" > "${WORK}/rc"
check 'guard variable skips the update' v1 1 -

echo
echo "passed ${passed}, failed ${failed}"
[ "${failed}" -eq 0 ]
