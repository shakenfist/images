#!/bin/bash

# Run every tools/test-*.sh, reporting each, and fail if any failed.
#
# Each suite is self-contained -- it builds its fixtures under a
# temporary directory and needs only bash, git and python3 -- so this
# is what ci.yml runs on a pull request and what to run locally before
# changing build.sh or an element. A glob rather than a list, so a new
# suite is run without anyone remembering to add it here.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=()
for suite in "${HERE}"/test-*.sh; do
    name="$(basename "${suite}")"
    echo "=== ${name}"
    if ! "${suite}"; then
        failed+=("${name}")
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    exit 1
fi
echo "All suites passed."
