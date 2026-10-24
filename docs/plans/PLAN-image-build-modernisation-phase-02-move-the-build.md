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
* Retiring sfyow's cron job on the same day the workflow's schedule
  starts, plus the 33fl changes that involves.
* A watcher outside this repository for the failure the move creates:
  GitHub switching the schedule off (D8).
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

**D2. Only `schedule` and `workflow_dispatch` trigger the workflow.
There is no `pull_request` and no `push`.** Every VM runner holds
`id_ci`, so any code a fork can get onto one reaches the whole CI mesh.
A build job also runs as root. The publish credential sits behind a
GitHub environment, `images-publish`. Its deployment branch policy
allows `master` only, and it has no required reviewers, for the same
reason `audit-write` has none: a schedule has nobody to approve it. The
publishing step also carries `if: github.ref == 'refs/heads/master'`, so
a dispatch from a branch shows the step as skipped rather than as a
failed environment check. A dispatch can still build any branch with
`push: false`, and that is how a `build.sh` change is tested before it
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
`tools/test-self-update.sh` are deleted together.

**D7. The matrix comes from `build.sh --list-images`.** A first job on
`[self-hosted, static]` turns the list into JSON. It is small and
changes nothing, which is what static runners are for. The build job
runs with `fail-fast: false`, `max-parallel: 4` and `timeout-minutes:
120`. A parallelism of four keeps a nightly build from taking fourteen
`m` VMs (56 vCPU) away from the fleet's CI at once. The timeout is a
first guess for a cold-cache build of the desktop images, and step 2d
replaces it with a measured number. A `workflow_dispatch` input `images`
(empty means the whole list) and a boolean `push` (default `false`) let
one image be rebuilt by hand. A scheduled run always publishes.

**D8. Moving the schedule into this repository creates a new silent
failure, so this phase adds a watcher outside it.** GitHub disables
scheduled workflows in a repository with no commits for 60 days. Today
that can only switch off the freshness watchdog. After this phase it
also switches off the build, at the same moment and from the same
cause. Nothing would build, and the one thing meant to notice would be
off too. The master plan listed "a second watcher outside this
repository" under Future work. This phase makes it necessary, so it is
pulled in. The watcher is a Grafana alert rule in 33fl, beside the
existing `image-nightly-stale` rule in
`config/maui/grafana/alerting/rules.yml`, that fires when no
`{job="image-build-summary"}` line has arrived in Loki for 72 hours. It
depends on neither GitHub's scheduler nor this repository, and it also
catches log shipping from the runners breaking. That makes D9 a
precondition for it.

**D9. Runners keep shipping to Loki.** `SF_IMAGES_LOKI_URL` and
`SF_IMAGES_LOKI_TENANT` become secrets in the `images-publish`
environment, because the URL is a private hostname and this repository
is public. Runners can reach the home LAN. However, the bootstrap exports
`HTTP(S)_PROXY` with no `NO_PROXY`, and `push_log_to_loki`'s `urllib`
honours both. Step 2d therefore has to show an `image-build-summary`
line arriving from a runner, rather than assume it. If the proxy will
not carry it, the fix is a `NO_PROXY` entry for the Loki host on the
`build.sh` step, not a change to `build.sh`.

**D10. The cutover happens on one day, in a fixed order.** The master
plan says to retire the cron "in the same change" that the workflow
starts. Across two repositories, one change means one day. First the
33fl pull request merges and deploys: it removes the cron job and its
two environment lines, and adds the D8 alert. Then the images pull
request that adds the `schedule` trigger merges. Done in that order,
the worst case is one night with no build, which the 72-hour watchdog
tolerates. Done in the other order, the worst case is two schedulers
publishing into the same directories on the same night. Rollback is
reverting both, 33fl first.

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
| 2c | high | opus | worktree | **33fl: a publish-only account on sfyow.** In the 33fl repository (`/srv/kasm_profiles/mikal/vscode/src/mach33labs/33fl`), extend `sfyow-images.yml`, or add a playbook beside it if that reads better, and document in `docs/sfyow-images.md`. Create an unprivileged user (suggested name `sf-images-publish`) that can write to `/srv/www/images.shakenfist.com`. Look at `sfyow-web.yml` and `docs/sfyow-web.md` for who owns the docroot now, and prefer a shared group over changing ownership, so apache and today's root-run cron keep working. Install `rrsync` (Debian ships it in the `rsync` package, as `/usr/bin/rrsync` on trixie; verify that). Give the user an `authorized_keys` entry `restrict,from="<sf-1 egress>",command="/usr/bin/rrsync /srv/www/images.shakenfist.com" <pubkey>`. The public key and the sf-1 address are variables in 33fl's normal secret and inventory handling. Find how `conductor.yml` handles `sfcbr_ci_images_key` and do the same. **Do not** remove the cron job in this step; that is 2e. The operator generates the key pair. The management session then creates the `images-publish` environment and its secrets (`IMAGES_PUBLISH_SSH_KEY`, `IMAGES_PUBLISH_KNOWN_HOSTS`, `IMAGES_PUBLISH_TARGET`, `SF_IMAGES_LOKI_URL`, `SF_IMAGES_LOKI_TENANT`) with `gh`, after asking, because they are outward-facing settings. Deployment branch policy: `master` only, no reviewers. |
| 2d | -- | -- | management session | **Prove it before switching anything.** (1) Dispatch `image-build.yml` on `master` with `push: false` and the whole list. Record each image's duration, its peak disk use (add a `df -h` step if the logs do not show it) and the result. Set `timeout-minutes` to about twice the slowest image, and change the runner size if disk or a DIB tmpfs `ENOSPC` calls for it. For tmpfs, prefer `DIB_NO_TMPFS=1` on a 200 GB disk over a bigger VM. (2) Confirm an `{job="image-build-summary"}` line from a runner host arrived in Loki (D9). (3) Dispatch `push: true, images: debian:13`. Confirm that `curl -sI https://images.shakenfist.com/debian:13/latest.qcow2` shows the new `Last-Modified`, that the served file's sha256 matches the one the job logged, and that retention left seven images. (4) Write the measurements into this file under *Results*. Then **stop for the operator's go-ahead** on cutover. |
| 2e | medium | sonnet | none | **Cutover, as two pull requests merged the same day in D10's order.** *33fl:* remove the `sfyow image build` cron entry and the `SF_IMAGES_LOKI_URL`/`SF_IMAGES_LOKI_TENANT` environment lines from `sfyow-images.yml` (use `state: absent`, so the deploy removes them rather than merely forgetting them). Leave the checkout task in place until 2f. Add the D8 Grafana rule to `config/maui/grafana/alerting/rules.yml`, modelled on `image-nightly-stale`: it fires when `count_over_time({job="image-build-summary"}[72h])` on the sfyow tenant is zero. Update `docs/sfyow-images.md`. *images:* add `schedule` to `image-build.yml`, with an offset minute (fleet convention), a comment on the 60-day disable that points at the D8 rule, and a note that GitHub delays scheduled starts by hours. Remove the `SF_IMAGES_PUBLISH_TARGET` default from `build.sh`, so a publishing run with no target exits 2 before the preamble, and extend `tools/test-build-arguments.sh` for that. Replace `docs/build-host.md` with `docs/nightly-build.md`, covering how the workflow runs, how to rebuild one image by dispatch, where logs go (Actions, `.qcow2.log` beside the image, Loki), the publish account, and recovering when the `debian-13` runner label is broken (R3). Update the README's two links to it. Change `AGENTS.md:5`, which says "manually or via cron", and its `docs/build-host.md` link, as Phase 5 deferred to this phase. Change `ARCHITECTURE.md:13-16`. |
| 2f | medium | sonnet | none | **After three clean scheduled nights, remove what only the cron used.** *images:* delete the self-update block, the `--no-self-update` flag, its use in `image-build.yml`, `tools/test-self-update.sh` and its mentions in docs (D6). *33fl:* remove the `/srv/sf-images` checkout tasks and the `--list-images` assertion from `sfyow-images.yml`, keeping the publish account. Decide with the operator whether `/srv/sf-images/{output,cache}` is deleted, and record what was freed. |

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
fleet's CI. *Mitigation:* `max-parallel: 4`, a schedule outside working
hours, and the conductor's right-sizing reports, which will show
whether `m` is wrong.

**R7. sf-1's egress address changes.** The `from=` restriction then
rejects every publish. This fails closed: every leg of the matrix goes
red, the per-image Loki record says `failure`, and the watchdog follows.
*Mitigation:* 2c records where the address is defined in 33fl, so
changing it is one edit.

## Definition of done

Each item can be checked by running something:

- [ ] `tools/run-tests.sh` passes, including `tools/test-publish.sh`.
  Each of its retention-refusal cases was shown failing with its guard
  removed, and the 2a commit message says so.
- [ ] `grep -nE '^\s+(pull_request|pull_request_target|push):'
  .github/workflows/image-build.yml` prints nothing.
- [ ] `grep -n 'debian-13' .github/workflows/image-build.yml` shows the
  `runs-on` line, with the comment saying it is the builder OS.
- [ ] `gh api repos/shakenfist/images/environments/images-publish
  --jq .deployment_branch_policy` shows custom branch policies, and
  `gh api repos/shakenfist/images/environments/images-publish/deployment-branch-policies
  --jq '.branch_policies[].name'` prints only `master`.
- [ ] `git grep -nE 'home\.stillhq|192\.168\.|BEGIN OPENSSH'` in this
  repository prints nothing.
- [ ] A scheduled (not dispatched) run of `image-build.yml` built and
  published every image in `build.sh --list-images`. Its URL is under
  *Results*, and `tools/check-image-freshness.sh` exits 0 the following
  day.
- [ ] `ssh sfyow sudo crontab -l -u root | grep -c build.sh` prints `0`.
- [ ] The D8 rule exists in 33fl's
  `config/maui/grafana/alerting/rules.yml` and its expression returns
  a non-zero count today.
- [ ] `grep -ci cron AGENTS.md` prints `0`, and `docs/build-host.md` no
  longer exists.
- [ ] After 2f, `grep -n 'self-update\|SF_IMAGES_SELF_UPDATED' build.sh`
  prints nothing.

## Execution notes

**2026-10-25 (AEDT), back brief.** The operator agreed the plan, and
answered the two questions it raised:

* PR A (2a and 2b) meets the template's "an image was actually built"
  check by the operator running
  `sudo --preserve-env=SF_IMAGES_LOKI_URL,SF_IMAGES_LOKI_TENANT ./build.sh --no-self-update debian:13`
  from the branch on sfyow **before PR A merges**. That is a real
  build and a real publish through the new two-rsync path and the new
  retention, to the local target the cron still uses.
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

## Results

To be filled in by step 2d and the cutover.

## Back brief

Before executing any step, back brief the operator. There are two
further gates, because they are cheap to propose and expensive to
redo:

* **Before 2c,** confirm the user, group and `from=` arrangement on
  sfyow with the operator. The operator generates the key pair, and no
  sub-agent ever holds the private half.
* **Before 2e,** present 2d's results and get an explicit go-ahead for
  the cutover day. Merging stays with the operator.
