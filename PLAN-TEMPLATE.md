# Title for the plan

## Prompt

Before responding to questions or discussion points in this
document, explore this repository thoroughly. Read the relevant
files and ground your answers in what they actually say. Do not
speculate about the repository when you could read it instead.
Flag any uncertainty explicitly rather than guessing.

There is no application code here. The artifacts are `build.sh`,
a single Bash script that drives OpenStack's diskimage-builder
(DIB); the DIB elements under `elements/` that customise each
image; the patches under `diskimage-builder-patches/` that this
repository carries against DIB itself; and `block-device-compat.yaml`,
a copy of a DIB default with one override.

Consult `AGENTS.md` for the conventions and the invariants that
are not visible in the code, and `ARCHITECTURE.md` for the shape
of the build pipeline, the element system and the three "extras"
element groups.

Three things make planning here different from planning in a
repository that holds a product, and all three should shape any
plan written from this template:

* **The feedback loop is slow and cannot be faked.** There are no
  unit tests and there is no cheap way to add meaningful ones: the
  thing being built is a bootable disk image, and the failures that
  matter are things like a bootloader that cannot read its own root
  filesystem. A single image takes minutes to tens of minutes to
  build and needs a host with `sudo`, loop devices and disk space.
  A plan that assumes a fast edit-test cycle is a plan that will not
  survive contact with this repository.

* **The output is consumed by people who did not ask for the
  change.** Everything published to images.shakenfist.com is used
  by the fleet's CI -- the private-ci dependencies cache disk is
  built from an image here -- and by anyone who has ever pointed at
  the site. A defect ships silently: the image builds, publishes,
  and is wrong. `debian-docker:12`, `debian-gnome:12` and
  `debian-xfce:12` were built from Debian 11 for two years and two
  months before anybody noticed.

* **Failure here is quiet by construction.** `build.sh` runs under
  `#!/bin/bash -e` from cron, so one broken image aborts the whole
  run and every image after it in the list produces no output and no
  log -- not a failure record, nothing at all. Cron mails root and
  nobody reads root's mail. Any plan that changes the build must say
  how its failure becomes visible, because the default is that it
  does not.

<!-- shared-block: plan-file-conventions v1 -->
Plan file conventions (shared block; do not edit -- the canonical
copy lives in shakenfist/development at
`templates/shared-blocks/plan-file-conventions.md`):

- All planning documents live in `docs/plans/`.
- Detailed planning gets one plan file per phase. Phase files are
  named for their master plan, sit in the same directory as it,
  and append `-phase-NN-descriptive` before the `.md` extension.
- The master plan tracks its phases in a table under its Execution
  section:

  | Phase | Plan | Status |
  |-------|------|--------|
  | 1. Schema migration | PLAN-thing-phase-01-schema.md | Not started |
  | 2. Public API | PLAN-thing-phase-02-api.md | Not started |

- One commit per logical change, and at minimum one commit per
  phase. Unrelated changes are not batched into a single commit.
  Each commit is self-contained: it builds, passes tests, and has
  a message explaining what changed and why.
<!-- shared-block-end -->

**In this repository.** Plans here keep their phases as sections
inside the master plan rather than as separate phase files, and
the Execution table's `Plan` column is dropped accordingly;
`docs/plans/index.md` says so. The shared convention above is the
fleet default, and a plan large enough to want phase files should
use them rather than argue with the block.

One commit per logical change is harder to honour here than it
looks. A change to `build.sh` and a change to an element under
`elements/` are usually one logical change from the image's point
of view -- the element does the work and the script passes it the
variables -- and splitting them produces a commit that builds a
broken image. Where that is true, say so in the commit message
rather than splitting the change into two commits that each fail.

## Situation

What is true today, with the measurements that make the case. A
plan whose Situation section is entirely adjectives is a plan
nobody can check afterwards.

For this repository that means naming the images involved, the
dates of the last successful builds, and where the evidence came
from -- the published build logs under
`https://images.shakenfist.com/<image>/`, or the Loki stream that
`push_log_to_loki()` in `build.sh` writes to (tenant `sfyow`).
Both outlive the session that read them, so cite them.

## Mission and problem statement

What this plan is for, in a paragraph, and what it deliberately
does not cover.

## Open questions

Anything the plan cannot decide on its own, with the decision it
would take by default if nobody answers.

## Execution

The phases, as a table. Where a phase is a section below rather
than a file, the table names the section.

<!-- shared-block: plan-status-vocabulary v1 -->
Plan status vocabulary (shared block; do not edit -- the canonical
copy lives in shakenfist/development at
`templates/shared-blocks/plan-status-vocabulary.md`):

A status cell -- in the master plan's own Execution phase table, and
in the row `docs/plans/index.md` carries for the plan -- holds
exactly one of these terms and nothing else:

- `Proposed` -- written down as a concept, not yet scheduled.
- `Not started` -- scheduled, but no work has begun.
- `In progress` -- work has begun and has not finished.
- `Blocked` -- cannot proceed until something outside the plan
  changes. Say what, in the plan.
- `Complete` -- the work is done.
- `Abandoned` -- deliberately dropped without being done.
- `Superseded` -- replaced by another plan, which the plan names.

The term is the whole cell. No dates, no phase arithmetic, no
parenthetical qualifiers, no summary of what happened: a status is
read to decide whether a plan still wants attention, and prose in
that column has repeatedly grown until it could no longer be read
either by a person scanning the table or by tooling. Detail belongs
in the plan file, and a one-line summary belongs in the index's own
Intent column.

Matching is case-insensitive, so `In Progress` is accepted, but the
spelling above is the one to write.
<!-- shared-block-end -->

**In this repository.** The same term is written twice: once in
this plan's own phase table, and once in the row the plan carries
in `docs/plans/index.md`. The index row is the whole-plan status,
so it only reaches `Complete` once every phase has been
completed, abandoned or superseded.

This repository is outside the fleet consistency audit -- it is on
the excluded list in shakenfist/development's
`docs/audits/README.md` -- so nothing checks these statuses for
you overnight. That makes the discipline more important here, not
less: a drifting status in an audited repository is caught the
next morning, and a drifting status here is caught by whoever is
confused by it months later.

<!-- shared-block: plan-push-audit-phase v3 -->
Push audit phase (shared block; do not edit -- the canonical
copy lives in shakenfist/development at
`templates/shared-blocks/plan-push-audit-phase.md`):

- Every master plan ends with a phase that runs the repository's
  `PUSH-AUDIT.md` over the whole plan's work. It is the last row of
  the Execution table and it is not optional. The rule binds every
  plan that carries the phase, which is decidable from the plan file
  alone: a plan that is already `Complete`, `Abandoned` or
  `Superseded` and does not carry the phase is not reopened to
  acquire one, and a plan that has the phase runs it even if it
  reaches `Complete` before the phase does.
- That phase audits the accumulated diff of every phase in the plan
  against the default branch, not the diff of the last phase alone.
  Auditing one phase at a time would miss what the phases did to
  each other -- the duplicated helper that only exists once phases
  three and six have both landed, the doc page that phase two made
  wrong and phase five never revisited.
- Once the plan's phases have merged, a diff against the default
  branch is empty and would read as a clean audit. The range is not
  reliably derivable after the fact either: unrelated work lands on
  the default branch between phases, so anything anchored on "since
  the plan file appeared" is far too wide. It has to be recorded. As
  each phase lands, what put it on the default branch goes into the
  plan: the merge commit of its pull request, whose diff against its
  first parent is the whole of what landed, or -- where the phase
  landed directly -- every commit of the phase, or its `first..last`
  range. A single commit is only ever enough when it is a merge
  commit.
- Where the Execution phases are a table, that record is a `Merged`
  column, added last so that a row which omits it still reaches
  `Status`; where they are prose sections it is a `Merged:` line in
  the phase's own section. The `Status` column keeps its single
  vocabulary term and nothing else (see `plan-status-vocabulary`).
  A phase that landed in another repository records `<repo> <sha>
  (#pr)` and is audited against that repository's default branch, as
  part of the pull request that lands it; the plan's own push-audit
  phase cites that audit rather than re-running it.
- Phases that landed before the plan started recording them are
  reconstructed rather than left blank. Recover what you can from
  `gh pr list --state merged` and `git rev-list --first-parent`, and
  say in the plan that the range was reconstructed. Do not trust a
  path-filtered `git log` on its own: it lists the commits that
  touched a path without saying which arrived directly and which
  arrived inside a pull request, and recording a commit that came in
  under a merge audits one commit of that pull request rather than
  the pull request. A reconstructed record may be a summary table in
  the audit phase's own section rather than a column or a line in
  the Execution table, which keeps retrospective archaeology out of
  a table that tracks live status. Where a phase accreted over
  months of unrelated commits and no range is recoverable, say that
  instead and name the paths the audit read -- an audit that says
  what it could not scope is a result; one that silently audits
  nothing is not.
- Findings land as their own pull request against the default
  branch, and the plan is not complete until they are resolved or
  explicitly declined in writing. A finding that is declined says
  why, in the plan, where the next reader will find it.
- Where the audit finds nothing, record that in the plan in one
  sentence. It is a real result, and a run of them is the evidence
  for making the phase conditional rather than mandatory.
- A repository with no `PUSH-AUDIT.md` still carries the phase, and
  the phase says that the runbook does not exist yet and what was
  done instead. Silently omitting it is what let the audit go
  untriggered for as long as it did.
<!-- shared-block-end -->

**In this repository.** There is no `PUSH-AUDIT.md` yet, so until
one exists the final phase says that the runbook is absent and
records what was done instead -- at minimum a read of the
accumulated diff against `master` for the failure modes this
repository actually has: a hardcoded release codename that does not
match the element it is paired with, a variable exported before the
value it depends on is assigned, and a `sudo` call that assumes an
environment variable survives into it. Creating `PUSH-AUDIT.md` is
itself a candidate phase for the plan that removes this paragraph.

Note also that the default branch here is `master`, not `main`, so
every diff range in a runbook copied from another Shaken Fist
repository needs adjusting. Read them as `origin/master...HEAD`.

## Agent guidance

### Execution model

<!-- shared-block: subagent-execution-model v1 -->
Sub-agent execution model (shared block; do not edit -- the
canonical copy lives in shakenfist/development at
`templates/shared-blocks/subagent-execution-model.md`):

All implementation work is done by sub-agents, never in the
management session. The management session is reserved for
planning, review, and decision-making. This keeps the management
context lean and avoids drowning it in implementation diffs.

The workflow is:

1. **Plan** at high effort in the management session.
2. **Spawn a sub-agent** for each implementation step with the
   brief from the plan, at the recommended effort level and model.
3. **Review** the sub-agent's output in the management session.
   Check the actual files -- the sub-agent's summary describes
   what it intended, not necessarily what it did.
4. **Fix or retry** if the output is wrong. Diagnose whether the
   brief was insufficient (improve it) or the model was too light
   (upgrade it), then re-run.
5. **Commit** once the management session is satisfied.

This applies to all steps, including high-effort ones. If a
sub-agent cannot succeed even with a detailed brief and the right
model, that is a signal the brief needs improving, not that the
management session should do the implementation itself.

Use `isolation: "worktree"` for sub-agents when the change is
risky or experimental; the worktree is discarded if the output is
unsatisfactory. For safe, well-understood changes, sub-agents can
work directly in the main tree.
<!-- shared-block-end -->

**In this repository.** Sub-agents that change `build.sh` or
anything under `elements/` cannot verify their own work: the
verification is a real image build on a host with `sudo` and loop
devices, which the management session arranges. Brief them to say
what they expect the build to do differently rather than to claim
it works, and treat "I have verified the change" from a sub-agent
that never built an image as the thing to check first.

### Planning effort

<!-- shared-block: plan-planning-effort v1 -->
Planning effort (shared block; do not edit -- the canonical copy
lives in shakenfist/development at
`templates/shared-blocks/plan-planning-effort.md`):

The master plan itself is always created at **high effort** -- it
requires broad codebase understanding, cross-referencing several
source files, and judgment calls about scope and sequencing.

Each phase plan states the recommended effort level for planning
that phase. Phases that turn on design decisions, cross-component
coordination, protocol changes, or subtle correctness questions
should be planned at high effort. Phases that are mechanical, or
that follow a pattern already established elsewhere in the
codebase, can be planned at medium effort.
<!-- shared-block-end -->

**In this repository.** High effort is anything that changes what
is inside a published image -- the element scripts, the release
codenames in `build.sh`, the partitioning and filesystem options in
`block-device-compat.yaml` -- because a mistake there ships a
working-looking image that is wrong, and the audience finds out
before we do. High effort is also anything touching the DIB patches
in `diskimage-builder-patches/`, which are carried against somebody
else's code and have to be re-checked whenever DIB moves.

Medium effort covers adding an image to the build list that follows
the shape of an existing block, documentation, and changes to the
publishing and retention logic, where the failure is visible
immediately and recoverable.

### Step-level guidance

<!-- shared-block: subagent-step-guidance v1 -->
Sub-agent step guidance (shared block; do not edit -- the
canonical copy lives in shakenfist/development at
`templates/shared-blocks/subagent-step-guidance.md`):

Each phase plan includes a table like this:

| Step | Effort | Model | Isolation | Brief for sub-agent |
|------|--------|-------|-----------|---------------------|
| 1a | medium | sonnet | none | One-sentence summary of what to do and which files to touch |
| 1b | high | opus | worktree | Why this needs high effort: requires understanding X to do Y |

**Effort levels**, from cheapest to most thorough:

- **low** -- Purely mechanical changes: rename, reformat, add a
  log line, regenerate generated code. The brief is a complete
  instruction.
- **medium** -- The plan provides enough context to follow a clear
  brief. The sub-agent may read a few files, but the approach is
  already decided.
- **high** -- Requires reading several files, making judgment
  calls, or understanding non-obvious invariants. The sub-agent
  needs to think about edge cases.
- **xhigh** -- The setting for hard coding and agentic steps:
  long-horizon changes, or steps where the sub-agent must both
  research and implement.
- **max** -- Correctness matters more than cost. Expect
  diminishing returns and occasional overthinking; reserve it for
  steps where a wrong answer would be expensive to detect.

**Brief for sub-agent:** this is the key field. Write it as if
briefing a colleague who has never seen the codebase. Include what
to change, which files to touch, what patterns to follow, and any
non-obvious constraints.

A good brief front-loads the research the planner already did, so
the implementing agent does not repeat it. Instead of "add storage
functions for the new object", name the functions to add, the file
they belong in, the existing equivalent to mirror (with line
numbers), and any registration the change also needs.

The better the brief, the lower the effort level needed and the
lighter the model that can succeed.
<!-- shared-block-end -->

**In this repository.** A worked brief: instead of "fix the Debian
12 desktop builds", write "in `build.sh`, the `debian-docker:12`,
`debian-gnome:12` and `debian-xfce:12` blocks pass `bullseye` as
the release argument while naming the `debian-12-extras` element;
change the release argument to `bookworm` in those three blocks
only, leave the plain `debian:12` block alone because it is already
correct, and do not touch the `:11` blocks which are genuinely
bullseye."

Name the image, name the block, and say which neighbouring blocks
must not change. The blocks in `build.sh` are near-identical to one
another and were originally created by copy-paste, which is exactly
how the two-year mislabelling happened; a brief that does not say
where to stop invites the same error.

### Model choice

<!-- shared-block: subagent-model-roster v1 -->
Sub-agent model roster (shared block; do not edit -- the canonical
copy lives in shakenfist/development at
`templates/shared-blocks/subagent-model-roster.md`):

The planner recommends which model is best suited to each step.
This is a judgment call, not a rigid rule -- the right model
depends on what the step requires, not on whether it is "planning"
or "implementation". The models available to sub-agents are:

- **fable** -- The most capable model available, for the hardest
  reasoning and the longest-horizon work: multi-step changes a
  single sub-agent must carry end to end, or steps whose
  correctness depends on holding a whole subsystem in mind at
  once. It costs materially more than opus, so reserve it for
  steps that have already defeated opus or are expected to.
- **opus** -- The default for steps needing deep reasoning,
  architectural understanding, subtle correctness judgment
  (locking, state machines, migrations), or intricate
  implementation that would be costly to debug if it were wrong.
- **sonnet** -- A good default for well-briefed implementation
  work. Faster and cheaper than opus, and effective when the plan
  front-loads the research and the brief leaves no broad judgment
  calls to make.
- **haiku** -- Suitable for purely mechanical tasks:
  search-and-replace, regenerating generated code, adding log
  lines, running commands. The brief must be a near-complete
  instruction.

Model choice interacts with effort level and brief quality. A
detailed brief compensates for a lighter model -- sonnet at medium
effort with a thorough brief often matches opus at medium effort
with a vague brief. The planner's job is to write briefs good
enough that the recommended model can succeed.

The model also determines the context window: fable, opus and
sonnet have 1M tokens, haiku has 200K. A step that must hold many
files in context at once may need one of the larger-context models
for that reason alone, even when the reasoning itself is
straightforward.

**When in doubt, skew to the more capable model.** Saving money
only matters if the outcome is still acceptable. A failed or
low-quality implementation wastes more time -- and therefore more
money -- than the heavier model would have cost. Recommend a
lighter model only when you are confident the brief is detailed
enough for it to succeed.
<!-- shared-block-end -->

**In this repository.** Skew heavier than you would elsewhere. The
cost of a wrong answer is not a failed test, it is a published
image that somebody boots in three months' time, and the cheap
signal that would have caught it does not exist.

The project-specific checks referred to above are:

- [ ] `bash -n build.sh` parses, and `shellcheck build.sh` reports
      no finding that was not already there. There is no
      `.pre-commit-config.yaml` yet, and shellcheck is not
      installed on every host -- `docker run --rm -v "$PWD:/mnt"
      -w /mnt koalaman/shellcheck:stable build.sh` works anywhere
      Docker does.
- [ ] Any change to `build.sh`, `elements/` or
      `block-device-compat.yaml` has had **at least one affected
      image actually built** before the change is proposed, and
      the plan records which image and where the log is. A change
      to the Debian elements is verified by building a Debian
      image, not by building whatever is quickest.
- [ ] If `block-device-compat.yaml` changed,
      `tools/check-block-device-config.sh` still passes -- it is a
      copy of a DIB default and drift from upstream is the failure
      it exists to catch.
- [ ] Nothing added to the default image list that has not been
      observed building. An entry that has never succeeded is
      worse than no entry: it consumes a build slot every night
      and trains everyone to ignore the failure.

### Management session review checklist

<!-- shared-block: plan-review-checklist v1 -->
Management session review checklist (shared block; do not edit --
the canonical copy lives in shakenfist/development at
`templates/shared-blocks/plan-review-checklist.md`):

After a sub-agent completes, the management session verifies:

- [ ] The files that were supposed to change actually changed --
      read them, do not trust the summary.
- [ ] No unrelated files were modified.
- [ ] The changes match the intent of the brief: not merely
      syntactically correct, but semantically right.
- [ ] The project's own pre-merge checks pass, including any
      generated code that has to be regenerated and committed
      (see the project-specific checks below).
- [ ] The commit message follows project conventions, including
      the `Co-Authored-By` line recording model, context window,
      and effort level.
<!-- shared-block-end -->

## Administration and logistics

### Success criteria

We will know when this plan has been successfully implemented
because the following statements will be true:

* Every image in the default list in `build.sh` has been observed
  building successfully, and the plan names the run.
* No image was removed from the default list without the plan
  saying what happens to the copies already published -- dropping
  an image from the list stops it being refreshed, it does not
  unpublish it, and the two are routinely confused.
* A change to any element is reflected in `ARCHITECTURE.md`'s
  description of the element groups, which is the only written
  description of what distinguishes them.
* Documentation in `docs/` describes any user-visible change.
  `AGENTS.md` changes only if a convention changed;
  `ARCHITECTURE.md` only if the shape of the build pipeline
  changed; `README.md` only if the pitch, the install story or the
  documentation links changed.
* Anything the plan could not verify is stated as unverified,
  naming what would have verified it. In a repository where the
  test is a one-hour build on a machine you may not have, "I could
  not check this" is an acceptable result and a silent assumption
  is not.

### Documentation index maintenance

When creating a new master plan from this template, add one row to
the table in `docs/plans/index.md`: the date the plan was written,
a link to it, a one-line intent, and its status from the
vocabulary above. Rows run oldest first. One row per master plan,
never one per phase -- the phases are tracked in the plan's own
Execution table, and duplicating them in the index is how the two
drift apart.

The index row carries the whole-plan status, so it only reaches
`Complete` once every phase has been completed, abandoned or
superseded. Update it as the plan progresses, not only at the end.

<!-- shared-block: plan-closeout-sections v1 -->
Plan close-out sections (shared block; do not edit -- the
canonical copy lives in shakenfist/development at
`templates/shared-blocks/plan-closeout-sections.md`):

### Future work

We should list obvious extensions, known issues, unrelated bugs we
encountered, and anything else we should one day do but have
chosen to defer to here, so that we do not forget them.

...

### Bugs fixed during this work

This section should list any bugs we encounter during development
that we fixed. You should also scan the project's issue tracker,
where one exists, for directly related issues that we should
either resolve as part of this master plan or at least be aware of
while planning it.

...

### Back brief

Before executing any step of this plan, please back brief the
operator as to your understanding of the plan and how the work you
intend to do aligns with that plan.
<!-- shared-block-end -->
