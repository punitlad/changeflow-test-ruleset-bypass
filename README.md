# changeflow test target: `ruleset_bypass`

Validates `CHANGEFLOW_MERGE_MODE=ruleset_bypass` — changeflow merges the PR directly via
`PUT /pulls/{n}/merge`, relying on the App being on the branch ruleset's bypass list rather
than on any check passing.

## What's here

| File | Purpose |
|---|---|
| `teams.json` | The file changeflow appends `{"team": "<name>"}` to |
| `.github/workflows/ci.yml` | PR-time check, scoped to PRs opened by the App — the ruleset's required check (bypassed by the App, would block a human PR) |
| `.github/workflows/deploy.yml` | The pipeline triggered by the merge, scoped to pushes actored by the App, gated by the `production` environment |
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
./setup.sh

# Step 2: install the App (manual, see setup.sh's printed instructions), THEN:
export APP_ID=<numeric App ID from the App settings page>
./finish-ruleset.sh
```

`setup.sh` will:
1. `gh repo create` (if `REPO_NAME` doesn't exist yet) and push this directory to it
2. Create the `production` environment with `punitlad` as a required reviewer

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
export CHANGEFLOW_APPROVER_TOKEN=<a PAT for punitlad with repo + workflow scope>
# ...plus CHANGEFLOW_APP_ID / CHANGEFLOW_APP_PRIVATE_KEY / CHANGEFLOW_INSTALLATION_ID
uvicorn changeflow.api:app
curl -XPOST localhost:8000/team-onboardings -d '{"team":"payments","requested_by":"you"}'
```

## What "validated" looks like

`GET /team-onboardings/{id}` reaches `phase: succeeded` with `merging` → `merged` happening
almost instantly (no wait on checks) — the App's `PUT /pulls/{n}/merge` call is what merges it,
confirmed by the merge commit's author being the App's bot identity, not a human.

## Identity-scoped gating (defense in depth on top of the bypass list)

Both workflows here are scoped to the App's identity rather than running unconditionally:

- `ci.yml`'s `validate` job only runs `if: github.event.pull_request.user.login ==
  'my-changeflow-app[bot]'`. Since this repo's only expected PR author is changeflow, this is
  safe; **don't** do this on a repo that also takes human PRs against the same required check
  (a skipped job never posts a status, so a human PR would block forever).
- `deploy.yml`'s `deploy` job only runs `if: github.actor == 'my-changeflow-app[bot]'`.
  Verified against a real run that `github.actor` reliably reflects the App's bot login for
  pushes resulting from its own API merges (not just the ruleset bypass actor's identity on
  paper — the actual push event attribution). This means the production pipeline only
  auto-fires for merges changeflow itself performed, even though the ruleset bypass alone
  would also permit e.g. an admin's direct push to land on `main` and trigger the same event.
