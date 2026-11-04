#!/bin/bash

# File, comment on or resolve the issue that reports an image that
# failed to build.
#
# Split out of the workflow rather than written inline in it because
# a workflow step is the one place in the fleet nothing can lint,
# test or run by hand. Here it can be executed against a scratch
# repository before anyone trusts it at half past one in the morning.
#
#   tools/build-failure-issue.sh file <image> <run-url>
#   tools/build-failure-issue.sh resolve <image> <run-url>
#   tools/build-failure-issue.sh reconcile <images-json> <jobs-file> <run-url>
#
# There is one issue per image, labelled build-failure:<image>, so a
# second broken image is never hidden behind the first. "file" opens
# that issue, or comments on the open one if there already is one: an
# outage that lasts a week should leave one issue, not seven.
# "resolve" closes it once the image builds again, because an issue
# that outlives the problem it describes is exactly the noise that
# teaches everyone to ignore the nightly build mail.
#
# "reconcile" is what the workflow calls. The requested image list
# (as image-matrix.sh emits it) is compared against the per-job
# conclusions GitHub recorded for the run, so an image whose build
# leg died without reporting -- a runner VM that vanished mid-build,
# a cancelled or skipped leg, a job that never appears -- is still
# reported as a failure to produce rather than silently passing. For
# each image it calls "file" when its "Build <image>" job did not
# succeed and "resolve" when it did.
#
# Requires GH_TOKEN in the environment.

set -o errexit
set -o nounset
set -o pipefail

usage() {
    echo "Usage: $0 file <image> <run-url>"
    echo "       $0 resolve <image> <run-url>"
    echo "       $0 reconcile <images-json> <jobs-file> <run-url>"
    exit 2
}

[ $# -ge 1 ] || usage
mode="$1"
shift

repo="${GITHUB_REPOSITORY:-}"
if [ -z "${repo}" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

# The open issue for one image, by its label, or empty if none is
# open.
open_issue() {
    gh issue list --repo "${repo}" --label "$1" \
        --state open --limit 1 --json number --jq '.[0].number // empty'
}

do_file() {
    local image="$1" run_url="$2"
    local label="build-failure:${image}"

    # gh issue create fails outright when the label does not exist,
    # which would lose the report at exactly the moment it is wanted.
    # Colons are legal in label names; --force makes this idempotent.
    gh label create "${label}" \
        --repo "${repo}" \
        --description "The ${image} image is failing to build" \
        --color d73a4a --force

    # The body is written flush left on purpose: four leading spaces
    # would make GitHub render the whole body as code and the run URL
    # would stop being a link.
    local body
    body=$(
        printf '%s\n' \
            "The nightly build of ${image} did not succeed." \
            "" \
            "Run: ${run_url}" \
            "" \
            "${image} is the image that failed; the build logs linked" \
            "from the run above say why." \
            "" \
            "This issue is updated rather than duplicated while ${image}" \
            "keeps failing, and closed automatically once ${image} builds" \
            "again."
    )

    local existing
    existing=$(open_issue "${label}")
    if [ -n "${existing}" ]; then
        echo "Commenting on existing issue #${existing} for ${image}."
        gh issue comment "${existing}" --repo "${repo}" --body "${body}"
    else
        echo "Filing a new build-failure issue for ${image}."
        gh issue create --repo "${repo}" \
            --title "${image} is failing to build" \
            --label "${label}" \
            --body "${body}"
    fi
}

do_resolve() {
    local image="$1" run_url="$2"
    local label="build-failure:${image}"

    local existing
    existing=$(open_issue "${label}")
    if [ -z "${existing}" ]; then
        echo "No open build-failure issue for ${image} to resolve."
        return 0
    fi

    echo "Resolving build-failure issue #${existing} for ${image}."
    gh issue close "${existing}" --repo "${repo}" \
        --comment "${image} built successfully again as of ${run_url}."
}

case "${mode}" in
    file)
        [ $# -eq 2 ] || usage
        do_file "$1" "$2"
        ;;

    resolve)
        [ $# -eq 2 ] || usage
        do_resolve "$1" "$2"
        ;;

    reconcile)
        [ $# -eq 3 ] || usage
        images_json="$1"
        jobs_file="$2"
        run_url="$3"

        if [ ! -f "${jobs_file}" ]; then
            echo "No jobs JSON at ${jobs_file}." >&2
            exit 2
        fi

        # python3 turns the two JSON inputs into one "action image"
        # line per image, so the shell never parses JSON itself. An
        # empty or unparseable image list yields no lines, so nothing
        # is reconciled and the loop exits 0: the list job may have
        # failed, and that is the freshness watchdog's business, not
        # this tool's.
        while IFS=$'\t' read -r action image; do
            [ -n "${action}" ] || continue
            case "${action}" in
                file) do_file "${image}" "${run_url}" ;;
                resolve) do_resolve "${image}" "${run_url}" ;;
            esac
        done < <(python3 - "${images_json}" "${jobs_file}" <<'PY'
import json
import sys

try:
    images = json.loads(sys.argv[1])
    if not isinstance(images, list):
        sys.exit(0)
except (ValueError, IndexError):
    sys.exit(0)

with open(sys.argv[2]) as handle:
    run = json.load(handle)

conclusions = {}
for job in run.get('jobs', []):
    conclusions[job.get('name')] = job.get('conclusion')

for image in images:
    if conclusions.get('Build ' + image) == 'success':
        print('resolve\t' + image)
    else:
        print('file\t' + image)
PY
        )
        ;;

    *)
        usage
        ;;
esac
