# Phase 2: move the build off sfyow

Phase 2 of [PLAN-image-build-modernisation.md](PLAN-image-build-modernisation.md).
Written 2026-10-24. Planned at high effort, and execute it at high
effort too. The phase moves the machine that produces every image the
fleet boots, the host that serves them, and a credential that can write
to a public download site.

This phase is large and spans two repositories, so it has a file of its
own. The template's note for this repository allows that, although the
other phases are sections of the master plan.

## Scope

**In:**

* A GitHub Actions workflow, `.github/workflows/image-build.yml`, that
  builds each image in its own job on an ephemeral sfcbr VM runner. The
  runner's operating system is named in the workflow.
* Publishing from those runners to sfyow over the WAN, with a
  credential that can do nothing else.
* The `build.sh` changes that publishing from another host needs.
  `build.sh` still builds one image per call; the workflow calls it, and
  the build logic is not rewritten in YAML.
* Retiring sfyow's cron job on the same day the conductor starts
  dispatching the workflow nightly, plus the 33fl and private-ci changes
  that involves (D2, D10).
* A watcher outside this repository for the failure the move creates:
  the nightly dispatch stopping without anyone noticing (D8).
* Documentation for the new mechanism, replacing the cron mechanism.

**Out:**

* Filing issues for failed builds (Signal A). That is Phase 3, which
  depends on this phase. Do not fold it in.
* Pinning diskimage-builder to a reviewed commit rather than upstream
  `master`. This is in the spirit of the mission, but it changes what is
  built rather than where. It is recorded under the master plan's
  Future work.
* Running image builds on pull requests. That would be valuable, but it
  is a separate trust decision (D2). Recorded under Future work.
* Anything that changes image contents: elements, release codenames,
  `block-device-compat.yaml`.
* Shellcheck clean-up of `build.sh`, which belongs to Phase 5.

## What the survey found

The survey was read on 2026-10-24 against images 8a179b6, 33fl
6e791193, private-ci 414b9d9, actions a729579 and development 724a233.

**Q1 now has an answer.** The master plan left Phase 2 blocked because
nobody knew whether a remote builder could reach sfyow cheaply. On
2026-10-24 the operator decided: build on the sfcbr CI cluster and push
over the WAN. The link is fast enough, and a slow copy is acceptable.
That settles Q1 in favour of its default, the split roles, and the
fallback (building in a container on sfyow) is not taken.

**There is a new reason to leave sfyow, beyond the one the plan gave.**
On 2026-10-24 the CentOS 9 Stream build, running as root in a chroot on
sfyow, ran `service auditd reload` from a package scriptlet. That
flushed the host's own audit rules: an internet-facing host was left
unaudited. 33fl now starts the build under
`setpriv --bounding-set -audit_control` (`33fl/sfyow-images.yml`, the
cron task; `33fl/docs/sfyow-images.md`, "The build cannot touch the
host's audit rules"). That is a sound mitigation for one capability.
The general point is that an image build is root running arbitrary
distribution scriptlets, and the web host is the wrong place for it. On
an ephemeral VM the same flush would hit a machine that is deleted an
hour later.

**The cron job is managed in 33fl, not by hand.** `33fl/sfyow-images.yml`
owns the job line, the two Loki environment lines, and the checkout at
`/srv/sf-images/images`. It also runs `./build.sh --list-images` as a
deploy-time assertion. So retiring the cron job is a 33fl pull request,
and the 33fl deploy is what makes it real.

**What the runners are** (facts gathered by a survey sub-agent, with the
key ones re-checked by the management session):

| Fact | Value | Source |
|---|---|---|
| Labels | `[self-hosted, vm, debian-13, <size>]` | fleet-wide usage |
| Size `m` | 4 vCPU, 8192 MB, 200 GB boot disk | `private-ci/conductor/provisioner.py:89-156` |
| Size `xl-bigdisk` | 8 vCPU, 16384 MB, 600 GB, the largest | same |
| Missing size | silently becomes `xs`, so always name one | `development/docs/audits/workflow-standards.md:94-97` |
| Lifetime | `--ephemeral`, one job per VM, powered off and deleted after | `private-ci/templates/userdata.yaml.j2:110-119`, `conductor/collector.py:1382-1398` |
| Kind | full KVM instance, not a container; passwordless `sudo` in practice | `provisioner.py:4198-4213`; fleet jobs run `sudo apt-get` |
| Which repositories | the whole `shakenfist` org, no per-repository allowlist | `userdata.yaml.j2:110`, `conductor/github.py:508-512` |
| Egress | NAT through the hypervisor, so all sfcbr traffic leaves from sf-1's address; apt and HTTP(S) go through a caching proxy on the home LAN; the home LAN is reachable | `private-ci/ARCHITECTURE.md:1860-1881`, `userdata.yaml.j2:4-7,62-66` |
| Secrets on every VM | `/srv/github/id_ci`, the key that reaches every node in the CI mesh, plus a per-namespace sfcbr API key | `userdata.yaml.j2:18-57`, `actions/docs/ci.md:97-109` |
| Fork protection | none in the conductor; each workflow carries its own guard | `actions/docs/ci.md:97-109` |
| Precedent for a gated secret | the `audit-write` environment: deploys from `main` only, no reviewers because a schedule has nobody to approve it, ephemeral VM | `development/.github/workflows/consistency-audit.yml:225-262` |
| Precedent for publishing to another host with a secret | none in the fleet | -- |

**There is a circularity, and it is not new.** The `debian-13`
runner label is rebuilt nightly by the conductor from `debian:13`,
which resolves to images.shakenfist.com, the site this repository
publishes (`private-ci/conductor/imagebuilder.py:60-66`;
`private-ci/docs/plans/PLAN-thin-ci-images.md`). So the builder boots
from yesterday's output of the build. What contains it is that the label
only moves after a test instance passes its checks
(`actions/ansible/ci-image.yml:427-622`), so a broken `debian:13` fails
the conductor's nightly and leaves the previous label in place. Risk R3
covers what is left over.

**Things in `build.sh` that assume it runs on sfyow:**

* The self-update (`build.sh:144-216`) runs `git pull --ff-only origin
  master` and re-executes. In an Actions checkout that is wrong in both
  directions. A dispatch from a branch would pull `master` over the
  branch under test, and a scheduled run already has exactly the commit
  it should build.
* Publishing is a local `rsync` to `/srv/www/images.shakenfist.com/`
  (`build.sh:784-790`), and it copies the whole of
  `/srv/sf-images/output`, not only the label just built.
* Retention `cd`s into the published directory and runs `ls`, `head`
  and `rm` there (`build.sh:795-811`). None of that works against a
  remote host.
* The `latest.qcow2` symlink is made in the local output tree and
  carried across by `rsync --links` in the same transfer as the image
  (`build.sh:775-786`). The transfer has no ordering guarantee, so a
  consumer could see `latest.qcow2` before the file it points at has
  finished arriving. On a local disk that window is milliseconds. Over a
  WAN it is the length of a 1.4 GB upload.
* The `/srv/sf-images/{output,cache,tmp}` paths work unchanged on a VM
  with `sudo`. The cache is cold on every run because the VM is new,
  which costs download time and nothing else.

**Nothing in 33fl's alerting reads the image build streams.** A grep of
`33fl` for `image-build` in YAML, Jinja and JSON finds only an unrelated
comment in `conductor.yml`. The `host` label on `{job="image-build"}`
changing from `sfyow` to an ephemeral VM name therefore breaks no rule.

**Two stale claims in the master plan, corrected at source in this
commit:**

* Phase 5 said the repository has no pre-commit, CI, renovate or
  secret scanning, and that it is excluded from the audit. a75db0b
  (#20) shipped pre-commit, `ci.yml`, renovate, gitleaks and CodeQL,
  and the repository is now in the audit matrix, scoped to
  `eol-distro`. #19 holds the two settings that remain. The Phase 5
  section has been rewritten to match.
* Phase 2's section said the phase was blocked on Q1. It now records
  the decision and links here.

## Decisions

**D1. Build each image on its own `[self-hosted, vm, debian-13, m]`
runner.** The builder's distribution becomes the string `debian-13` in
a reviewed file, which is the point of the phase. It is the same
release sfyow runs today, and that is deliberate. The move changes
where the images are built and nothing else, so any difference in the
images after cutover is down to the environment and not to a new
release. Changing to a new builder release later is a separate one-line
pull request, which is exactly the kind of change the plan wanted to be
reviewable. `m` (200 GB) is enough disk for one image with room to
spare. `m-bigdisk` would be paying for space no single-image job uses.
Step 2d measures the real numbers and moves the size if they say so.

**D2. Only `workflow_dispatch` triggers the workflow. There is no
`schedule`, no `pull_request` and no `push`.** The nightly run is
dispatched by the conductor on maui, the same way, and from the same
module, as 33fl's nightly reports (`conductor/reports.py` in
private-ci). GitHub's `schedule` trigger is best effort, and from
2026-08-26 the fleet found it unusable: 33fl's reports ran three hours
late on two nights and were skipped entirely on two others, and an hourly
cron in client-python delivered six of its twenty-four firings. A
`workflow_dispatch` starts within seconds, and a dispatch-only workflow
is also immune to GitHub disabling the schedules of a quiet repository.
This was corrected on 2026-10-27, before cutover; the plan first said
`schedule`. Do not add a `schedule` as a backup. It would eventually
fire hours after the conductor's run and rebuild the same night again.

There is no `pull_request` and no `push`. Every VM runner holds
`id_ci`, so any code a fork can get onto one reaches the whole CI mesh.
A build job also runs as root. The publish credential sits behind a
GitHub environment, `images-publish`. Its deployment branch policy
allows `master` only, and it has no required reviewers, for the same
reason `audit-write` has none: a nightly run has nobody to approve it. The
publishing step also carries `if: github.ref == 'refs/heads/master'`, so
a dispatch from a branch shows the step as skipped rather than as a
failed environment check. A dispatch can still build any branch with
`publish: false`, and that is how a `build.sh` change is tested before it
merges.

**D3. The credential can only write into the document root, and only
from sfcbr.** A new SSH key pair. The private half goes into
`images-publish` as an environment secret, together with a pinned
`known_hosts` line for sfyow. The pinned line is taken from sfyow
itself; `ssh-keyscan` at run time would trust whoever answers. On sfyow,
33fl adds an unprivileged user that owns the document root (or shares a
group with it), with an `authorized_keys` entry of the form
`restrict,from="<sf-1 egress address>",command="rrsync <docroot>"`.
`rrsync` confines the key to rsync inside that directory. `from=` pins
it to the one address all sfcbr egress leaves from (survey, Egress), so
even a leaked key is useless from anywhere else. No part of the
credential or the address enters this public repository.

**D4. `build.sh` publishes to an rsync destination named by
`SF_IMAGES_PUBLISH_TARGET`, and SSH comes from `RSYNC_RSH`.** rsync
reads `RSYNC_RSH` natively, so `build.sh` learns nothing about SSH. The
same code publishes to a local path or to `user@host:path`, so the
tests can drive the real publish code against a temporary directory.
Until cutover, an unset target defaults to today's local path, so the
sfyow cron keeps working without a coordinated 33fl change. At cutover
(step 2e) the default is removed, and a publishing run with no target
fails before it builds anything. That is the "refuse to guess" stance
#22 took for the other inputs.

Publishing changes in three ways:

* only the label just built is sent, not the whole output tree;
* the dated image and its log go in one rsync, and `latest.qcow2` goes
  in a second rsync afterwards, so the symlink never points at a file
  still in transit;
* retention moves into rsync: list the label's remote directory with
  `rsync --list-only`, choose what to keep, and delete the rest with
  `rsync -r --delete --existing --ignore-existing` from a staging
  directory of empty placeholder files named for the keepers.

**D5. Retention stays in `build.sh` rather than becoming a timer on
sfyow.** This is the decision most likely to be argued with. A
server-side `find`-based timer would be simpler to write, and it would
leave the credential unable to delete. Keeping retention here was chosen
for three reasons. It stays in one place, with one owner, under the
tests in `tools/`. It runs the same code path before and after cutover,
so the cutover changes configuration and not behaviour. And a credential
that can overwrite every image on the site gains little real power from
also being able to delete them. The danger is the `--delete`
idiom itself: a listing that parses as empty would turn "keep seven"
into "keep nothing". So retention refuses to run unless the keep list
contains the image this run just published and `latest.qcow2`, and the
tests prove that refusal (DoD).

**D6. The self-update is switched off by an explicit flag,
`--no-self-update`, and removed once sfyow no longer runs the build.**
The workflow does not rely on noticing `GITHUB_ACTIONS` in the
environment. #22's rule is that `build.sh` refuses to guess, and this is
a guess. The flag is how the cron and the workflow can both run the
script during the transition. Once the cron is gone (step 2f, after the
soak), nothing pulls, and the self-update block, the flag and
`tools/test-self-update.sh` are deleted together. They were, on
2026-10-30; commands quoted elsewhere in this plan with the flag are
history, and `build.sh` now refuses it as an unknown flag.

**D7. The matrix comes from `build.sh --list-images`.** A first job on
`[self-hosted, static]` turns the list into JSON. It is small and
changes nothing, which is what static runners are for. The build job
runs with `fail-fast: false`, `max-parallel: 4` and `timeout-minutes:
120`. A parallelism of four keeps a nightly build from taking fourteen
`m` VMs (56 vCPU) away from the fleet's CI at once. The timeout is a
first guess for a cold-cache build of the desktop images, and step 2d
replaces it with a measured number. (2d set it to 60 minutes: the
slowest build plus the slowest upload, with margin. See *Results*.) A
`workflow_dispatch` input `images` (empty means the whole list) and a
boolean `publish` (default `false`) let one image be rebuilt by hand.
The conductor's nightly dispatch passes `publish: true`.

**D8. Moving the trigger out of sfyow's cron creates new silent
failures, so this phase adds a watcher outside the chain that runs the
build.** The nightly build now depends on the conductor dispatching,
on GitHub accepting the dispatch, on VM runners picking up the jobs and
on the runners shipping logs. Two watchers cover that chain:

* The conductor's dispatch history. 33fl's existing
  `report-dispatch-stale` rule alerts per workflow on
  `conductor_report_last_dispatch_timestamp_seconds`, so a conductor
  that stops dispatching `image-build.yml` alerts like a stalled report.
  This needs nothing new beyond the conductor target.
* A Grafana alert rule in 33fl, beside `image-nightly-stale` in
  `config/maui/grafana/alerting/rules.yml`, on the `Loki (sfyow)`
  datasource. It fires when no `{job="image-build-summary"}` line has
  arrived for 72 hours. It catches every way the chain can fail after
  the dispatch: GitHub dropping it, runners never starting it, or log
  shipping breaking. That makes D9 a precondition for it.

The master plan listed "a second watcher outside this repository" under
Future work. This phase makes it necessary, so it is pulled in. (The
plan first framed D8 around GitHub's 60-day schedule disable. That no
longer applies to a dispatch-only workflow; D2 records the change.)

**D9. Runners keep shipping to Loki.** `SF_IMAGES_LOKI_URL` and
`SF_IMAGES_LOKI_TENANT` become secrets in the `images-publish`
environment, because the URL is a private hostname and this repository
is public. Runners can reach the home LAN. However, the bootstrap exports
`HTTP(S)_PROXY` with no `NO_PROXY`, and `push_log_to_loki`'s `urllib`
honours both. Step 2d therefore has to show an `image-build-summary`
line arriving from a runner, rather than assume it. If the proxy will
not carry it, the fix is a `NO_PROXY` entry for the Loki host on the
`build.sh` step, not a change to `build.sh`.

**D10. The cutover happens on one day, in a fixed order, across three
repositories.** The master plan says to retire the cron "in the same
change" that the workflow starts. Across three repositories, one change
means one day:

1. **33fl** merges and deploys. It removes the cron job and its two
   environment lines, and adds the D8 Loki rule. Deploy it after that
   day's 05:00 UTC cron run has published.
2. **private-ci** merges and the conductor is redeployed, with
   `image-build.yml` as a dispatch target. A new target is primed, not
   fired, so its first dispatch is the next 01:30 Canberra slot, about
   ten hours after a cron run at 05:00 UTC. That is no gap at all.
3. **images** merges. It removes `build.sh`'s local publish target, so
   it must not merge while the cron still runs, and carries the docs.
   Nothing in it is needed for the first dispatch, because `master`'s
   workflow already publishes when asked.

Done in that order, the worst case is one night with no build, which
the 72-hour watcher tolerates. With the conductor first, the worst case
is two builders publishing into the same directories on the same day.
Rollback is reverting private-ci first, then 33fl, and redeploying
both.

**D11. The `build.sh` step under `sudo` names every variable it
passes.** It runs as `sudo --preserve-env=SF_IMAGES_PUBLISH_TARGET,RSYNC_RSH,SF_IMAGES_LOKI_URL,SF_IMAGES_LOKI_TENANT ./build.sh --no-self-update "<image>"`.
A `sudo` call that assumes an environment variable survives is one of
the three failure shapes this plan's push audit hunts for. Under D4,
after cutover, a target lost to `sudo` is a refusal rather than a
silent local publish.

## Step plan

PR A is 2a and 2b, in this repository. PR B is 2c, in 33fl, together
with GitHub settings. 2d is operations run by the management session.
The cutover pair is 2e, and the clean-up pair after the soak is 2f.
Each lettered step is one commit, unless its brief says otherwise.

| Step | Effort | Model | Isolation | Brief for sub-agent |
|------|--------|-------|-----------|---------------------|
| 2a | high | opus | worktree | **Make `build.sh` able to publish from another host.** In `build.sh` only, plus a new `tools/test-publish.sh`. (1) Add `--no-self-update` to the flag loop at `build.sh:103-122`, which skips the self-update block at `:193-216`. Follow the existing flag style and the usage line at `:115`, extend `tools/test-build-arguments.sh` for the new flag, and keep the self-update's re-exec passing `original_args` unchanged. (2) Replace the publish block at `:783-814` as follows. Read `SF_IMAGES_PUBLISH_TARGET`, defaulting for now to `/srv/www/images.shakenfist.com/`, with a comment saying the default is removed at cutover and why. Publish **only** `${outdir}`, not `/srv/sf-images/output`. Use two rsyncs: first everything in `${outdir}` except `latest.qcow2` into `${target}${label}/`, then `latest.qcow2` alone. Drop `-c` (only new files are ever sent) and `--progress` (it floods the Actions log). Do not reference SSH anywhere; rsync takes `RSYNC_RSH` from the environment. (3) Rewrite the retention block at `:795-811` to work against the target by rsync alone: `rsync --list-only "${target}${label}/"`, parse the `*.qcow2` names other than `latest.qcow2`, keep the newest seven by name sort (as now) plus each keeper's `.log` and `latest.qcow2`, then delete the rest with `rsync -r --delete --existing --ignore-existing <staging>/ "${target}${label}/"`, where the staging directory holds an empty file per keeper and a placeholder for `latest.qcow2`. **Refuse to delete**, warn, and skip, unless the keep set contains the file this run just published and `latest.qcow2`. Retention stays non-fatal, as now (`:792-794`). (4) `build_one()` runs with errexit off (read its header at `:584-591`), so every new fallible command is checked by hand and returns 1 with a `push_log_to_loki` failure record, as the surrounding code does. Do not use `pipefail`. (5) `tools/test-publish.sh`: extract the publish and retention code from `build.sh` at run time, the way `tools/test-run-summary.sh` extracts its block, so the shipped text is what gets tested, and drive it against a temporary directory as the target. Cases: one publish lands image, log and symlink; the symlink is sent in a separate, later rsync (wrap `rsync` in a shim that logs its argument lists); retention with 9 images keeps 7, their logs and `latest.qcow2`; retention with 3 images deletes nothing; a listing that yields nothing deletes nothing and warns; a keep set missing the just-published image deletes nothing. Confirm each case fails with its fix reverted, and say so. (6) `bash -n`, `tools/run-tests.sh`, `pre-commit run --all-files`, and a shellcheck count on `build.sh` no higher than 126 (`docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable build.sh`). You cannot build an image. Say what a real run should do differently, and do not claim it works. |
| 2b | high | opus | none | **Add `.github/workflows/image-build.yml`, dispatch-only.** Triggers: `workflow_dispatch` only, with inputs `images` (string, default empty, meaning `build.sh --list-images`) and `push` (boolean, default false). **No** `schedule` yet; 2e adds it. **No** `pull_request` or `push` trigger, ever (D2). Top-level `permissions: contents: read`. Job 1, `list`, on `[self-hosted, static]`, `timeout-minutes: 10`: run `tools/image-matrix.sh` (new, small, under `tools/` per the five-line rule), which prints `build.sh --list-images`, or the `images` input, as a JSON array to `GITHUB_OUTPUT`. Job 2, `build`, `needs: list`, `runs-on: [self-hosted, vm, debian-13, m]` with a comment saying this line **is** the declared builder OS and why it matches sfyow (D1), `strategy: {fail-fast: false, max-parallel: 4, matrix: {image: fromJSON(...)}}`, `timeout-minutes: 120` marked as a first guess, and `environment: images-publish` only when publishing. Use a separate job or an expression so a `push: false` dispatch from any branch needs no environment, and add `if: github.ref == 'refs/heads/master'` to the publishing path (D2). Checkout with `persist-credentials: false`. A step writes the SSH key and the pinned `known_hosts` line from secrets into `${RUNNER_TEMP}` with mode 600 and exports `RSYNC_RSH="ssh -i <key> -o IdentitiesOnly=yes -o UserKnownHostsFile=<kh> -o StrictHostKeyChecking=yes"`. Put that in `tools/`, not inline, if it exceeds five lines. The build step runs exactly as D11 states, passing `--no-push` when not publishing. A final `if: always()` step shreds the key. English-sentence `name:` on every job and step. Concurrency: `group: image-build-${{ github.ref }}`, `cancel-in-progress: false`. Read `.github/workflows/image-freshness.yml` and `ci.yml` for house style, and `development/.github/workflows/consistency-audit.yml:225-262` for the environment precedent. Confirm `actionlint` passes through pre-commit. |
| 2c | high | opus | worktree | **33fl: a publish-only account on sfyow.** In the 33fl repository (`/srv/kasm_profiles/mikal/vscode/src/mach33labs/33fl`), extend `sfyow-images.yml`, or add a playbook beside it if that reads better, and document in `docs/sfyow-images.md`. Create an unprivileged user (suggested name `sf-images-publish`) that can write to `/srv/www/images.shakenfist.com`. Look at `sfyow-web.yml` and `docs/sfyow-web.md` for who owns the docroot now, and prefer a shared group over changing ownership, so apache and today's root-run cron keep working. Install `rrsync` (Debian ships it in the `rsync` package, as `/usr/bin/rrsync` on trixie; verify that). Give the user an `authorized_keys` entry `restrict,from="<sf-1 egress>",command="/usr/bin/rrsync /srv/www/images.shakenfist.com" <pubkey>`. The public key and the sf-1 address are variables in 33fl's normal secret and inventory handling. Find how `conductor.yml` handles `sfcbr_ci_images_key` and do the same. **Do not** remove the cron job in this step; that is 2e. The operator generates the key pair. The management session then creates the `images-publish` environment and its secrets (`IMAGES_PUBLISH_SSH_KEY`, `IMAGES_PUBLISH_KNOWN_HOSTS`, `IMAGES_PUBLISH_TARGET`, `SF_IMAGES_LOKI_URL`, `SF_IMAGES_LOKI_TENANT`) with `gh`, after asking, because they are outward-facing settings. Deployment branch policy: `master` only, no reviewers. **Set or check the policy before adding any secret.** GitHub creates an environment named by a workflow the first time a job uses it, with no branch policy. So a `master` dispatch made after PR A merges may already have created `images-publish`, unprotected. |
| 2d | -- | -- | management session | **Prove it before switching anything.** (0) Dispatch `image-build.yml` from a branch with `images: debian:13`. This settles whether an empty `environment:` name means no environment. If the job will not start, split `build` into two jobs gated by `if:` on the ref, one with the environment and one without, before going on. (1) Dispatch on `master` with `publish: false` and the whole list. Record each image's duration, its peak disk use (add a `df -h` step if the logs do not show it) and the result. Set `timeout-minutes` to the slowest build plus the slowest upload, with margin (the job includes the upload on a publishing run), and change the runner size if disk or a DIB tmpfs `ENOSPC` calls for it. For tmpfs, prefer `DIB_NO_TMPFS=1` on a 200 GB disk over a bigger VM. (2) Confirm an `{job="image-build-summary"}` line from a runner host arrived in Loki (D9). (3) Dispatch `publish: true, images: debian:13`. Confirm that `curl -sI https://images.shakenfist.com/debian:13/latest.qcow2` shows the new `Last-Modified`, that the served file's size matches the image rsync sent (the job logs no sha256, and rsync verifies a whole-file checksum on every transfer), and that retention left seven images. (4) Write the measurements into this file under *Results*. Then **stop for the operator's go-ahead** on cutover. |
| 2e | medium | sonnet | worktree | **Cutover, as three pull requests merged the same day in D10's order: 33fl, then private-ci, then images.** Prepare all three; merging and deploying are the operator's. *33fl:* remove the `sfyow image build` cron entry and the `SF_IMAGES_LOKI_URL`/`SF_IMAGES_LOKI_TENANT` environment lines from `sfyow-images.yml`, with `state: absent` so the deploy removes them rather than merely forgetting them. Leave the checkout task in place until 2f. Add the D8 rule to `config/maui/grafana/alerting/rules.yml`, modelled on `image-nightly-stale`, on the `Loki (sfyow)` datasource (uid `cg54qgsjqi1jec` in `templates/grafana-datasource-provisioning.yml.j2`): it fires when `count_over_time({job="image-build-summary"}[72h])` is zero. Update `docs/sfyow-images.md`. *private-ci:* add `shakenfist/images` `image-build.yml` on `master`, with `publish: true`, to `conductor/reports.py`'s `TARGETS`. Give a target an optional `inputs` key, which `_dispatch_target` passes to `github.dispatch_workflow` (it already takes `inputs`). The dashboard's "Run reports now" button (`dispatch_now`) must not fire the image build: a full rebuild and publish uses the fleet for hours and is not a report. Correct the comments this makes false: the module docstring, "All four run on the static claude-code runner", and "every target is in the same repository". Extend `conductor/tests/test_reports.py` and `docs/nightly-report-dispatch.md`. Check, and report rather than change, whether the conductor's GitHub credential can dispatch workflows in `shakenfist/images`. *images:* `image-build.yml` stays dispatch-only; correct its header, which says the cron still keeps the site fresh, to say the conductor dispatches it nightly, and that a `schedule` must not be added (D2). Remove the `SF_IMAGES_PUBLISH_TARGET` default from `build.sh`, so a publishing run with no target exits 2 before the preamble, and extend `tools/test-build-arguments.sh` for that. Move `export DIB_NO_TMPFS=1` into `build_one()` beside `TMP_DIR`, and drop it from the workflow's `env:` and `--preserve-env`, so that a hand-run `build.sh` on a small VM builds the way CI does. Replace `docs/build-host.md` with `docs/nightly-build.md`, covering how the nightly is dispatched and by what, how to rebuild one image by dispatch, where logs go (Actions, `.qcow2.log` beside the image, Loki), the publish account, scratch space and `DIB_NO_TMPFS` (carried over from `docs/build-host.md`'s "Scratch space is on disk" section), that a busy fleet can stretch a nightly to hours, and recovering when the `debian-13` runner label is broken (R3). Update the README's three links to it. Change `AGENTS.md:5`, which says "manually or via cron", and its `docs/build-host.md` link, as Phase 5 deferred to this phase. Change `ARCHITECTURE.md`'s paragraph that says the script runs nightly from cron. |
| 2f | medium | sonnet | none | **After three clean nightly runs, remove what only the cron used.** *images:* delete the self-update block, the `--no-self-update` flag, its use in `image-build.yml`, `tools/test-self-update.sh` and its mentions in docs (D6). *33fl:* remove the `/srv/sf-images` checkout tasks and the `--list-images` assertion from `sfyow-images.yml`, keeping the publish account. Decide with the operator whether `/srv/sf-images/{output,cache}` is deleted, and record what was freed. |

## Risks and mitigations

**R1. The blast radius moves from sfyow to the CI mesh.** Every night
the build runs diskimage-builder from upstream `master`, plus whatever
package scriptlets fourteen distributions ship, as root. Today that
happens on the internet-facing web host. After this phase it happens on
a VM holding `id_ci`. That is a real change, and the plan accepts it:
the code is the same code already being run, nothing reaches the runner
except from `master` (D2), and sfyow is no better a place to be
compromised from. Pinning DIB is the real mitigation, and it is Future
work. *Who checks:* the push audit phase, under checklist item 3.

The publish key is exposed in the same way, and that is also
accepted. On a publishing run, the key and `RSYNC_RSH` are written
before the build step, so the root-run build can read them. `from=`
and rrsync stop the key being used anywhere else, but not from the VM
itself, where it can overwrite or delete the site. PR #23's review
suggested publishing from a later step, through a publish-only mode in
`build.sh`. That was declined because it narrows the window without
closing it. A root scriptlet can leave a process behind on the VM that
waits for the key to appear in the later step, and nothing between
steps would stop it. What would close it is not running untrusted
code as root on the machine that holds the key: building in a
throwaway VM nested inside the job, or publishing from a second job on
a fresh VM that only downloads the artifact. Both are larger changes
than this phase, and either can be added later without reworking the
publish code.

**R2. A wrong keep list deletes published images.** *Mitigation:* the
refusal in D5 and the 2a test cases that prove it. 2d step 3 then checks
retention on the real site with one image before fourteen run.

**R3. A broken `debian:13` prevents the build that would fix it.** The
conductor's check gate (survey) catches most of this. What it misses is
an image that boots and passes its checks but breaks DIB. *Mitigation:*
`docs/nightly-build.md` (2e) documents rolling the label back with
`sf-client label update` to the previous blob, and dispatching on that.
The freshness watchdog reports the stall on day three either way.

**R4. Two writers during 2d and before cutover.** The sfyow cron and a
dispatch can both publish `debian:13` on the same day, with the same
dated filename. *Mitigation:* 2d publishes one image. rsync writes
through a temporary file and renames, so the last writer wins with a
complete file. D10 governs the cutover itself.

**R5. Log shipping fails behind the proxy.** *Mitigation:* 2d step 2
is a gate, and D9 names the fix.

**R6. sfcbr capacity.** Fourteen VM jobs a night compete with the
fleet's CI. *Mitigation:* `max-parallel: 4`, a dispatch at 01:30
Canberra time, outside working hours, and the conductor's right-sizing
reports, which will show whether `m` is wrong.

**R7. sf-1's egress address changes.** The `from=` restriction then
rejects every publish. This fails closed: every leg of the matrix goes
red, the per-image Loki record says `failure`, and the watchdog follows.
*Mitigation:* 2c records where the address is defined in 33fl, so
changing it is one edit.

## Definition of done

Each item can be checked by running something:

- [x] `tools/run-tests.sh` passes, including `tools/test-publish.sh`.
  Each of its retention-refusal cases was shown failing with its guard
  removed, and the 2a commit message says so.
- [x] `grep -nE '^\s+(pull_request|pull_request_target|push):'
  .github/workflows/image-build.yml` prints nothing.
- [x] `grep -n 'debian-13' .github/workflows/image-build.yml` shows the
  `runs-on` line, with the comment saying it is the builder OS.
- [x] `gh api repos/shakenfist/images/environments/images-publish
  --jq .deployment_branch_policy` shows custom branch policies, and
  `gh api repos/shakenfist/images/environments/images-publish/deployment-branch-policies
  --jq '.branch_policies[].name'` prints only `master`.
- [x] `git grep -nE 'home\.stillhq|192\.168\.|BEGIN OPENSSH' -- ':!docs/plans'`
  prints nothing. The plans are excluded because this line matches
  itself; read the plan diff by eye instead.
- [x] A conductor-dispatched nightly run of `image-build.yml`, with
  `publish: true` and an empty image list, built and published every
  image in `build.sh --list-images`. Its URL is under
  *Results*, and `tools/check-image-freshness.sh` exits 0 the following
  day.
- [x] `ssh sfyow sudo crontab -l -u root | grep -c build.sh` prints `0`.
- [x] The D8 rule exists in 33fl's
  `config/maui/grafana/alerting/rules.yml` and its expression returns
  a non-zero count today.
- [x] `grep -ci cron AGENTS.md` prints `0`, and `docs/build-host.md` no
  longer exists.
- [x] After 2f, `grep -n 'self-update\|SF_IMAGES_SELF_UPDATED' build.sh`
  prints nothing.

## Execution notes

**2026-10-25 (AEDT), back brief.** The operator agreed the plan, and
answered the two questions it raised:

* PR A (2a and 2b) meets the template's "an image was actually built"
  check by the operator running
  the branch's `build.sh --no-self-update debian:13` on sfyow
  **before PR A merges**. That is a real
  build and a real publish through the new two-rsync path and the new
  retention, to the local target the cron still uses.
* Corrected the same day, when the operator asked where to run it.
  The command first given used the cron's checkout, which the 33fl
  deploy resets to `master`, and `--preserve-env` for variables that
  live in root's crontab rather than in an operator's shell. The test
  runs in a separate root-owned clone, outside the 05:00 UTC nightly
  window, because it shares `/srv/sf-images/output`. It drops the same
  capability as the cron:
  `sudo git clone -b <branch> https://github.com/shakenfist/images /srv/sf-images/images-pr23`,
  then from that clone
  `sudo env SF_IMAGES_LOKI_URL=... SF_IMAGES_LOKI_TENANT=... setpriv --bounding-set -audit_control -- ./build.sh --no-self-update debian:13`,
  and afterwards remove the clone. PR #23's description carries the
  same commands.
* This session may push the branch and open PR A. Merging stays with
  the operator.

**2a ran in the phase worktree, not in a worktree of its own.** The
phase worktree is already isolated from `master`, and a second
worktree would only have added a copy step.

**2a departed from its brief in two ways. Both were kept after
review:**

* The first rsync names the image and its log, rather than sending
  `${outdir}/` minus `latest.qcow2`. When an account that does not own
  the label directory sends a directory, rsync tries to set that
  directory's permissions and exits 23 after copying everything. The
  agent reproduced this in a debian:13 container. The plan's own
  wording was already "the dated image and its log go in one rsync".
* The delete rsync is narrowed by `--include='*.qcow2'
  --include='*.qcow2.log' --exclude='*'`, so retention can only remove
  the kinds of file the old `ls`/`rm` removed. A check on 2026-10-25
  of every label in `--list-images` on images.shakenfist.com found
  only `<name>-YYYYMMDD.qcow2`, its `.log`, and `latest.qcow2`.

**The shellcheck baseline was 125, not 126.** After 2a it is 119, and
the diff only removes findings.

**Prerequisites 2a sets for 2c:**

* The publish account needs group write on every existing label
  directory as well as the document root, and no sticky bit, or it
  cannot replace or delete root-owned files.
* rrsync must run without `-ro`, `-wo`, `-no-del` and `-munge`.
  Retention lists and deletes, and `latest.qcow2` has to arrive as a
  real symlink.

**2b's brief was refined before it ran, in two ways:**

* On `master`, the build job always takes the `images-publish`
  environment, whether or not it publishes. The Loki secrets live
  there, and 2d's first run, with publishing off, has to show a
  summary arriving in Loki (D9). Every other ref takes no environment.
  Publishing still needs both `master` and the input.
* The boolean input is named `publish` rather than `push`, so the
  "no push trigger" grep in the Definition of done cannot match an
  input key.

**Still open after 2b, for 2d to settle:**

* Whether an empty `environment:` name means "no environment" at
  runtime. actionlint accepts it. The first dispatch from a branch
  will show whether GitHub does.
* Debian's default sudoers drops `HTTP(S)_PROXY`, so under `sudo`
  `build.sh`'s downloads and its Loki push probably leave through the
  hypervisor's NAT rather than the proxy. That may be fine. 2d step 2
  is where it shows.
* The host in `IMAGES_PUBLISH_KNOWN_HOSTS` has to be written exactly
  as the host in `IMAGES_PUBLISH_TARGET`. That belongs to 2c.

**2b added `.github/actionlint.yaml`'s `m` label.** actionlint rejects
a `runs-on` label it has not been told about.

**A private hostname reached this file and was removed before
anything was pushed.** The survey table named the CI proxy's
hostname. The Definition of done grep would have caught it, but it
also matched the author email in an old DIB patch, so the grep now
looks for `home\.stillhq` instead of `stillhq`. The planning commit
was rewritten locally, so the hostname never reached GitHub.

**PR A's sfyow test passed on 2026-10-24 (UTC).** The branch's
`build.sh --no-self-update debian:13`, run from a separate clone,
published `debian-13-sfagent-20261024.qcow2` through the two-rsync
path. Retention left seven images, and the run summary reached Loki
as a success. PR #23 merged as `da7683b`. The first nightly after
that, on 2026-10-25, pruned `debian-13-sfagent-20261017` from the live
site, which exercised the delete path for real.

**Step (0) of 2d: an empty `environment:` name means no environment.**
The branch dispatch on 2026-10-24 (run 40129939801) started, built
debian:13 on a debian-13 VM in 3m43s, and asked for no environment.
`build` stays one job.

**2c, as built (2026-10-25):**

* The `images-publish` environment was created with a custom branch
  policy allowing only `master`, and no reviewers. The policy was in
  place before any secret was added.
* The runners publish over the WireGuard tunnel to sfyow, not over a
  new edge rule. Their NAT egress is sf-1, and the tunnel's existing
  rule already lets the LAN reach sfyow's SSH. So
  `IMAGES_PUBLISH_TARGET` names sfyow's tunnel address with an empty
  path, `IMAGES_PUBLISH_KNOWN_HOSTS` names the host key under that
  same address, and the account's `from=` is sf-1's LAN address.
* The path is empty because rrsync strips a leading `/` and roots
  every path at the document root.
* rrsync runs with `-no-lock`. Without it, rrsync takes a lock per
  directory and the matrix's parallel uploads would fail.
* The operator generated the key pair and set all five secrets.
  Nothing in this session ever held the private half.
* The account, its sshd rule and the group-writable docroot are a
  33fl change, deployed by the operator.

**2d step (1) failed two of fourteen images, both because of DIB's
tmpfs.** On an `m` VM (8 GB), DIB's two tmpfs mounts, the chroot and
the image, may each grow to half of RAM. ubuntu:22.04 hit
`No space left on device` writing its initramfs. debian-gnome:12's VM
died mid-build, leaving no log and no Loki summary. Both images built
on sfyow (31 GB) the same nights. As this table's 2d brief prefers,
the workflow now sets `DIB_NO_TMPFS=1` rather than asking for a bigger
VM. Step (1) is re-run after that merges, and `timeout-minutes` is set
from the re-run, because builds on disk are slower than in RAM.

**2d step (3) ran before step (1) was clean**, with the operator's
agreement. debian:13 built fine in step (1), and the tmpfs failures
have nothing to do with publishing.

**2d step (3)'s sha256 check was corrected at its source.** The brief
asked for the served file's sha256 to match "the one the job logged",
but `build.sh` logs no checksum. rsync already verifies a whole-file
checksum on every transfer, so the check is now the served size
against the size rsync sent. Publishing a checksum alongside each
image would be a change to what the site serves, not to how the build
runs.

**2026-10-27 (AEDT): the nightly trigger changed from GitHub's
`schedule` to a conductor dispatch, before cutover.** While preparing
2e, a survey of 33fl found that its four nightly report workflows
carry no `schedule` on purpose, because GitHub's scheduler had been
late by hours and had skipped nights outright since 2026-08-26. The
conductor on maui dispatches them instead. The operator chose the same
for the image build. D2, D8, D10, R6, the 2e and 2f briefs and the
Definition of done were corrected at their source, and the cutover
became three pull requests instead of two. A side benefit is the time:
01:30 Canberra is outside working hours, where sfyow's 05:00 UTC cron
landed in the middle of the Australian afternoon.

**2026-10-30 (AEDT): 2e's checks, and 2f.** All three conductor
nightlies were clean (see *Results*), so 2f ran. Each Definition of
done item was checked by running its command: the crontab check on
2026-10-26 at 22:02 UTC, the rest on 2026-10-29 UTC. Departures from
the 2f brief:

* **The operator chose to delete all of `/srv/sf-images`** on sfyow
  (about 31 GB: a 28 GB DIB cache, the 2.2 GB checkout and 746 MB of
  old output), not only `output` and `cache`. 33fl removes it with
  `state: absent`, so no later deploy can bring it back.
* **33fl's reason for keeping the checkout was false.** Its comment
  said `tools/check-image-freshness.sh` reads the image list through
  the checkout on sfyow. The freshness check runs in GitHub Actions
  against its own checkout, and nothing on sfyow runs it. The comment
  went with the checkout.
* **The removal refuses while anything is mounted under the tree.**
  `file: state: absent` deletes recursively and does not stop at a
  mount point, and DIB bind-mounts `/dev`, `/proc` and `/sys` into its
  chroots under `/srv/sf-images`. Nothing was mounted there on
  2026-10-29.
* **33fl's backup coverage declaration named the tree too:**
  `/srv/sf-images/images` was backed up and `/srv/sf-images/cache`
  excluded. Both entries are removed.
* **`build.sh`'s `original_args` went too.** It existed only to hand
  the re-exec the same arguments.

## Results

**2d step (1), first attempt** (run 40238608134, 2026-10-25 UTC, `m`
runners, DIB in tmpfs). 12 of 14 images built. Wall-clock per job:

| Image | Minutes | Result |
|---|---|---|
| ubuntu:24.04 | 9.2 | built |
| rocky:8 | 9.0 | built |
| debian-gnome:12 | 7.2 | VM died (tmpfs) |
| rocky:9 | 6.5 | built |
| centos:9-stream | 5.9 | built |
| debian-xfce:12 | 4.8 | built |
| debian-docker:12, debian-gnome:13 | 4.4 | built |
| ubuntu:22.04 | 4.2 | ENOSPC (tmpfs) |
| debian:12 | 4.2 | built |
| rocky:10, debian-xfce:13 | 4.1 | built |
| debian-docker:13 | 3.8 | built |
| debian:13 | 3.4 | built |

**2d step (2): Loki works from a runner.** Thirteen
`{job="image-build-summary"}` streams from that run arrived in the
build's tenant, one for every image except debian-gnome:12, whose VM
died before it could push one.

**2d step (3): the first publish from a runner worked** (run
40254427992, 2026-10-26 UTC, debian:13, `publish: true`). The build took
2m46s, and the job 5m18s overall.

* rsync sent `debian-13-sfagent-20261026.qcow2` and its log over the
  tunnel at about 4 MB/s: 441 MB in 1m43s.
* `latest.qcow2` followed as a symlink in the second rsync.
* images.shakenfist.com serves `latest.qcow2` and the dated name with
  `Last-Modified: Mon, 26 Oct 2026 01:34:46 GMT` and
  `Content-Length: 440980992`, which is the image size rsync sent.
* Retention removed `debian-13-sfagent-20261018` and its log, leaving
  seven images, seven logs and `latest.qcow2`.
* The new files belong to `sf-images-publish:sf-images` and sit beside
  the cron's root-owned ones.
* The run's log and summary reached Loki.
* A full nightly is about 14.7 GB: the sum of every label's
  `latest.qcow2` on 2026-10-26. rocky:8 is the largest at 1.9 GB, and
  the desktop images, ubuntu:24.04 and centos:9-stream are each about
  1.4 GB. If the matrix's four parallel uploads share the 4.3 MB/s,
  the uploads take about an hour in total. If each upload gets that
  rate, they take about 15 minutes. This run had one upload, so it
  cannot tell the two apart; the first publishing run of the whole
  list will. Either way it is the
  slower copy the operator accepted when choosing to publish over the
  WAN, and it fits well inside the night.

**2d step (1), re-run after the tmpfs fix** (run 40275203133,
2026-10-26 UTC, `m` runners, `DIB_NO_TMPFS=1`, publishing off). All 14
images built, and all 14 summaries reached Loki. Time per job:

| Image | Minutes |
|---|---|
| debian-gnome:13 | 14.7 |
| debian-gnome:12 | 13.4 |
| ubuntu:24.04 | 11.1 |
| ubuntu:22.04 | 11.0 |
| rocky:8 | 9.0 |
| debian-xfce:12 | 7.5 |
| debian-xfce:13 | 6.6 |
| rocky:9 | 5.8 |
| rocky:10, debian-docker:12 | 5.2 |
| debian:12 | 5.1 |
| debian:13 | 5.0 |
| centos:9-stream | 4.4 |
| debian-docker:13 | 4.2 |

* Building on disk hit the desktop images hardest compared with the
  tmpfs run: debian-gnome:13 went from 4.4 to 14.7 minutes, and the xfce
  images took about 1.6 times as long. rocky:8 did not change, and
  ubuntu:24.04 took about a fifth longer.
* **2d's timeout rule was corrected at its source.** The brief said
  about twice the slowest image, which gives 30 minutes, and that is
  what this branch first set. But the job includes the upload on a
  publishing run, so the rule is now the slowest build plus the slowest
  upload, with margin. The first publishing run of the whole list
  should record each job's upload time, rocky:8's and the desktop
  images' especially, and revisit the figure.
* `timeout-minutes` is now 60. It bounds the whole job, and on a
  publishing run that includes the upload, which this run did not do.
  The slowest build was 14.7 minutes. The slowest upload, rocky:8's
  1.9 GB, takes about 30 minutes if the four parallel uploads share
  the 4.3 MB/s that one upload measured. The first publishing run of
  the whole list will show whether they do.
  Every runner build is a cold-cache build, so there is no warm case
  to allow for.
* Peak disk use was not measured: nothing in the logs shows it, and no
  `df` step was added. The largest output image is 1.9 GB (rocky:8),
  and DIB's scratch space is a few times an image, against 200 GB.
* **The run took 6h39m of wall-clock time for 108 minutes of builds.**
  It was dispatched at 05:37 UTC, the first build started at 05:50 and
  the last finished at 12:16. Between those times the jobs mostly
  waited for VM runners: the fleet's CI was backed up that day, and at
  the worst point jobs waited about 2h25m. With four builds at a time
  and no queue, the same builds take about half an hour. 2e should
  expect a scheduled nightly to take hours on a busy day, and should
  not assume it finishes by any particular time.

**2e: the first three conductor-dispatched nightlies were clean.** Each
was dispatched on `master` with `publish: true` and no image list, and
each built and published all 14 images:

| Night (UTC) | Run | Dispatched | Finished | Wall-clock |
|---|---|---|---|---|
| 2026-10-27 | 40521732555 | 14:30:20 | 15:37:43 | 67 min |
| 2026-10-28 | 40706569015 | 14:30:16 | 15:35:38 | 65 min |
| 2026-10-29 | 40892111356 | 14:30:13 | 15:37:38 | 67 min |

* Every night, 14 summaries reached Loki, each with `Built:` and none
  with `Failed:`, `Not attempted:` or `Stopped:`. That satisfies the
  D8 rule's expression.
* Every night, 14 new dated images and their logs appeared on sfyow,
  owned by `sf-images-publish`, with no `.<image>.qcow2.<random>` temp
  file left behind.
* `image-freshness.yml` exited 0 on 2026-10-28 and 2026-10-29. Its
  `schedule` fired at about 15:55 UTC both days, nearly seven hours
  after its 09:00 cron, which is the lateness D2 describes.
* Root's crontab on sfyow held no `build.sh` line from 2026-10-26
  22:02 UTC onwards.
* The runners were idle at 14:30 UTC each night, so the four-wide
  matrix ran without queueing, unlike 2d's 6h39m re-run.

Per job, in minutes: the time to the upload's start (which includes
the job's package installs), the upload itself, and the whole job, with
the upload's rate in MB/s. The rate is rsync's own `bytes/sec` figure.

| Image | GB | 2026-10-27 | 2026-10-28 | 2026-10-29 |
|---|---|---|---|---|
| rocky:8 | 1.93 | 9 / 18.4 / 28 @1.7 | 9 / 19.4 / 28 @1.7 | 9 / 17.7 / 28 @1.8 |
| rocky:9 | 1.60 | 5 / 16.6 / 22 @1.6 | 5 / 15.6 / 21 @1.7 | 6 / 14.8 / 21 @1.8 |
| debian-gnome:13 | 1.45 | 11 / 15.6 / 27 @1.6 | 13 / 16.2 / 30 @1.5 | 11 / 12.2 / 24 @2.0 |
| ubuntu:24.04 | 1.44 | 9 / 12.0 / 21 @2.0 | 8 / 12.5 / 21 @1.9 | 9 / 8.8 / 18 @2.7 |
| debian-gnome:12 | 1.43 | 14 / 10.2 / 24 @2.3 | 13 / 7.0 / 20 @3.4 | 14 / 10.0 / 24 @2.4 |
| centos:9-stream | 1.39 | 4 / 8.4 / 13 @2.8 | 4 / 10.1 / 15 @2.3 | 3 / 7.2 / 11 @3.2 |
| rocky:10 | 1.07 | 6 / 8.6 / 15 @2.1 | 6 / 7.6 / 14 @2.4 | 4 / 6.6 / 11 @2.7 |
| ubuntu:22.04 | 0.81 | 10 / 8.6 / 19 @1.6 | 9 / 8.7 / 18 @1.6 | 11 / 5.3 / 16 @2.5 |
| debian-xfce:13 | 0.79 | 7 / 6.2 / 14 @2.1 | 8 / 7.1 / 16 @1.8 | 8 / 8.6 / 17 @1.5 |
| debian-xfce:12 | 0.78 | 7 / 7.2 / 14 @1.8 | 7 / 5.9 / 13 @2.2 | 9 / 8.0 / 17 @1.6 |
| debian-docker:12 | 0.60 | 6 / 4.7 / 11 @2.1 | 7 / 4.9 / 12 @2.0 | 7 / 4.0 / 11 @2.5 |
| debian-docker:13 | 0.56 | 6 / 5.9 / 12 @1.6 | 5 / 5.4 / 11 @1.7 | 6 / 5.1 / 12 @1.8 |
| debian:12 | 0.50 | 6 / 3.0 / 10 @2.8 | 4 / 3.1 / 8 @2.7 | 6 / 3.6 / 10 @2.3 |
| debian:13 | 0.44 | 5 / 5.7 / 11 @1.3 | 4 / 3.2 / 8 @2.3 | 6 / 3.6 / 10 @2.1 |

* **The parallel uploads partly share the link.** Each upload ran at
  1.3 to 3.4 MB/s, against the 4.3 MB/s that 2d step (3)'s single
  upload measured, so four at once move about 8 MB/s between them. 2d
  could not tell "shared" from "each at full rate"; the answer is
  in between.
* **The timeout stays at 60 minutes.** The longest job in three nights
  was debian-gnome:13's 30 minutes, and the longest upload rocky:8's
  19.4. That is the slowest build plus the slowest upload, with about
  double the margin, which is the rule 2d settled on. Lowering it
  would buy nothing: a job that hangs is caught either way, and a
  slower night on a busier link would be cut off.
* Each night published about 14.8 GB, the same as 2d's estimate from
  the site.

## Back brief

Before executing any step, back brief the operator. There are two
further gates, because they are cheap to propose and expensive to
redo:

* **Before 2c,** confirm the user, group and `from=` arrangement on
  sfyow with the operator. The operator generates the key pair, and no
  sub-agent ever holds the private half.
* **Before 2e,** present 2d's results and get an explicit go-ahead for
  the cutover day. Merging stays with the operator.
