# Agents

This repository has no Claude Code skills. Pull requests are reviewed
by the fleet's automated reviewer, from `ci.yml` and
`pr-re-review.yml`. Image builds are triggered manually or via cron on
the image build server.

Run `pre-commit run --all-files` and `tools/run-tests.sh` before
committing. `ci.yml` runs both on every pull request, so a skipped
local run only moves the failure later.

## Where to look

* [docs/build-host.md](docs/build-host.md) -- how the build host runs
  `build.sh`, how it keeps itself up to date, and where its
  configuration lives.
* [docs/plans/index.md](docs/plans/index.md) -- the plans for this
  repository and their status. Plans are written from
  `PLAN-TEMPLATE.md`.
* [ARCHITECTURE.md](ARCHITECTURE.md) -- the build pipeline and the
  element system.
