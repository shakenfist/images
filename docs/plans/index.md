# Plans

Planning documents for this repository. One row per master plan,
oldest first. Phases are tracked inside each plan's own Execution
table, not here -- duplicating them is how the two drift apart.

Plans here keep their phases as sections inside the master plan
rather than as separate phase files, so the Execution table drops
the `Plan` column that the fleet convention in `PLAN-TEMPLATE.md`
otherwise calls for.

Status values come from the shared vocabulary in
`PLAN-TEMPLATE.md`: `Proposed`, `Not started`, `In progress`,
`Blocked`, `Complete`, `Abandoned`, `Superseded`.

| Date | Plan | Intent | Status |
|------|------|--------|--------|
| 2026-09-12 | [PLAN-image-build-modernisation.md](PLAN-image-build-modernisation.md) | Move image builds off an unmonitored cron job and make a failed or missing build visible | In progress |
