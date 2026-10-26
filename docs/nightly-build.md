# The nightly build

Every published image is built on an ephemeral CI VM and copied to the
image server. This page is what you need to know when a change to this
repository does not seem to have taken effect, or when an image needs
rebuilding outside the nightly.

## How the nightly runs

The conductor, a service on maui, dispatches
`.github/workflows/image-build.yml` on `master` at about 01:30
Canberra time, with its `publish` input on. The workflow runs one job
per image, four at a time, each on a fresh
`[self-hosted, vm, debian-13, m]` VM that runs `build.sh` for that
image alone and then publishes it. Per image jobs are independent: one
failing does not stop the rest.

The workflow has no `schedule:` and must not get one. GitHub's
scheduler ran hours late and skipped nights across the fleet, and a
schedule added as a backup would fire after the conductor's run and
rebuild the same night. It has no `push` or `pull_request` trigger
either, because the VM runners hold a key that reaches the whole CI
mesh and the build job runs as root.

**A busy fleet can stretch a nightly to hours.** The builds themselves
add up to about 108 minutes of work, but the first full run took 6h39m
from dispatch to the last job, because the jobs queue behind everything
else the fleet is doing. A nightly that is still running at breakfast
is not necessarily broken: look at the Actions run before assuming it
is stuck.

## Rebuilding one image, or a few, by hand

In the repository's Actions tab, choose "Image build", then Run
workflow:

* Branch: `master`.
* `images`: the images to build, separated by spaces, such as
  `debian:13` or `debian:13 rocky:9`. Empty builds the default list.
* `publish`: on.

That builds on a CI VM and publishes exactly as the nightly does,
including pruning each label to its newest seven images. From any
branch other than `master`, `publish` is ignored: the image is built,
checked and thrown away, and nothing is published.

A second dispatch on the same ref waits for the first rather than
cancelling it, so a hand run started during the nightly queues behind
it.

## Trying a change to build.sh

Dispatch the workflow from the branch with `publish` off and the
`images` that the change touches. The branch's own `build.sh` runs,
unchanged by any update, and the result is discarded. Merge only once
that run has built the image.

## Where the logs are

* The Actions run for the dispatch, one job per image.
* A log beside each published image, named
  `<image>/<name>-<datestamp>.qcow2.log`, for example
  `https://images.shakenfist.com/debian:13/latest.qcow2.log`. The
  element list is printed at its top, so this answers whether a change
  is running:

  ```
  curl -s https://images.shakenfist.com/debian:13/latest.qcow2.log \
      | grep -m1 'Building elements:'
  ```

* Loki, in the `sfyow` tenant. Each image's log is
  `{job="image-build"}`, with an `image` label. Each job also ships a
  summary of what it was asked to build and what became of it, as
  `{job="image-build-summary"}`, which carries a `result` label that is
  `failure` when the image failed or was not attempted:

  ```
  {job="image-build", image="debian:13"}
  {job="image-build-summary", result="failure"}
  {job="image-build-summary"} |= "Stopped:"
  ```

  A run that stops before its end still sends a summary. A stop while
  preparing the VM (apt, the diskimage-builder pull from upstream
  `master`, applying `diskimage-builder-patches/`) has a `Stopped:`
  line, the last forty lines the preparation printed, and the image as
  not attempted. A stop anywhere else outside the image build names the
  line of `build.sh` and the command that failed.

Shipping happens only when both `SF_IMAGES_LOKI_URL` and
`SF_IMAGES_LOKI_TENANT` are set. In the workflow they come from the
`images-publish` environment's secrets, which only `master` receives,
so a dispatch from a branch ships nothing and its run warns so when it
starts. If `{job="image-build"}` goes quiet, check those first.

## The publishing credential

Publishing needs secrets that live in the `images-publish`
environment, which only `master` may deploy from. A dispatch from a
branch takes no environment and so no secret. The environment holds the
SSH key, the pinned host key for the image server, the rsync target,
and the two Loki settings.

The key belongs to an account on sfyow that is confined with `rrsync`:
it can run rsync inside the image document root and nothing else, and
only from the CI VMs' egress address. Images travel over sfyow's
WireGuard tunnel address, not the public one. The key, the target and
the address are not written here because this repository is public.

If every image's publish fails, suspect the egress address having
changed, which the account refuses, before suspecting the key.

A job killed during its upload, by its timeout or by a lost VM, can
leave rsync's temporary file in the label directory: a hidden
`.<image>.qcow2.<random>`. Retention only ever deletes `*.qcow2` and
`*.qcow2.log`, so nothing removes it. List hidden files in a label
directory on sfyow after such a run, and delete any that no rsync is
still writing.

## If the debian-13 runner label is broken

The build runs on VMs booted from the `debian-13` label, which is
itself one of the images this repository publishes. A bad `debian:13`
image can therefore stop the build that would replace it. The
conductor's checks catch most bad images before they are used, but not
one that boots and passes its checks yet breaks diskimage-builder.

To recover, point the label back at the previous blob with
`sf-client label update`, wait for new VMs to boot from it, and
dispatch `debian:13` from `master` with `publish` on. The freshness
watchdog reports the stall on the third day either way.

## Building build.sh directly

```
sudo --preserve-env=SF_IMAGES_LOKI_URL,SF_IMAGES_LOKI_TENANT \
    ./build.sh --no-push debian:13
```

* `sudo` resets the environment, so without `--preserve-env` the
  Loki variables you exported do not reach `build.sh`. The run warns
  if `SF_IMAGES_LOKI_URL` is missing.
* Without `--no-push`, a run publishes what it builds and prunes old
  images, keeping the newest seven of each. Where it publishes is
  `SF_IMAGES_PUBLISH_TARGET`, an rsync destination: a local directory
  or `user@host:path`. There is no default: a run that would publish
  and has no target exits 2 before it builds anything, rather than
  writing the images to whatever machine it happens to be on.
  `build.sh` knows nothing about SSH. rsync takes `RSYNC_RSH` from the
  environment, so a remote target's key and host key go there. Under
  `sudo`, add both to `--preserve-env`. Retention refuses to delete
  anything, and says so, if the target's listing does not show the
  image just published and `latest.qcow2`.
* `--no-push` leaves every image the run builds under
  `/srv/sf-images/output/<label>/` and says so in the summary. They
  stay there until the next publishing run, which empties the directory
  before each image, so a `--no-push` of the whole list needs disk for
  all of them at once. File names carry only the date, so rebuilding an
  image the same day replaces the earlier one.
* Flags go before the image list, and several images are quoted as one
  argument: `./build.sh --no-push "debian:13 rocky:9"`. An unknown
  flag, or anything after the image list, is refused rather than
  guessed at, because the guess that goes wrong is a run that
  publishes.
* `--list-images` prints the list `build.sh` would build and exits, as
  an unprivileged user, with no target and none of the build
  dependencies. `tools/check-image-freshness.sh` reads the list that
  way.

`build.sh` still carries a self-update, which fast-forwards the
checkout it runs from and restarts, and a `--no-self-update` flag that
turns it off. The workflow passes the flag because its checkout is
already the commit it was asked to build. The self-update has no job
left to do and a follow-up removes both.

## Checking whether a change is live

See the log beside the image, above: the element list is printed at the
top of every per image log. The same line in Loki, for the whole run:

```
{job="image-build"} |~ "Building elements:"
```

## Scratch space is on disk, not /tmp

`build.sh` sets diskimage-builder's `TMP_DIR` to `/srv/sf-images/tmp`.
DIB defaults to `/tmp`, which can be a small tmpfs: on the machine the
nightly used to run on it was 2G, sized for other services. Most of a
build never notices, because DIB mounts a separate tmpfs for each
image's chroot. The exception is the `extract-image` element, which the
CentOS Stream 9 image uses (and so may any other image built from an
upstream cloud image): when a newer upstream image is downloaded, it
repacks the image into a tarball under `TMP_DIR`. That needs a raw copy
of the image plus a tarball of about 1.2G. On 2026-10-08 a new CentOS
Stream 9 image arrived, the repack failed with
`gzip: stdout: No space left on device`, and because the repack only
reruns while the cached image is newer than the cached tarball, every
night after that failed the same way.

A failed repack shows in `{job="image-build"}` as `Working in
/tmp/tmp.*` followed by the ENOSPC line, and in the run summary as that
one image failing while the rest build.

`build.sh` also sets `DIB_NO_TMPFS=1`, so DIB builds on disk instead
of in its per-image tmpfs. DIB mounts two of those, the chroot and the
image, and lets each grow to half of RAM with nothing capping the pair.
On an 8 GB CI VM, ubuntu:22.04 ran out of space writing its initramfs
(`zstd: ... No space left on device`), and debian-gnome:12's VM died
mid-build without a log, which is what the two mounts overrunning RAM
looks like. The VM has 200 GB of disk and nothing else on it, so
building on disk beats renting a bigger VM, where the pair would still
be uncapped. It is set in `build.sh` rather than in the workflow so a
hand run on a small VM builds the way CI does.
