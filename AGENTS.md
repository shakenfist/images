# Agents

This repository has no Claude Code skills. Pull requests are reviewed
by the fleet's automated reviewer, from `ci.yml` and
`pr-re-review.yml`. Image builds are triggered manually, or nightly by
the conductor dispatching `image-build.yml`.

Run `pre-commit run --all-files` and `tools/run-tests.sh` before
committing. `ci.yml` runs both on every pull request, so a skipped
local run only moves the failure later.

## Where to look

* [docs/nightly-build.md](docs/nightly-build.md) -- how the nightly
  build is dispatched, how to rebuild an image by hand, and where its
  logs go.
* [docs/plans/index.md](docs/plans/index.md) -- the plans for this
  repository and their status. Plans are written from
  `PLAN-TEMPLATE.md`.
* [ARCHITECTURE.md](ARCHITECTURE.md) -- the build pipeline and the
  element system.
