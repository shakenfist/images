# The build host

Every published image comes from one machine running one cron job.
This page is what you need to know about that machine when a change
to this repository does not seem to have taken effect.

## How the nightly build runs

```
0 5 * * * cd /srv/sf-images/images; ./build.sh
```

`/srv/sf-images/images` is an ordinary clone of this repository. The
run takes a little over an hour for the full list, builds the images
in the order the `if` blocks appear in `build.sh` rather than the
order of the list, and publishes each one as it finishes. Per image
logs are published beside the image itself, as
`<image>/<name>-<datestamp>.qcow2.log`, and shipped to Loki under
`{job="image-build"}` on the `sfyow` tenant.

## The checkout updates itself, but only since 2026-09-14

`build.sh` fast-forwards its own checkout to `origin/master` at the
start of a run and re-executes itself if that moved anything. Before
that it did not, and nothing else did either, so the code cron ran
was whatever had last been pulled by hand.

That is not a hypothetical. images#5, #6 and #7 all merged and then
did not run. On the night of 2026-09-14 the nightly build was still
assembling its element list without `verify-release` -- the check
that is supposed to stop an image publishing under a name it does not
match -- a day after that element landed on `master`, and nothing
reported it. The build looked healthy because it was: it was
faithfully running code from before the fix.

What made it hard to see is that `build.sh` does contain a
`git pull origin master`, a few lines below. That one is
diskimage-builder's, in the block that installs DIB from source, and
it made the checkout look maintained.

**Bootstrapping.** A self-update in a script only helps once the
script that runs is the one that has it. The checkout has to be
pulled by hand once:

```
cd /srv/sf-images/images && git pull --ff-only origin master
```

After that the run keeps itself current.

**Caveats worth knowing.**

* The pull is skipped entirely for `build.sh --list-images`, which is
  how `tools/check-image-freshness.sh` reads the image list. The
  watchdog runs on a GitHub runner in a fresh checkout and has no
  business pulling.
* A checkout that cannot fast-forward -- a local edit, a diverged
  branch, no network -- warns loudly and builds anyway. Yesterday's
  images beat no images, and
  [the freshness watchdog](../tools/check-image-freshness.sh) is what
  notices if it goes on.
* The re-exec matters. bash reads a script lazily, by byte offset, so
  replacing `build.sh` underneath a running `build.sh` resumes it at
  whatever text now sits at that offset. `tools/test-self-update.sh`
  exercises all of this, including that the restart happens exactly
  once.

## Checking whether a change is live

The element list is printed at the top of every per image log, so it
answers "is my element running" directly:

```
curl -s https://images.shakenfist.com/debian:13/latest.qcow2.log \
    | grep -m1 'Building elements:'
```

The same line in Loki, for the whole run:

```
{job="image-build"} |~ "Building elements:"
```
