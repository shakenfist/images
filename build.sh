#!/bin/bash -e

# Set again here because the shebang is skipped by "bash build.sh".
# The exit trap's stop reporting and the preamble's PIPESTATUS check
# both depend on errexit, and without it a failed apt-get or patch
# would carry on silently into the builds.
set -o errexit

# Obsolete image builds (not built by default, but still here just in case):
#   centos:7 centos:8-stream
#   debian:10
#   fedora:34 fedora:38 fedora:39 fedora:40
#   ubuntu:16.04 ubuntu:18.04
#
# Retired 2026-09-12 because the release is end of life upstream. The
# build blocks below are kept so a one-off rebuild is still possible,
# and what is already published stays on images.shakenfist.com --
# anything pinned to it keeps working, it simply stops being
# refreshed.
#   ubuntu:20.04  EOL 2025-05-31
#   fedora:41     EOL 2025-11
#   fedora:42     EOL 2026-06
#   debian:11, and its -docker, -gnome and -xfce variants. Bullseye
#                 LTS ended 2026-08-31 and the security suite's
#                 Release file expired on 2026-09-08, so these can no
#                 longer be built at all: apt refuses the expired
#                 repository and the build stops there. This is not a
#                 policy choice we could reverse by editing the list.
#
# No Fedora is built at all, which is not a policy choice either.
# fedora:43 and fedora:44 have never built, both dying the same way:
# their python is new enough that grpcio-tools has no wheel, so pip
# falls back to compiling it and the image carries no C++ compiler.
# Loki has fedora:43 failing that way as far back as 2026-08-14 and
# no successful build ever. The newest Fedora that does build is
# fedora:42, which is end of life, so there is no supported Fedora we
# can currently produce.
#
# Fixing this means teaching sf-agent to install a compiler for the
# RHEL family and remove it again afterwards -- the element already
# does the equivalent for old Debian releases, installing
# build-essential and python3-dev -- or waiting for grpcio to publish
# wheels. Until then, putting fedora:43 or fedora:44 in the list above
# only manufactures a nightly failure, which is the noise that hid a
# sixteen day outage.
#
# debian:12 is past standard security support (2026-06-10)
# and is still built deliberately: Debian LTS covers bookworm
# until 2028, and a guest image someone boots on purpose is a
# supported option, not a defect. The debian-12, debian-12-docker
# and debian-gnome-12 runner labels this image used to feed were
# retired from private-ci's IMAGE_BUILDS and CI_IMAGES on 2026-10-03
# (private-ci#100), so nothing bakes them from here any more and
# a future reader does not need to go looking for the repositories
# that used to boot it. Retire this entry when bookworm's LTS ends
# in 2028, not before.
#
# Two things elsewhere need doing as a result of the above, and
# neither can be done in this repository:
#   * private-ci builds its "dependencies" cache disk from debian:11,
#     and its own comment says a missing dependencies label blocks ALL
#     CI provisioning. That base can no longer be rebuilt, so moving
#     it to debian:13 is now the thing standing between us and an
#     unrecoverable CI outage.
#   * the debian-docker:12, debian-gnome:12 and debian-xfce:12 images
#     were built from bullseye rather than bookworm until 2026-09-12.
#     Anything baked from them before that date -- the debian-12-docker
#     and debian-gnome-12 runner labels especially -- is Debian 11 and
#     needs rebuilding.

do_not_push=0

# Kept before the flags below are consumed, because the self-update
# re-executes this script and has to hand the new copy exactly what
# this one was given. Restarting with the image list but without
# --no-push would publish what the operator asked not to.
original_args=("$@")

# Flags come before the image list.
#
# --list-images prints the list this script would build and exits.
# tools/check-image-freshness.sh reads the list from here rather than
# keeping its own copy: a watchdog with a second copy of the list
# stops watching anything added to the real one, and does so
# silently.
#
# It is handled here, before the apt-get preamble below, so it runs
# as an unprivileged user on a host with none of the build
# dependencies installed. That is what lets the watchdog run
# anywhere, which is the whole point of the watchdog.
#
# --no-push builds the images but does not publish them to
# images.shakenfist.com or prune old ones there. Without it, every run
# publishes, including one somebody started by hand to try something.
#
# --no-self-update skips the fast-forward of this checkout below. That
# update exists for a long-lived clone run by cron, and in a fresh CI
# checkout it is wrong in both directions: a run started from a branch
# would pull master over the branch it was asked to test, and a
# scheduled run already has exactly the commit it should build. It is
# a flag rather than a guess from the environment, such as noticing
# GITHUB_ACTIONS, for the same reason the rest of this parser refuses
# to guess: the run should do what it was told, and say so.
#
# Anything else that looks like a flag, and anything after the image
# list, is refused rather than guessed at. A mistyped --no-push would
# otherwise become the image list, and a --no-push written after the
# list would be ignored -- either way the run publishes, which is the
# one thing the operator asked it not to do. The list is a single
# argument, so several images have to be quoted together.
list_images_only=0
self_update=1
while [ $# -gt 0 ]; do
    case "$1" in
        --list-images)
            list_images_only=1
            shift
            ;;
        --no-push)
            do_not_push=1
            shift
            ;;
        --no-self-update)
            self_update=0
            shift
            ;;
        -*)
            echo "Unknown flag: $1"
            echo "Usage: $0 [--list-images] [--no-push] [--no-self-update] [\"image image ...\"]"
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -gt 1 ]; then
    echo "Unexpected arguments after the image list: ${*:2}"
    echo "Flags go first, and several images are quoted as one argument:"
    echo "    $0 --no-push \"debian:13 rocky:9\""
    exit 2
fi

images="${1:-}"
if [ "$images" == "" ]; then
    images="ubuntu:22.04 ubuntu:24.04 centos:9-stream debian:12 debian-docker:12 debian-gnome:12 debian-xfce:12 debian:13 debian-docker:13 debian-gnome:13 debian-xfce:13 rocky:8 rocky:9 rocky:10"
fi

if [ $list_images_only -eq 1 ]; then
    echo "${images}"
    exit 0
fi

# Where a publishing run sends what it built: an rsync destination,
# either a local directory or [user@]host:path, holding a directory
# per image label. Like the Loki settings below it is read from the
# environment, because where the site lives is a property of the
# deployment, and this repository is public.
#
# There is no default. A publishing run that has lost its target
# should stop, not write the images into a local directory on
# whichever machine it happens to be running on, and under sudo a
# target is lost quietly unless it is named in --preserve-env. So a
# run that will publish and has no target is refused here, with the
# same exit status as a bad argument, before the self-update, the
# preamble or any build. --no-push and --list-images need no target.
#
# Nothing here knows about SSH. rsync reads RSYNC_RSH from the
# environment by itself, so the key and the pinned host key belong to
# whoever starts the run, and tools/test-publish.sh can drive the same
# code against a temporary directory. Under sudo both variables have
# to be passed through with --preserve-env.
#
# A missing trailing slash is added, because the label is appended to
# this as a path component: without it /srv/www/site and debian:13
# would make /srv/www/sitedebian:13. A bare host: is left alone, since
# that already ends a path.
#
# tools/test-build-arguments.sh extracts this stretch of the file by
# its first and last lines.
publish_target="${SF_IMAGES_PUBLISH_TARGET:-}"
if [ -z "${publish_target}" ]; then
    if [ "${do_not_push}" -eq 0 ]; then
        echo "SF_IMAGES_PUBLISH_TARGET is not set, and this run would publish."
        echo "Set it to an rsync destination (a directory or user@host:path),"
        echo "or pass --no-push to build without publishing. Under sudo, name it"
        echo "in --preserve-env."
        exit 2
    fi
else
    case "${publish_target}" in
        */ | *:)
            ;;
        *)
            publish_target="${publish_target}/"
            ;;
    esac
fi
# end of the publish target check

echo "I will build the following images: ${images}"
echo

# Run the build.sh that is on master, not the one that happened to be
# in this checkout when cron fired.
#
# Nothing updated this repository. cron runs
# "cd /srv/sf-images/images; ./build.sh", and the only "git pull" in
# this script is diskimage-builder's, a few lines below -- which made
# the checkout look maintained while it was not. images#5, #6 and #7
# all merged and then did not run: on the night of 2026-09-14 the
# build was still assembling its element list without verify-release,
# a day after that element landed, and nothing said so.
#
# Placed after the --list-images exit above so the watchdog, which
# runs this script on a GitHub runner in a fresh checkout, never
# triggers a pull. A build in a fresh checkout passes --no-self-update
# for the same reason, and the run says it was skipped.
#
# The re-exec is not optional. bash reads a script lazily, by byte
# offset, so replacing build.sh underneath a running build.sh makes it
# resume at whatever text now happens to sit at that offset. The guard
# variable stops the new copy pulling again and recursing.
#
# A failed pull warns and carries on rather than aborting. A checkout
# that cannot fast-forward -- no network, a local edit, a diverged
# branch -- is an operator problem, and building yesterday's images is
# a much better answer to it than building none; the freshness
# watchdog in tools/check-image-freshness.sh is what notices if this
# goes on.
#
# Every git command here has to be inside the "if" condition, because
# this script runs under errexit and an assignment from a command
# substitution is a simple command: "before=$(git rev-parse HEAD)" on
# a line of its own ends the run when git exits non-zero, before the
# warning below can be reached.
#
# That is not hypothetical. On 2026-09-15 the nightly build stopped
# dead at 05:00:01, having published nothing and said nothing:
#
#   fatal: detected dubious ownership in repository at
#   '/srv/sf-images/images'
#
# The checkout on the build host belongs to a different user than the
# root cron job that runs this script, so git refuses to touch it. The
# "-d .git" guard did not help -- .git was there, and perfectly valid;
# git declined on ownership rather than on the repository being
# missing. cron had no MTA, so the output went nowhere.
#
# So the guard cannot be a test for one particular way of not being a
# repository. Any git failure at all has to land in the else branch:
# an unpacked copy with no .git, a checkout git will not open, a
# missing origin, a diverged branch, no network.
if [ "${SF_IMAGES_SELF_UPDATED:-0}" != "1" ] && [ "${self_update}" = 1 ] && [ -d .git ]; then
    if before=$(git rev-parse HEAD) && git pull --ff-only origin master; then
        after=$(git rev-parse HEAD)
        if [ "${before}" != "${after}" ]; then
            echo
            echo "===================================================================="
            echo "build.sh updated: ${before} -> ${after}. Restarting."
            echo "===================================================================="
            echo
            export SF_IMAGES_SELF_UPDATED=1
            exec "$0" "${original_args[@]}"
        fi
    else
        echo
        echo "===================================================================="
        echo "WARNING: could not update this checkout from origin/master."
        echo "Building with the code that is here, which may be older than"
        echo "what has been merged. The git error is above; if it is about"
        echo "dubious ownership, the checkout belongs to a different user"
        echo "than the one running this script. Fix the checkout at $(pwd)."
        echo "===================================================================="
        echo
    fi
elif [ "${self_update}" = 0 ]; then
    echo "Not updating this checkout: --no-self-update was given."
    echo
fi

# Where build logs are shipped, read from the environment so the
# destination is a property of the deployment rather than of the
# build. Unset means logs are not shipped at all, which is the right
# default for anyone who clones this repository and runs it: a build
# should not post to somebody else's log aggregator because the
# address was baked into the script. The run says so when it starts,
# below; see docs/nightly-build.md for where the nightly build sets them.
#
# Everything from here to the traps is defined before the preamble
# that prepares the build host, so that a preamble failure can still
# be reported. tools/test-run-summary.sh extracts this stretch of the
# file by its first and last lines.
LOKI_URL="${SF_IMAGES_LOKI_URL:-}"
LOKI_TENANT="${SF_IMAGES_LOKI_TENANT:-}"

# Which images built and which failed. The reconciliation at the end of the script turns the
# gap between the request and these two into a record: an image that
# is in neither list was never attempted, and before this that state
# produced no signal at all.
built_images=""
failed_images=""

function push_log_to_loki() {
    # Push build log to Loki for centralized monitoring
    # $1: log file path (may not exist; see below)
    # $2: image label (e.g., "debian-xfce:12")
    # $3: build result ("success" or "failure")
    # $4: optional message to record when there is no log file
    #
    # The stream is labelled job="image-build" unless LOKI_JOB says
    # otherwise, and carries no image label when $2 is empty. The run
    # summary uses both, so it does not show up as an image in queries
    # written against the per image logs.
    #
    # A missing log file used to return quietly. That is the shape of
    # the sixteen day outage: the images that were never reached
    # produced no record, so afterwards there was no way to tell a
    # build that failed from one that never ran. A missing log now
    # ships a single synthetic line saying so.

    local log_file="$1"
    local image_label="$2"
    local build_result="$3"
    local note="${4:-}"

    # Quiet on purpose: the run warns once, at the start, rather than
    # once per image.
    if [ -z "${LOKI_URL}" ]; then
        return 0
    fi

    local job="${LOKI_JOB:-image-build}"

    echo "Pushing ${job} log to Loki for ${image_label:-the run} (${build_result})"

    LOG_FILE="$log_file" IMAGE_LABEL="$image_label" BUILD_RESULT="$build_result" \
        LOKI_URL="${LOKI_URL}" LOKI_TENANT="${LOKI_TENANT}" NOTE="${note}" \
        JOB="${job}" BUILD_HOST="$(hostname)" python3 << 'PYEOF' || true
import json, os, time, urllib.request

log_file = os.environ['LOG_FILE']
image_label = os.environ['IMAGE_LABEL']
build_result = os.environ['BUILD_RESULT']
build_host = os.environ.get('BUILD_HOST', 'unknown')

try:
    with open(log_file, 'r', errors='replace') as f:
        lines = f.readlines()
except OSError:
    # No log means the build never got far enough to write one.
    # Say so rather than saying nothing.
    lines = [os.environ.get('NOTE', '') or (
        'No build log at %s; this image produced no output.'
        % log_file)]

base_ns = int(time.time() * 1e9)
values = [
    [str(base_ns + i), line.rstrip('\n')]
    for i, line in enumerate(lines)
    if line.strip()
]

if not values:
    exit(0)

stream = {
    'job': os.environ['JOB'],
    'host': build_host,
    'result': build_result,
}
if image_label:
    stream['image'] = image_label

payload = json.dumps({
    'streams': [{
        'stream': stream,
        'values': values,
    }]
}).encode()

headers = {'Content-Type': 'application/json'}
tenant = os.environ.get('LOKI_TENANT', '')
if tenant:
    headers['X-Scope-OrgID'] = tenant

req = urllib.request.Request(
    os.environ['LOKI_URL'],
    data=payload,
    headers=headers,
)
try:
    urllib.request.urlopen(req)
    print('Pushed %d log lines to Loki for %s' % (len(values), image_label or 'the run'))
except Exception as e:
    print('Warning: failed to push logs to Loki: %s' % e)
PYEOF
}

# Reconcile what was asked for against what actually happened, and
# record it. Sets run_result.
#
# An image named in the request that reached neither list was never
# attempted: the run stopped before it, or nothing here knows how to
# build it. That state used to produce no record at all, which is why
# the sixteen day outage could not be read afterwards even though
# logs were being shipped the whole time -- the images that mattered
# were the ones that said nothing.
#
# The comparison is against the list as given, so a partial label
# typed by hand ("debian" rather than "debian:13") reports as not
# attempted. The default list is exact.
#
# The summary itself is shipped to Loki as well as printed. cron runs
# this on a host with no MTA, so stdout goes nowhere, and the summary
# is the only place the run says what it did not do.
function finish_run() {
    # $1: why the run stopped before its end; empty if it did not
    # $2: optional log of what was running when it stopped
    summary_started=1
    local stopped="${1:-}"
    local stop_log="${2:-}"
    local not_attempted=""
    local image summary_log

    for image in ${images}; do
        if echo " ${built_images} " | grep -qF " ${image} "; then
            continue
        fi
        if echo " ${failed_images} " | grep -qF " ${image} "; then
            continue
        fi
        not_attempted="${not_attempted} ${image}"
        push_log_to_loki \
            "/srv/sf-images/output/${image}/not-attempted.log" \
            "${image}" "failure" \
            "${image} was requested but never attempted; the run ended before reaching it."
    done

    summary_log=$(mktemp)
    {
        echo
        echo "===================================================================="
        echo "Build summary"
        echo "===================================================================="
        printf '%-15s%s\n' 'Requested:' "${images}"
        if [ -n "${stopped}" ]; then
            printf '%-15s%s\n' 'Stopped:' "${stopped}"
        fi
        if [ "${do_not_push}" != 0 ]; then
            printf '%-15s%s\n' 'Published:' 'nothing; --no-push was given'
        fi
        if [ -n "${built_images}" ]; then
            printf '%-15s%s\n' 'Built:' "${built_images# }"
        fi
        if [ -n "${failed_images}" ]; then
            printf '%-15s%s\n' 'Failed:' "${failed_images# }"
        fi
        if [ -n "${not_attempted}" ]; then
            printf '%-15s%s\n' 'Not attempted:' "${not_attempted# }"
        fi
        if [ -z "${stopped}${built_images}${failed_images}${not_attempted}" ]; then
            echo "Nothing to do."
        fi
        echo
        if [ -n "${stop_log}" ] && [ -s "${stop_log}" ]; then
            echo "The last lines printed before it stopped:"
            echo
            tail -n 40 "${stop_log}"
            echo
        fi
    } > "${summary_log}"
    cat "${summary_log}"

    if [ -n "${stopped}" ] || [ -n "${failed_images}" ] || [ -n "${not_attempted}" ]; then
        run_result="failure"
    else
        run_result="success"
    fi
    LOKI_JOB="image-build-summary" push_log_to_loki "${summary_log}" "" "${run_result}"
    rm -f "${summary_log}"
}

# A run that stops before it reaches finish_run at the bottom of this
# file still produces a summary, saying where it stopped.
#
# Before this, anything that ended the run under errexit outside a
# build -- an apt-get, the diskimage-builder pull, a patch that no
# longer applies -- left no Loki record, no per image log and, with no
# MTA on the build host, nothing at all. That is the shape of the
# 2026-09-15 failure, and the only control that noticed it was the
# freshness watchdog, three days later.
#
# The ERR trap only notes where errexit fired; the EXIT trap does the
# reporting. Neither is inherited by functions or subshells, because
# errtrace is not set, which is what we want: build_one runs with
# errexit off by design and reports its own failures, and a grep that
# matches nothing inside a command substitution is not a stop.
#
# A failure inside finish_run itself is the one stop that must not be
# reconciled again: the images it had already recorded as not
# attempted would be pushed a second time, beside a second summary
# blaming the wrong thing. summary_started says the reconciliation has
# begun, and the exit trap then only says the summary may be cut short.
run_finished=0
summary_started=0
stop_reason=""
stop_log=""

function on_exit() {
    local status=$?
    if [ "${run_finished}" = "1" ]; then
        return
    fi
    if [ "${summary_started}" = "1" ]; then
        echo
        echo "*** build.sh exited ${status} while writing the run summary," \
            "so the summary above may be incomplete ***"
        exit "${status}"
    fi

    set +e
    if [ -z "${stop_reason}" ]; then
        stop_reason="build.sh exited ${status}"
        if [ -n "${failed_line:-}" ]; then
            stop_reason="${stop_reason} at line ${failed_line}: ${failed_command:-}"
        fi
    fi
    echo
    echo "*** The run stopped before it finished: ${stop_reason} ***"
    finish_run "${stop_reason}" "${stop_log}"
    if [ -n "${stop_log}" ]; then
        rm -f "${stop_log}"
    fi
    exit "${status}"
}

trap 'failed_line=${LINENO}; failed_command=${BASH_COMMAND}' ERR
trap on_exit EXIT

if [ -z "${LOKI_URL}" ]; then
    echo "WARNING: SF_IMAGES_LOKI_URL is not set, so no build log and no"
    echo "run summary will be shipped from this run. Under sudo, pass it"
    echo "through with --preserve-env=SF_IMAGES_LOKI_URL,SF_IMAGES_LOKI_TENANT."
    echo
fi

# Prepare the build host: packages, and diskimage-builder with our
# patches applied.
#
# This is the part of the run most likely to stop it. diskimage-builder
# is pulled from upstream master every night, so one of the patches in
# diskimage-builder-patches/ failing to apply is a matter of when.
#
# The block runs as a subshell on the left of a pipe. errexit stays in
# force inside it -- unlike build_one it is not an "if" condition --
# so its first failure ends it, and PIPESTATUS carries that status past
# tee. tee keeps a copy of what it printed for the summary, because the
# command the exit trap can name ("git apply $patch") is much less use
# than the error git printed. Being a subshell, a cd inside it cannot
# leak out, and nothing it assigns survives it.
preamble_log=$(mktemp)
{
    apt-get update
    apt-get dist-upgrade -y
    apt-get install -y git python3 python3-dev python3-pip python3-wheel rsync xz-utils podman
    pip3 install --break-system-packages bindep

    # We have to install diskimage-builder this way because the Ubuntu dependancies
    # are wrong for the packaged version.
    if [ ! -e diskimage-builder ]; then
        git clone https://github.com/openstack/diskimage-builder
    else
        cd diskimage-builder
        git stash
        git pull origin master
        cd ..
    fi

    cd diskimage-builder

    for patch in ../diskimage-builder-patches/*.patch; do
        echo "Applying patch $patch"
        git apply $patch
    done

    apt-get install -y `bindep --list_all newline`
    python3 setup.py develop
    cd ..

    # diskimage-builder requires the hostname be known, or it gets confused
    hostname=$(hostname)
    if [ $(grep -c $hostname /etc/hosts) -lt 1 ]; then
        sed -i "s/127.0.0.1\tlocalhost/127.0.0.1\tlocalhost $hostname/" /etc/hosts
    fi

    mkdir -p /srv/sf-images/cache
} 2>&1 | tee "${preamble_log}"
preamble_status=${PIPESTATUS[0]}
if [ "${preamble_status}" -ne 0 ]; then
    stop_reason="preparing the build host failed (exit ${preamble_status})"
    stop_log="${preamble_log}"
    exit "${preamble_status}"
fi
rm -f "${preamble_log}"

# Build images
datestamp=$(date +%Y%m%d)

# Build one image, or record why we could not.
#
# Every image in the list gets its own call, and a failure here must
# stop this image rather than the run. The script is "#!/bin/bash -e",
# which used to mean the first image that failed took the other
# thirteen with it -- the shape of the sixteen day outage in August
# and September 2026.
#
# Read the header of build_one() before editing it. errexit is NOT in
# force inside that function, so every fallible command there is
# checked by hand.
function build () {
    local output="$1"
    local label
    label=$(basename "$(dirname "${output}")")

    if build_one "$@"; then
        built_images="${built_images} ${label}"
    else
        failed_images="${failed_images} ${label}"
        echo
        echo "*** ${label} FAILED; continuing with the next image ***"
        echo
    fi

    # Always successful, so that "set -e" at the top of the script
    # cannot kill the run at a call site. The non-zero exit the run
    # owes its caller is raised once, at the end, by the summary.
    return 0
}

function build_one () {
    # $1: output filename
    # $2: OS release name (bionic, focal, etc)
    # $3: python version (2 or 3)
    # $4: distro specific args
    # $5: name of the shakenfist agent package
    #
    # IMPORTANT: this function is called from the condition of an "if"
    # in build(), and bash disables errexit for the whole of a
    # function invoked that way -- including, as tested, inside a
    # subshell that sets "set -e" again. So nothing here fails the
    # script by itself. Every command whose failure matters is
    # checked explicitly, and the function returns non-zero. Adding
    # an unchecked command here reintroduces the class of bug where a
    # broken conversion publishes whatever happened to be on disk.

    local output="$1"
    local outdir
    local label
    outdir=$(dirname "${output}")
    label=$(basename "${outdir}")

    echo
    echo "===================================================================="
    echo "Building $1 (agent package $5)"
    echo "===================================================================="
    echo

    # Each publishing build starts from an empty output tree. File
    # names carry the date, so on a long-lived build host nothing else
    # would ever remove an image from it, and the disk would fill a
    # night at a time. --no-push publishes nothing, so it keeps every
    # image the run builds for inspection instead of only the last.
    #
    # publish_image names the files this call built, so a leftover in
    # the tree is never published. The removal is checked all the same:
    # errexit is off in here, so a failure nobody checks goes unseen.
    if [ "${do_not_push}" = 0 ]; then
        if ! rm -rf /srv/sf-images/output || [ -e /srv/sf-images/output ]; then
            echo "BUILD FAILED: could not empty /srv/sf-images/output"
            push_log_to_loki "${output}.log" "${label}" "failure" \
                "Could not empty /srv/sf-images/output before building ${label}."
            return 1
        fi
    fi
    export ELEMENTS_PATH=elements:diskimage-builder/diskimage_builder/elements
    export DIB_APT_MINIMAL_CREATE_INTERFACES=0
    export DIB_CLOUD_INIT_DATASOURCES="ConfigDrive, OpenStack, NoCloud"
    export DIB_CLOUD_INIT_ETC_HOSTS=1
    export DIB_CLOUD_INIT_GROWPART_DEVICES="/dev/vda3"
    export DIB_GRUB_TIMEOUT=0
    export DIB_IMAGE_CACHE="/srv/sf-images/cache"

    # diskimage-builder's scratch space, which defaults to /tmp. The
    # build host's /tmp is a 2G tmpfs (33fl, since 2026-10-05), and the
    # extract-image element repacks a downloaded cloud image there: a raw
    # copy of the image plus a ~1.2G tarball, so the CentOS Stream 9
    # repack ran out of space and failed every night from 2026-10-08.
    # /srv/sf-images is on disk, beside the cache. DIB still mounts its
    # own tmpfs for each build under this directory as it did under /tmp.
    export TMP_DIR="/srv/sf-images/tmp"
    mkdir -p "${TMP_DIR}"

    # Build on disk rather than in diskimage-builder's tmpfs. DIB
    # mounts two of them, the chroot and the image, and lets each grow
    # to half of RAM with nothing capping the pair. On an 8 GB CI VM
    # that ran out of space (ubuntu:22.04 failed writing its initramfs)
    # or killed the VM mid-build with no log. Disk is plentiful where
    # this runs and RAM is not, so it is the same everywhere.
    export DIB_NO_TMPFS=1

    # Note the default here is "nofb nomodeset gfxpayload=text" which breaks
    # graphical consoles if you choose to install one later...
    export DIB_BOOTLOADER_DEFAULT_CMDLINE="net.ifnames=0 biosdevname=0 earlyprintk=ttyS0,115200 consoleblank=0"

    export build_args="cloud-init cloud-init-datasources cloud-init-growpart block-device-efi vm verify-release"

    cwd=$(pwd)

    # Root filesystem features the guest's grub has to be able to read.
    # See the header of block-device-compat.yaml: without this every
    # image whose release ships grub older than 2.12 fails with
    # "grub-install: error: unknown filesystem". The path is absolute
    # because disk-image-create runs from elsewhere, and this is
    # deliberately not exported once at the top of the script -- ${cwd}
    # is only known inside build_one().
    export DIB_BLOCK_DEVICE_CONFIG="file://${cwd}/block-device-compat.yaml"

    # The release this image will be published as, taken from the
    # label rather than from DIB_RELEASE. The verify-release element
    # compares the built image against this and fails the build if
    # they disagree.
    #
    # It has to come from the label because the two year
    # Debian-11-as-Debian-12 defect had DIB_RELEASE, the element list
    # and the image all agreeing with each other; the only thing they
    # disagreed with was the name on the tin. A check against
    # DIB_RELEASE would have passed every night for two years.
    case "${label}" in
        *:*)
            expected_version="${label##*:}"
            # CentOS Stream publishes as 9-stream and reports 9.
            expected_version="${expected_version%-stream}"
            export DIB_SF_EXPECTED_VERSION="${expected_version}"
            ;;
        *)
            echo "BUILD FAILED: output label ${label} carries no version,"
            echo "so the built image cannot be checked against it."
            push_log_to_loki "${output}.log" "${label}" "failure"
            return 1
            ;;
    esac

    if ! mkdir -p "${outdir}"; then
        echo "BUILD FAILED: could not create ${outdir}"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi

    echo "OS release: ${2}"
    export DIB_APT_OPTIONS=""
    if [ $(echo "${2}" | egrep -c "(jessie|stretch|buster)" || true) -gt 0 ]; then
	echo "Debian release which is ancient, overriding the apt mirror."
	export DIB_DISTRIBUTION_MIRROR="https://deb.freexian.com/extended-lts"
	export DIB_APT_SOURCES_CONF="default:deb https://deb.freexian.com/extended-lts ${2} main contrib non-free
lts:deb https://deb.freexian.com/extended-lts ${2}-lts main contrib non-free"
	export DIB_APT_KEYRING=$(pwd)"/debian-release-freexian.gpg"
    fi

    echo "Python version: ${3}"
    if [ "${3}" == "-" ]; then
        unset DIB_PYTHON_VERSION
    else
        export DIB_PYTHON_VERSION=$3
    fi

    echo "Shakenfist agent package: ${5}"
    if [ ! -z ${5} ]; then
	export DIB_SF_AGENT_PACKAGE="${5}"
	export build_args="${build_args} sf-agent"
    fi

    # Nothing may be at the path disk-image-create writes to before it
    # runs. The cleanup after the transcode below is skipped by every
    # failure between here and there, and by a run killed part way, so
    # a temp.qcow2 left by an earlier image is otherwise still here.
    # Were a later disk-image-create to exit zero and print its success
    # marker without writing its output, the transcode would publish
    # that earlier image under this one's label. Of everything this
    # function can do wrong, that is the one nobody could undo: a
    # build that publishes nothing is recoverable, one that publishes
    # the wrong thing is not. With the file gone, the same misbehaviour
    # fails the transcode instead.
    if ! rm -f temp.qcow2; then
        echo "BUILD FAILED: could not remove a stale temp.qcow2"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi

    set -x
    # Build an uncompressed image first.
    #
    # The pipe into tee is why detecting a failure here was ever hard:
    # a pipeline reports the exit status of its LAST command, so this
    # line's status is tee's and is essentially always zero. The check
    # that used to sit below read $? of the "if" above it and could
    # never fire. PIPESTATUS carries the real answer and has to be read
    # immediately, before any other command overwrites it. env is the
    # first command of the pipeline and exits with whatever
    # disk-image-create did, so PIPESTATUS[0] is the build's status.
    #
    # env -u keeps the publishing variables out of the build's
    # environment. Every element hook and chroot scriptlet would
    # otherwise inherit them, and one that printed its environment would
    # write the private publish target into this log, which is
    # published beside the image and is not masked the way the Actions
    # log is. It keeps them out of the build and its log; it does not
    # stop root code on this machine reading them some other way.
    env -u SF_IMAGES_PUBLISH_TARGET -u RSYNC_RSH DIB_RELEASE="$2" \
        /usr/local/bin/disk-image-create $4 ${build_args} -u -o temp.qcow2 | tee ${output}.log
    dib_status=${PIPESTATUS[0]}
    set +x

    # If we detected a checksum failure, clear the cache. This seems common with
    # upstream Ubuntu images for some reason.
    if [ $(grep -c "computed checksum did NOT match" ${output}.log) -gt 0 ]; then
        rm -rf /srv/sf-images/cache
    fi

    if [ "${dib_status}" -ne 0 ]; then
        echo "BUILD FAILED: disk-image-create exited ${dib_status}"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi

    # Kept as a second assertion now that the first one works. It
    # catches a builder that exits zero having produced nothing,
    # which the exit status alone would not.
    if [ $(grep -c "Build completed successfully" ${output}.log) -lt 1 ]; then
        echo "BUILD FAILED: no success marker in the build log"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi

    # Transcode the image into the preferred format
    if ! qemu-img convert -t none -o cluster_size=2048K -c -O qcow2 temp.qcow2 ${output}; then
        echo "BUILD FAILED: could not transcode the image"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi
    rm -rf tmp* temp.qcow2

    # Each stage below runs in a subshell so that a cd cannot leak
    # into the next image if the stage fails part way through. The
    # old code cd'd in the function body and relied on reaching the
    # matching cd at the end, which a failure in between skipped.
    if ! ( cd "${outdir}" \
            && rm -f latest.qcow2 \
            && ln -s "$(basename "${output}")" latest.qcow2 ); then
        echo "BUILD FAILED: could not update the latest.qcow2 symlink"
        push_log_to_loki "${output}.log" "${label}" "failure"
        return 1
    fi

    # Publish the image, then prune old ones. Both are below, after
    # this function, and both run with errexit off for the same reason
    # this function does.
    if [ $do_not_push == 0 ]; then
        if ! publish_image "${output}"; then
            push_log_to_loki "${output}.log" "${label}" "failure"
            return 1
        fi

        # Not fatal: the image is published by this point, and failing
        # the build because the retention sweep stumbled would report
        # the wrong problem.
        if ! prune_published "${output}"; then
            echo "WARNING: retention sweep for ${label} did not complete"
        fi
    else
        echo "Skipping push"
    fi

    push_log_to_loki "${output}.log" "${label}" "success"
    return 0
}

# Publishing and retention. Each of these works through rsync alone,
# so the same code writes to a local directory or to another host, and
# tools/test-publish.sh extracts these functions by name and drives
# them against a temporary directory. They are called from build_one,
# so errexit is off inside them as well, and every command whose
# failure matters is checked by hand.

# Send one image, with its log, to the publish target, then its
# latest.qcow2 symlink in a second rsync of its own.
#
# The symlink goes last so that it never points at a file still in
# transit. rsync makes no promise about the order it sends files in.
# On a local disk the window in which latest.qcow2 would lead nowhere
# is milliseconds; over a WAN it is as long as the upload of the image. A
# failed first rsync returns before the second, so an image that did
# not arrive is never made latest.
#
# The files are named rather than the directory being sent with a
# trailing slash. Sending the directory makes rsync set the
# permissions and times of the label's directory at the far end, and
# an account that can write into a directory it does not own is not
# allowed to do that: rsync exits 23 having copied everything. Naming
# the files also means exactly what this call built is published,
# whatever else is in the output directory.
#
# No -c: a dated name is new each day, and rsync's own check of size
# and time resends a same-day rebuild, so a checksum of every file at
# both ends would buy nothing. No --progress: a meter per file floods
# a CI log.
function publish_image () {
    # $1: output filename, as build_one has it
    local output="$1"
    local outdir label
    outdir=$(dirname "${output}")
    label=$(basename "${outdir}")

    if ! rsync -av "${output}" "${output}.log" "${publish_target}${label}/"; then
        echo "BUILD FAILED: could not publish ${label} to ${publish_target}"
        return 1
    fi
    if ! rsync -av "${outdir}/latest.qcow2" "${publish_target}${label}/"; then
        echo "BUILD FAILED: published ${label}, but could not update its latest.qcow2"
        return 1
    fi
    return 0
}

# Remove all but the newest seven images of one label from the publish
# target, with their logs. latest.qcow2 is always kept.
#
# rsync cannot run rm at the far end, so the deletion is an rsync from
# a staging directory holding an empty file named for each keeper.
# --existing and --ignore-existing together mean nothing is ever sent,
# so all that transfer can do is --delete what the staging directory
# does not name. The filters narrow even that to images and their
# logs: anything else somebody put beside them is left alone.
#
# The --delete is the danger. A listing that parsed as empty, or as
# something other than what is really there, would turn "keep seven"
# into "keep nothing", and a deleted image cannot be rebuilt as it
# was. So nothing is deleted unless the keep set holds both the image
# this run has just published and latest.qcow2. Both were sent moments
# ago, so a listing that does not show them is not a listing of what
# is there. Keepers are chosen by sorting names, which carry the build
# date, so the same check also refuses when names sorting after
# today's would push it out of the seven.
#
# Returns non-zero, having warned, on any failure and on that refusal.
function prune_published () {
    # $1: output filename, as build_one has it
    local staging status
    if ! staging=$(mktemp -d); then
        echo "WARNING: could not make a staging directory for the retention sweep"
        return 1
    fi
    prune_published_in "${staging}" "$1"
    status=$?
    rm -rf "${staging}"
    return "${status}"
}

function prune_published_in () {
    # $1: an empty scratch directory, removed by the caller
    # $2: output filename, as build_one has it
    local staging="$1"
    local output="$2"
    local outdir label published dest
    local perms name rest start keeper
    local saw_latest=0 keeps_published=0
    local listed=() sorted=() keepers=()
    outdir=$(dirname "${output}")
    label=$(basename "${outdir}")
    published=$(basename "${output}")
    dest="${publish_target}${label}/"

    # Each line of the listing is permissions, size, date, time and
    # name. A symlink comes in one of two forms: plainly, as here, it
    # is "lrwxrwxrwx 16 2026/10/25 06:43:41 latest.qcow2", but with -l
    # or -a rsync appends its target, as "latest.qcow2 -> image.qcow2".
    # The parser below accepts both for latest.qcow2, so adding either
    # flag here does not quietly make every sweep refuse.
    if ! rsync --list-only "${dest}" > "${staging}/listing"; then
        echo "WARNING: could not list ${dest}, so nothing was pruned"
        return 1
    fi

    # Regular files named *.qcow2 are images; latest.qcow2 is not one,
    # and only has to be there. A line with more fields than the five
    # is a name with a space in it, which is not ours, unless it is
    # latest.qcow2 shown with its target.
    while read -r perms _ _ _ name rest; do
        if [ -n "${rest}" ]; then
            if [ "${name}" = latest.qcow2 ]; then
                case "${perms}:${rest}" in
                    l*:'-> '*)
                        saw_latest=1
                        ;;
                esac
            fi
            continue
        fi
        case "${name}" in
            latest.qcow2)
                case "${perms}" in
                    -* | l*)
                        saw_latest=1
                        ;;
                esac
                ;;
            *.qcow2)
                case "${perms}" in
                    -*)
                        listed+=("${name}")
                        ;;
                esac
                ;;
        esac
    done < "${staging}/listing"

    if [ "${#listed[@]}" -gt 0 ]; then
        if ! printf '%s\n' "${listed[@]}" > "${staging}/listed" \
                || ! LC_ALL=C sort "${staging}/listed" > "${staging}/sorted" \
                || ! mapfile -t sorted < "${staging}/sorted"; then
            echo "WARNING: could not sort the images listed in ${dest}, so nothing was pruned"
            return 1
        fi
    fi

    # A negative offset past the start of an array expands to nothing
    # rather than to the whole array, so the start is clamped here.
    start=$(( ${#sorted[@]} > 7 ? ${#sorted[@]} - 7 : 0 ))
    keepers=("${sorted[@]:start}")

    for keeper in "${keepers[@]}"; do
        if [ "${keeper}" = "${published}" ]; then
            keeps_published=1
        fi
    done
    if [ "${keeps_published}" != 1 ] || [ "${saw_latest}" != 1 ]; then
        echo "WARNING: not pruning ${label}. The listing of ${dest} should show"
        echo "${published} among the newest seven images and a latest.qcow2,"
        echo "because both were sent moments ago, and it does not. It cannot be"
        echo "trusted to say what to keep, so nothing was deleted."
        echo "Images listed: ${#sorted[@]}; latest.qcow2 listed: ${saw_latest}"
        return 1
    fi

    if [ "${start}" -eq 0 ]; then
        echo "Nothing to prune for ${label}: ${#sorted[@]} images, and seven are kept"
        return 0
    fi

    if ! mkdir "${staging}/keep"; then
        echo "WARNING: could not make the keep list for ${label}, so nothing was pruned"
        return 1
    fi
    for keeper in "${keepers[@]}"; do
        if ! touch "${staging}/keep/${keeper}" "${staging}/keep/${keeper}.log"; then
            echo "WARNING: could not make the keep list for ${label}, so nothing was pruned"
            return 1
        fi
    done
    if ! touch "${staging}/keep/latest.qcow2"; then
        echo "WARNING: could not make the keep list for ${label}, so nothing was pruned"
        return 1
    fi

    echo "Pruning ${label}: removing the oldest ${start} of ${#sorted[@]} images"
    if ! rsync -rv --delete --existing --ignore-existing \
            --include='*.qcow2' --include='*.qcow2.log' --exclude='*' \
            "${staging}/keep/" "${dest}"; then
        echo "WARNING: removing old images of ${label} from ${dest} failed part way"
        return 1
    fi
    return 0
}

# Too old for the agent to run, but convenient to have for testing
if [ $(echo $images | grep -c "ubuntu:16.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:16.04/ubuntu-16.04-${datestamp}.qcow2"
    build ${output} xenial "-" "apparmor utilities debian-old-extras ubuntu ubuntu-remove-pollinate"
fi

# Images containing the agent
if [ $(echo $images | grep -c "ubuntu:18.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:18.04/ubuntu-18.04-sfagent-${datestamp}.qcow2"
    build ${output} bionic "-" "apparmor utilities debian-old-extras ubuntu ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:20.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:20.04/ubuntu-20.04-sfagent-${datestamp}.qcow2"
    build ${output} focal 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:22.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:22.04/ubuntu-22.04-sfagent-${datestamp}.qcow2"
    build ${output} jammy 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "ubuntu:24.04") -gt 0 ]; then
    output="/srv/sf-images/output/ubuntu:24.04/ubuntu-24.04-sfagent-${datestamp}.qcow2"
    build ${output} noble 3 "apparmor utilities debian-old-extras ubuntu ubuntu-remove-snap ubuntu-remove-firmware ubuntu-remove-pollinate" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:8") -gt 0 ]; then
    output="/srv/sf-images/output/debian:8/debian-8-${datestamp}.qcow2"
    build ${output} jessie 3 "apparmor utilities debian-old-extras debian debian-systemd"
fi

if [ $(echo $images | grep -c "debian:9") -gt 0 ]; then
    output="/srv/sf-images/output/debian:9/debian-9-${datestamp}.qcow2"
    build ${output} stretch 3 "apparmor utilities debian-old-extras debian debian-systemd"
fi

if [ $(echo $images | grep -c "debian:10") -gt 0 ]; then
    output="/srv/sf-images/output/debian:10/debian-10-sfagent-${datestamp}.qcow2"
    build ${output} buster 3 "apparmor utilities debian-old-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian:11/debian-11-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian:12/debian-12-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian-12-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian:13/debian-13-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian-13-extras debian debian-systemd" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:7") -gt 0 ]; then
    output="/srv/sf-images/output/centos:7/centos-7-sfagent-${datestamp}.qcow2"
    build ${output} 7 "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:8-stream") -gt 0 ]; then
    output="/srv/sf-images/output/centos:8-stream/centos-8-stream-sfagent-${datestamp}.qcow2"
    build ${output} 8-stream "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "centos:9-stream") -gt 0 ]; then
    output="/srv/sf-images/output/centos:9-stream/centos-9-stream-sfagent-${datestamp}.qcow2"
    build ${output} 9-stream "-" "centos rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:34") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:34/fedora-34-sfagent-${datestamp}.qcow2"
    build ${output} 34 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:38") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:38/fedora-38-sfagent-${datestamp}.qcow2"
    build ${output} 38 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:39") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:39/fedora-39-sfagent-${datestamp}.qcow2"
    build ${output} 39 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:40") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:40/fedora-40-sfagent-${datestamp}.qcow2"
    build ${output} 40 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:41") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:41/fedora-41-sfagent-${datestamp}.qcow2"
    build ${output} 41 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:42") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:42/fedora-42-sfagent-${datestamp}.qcow2"
    build ${output} 42 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:43") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:43/fedora-43-sfagent-${datestamp}.qcow2"
    build ${output} 43 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "fedora:44") -gt 0 ]; then
    output="/srv/sf-images/output/fedora:44/fedora-44-sfagent-${datestamp}.qcow2"
    build ${output} 44 "-" "fedora rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:8") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:8/rocky-8-sfagent-${datestamp}.qcow2"
    build ${output} 8 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:9") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:9/rocky-9-sfagent-${datestamp}.qcow2"
    build ${output} 9 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "rocky:10") -gt 0 ]; then
    output="/srv/sf-images/output/rocky:10/rocky-10-sfagent-${datestamp}.qcow2"
    build ${output} 10 "-" "rocky-container rhel-extras" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:11/debian-11-docker-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:12/debian-12-docker-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-docker:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-docker:13/debian-13-docker-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras docker-host" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:11/debian-11-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:12/debian-12-gnome-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-gnome:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-gnome:13/debian-13-gnome-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras gnome-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:11") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:11/debian-11-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bullseye 3 "apparmor utilities debian-old-extras debian debian-systemd xfce-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:12") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:12/debian-12-xfce-sfagent-${datestamp}.qcow2"
    build ${output} bookworm 3 "apparmor utilities debian debian-systemd debian-12-extras xfce-desktop" shakenfist-agent
fi

if [ $(echo $images | grep -c "debian-xfce:13") -gt 0 ]; then
    output="/srv/sf-images/output/debian-xfce:13/debian-13-xfce-sfagent-${datestamp}.qcow2"
    build ${output} trixie 3 "apparmor utilities debian debian-systemd debian-13-extras xfce-desktop" shakenfist-agent
fi

finish_run
run_finished=1

# The run's exit status. Cron mail and any future workflow both key
# off this, so it has to survive the per-image isolation above: one
# image failing no longer stops the others, but it still fails the
# run.
if [ "${run_result}" = "failure" ]; then
    echo "Complete, with failures."
    exit 1
fi

echo "Complete"
