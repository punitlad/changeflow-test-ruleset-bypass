# changeflow test target: `ruleset_bypass`

Validates `CHANGEFLOW_MERGE_MODE=ruleset_bypass` — changeflow merges the PR directly via
`PUT /pulls/{n}/merge`, relying on the App being on the branch ruleset's bypass list rather
than on any check passing. **Validated end-to-end, including both the human and App paths
separately (see "What validated looks like" below) — this is the mode we're taking forward.**

This repo deliberately supports **two ways onto `main`**, not just the App's:

| Path | Flow | Gated by |
|---|---|---|
| Human | open a PR → `ci.yml`'s `validate` check must pass → merge normally | the ruleset (no bypass for a human identity) |
| The App | open a PR (changeflow always does) → merge immediately via `PUT /pulls/{n}/merge` | the ruleset's bypass list |

And correspondingly **two mutually exclusive push-triggered pipelines**, one per path —
exactly one of the two runs its job per push, based on `github.actor`:

| Workflow | Runs for | changeflow polls this? |
|---|---|---|
| `deploy.yml` | human merges (`if: github.actor != 'my-changeflow-app[bot]'`) | no |
| `app-merge.yml` | the App's own merges (`if: github.actor == 'my-changeflow-app[bot]'`) | **yes** — `CHANGEFLOW_PIPELINE_WORKFLOW_FILE=app-merge.yml` |

changeflow's `find_run()` only ever looks at merge SHAs *it* produced, so it only cares about
`app-merge.yml` here — set `CHANGEFLOW_PIPELINE_WORKFLOW_FILE=app-merge.yml` when pointing it at
this repo (already set in `api-repo/.env.ruleset-bypass`), since the default
(`deploy.yml`) now deliberately never runs for the App's merges.

## What's here

| File | Purpose |
|---|---|
| `teams.json` | The file changeflow appends `{"team": "<name>"}` to |
| `.github/workflows/ci.yml` | PR-time check, unscoped — the ruleset's required check, satisfied by either path |
| `.github/workflows/deploy.yml` | The human-path pipeline, gated by the `production` environment |
| `.github/workflows/app-merge.yml` | The App-path pipeline — this is what changeflow actually polls, gated by the `production` environment |
| `setup.sh` | One-time `gh` CLI setup for this repo (ruleset + bypass actor, environment) |

## Why this mode specifically needs this layout

This is the biggest trust grant of the three: the App skips the ruleset entirely, including
the required status check and required PR, for its own merges. `setup.sh` adds the App as a
**bypass actor scoped to "pull requests only"** where the API allows it — confirm that scope
held in the repo's Settings → Rules → Rulesets UI, since the REST API's bypass mode options
are coarser than the UI's.

You need the App's **numeric App ID** for this (not the slug) — found at the top of
`https://github.com/settings/apps/my-changeflow-app`.

**Setup is two steps, in order, because GitHub rejects the bypass_actor otherwise:**
`POST /rulesets` with an `Integration` bypass actor 422s with *"Actor ... integration must be
part of the ruleset source or owner organization"* until the App is actually installed on the
repo. So the repo has to exist and the App has to be installed on it *before* the ruleset step.

## One-time setup

```bash
# Step 1: create/push the repo, set up the approval environment
export GH_OWNER=<your-github-user-or-org>
export REPO_NAME=changeflow-test-ruleset-bypass
export REVIEWER_LOGIN=<github-login-for-the-required-reviewer>   # defaults to punitlad
./setup.sh

# Step 2: install the App (manual, see setup.sh's printed instructions), THEN:
export APP_ID=<numeric App ID from the App settings page>
./finish-ruleset.sh
```

`setup.sh` will:
1. `gh repo create` (if `REPO_NAME` doesn't exist yet) and push this directory to it
2. Create the `production` environment with `$REVIEWER_LOGIN` (`punitlad` by default) as a
   required reviewer

`finish-ruleset.sh` (after the App is installed) will:
1. Create a branch ruleset on `main`: require a pull request + the `validate` status check,
   with the App (`actor_type=Integration`, `actor_id=$APP_ID`) on the bypass list

Afterwards, double-check in the repo's ruleset UI (Settings → Rules → Rulesets →
main-protection) that the bypass is scoped to "Pull requests only" rather than "Always" if you
want the App to still be blocked from e.g. force-pushing to `main` directly.

## Run changeflow against it

```bash
export CHANGEFLOW_TARGET_OWNER=$GH_OWNER
export CHANGEFLOW_TARGET_REPO=$REPO_NAME
export CHANGEFLOW_MERGE_MODE=ruleset_bypass
export CHANGEFLOW_MERGE_METHOD=squash
export CHANGEFLOW_APPROVAL_MODE=pending_deployments
export CHANGEFLOW_PIPELINE_ENVIRONMENT=production
export CHANGEFLOW_APPROVER_TOKEN=<a PAT for whoever REVIEWER_LOGIN was set to (punitlad by default), with repo + workflow scope>
# ...plus CHANGEFLOW_APP_ID / CHANGEFLOW_APP_PRIVATE_KEY / CHANGEFLOW_INSTALLATION_ID
uvicorn changeflow.api:app
curl -XPOST localhost:8000/team-onboardings -d '{"team":"payments","requested_by":"you"}'
```

## What "validated" looks like

For the App path: `GET /team-onboardings/{id}` reaches `phase: succeeded` with `merging` →
`merged` happening almost instantly (no wait on checks) — the App's `PUT /pulls/{n}/merge` call
is what merges it. On GitHub, confirm `app-merge.yml` ran (`conclusion: success`) and
`deploy.yml` did **not** run its job for that same SHA (`conclusion: skipped`, since
`github.actor` was the App).

For the human path: open and merge a PR normally (no bypass), confirm `deploy.yml` ran and
`app-merge.yml` skipped — the mirror image — and that the `production` approval has to be
granted manually (or by whatever separate automation you stand up for human deploys; changeflow
only auto-approves its own merges).

## Why two workflows instead of one shared, identity-branching workflow

Both pipelines are gated behind the same `production` environment and read the same
`teams.json`, but kept as separate files rather than one `deploy.yml` with an if/else inside:
cleaner Actions UI history (each run is unambiguously "the human pipeline" or "the App
pipeline," not a single run whose steps conditionally no-op), and changeflow's own
`find_run()` only has to know one workflow filename to poll instead of parsing which branch
of a shared job actually executed. `github.actor` was confirmed against a real run to reliably
reflect the App's bot login for pushes resulting from its own API merges, which is what makes
the `if:` scoping on both files trustworthy rather than guesswork.

## Trade-offs for team discussion

- **Largest trust grant of the three** — the App can merge its own PRs with no check and no
  review, full stop. The bypass list is a standing grant, not a per-PR decision; anyone with
  write access to the App's credentials can merge anything on this branch, any time the App
  has an open PR.
- **Fastest of the three** — `merging` → `merged` is near-instant, vs. ~30-40s waiting on a
  check (`native_auto_merge`) or however long their own workflow takes to notice and act
  (`workflow_gated`).
- **One-time setup cost, not ongoing maintenance** — the trust grant is a ruleset config
  change on their side, done once. Compare to `workflow_gated`, where they maintain a workflow
  file whose correctness changeflow depends on indefinitely.
- **The two-path design here (human + App, mutually exclusive pipelines) is *our* addition,
  not inherent to the mode** — a target repo adopting `ruleset_bypass` doesn't have to support
  a human path at all if they don't want one; we built it because we wanted ordinary
  maintenance PRs to keep working without needing the App's bypass.
- **Biggest ask of the target team** — "give our App's identity standing bypass rights on your
  protected branch" is a harder sell than the other two modes' asks, and is the thing most
  likely to need a security review on their end before they agree.
<!-- scenario 1 validation run -->
