# Image build modernisation

## Prompt

Written 2026-09-12, after the nightly image builds were found to
have produced nothing for sixteen days without anyone noticing.
The immediate defects are fixed in shakenfist/images#2. This plan
is about the mechanism that let the outage last sixteen days,
which that pull request does not address.

Read `build.sh` before acting on any phase here. It is the whole
build system and it is one 19KB Bash script; every claim in this
plan about how the build behaves is a claim about that file.

## Situation

Nightly builds run from cron on sfyow-1:

```
0 5 * * * cd /srv/sf-images/images; ./build.sh
```

There is no output redirection, so cron mails root. Nobody reads
root's mail. This is the entire failure notification mechanism.

**What happened.** `ubuntu:20.04` began failing on 2026-08-27 with
`grub-install: error: unknown filesystem`. `build.sh` runs under
`#!/bin/bash -e` and `ubuntu:20.04` was first in build order, so
the single failure aborted the script. No image was rebuilt between
2026-08-26 and 2026-09-12 -- sixteen days.

**Why it stayed invisible.** `push_log_to_loki()` (`build.sh:107`)
records each image's outcome to Loki with a `success` or `failure`
label, so monitoring signal did exist. It did not help, for a
reason worth stating precisely because it shapes Phase 4: when the
script aborts, the images after the failure emit **nothing at
all** -- not a failure record, no record. Only `ubuntu:20.04`
reported failure. The other thirteen images were silent, and
silence is indistinguishable from "not scheduled tonight". Any
alert built on the presence of a failure event would have caught
one image and missed thirteen.

**The second defect found while fixing the first.** The root cause
was not the end-of-life status of Ubuntu 20.04. sfyow-1 runs Debian
13 trixie, whose e2fsprogs 1.47.2 enables the `orphan_file` and
`metadata_csum_seed` ext4 features by default. `grub-install` runs
inside the chroot, so the **guest's** grub must read the
filesystem, and grub gained support for those features only in
2.12:

| Image | Guest grub | Result |
|---|---|---|
| ubuntu:20.04 | 2.04 | FAIL |
| ubuntu:22.04 | 2.06 | FAIL |
| ubuntu:24.04 | 2.12 | PASS |
| debian:13 | 2.12 | PASS |

The build host was upgraded and every guest older than grub 2.12
broke. Nothing declared, pinned, or even recorded the builder's
own distribution version -- it is whatever sfyow-1 was last
upgraded to. This is the single most important fact in this
document and it drives the Phase 2 recommendation.

**A third defect, found by reading the build logs.**
`debian-docker:12`, `debian-gnome:12` and `debian-xfce:12` passed
`DIB_RELEASE=bullseye` while naming the `debian-12-extras`
element, from commit `8d73ca9` on 2024-07-06 until 2026-09-12 --
two years and two months of publishing Debian 11 under a Debian 12
name. No test, no check and no human noticed. The blast radius
reached private-ci, whose CI dependencies cache disk snapshots
`debian-gnome-12` (shakenfist/private-ci#38).

**Where things stand.** All fourteen images in the current default
list were observed building successfully in the catch-up run of
2026-09-12 00:59-02:07 UTC and the corrected bookworm rebuild that
followed. The six mislabelled copies in each of the three affected
directories have been deleted from images.shakenfist.com.

**Repository standards.** This repository is on shakenfist/
development's excluded list. It has no `.github/`, no
`.pre-commit-config.yaml`, no `docs/` (until this plan), no
renovate configuration, no tests, and its default branch is
`master` rather than `develop`. `build.sh` has 91 outstanding
shellcheck findings, including a dead `if [ $? -gt 0 ]` at
`build.sh:215` that follows a redirect and can never fire.

## Mission and problem statement

Make a failed or missing image build visible within a day, and
make the builder's own environment a declared input rather than an
accident of whenever the build host was last upgraded.

This plan deliberately does not cover: the content of the images
themselves, the DIB patches under `diskimage-builder-patches/`,
whether the fleet should consume these images at all, or the
retirement of further end-of-life distributions. It also does not
attempt to add meaningful automated testing of image *contents* --
booting and inspecting a published image is worth doing and is
listed under Future work, but it is a larger piece of work than
this plan should absorb.

## Open questions

These are the three questions that prompted this plan. Each states
the decision the plan takes by default if nobody answers.

### Q1. Should builds still happen on sfyow, or should it strictly host?

**Default decision: split the roles.** sfyow becomes strictly the
host for images.shakenfist.com; builds move to an ephemeral runner
whose operating system is a declared, pinned input.

The argument is not tidiness, it is the grub outage. The build
broke because sfyow-1 was upgraded to trixie and e2fsprogs changed
its ext4 defaults underneath a build system that never declared
what it was building on. A long-lived, mutable build host makes
every build depend on the accumulated state of one machine --
`build.sh:72` installs packages and then builds and patches DIB
from source, so that state is substantial. An ephemeral builder
turns "which distro do we build on" into a line in a workflow file
that changes when somebody decides to change it, and that one
change would have converted a sixteen-day outage into a reviewable
one-line diff.

`block-device-compat.yaml` is worth reading in this light. It is a
real fix and it should stay, but it is a compatibility shim that
exists because the builder moved without anyone choosing to move
it. Pinning the builder does not make the shim unnecessary -- old
guests still have old grub -- but it stops the next such surprise
arriving unannounced.

Costs, stated honestly:

* **Transfer.** Publishing stops being a local `rsync` to
  `/srv/www/images.shakenfist.com/` (`build.sh:273`) and becomes a
  network copy of roughly 10GB per night. Whether that is minutes
  or hours depends on where the builder sits relative to sfyow,
  **which I do not know and could not determine from the
  repository**. This needs a real answer before Phase 2 is
  scheduled; if the builder cannot reach sfyow cheaply, the
  default decision is wrong and the fallback below applies.
* **Credentials.** The builder needs write access to sfyow's
  document root. That is a new secret with a new blast radius.
* **Build time.** A fresh builder rebuilds DIB from source every
  run. Acceptable if images are built in parallel; painful if not.

**Fallback if the transfer cost turns out to be prohibitive:**
keep building on sfyow, but pin what the build runs *in* by doing
the build inside a container or a throwaway VM on sfyow, so the
host's own distribution stops being an input. This gets most of
the reproducibility benefit and none of the transfer cost, and it
is the option to take if Q1's unknown resolves badly.

### Q2. What mechanism?

**Default decision: GitHub Actions, with a matrix job per image
and `fail-fast: false`.** The conclusion is the obvious one, but
the reason that matters is not the one usually given.

The value is not "Actions is where our other CI lives", true
though that is. It is that a matrix with `fail-fast: false` makes
the sixteen-day outage **structurally impossible**. One image
failing stops that image. Thirteen others build. No amount of
notification bolted onto the current serial `bash -e` script
achieves that, because the script's failure mode is to stop doing
the work, and a notification about work that was never attempted
is the hardest kind of alert to act on.

What Actions also brings, in rough order of value: per-image
history with logs retained; `workflow_dispatch` to rebuild one
image by hand without editing a cron line on a server; the
issue-filing pattern for Phase 3; and review of build changes
through pull requests, which this repository has barely used --
shakenfist/images#2 was the first pull request this repository
has ever had, and it is numbered 2 only because an issue took
number 1.

Alternatives considered and rejected:

* **Keep cron, add notification.** Cheapest, and it is a genuine
  option if Phase 1 lands and nothing else does. Rejected as the
  target state because it leaves the build serial and fail-fast,
  fixes visibility without fixing the thing being made visible,
  and leaves no history to look at when an image starts failing
  intermittently.
* **GitHub-hosted runners.** Rejected twice over. The fleet's
  `self-hosted-runners` consistency criterion bans them for cost,
  and independently the disk available on a hosted runner is far
  too small for a DIB build that produces a 1.4GB compressed
  image from a much larger working tree.
* **Zuul.** The fleet already reads Zuul results for OpenStack
  work, so it is not unfamiliar. Rejected as disproportionate:
  this is fourteen independent builds on a timer, which is the
  case Actions matrices handle natively.

**A constraint that must not be missed: this repository is
public.** A self-hosted runner attached to a public repository is
a documented security hazard -- a pull request from a fork can
execute arbitrary code on the runner, and this runner has `sudo`,
loop devices and (under the default decision for Q1) a credential
that writes to the public image site. Any implementation must
therefore:

* trigger the build job from `schedule` and `workflow_dispatch`
  only, never from `pull_request` on forks;
* keep the publishing credential out of any job reachable from a
  fork; and
* prefer ephemeral runners, which bound the damage to one job.

If that cannot be arranged, building on sfyow behind a cron
trigger is *safer* than building on a fork-reachable self-hosted
runner, and Q1's fallback should be taken for this reason rather
than the transfer one.

### Q3. How would we know a build run had failed?

**Default decision: two independent signals, filing GitHub
issues. Both are needed, because they fail differently.**

**Signal A -- the build ran and failed.** A matrix job fails;
a follow-on job files or updates a GitHub issue. Reuse the pattern
already proven in shakenfist/actions'
`.github/workflows/canary.yml:95-155`: ensure the label exists with
`gh label create --force` (because `gh issue create` fails outright
on a missing label, losing the report at exactly the wrong moment),
look for an open issue with that label, and comment on it rather
than filing a second one. One issue per outage, not one per night.

Two adaptations for this repository. The label should be per image
(`build-failure:debian:13`), not one global label, so a single
broken image does not hide a second one behind it. And the body of
the script belongs in `tools/`, not inline in the workflow: the
fleet convention is that no CI step carries more than about five
lines of script, and the canary's copy is thirty-five.

**Signal B -- the build did not run at all.** A scheduled job that
makes a `HEAD` request to
`https://images.shakenfist.com/<image>/latest.qcow2` for every
image in the default list and files an issue for any whose
`Last-Modified` is older than a threshold.

Signal B is the one that would have caught this outage, and it is
worth being precise about why. Signal A can only fire for work
that was attempted. On 2026-08-27 exactly one image attempted and
failed; thirteen were never reached and reported nothing. Signal A
alone would have produced one issue about `ubuntu:20.04` -- which,
being an end-of-life image nobody urgently needed, is precisely
the issue most likely to be triaged as "yes, we know" and left.
The thirteen images that mattered would have stayed silent.

Signal B also measures the right thing. It tests what a consumer
actually receives, not what the build system believes it did, so it
catches the cases Signal A cannot see at all: the publish step
silently failing, nginx serving a stale directory, a full disk, the
workflow being disabled, the schedule never firing, or the runner
being offline. A build system reporting its own health cannot
report that it did not run.

For that reason Signal B must not run on sfyow and must not depend
on any of the build machinery. It needs outbound HTTPS and nothing
else, so it can run anywhere -- and it should, deliberately,
somewhere with no other connection to the thing it is watching.

Threshold: start at **72 hours**, not 24. Nightly builds already
skip a night for transient reasons, and an alert that cries wolf
weekly gets muted, which is how the current mail notification
died. Three days is short enough that sixteen would have been
impossible and long enough to survive one bad night.

## Execution

Phases are sections of this file rather than separate phase files,
per `docs/plans/index.md`.

| Phase | Merged | Status |
|-------|--------|--------|
| 0. Planning foundation | 39303ef (#3) | Complete |
| 1. One failure stops one image | | In progress |
| 2. Move the build mechanism | | Not started |
| 3. Failure files an issue | | Not started |
| 4. Freshness watchdog | acccd2b (#5) | Complete |
| 5. Repository standards | | Not started |
| 6. Push audit | | Not started |

Phases 1 and 4 are deliberately ordered before and independent of
Phase 2. Both are worth having even if the mechanism question is
never resolved, and neither depends on its answer. If this plan
stalls, it should stall after Phase 4, not before it.

### Phase 0. Planning foundation

Status: Complete

This phase. The repository had no planning template, which made
writing a plan for it circular -- hence bootstrapping the template
first and writing the plan on top of it.

* `PLAN-TEMPLATE.md` at the repository root, carrying all nine
  shared blocks required by shakenfist/development's
  `plan-template` criterion, verbatim and at current versions
  (`plan-push-audit-phase` is at v3; the other eight at v1).
  Blocks were assembled by concatenating the canonical files
  rather than transcribed, and verified byte-identical.
* `docs/plans/index.md`, following the `plan-index` criterion:
  `Date` then `Plan` leading columns, `YYYY-MM-DD` dates, oldest
  first, status from the shared vocabulary.
* This plan.

Note that this repository is **excluded** from the fleet
consistency audit, so nothing verifies any of the above overnight.
The template was built to the audited standard anyway: matching the
fleet costs nothing here and diverging would have to be explained
to every agent that reads it. Whether this repository should be
brought into audit scope is Phase 5's business.

### Phase 1. One failure stops one image

Status: In progress
Effort: medium. Model: sonnet.

Make `build.sh` continue past a failed image and report at the end,
instead of aborting the run. This is the outage class, and fixing it
here means it is fixed whether or not Phase 2 ever happens.

The mechanism was traced on 2026-09-13 and is not quite what this
phase originally assumed. Three findings shape the work, and the
third will mislead anyone who does not know it.

**The build failure is invisible because of a pipe, not because
detection is hard.** `disk-image-create` is piped into `tee`, so the
pipeline reports `tee`'s exit status and never the builder's. The
comment above the check asks "why is it so hard to detect a DIB
failure?"; the answer is that nothing has ever read the right
variable. `${PIPESTATUS[0]}`, taken immediately after the pipeline,
carries the real status and does not trip `errexit` -- confirmed by
experiment. That is the root-cause fix, and it is the same idiom the
fleet's `workflow-standards` criterion asks for elsewhere.

**Do not reach for `pipefail` globally instead.** The retention
pipeline ends in `head`, which closes the pipe early; under
`pipefail` that pipeline reports 141. Scoping the fix to
`PIPESTATUS` at the one pipeline that matters avoids inventing a new
failure in the publish path.

**`errexit` cannot be re-armed inside a subshell in a condition
context.** Both `if build ...; then` and `if ( set -e; build ... );
then` were tested; both ran straight past a failing command and then
reported success. So the obvious implementation -- wrap the call
site and catch the return -- produces a function that silently
continues after a failed `qemu-img convert` and publishes whatever
is on disk. `build()` has to stop depending on `errexit` internally
and check its own fallible steps instead.

The work:

* Replace the dead exit status check with one that reads
  `${PIPESTATUS[0]}`. It is at `build.sh:249` as of 39303ef -- this
  phase originally cited line 215, which the comment block added in
  #2 has since moved, so find it by content rather than by line.
  Keep the "Build completed successfully" grep as a second
  assertion: it catches a builder that exits zero having done
  nothing.
* Make `build()` explicitly error-checked. `qemu-img convert`, the
  `rsync` publish, the `latest.qcow2` relink and the `cd` pair each
  need a checked failure path, because per the third finding
  `errexit` will not be in force inside the function.
* Accumulate outcomes inside `build()` rather than editing the 38
  call sites, and exit non-zero at the end with a summary naming
  which images failed. A non-zero exit is what Phase 2 and the
  current cron mail both key off, so it must survive.
* Emit a `failure` log record for every image in the list that did
  not produce an image, by reconciling the requested list against
  the recorded outcomes at the end of the run. The absence of a
  record is what made the outage unreadable after the fact, and the
  reconciliation is what covers images a run never reached at all.
* Guard the retention arithmetic. When a directory holds fewer than
  seven images, `numextra` goes negative and `head -$numextra`
  becomes `head --4`, which errors inside a command substitution and
  is discarded. Nothing is lost today because there is nothing to
  delete, but it is the same class of defect as the dead exit status
  check -- an error path that cannot report -- and this phase is
  already editing that function.
* Move the log shipping destination and tenant out of the script and
  into the environment, defaulting to not shipping when unset. Where
  build logs go is a property of the deployment rather than of the
  build, and this repository is public.

Verification: run `./build.sh "debian:13 <a deliberately broken
image> rocky:9"` on a build host and confirm that `debian:13` and
`rocky:9` both publish, that the script exits non-zero, and that the
summary names only the broken image.

### Phase 2. Move the build mechanism

Status: Not started
Effort: high. Model: opus.
Blocked on: Q1 and Q2 above, and specifically on the transfer-cost
unknown in Q1.

Implement the answers to Q1 and Q2: a GitHub Actions workflow with
a matrix job per image and `fail-fast: false`, on a runner whose
operating system is pinned, publishing to sfyow.

* Do not schedule this phase until the Q1 transfer question has a
  real answer. Both of its possible answers lead to a coherent
  design and they are different designs; guessing means building
  one and discovering it was the other.
* Whichever answer, the builder's distribution becomes an
  explicit, reviewable value. That is the point of the phase.
* Honour the public-repository constraint in Q2. No
  `pull_request`-triggered job touches the publishing credential
  or runs on a runner with `sudo`.
* Retire the cron entry on sfyow **in the same change** that the
  workflow starts running, not before and not after. Two
  schedulers both believing they own the nightly build is a worse
  state than either alone.
* `build.sh` stays the thing that builds one image. It should not
  be reimplemented in YAML; the workflow calls it per image.

### Phase 3. Failure files an issue

Status: Not started
Effort: medium. Model: sonnet.
Depends on: Phase 2.

Signal A from Q3.

* `tools/file-build-failure-issue.sh`, taking the image name and
  the run URL, following `canary.yml:95-155` but keyed on a
  per-image label. In `tools/`, not inline in the workflow.
* A follow-on job with `if: failure()` and `issues: write`.
* Close or comment the issue when the image next builds, so a
  fixed image does not leave a stale open issue behind.

### Phase 4. Freshness watchdog

Status: Complete
Effort: medium. Model: sonnet.
Depends on: nothing. Independent of Phase 2.

Signal B from Q3, and the highest value-per-hour phase in this plan.
It is a scheduled job, a `HEAD` request per image, and a threshold.

* `tools/check-image-freshness.sh`: for each image in the default
  list, `HEAD https://images.shakenfist.com/<image>/latest.qcow2`,
  compare `Last-Modified` against the threshold, and report every
  stale image rather than exiting on the first one. Follow the house
  style already set by `tools/check-block-device-config.sh`:
  `errexit`, `nounset`, `pipefail`, an explanatory header, a usage
  line, and exit 0/1/2 rather than 0/1.
* Threshold 72 hours, as a named constant with the reasoning beside
  it. Nightly builds mean a healthy image is under 24 hours old, so
  72 tolerates two consecutive misses before it speaks -- long
  enough not to cry wolf over one bad night, short enough that the
  sixteen day outage would have been reported on day three.
* A `--list-images` flag on `build.sh`, printing the default list
  and exiting before the `apt-get` preamble, so the watchdog can
  derive the list rather than duplicate it. A watchdog with its own
  copy stops watching anything added to the real one, and does so
  silently. Everything before the preamble is safe to run anywhere,
  as an unprivileged user, so the flag adds no requirement on where
  the watchdog runs.

  This flag was originally an item of Phase 1. It moved here on
  2026-09-13 so that Phase 4 does not wait on Phase 1: the flag is
  three lines at the top of the script and shares nothing with the
  failure isolation work further down, while Phase 1 is surgery on
  the script that produces every image the fleet boots from.
  Landing the detector first is the same argument the parent plan
  makes for putting detection ahead of the migration, one level
  down -- doing the surgery first is a smaller version of the
  experiment that produced the outage.
* `.github/workflows/image-freshness.yml`, this repository's first
  workflow: a `schedule` trigger, `issues: write`, calling the script
  and upserting a single issue that lists everything stale. One issue
  for the run, not one per image.

Two things were confirmed on 2026-09-13 before writing this.

`Last-Modified` is usable. The published `latest.qcow2` is a symlink
and the server follows it, so the header carries the target's
modification time and differs per image -- `debian:13` reported
`Sat, 12 Sep 2026 05:17:21 GMT` while `ubuntu:22.04` reported
`05:05:55`. Nothing needs to parse a directory listing or a filename
datestamp.

**Run this on a GitHub-hosted runner, not a self-hosted one.** The
phase exists to detect the build host having stopped, so a watchdog
sharing infrastructure with the build is worth less than one that
does not; and this repository is public, so hosted minutes are free
and a hosted runner is the weaker trust boundary of the two. This is
a deliberate departure from the fleet's `self-hosted-runners`
criterion, which does not currently apply here -- see Phase 5 -- so
mark the line `audit-ok: github-hosted-runner` with the reason. If
Phase 5 brings this repository into audit scope, the exemption is
then already stated where the criterion looks for it.

Doing this before Phase 2 is deliberate. It is independent of every
mechanism question, it would have caught the outage that prompted
this plan, and it keeps working no matter what Phase 2 eventually
decides.

### Phase 5. Repository standards

Status: Not started
Effort: medium. Model: sonnet.

Close the gap between this repository and the rest of the fleet.
Each item is separable; none blocks the others.

* `.pre-commit-config.yaml` running shellcheck and trailing
  whitespace checks, plus a CI workflow running the same.
* The outstanding shellcheck findings in `build.sh`. This plan said
  91; it was 136 on master before Phase 1 and 125 after, so re-count
  rather than trusting any of those numbers. Expect to suppress some
  deliberately; a suppression with a reason is a result, a blanket
  disable is not.
* `AGENTS.md` is four lines and says image builds are triggered
  "manually or via cron", which Phase 2 makes wrong. Update it
  when Phase 2 lands, not before.
* Decide whether this repository joins the fleet consistency
  audit. It is on the excluded list as a historical archive, which
  it demonstrably is not -- it is actively built from every night
  and the fleet's CI depends on its output. Changing that is a
  change to shakenfist/development's `docs/audits/README.md` and
  `REPO_OVERRIDES`, and it should be a deliberate decision rather
  than a side effect of this plan.
* Renovate configuration, and the `master` versus `develop`
  default branch question, both follow from that decision.

### Phase 6. Push audit

Status: Not started

Per the push audit shared block above. There is no `PUSH-AUDIT.md`
in this repository, so this phase either creates one -- the better
outcome -- or records its absence and says what was done instead.

The audit reads the accumulated diff of every phase against
`master`, not the diff of the last phase alone. Record each
phase's merge commit in the `Merged` column above as it lands;
once merged, a diff against `master` is empty and the range is not
reliably recoverable afterwards.

Specific things for this repository's audit to look for, drawn
from the three defects in the Situation section: a release codename
that does not match the element it is paired with; a variable
exported before the value it interpolates is assigned; and a
`sudo` invocation that assumes an environment variable survives
into it.

## Administration and logistics

### Success criteria

* A single failing image no longer prevents any other image from
  building, demonstrated by a run in which one image fails and the
  rest publish.
* An image that fails to build produces a GitHub issue without a
  human looking for it.
* An image that stops being rebuilt for any reason -- including
  the build never running -- produces a GitHub issue within 72
  hours, from a check that does not depend on the build system or
  on sfyow.
* The operating system the images are built on is a value someone
  chose and can see, not a property of whichever machine happened
  to run the build.
* The cron entry on sfyow is gone, and exactly one scheduler owns
  the nightly build.
* `AGENTS.md` and `ARCHITECTURE.md` describe how builds are
  actually triggered once Phase 2 lands.

### Future work

* **Boot-test published images.** Nothing checks that a published
  image boots. This is the largest remaining quality gap in this
  repository and it is deliberately out of scope here only because
  it is a plan of its own.

  The other half of this item -- checking that an image is the
  distribution it claims to be -- was delivered on 2026-09-13 as the
  `verify-release` element, under phase 2 of shakenfist/development's
  `PLAN-image-supply-chain.md`. It needed no boot: `finalise.d` hooks
  run in the chroot while the image is being assembled, so the check
  reads `/etc/os-release` in place.

  This item used to claim the mislabelling "would have been caught in
  one night by a check that booted the image and read
  `/etc/os-release`". That was wrong in a way worth recording,
  because it is the reason the element is built the way it is.
  Nothing in that build disagreed with itself: `build.sh` passed
  `DIB_RELEASE=bullseye`, diskimage-builder built bullseye, and the
  image honestly reported bullseye. Any check comparing the image
  against what the build asked for would have passed every night for
  two years and two months. What was wrong was the name it was
  published under, so that is what the element compares against.
* **A Fedora image that builds.** `fedora:43` and `fedora:44` have
  never built successfully -- both fail on `grpcio-tools` needing
  a C++ compiler. Fedora is currently absent from the default list
  entirely, and the `fedora` convenience symlink points at
  `fedora:42`, which is end of life and frozen.
* **The convenience symlinks.** `debian` points at `debian:12` and
  should probably point at `debian:13`; `debian-docker` points at
  `debian-docker:12`, which served Debian 11 for two years;
  `fedora` has nowhere good to point until the item above is done.
* **Retention and the size of the published site.** The repository
  is 166GB. Retention keeps the seven newest builds per image,
  which is a reasonable default nobody has revisited against what
  the images are actually used for.
* **Publishing checksums and signatures.** Consumers currently
  fetch `latest.qcow2` over HTTPS with no way to verify what they
  got.

### Bugs fixed during this work

The issue tracker for this repository holds one closed issue
(#1, an in-cloud pollinate seeding service for Ubuntu images) and
nothing open, so there was no related work to fold in.

Fixed in shakenfist/images#2, before this plan was written:

* Nightly builds producing nothing for sixteen days, caused by
  `ubuntu:20.04` failing under `bash -e` at the head of the build
  order.
* `grub-install: error: unknown filesystem` on every guest with
  grub older than 2.12, caused by e2fsprogs 1.47 enabling
  `orphan_file` and `metadata_csum_seed` by default on the
  upgraded build host. Fixed with `block-device-compat.yaml`.
* `debian-docker:12`, `debian-gnome:12` and `debian-xfce:12` built
  from bullseye while naming the `debian-12-extras` element, since
  2024-07-06.

Related work tracked elsewhere: shakenfist/private-ci#38 collates
where the fleet still consumes obsolete images, #39 moves the CI
dependencies disk off `debian:11`, and #40 retires the unused
`debian-11` runner label.

### Back brief

Before executing any step of this plan, please back brief the
operator as to your understanding of the plan and how the work you
intend to do aligns with that plan.
