#!/bin/bash

# File, update or resolve the issue that reports stale published
# images.
#
# Split out of the workflow rather than written inline in it because
# a workflow step is the one place in the fleet nothing can lint,
# test or run by hand. Here it can be executed against a scratch
# repository before anyone trusts it at three in the morning.
#
#   tools/freshness-issue.sh file <report-file> <run-url> <check-exit-status>
#   tools/freshness-issue.sh resolve <run-url>
#
# The exit status is check-image-freshness.sh's, and decides the
# issue's opening sentence. Status 2 means some images could not be
# checked and none were stale, which is a different fault from images
# that have stopped being refreshed, and the first sentence is what
# sends the reader looking.
#
# "file" opens one issue, or comments on the open one if there
# already is one: an outage that lasts a week should not leave seven
# issues behind. "resolve" closes it once everything is fresh again,
# because an issue that outlives the problem it describes is exactly
# the noise that taught everyone to ignore the nightly build mail.
#
# Requires GH_TOKEN in the environment.

set -o errexit
set -o nounset
set -o pipefail

LABEL="image-freshness"
TITLE="Published images are not being refreshed"

usage() {
    echo "Usage: $0 file <report-file> <run-url> <check-exit-status>"
    echo "       $0 resolve <run-url>"
    exit 2
}

[ $# -ge 1 ] || usage
mode="$1"
shift

repo="${GITHUB_REPOSITORY:-}"
if [ -z "${repo}" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

open_issue() {
    gh issue list --repo "${repo}" --label "${LABEL}" \
        --state open --limit 1 --json number --jq '.[0].number // empty'
}

case "${mode}" in
    file)
        [ $# -eq 3 ] || usage
        report_file="$1"
        run_url="$2"
        check_rc="$3"

        if [ ! -f "${report_file}" ]; then
            echo "No report at ${report_file}."
            exit 2
        fi

        case "${check_rc}" in
            1)
                finding=(
                    "The freshness watchdog found published images that have"
                    "not been refreshed."
                )
                ;;
            2)
                finding=(
                    "The freshness watchdog could not check some published"
                    "images, and found none of the others stale. The images"
                    "marked UNREACHABLE below are the ones it could not"
                    "check; this may be the web host or the watchdog rather"
                    "than the build."
                )
                ;;
            *)
                finding=(
                    "The freshness watchdog exited ${check_rc}, which it does"
                    "not document. The report below is everything it said."
                )
                ;;
        esac

        # gh issue create fails outright when the label does not
        # exist, which would lose the report at exactly the moment it
        # is wanted. --force makes this idempotent.
        gh label create "${LABEL}" \
            --repo "${repo}" \
            --description "Published images have stopped being refreshed" \
            --color d73a4a --force

        # The report is a fixed-width table, so it goes in a fence on
        # purpose. Everything outside the fence is written flush left:
        # four leading spaces would make GitHub render the whole body
        # as code and the run URL would stop being a link.
        body=$(
            printf '%s\n' \
                "${finding[@]}" \
                "" \
                "Run: ${run_url}" \
                "" \
                '```'
            cat "${report_file}"
            printf '%s\n' \
                '```' \
                "" \
                "This checks what images.shakenfist.com actually serves," \
                "so it fires for a failed build, a failed publish, or a" \
                "web host that has stopped serving new files. The build" \
                "logs on the build host say which." \
                "" \
                "This issue is updated rather than duplicated while the" \
                "problem lasts, and closed automatically once every" \
                "image is fresh again."
        )

        existing=$(open_issue)
        if [ -n "${existing}" ]; then
            echo "Commenting on existing issue #${existing}."
            gh issue comment "${existing}" --repo "${repo}" \
                --body "${body}"
        else
            echo "Filing a new freshness issue."
            gh issue create --repo "${repo}" \
                --title "${TITLE}" \
                --label "${LABEL}" \
                --body "${body}"
        fi
        ;;

    resolve)
        [ $# -eq 1 ] || usage
        run_url="$1"

        existing=$(open_issue)
        if [ -z "${existing}" ]; then
            echo "No open freshness issue to resolve."
            exit 0
        fi

        echo "Resolving freshness issue #${existing}."
        gh issue close "${existing}" --repo "${repo}" \
            --comment "Every published image is fresh again as of ${run_url}."
        ;;

    *)
        usage
        ;;
esac
