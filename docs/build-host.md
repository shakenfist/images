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

## The run summary is in Loki, not in cron mail

The run ends with a summary of what it was asked to build and what
became of each image: built, failed, or never attempted. The build
host has no MTA, so cron discards everything the run prints, and that
summary used to go with it. It is the only record of an image that
was never attempted -- a failed build at least leaves its own log
behind -- so it is shipped to Loki as a stream of its own:

```
{job="image-build-summary"}
{job="image-build-summary", result="failure"}
```

`result` is `failure` when any image failed or was not attempted,
matching the run's exit status. The stream carries no `image` label,
so queries against `{job="image-build"}` see only per image logs. An
absence of this stream for a night means the run did not reach its
end at all.

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
* A checkout that cannot be updated -- a local edit, a diverged
  branch, no network, or a repository git refuses to open at all --
  warns loudly and builds anyway. Yesterday's images beat no images,
  and [the freshness watchdog](../tools/check-image-freshness.sh) is
  what notices if it goes on.
* The re-exec matters. bash reads a script lazily, by byte offset, so
  replacing `build.sh` underneath a running `build.sh` resumes it at
  whatever text now sits at that offset. `tools/test-self-update.sh`
  exercises all of this, including that the restart happens exactly
  once.

## The checkout has to belong to the user cron runs as

cron runs `build.sh` as root. git refuses to operate on a repository
owned by somebody else:

```
fatal: detected dubious ownership in repository at '/srv/sf-images/images'
```

On 2026-09-15 that ended the nightly build in under a second. The
checkout on the build host belonged to `debian`, the self-update runs
git before anything else, and the host has no MTA, so cron discarded
the one line that said why. Nothing was published and nothing was
said. `build.sh` now treats any git failure as a reason to warn and
build anyway, so the same mistake costs a stale checkout rather than
a whole night -- but the ownership still has to be right for the
self-update to do its job at all. The deploy in the 33fl repository
owns the checkout as root and checks it.

**This does not reproduce under `sudo`,** which is the trap. git
allows a repository owned by the uid in `SUDO_UID`, so
`sudo git -C /srv/sf-images/images status` succeeds from an
interactive login on exactly the checkout that cron cannot read. To
ask the question cron asks:

```
sudo env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
    git -C /srv/sf-images/images rev-parse HEAD
```

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

## Scratch space is on disk, not /tmp

`build.sh` sets diskimage-builder's `TMP_DIR` to `/srv/sf-images/tmp`.
DIB defaults to `/tmp`, and on the build host `/tmp` is a 2G tmpfs
(set by the 33fl deploy on 2026-10-05 and sized for other services).
Most of a build never notices, because DIB mounts a separate tmpfs for
each image's chroot. The exception is the `extract-image` element, which
the CentOS Stream 9 image uses (and so may any other image built from an
upstream cloud image): when a newer upstream image is downloaded, it
repacks the image into a tarball under `TMP_DIR`. That
needs a raw copy of the image plus a tarball of about 1.2G. On
2026-10-08 a new CentOS Stream 9 image arrived, the repack failed with
`gzip: stdout: No space left on device`, and because the repack only
reruns while the cached image is newer than the cached tarball, every
night after that failed the same way.

A failed repack shows in `{job="image-build"}` as `Working in
/tmp/tmp.*` followed by the ENOSPC line, and in the run summary as that
one image failing while the rest build.
