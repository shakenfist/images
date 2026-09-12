#!/bin/bash

# Check block-device-compat.yaml against the upstream layout it was
# copied from.
#
# block-device-compat.yaml is diskimage-builder's own
# block-device-efi/block-device-default.yaml with one line added: mkfs
# opts for the root filesystem. build.sh pulls diskimage-builder from
# git master on every run, so upstream can change that layout under
# us, and a stale copy would silently build images with a partition
# table nobody chose -- the copy still applies cleanly, it just stops
# being what DIB would have done.
#
# Run with the path to a diskimage-builder checkout; build.sh leaves
# one beside itself:
#
#   tools/check-block-device-config.sh diskimage-builder

set -o errexit
set -o nounset
set -o pipefail

DIB_CHECKOUT="${1:-diskimage-builder}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OURS="${HERE}/block-device-compat.yaml"
THEIRS="${DIB_CHECKOUT}/diskimage_builder/elements/block-device-efi/block-device-default.yaml"

if [ ! -f "${THEIRS}" ]; then
    echo "No diskimage-builder checkout at ${DIB_CHECKOUT}."
    echo "Pass one as the first argument, or run build.sh once to clone it."
    exit 2
fi

# Comments are ours alone, and the opts line is the whole point of the
# copy, so neither takes part in the comparison.
strip() {
    grep -v '^\s*#' "$1" | grep -v 'opts: "-O ' | sed '/^\s*$/d'
}

if diff -u <(strip "${THEIRS}") <(strip "${OURS}"); then
    echo "block-device-compat.yaml matches upstream."
    exit 0
fi

echo
echo "block-device-compat.yaml has drifted from upstream's"
echo "block-device-efi layout (shown above: upstream on the left)."
echo "Re-copy it and re-add the root mkfs opts line."
exit 1
