#!/usr/bin/env bash
# Part 2 of ruleset_bypass setup. Run AFTER installing the GitHub App on this repo
# (https://github.com/settings/apps/my-changeflow-app -> Install App) -- GitHub rejects
# an Integration bypass_actor that isn't installed on the repo yet.
set -euo pipefail

: "${GH_OWNER:?set GH_OWNER to your github user or org}"
: "${REPO_NAME:=changeflow-test-ruleset-bypass}"
: "${APP_ID:?set APP_ID to the numeric App ID from https://github.com/settings/apps/my-changeflow-app}"

echo "==> Creating branch ruleset on main (PR + 'validate' check, App bypasses via APP_ID=$APP_ID)"
gh api -X POST "repos/$GH_OWNER/$REPO_NAME/rulesets" --input - >/dev/null <<EOF
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "pull_request"},
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [{"context": "validate"}],
        "strict_required_status_checks_policy": true
      }
    }
  ],
  "bypass_actors": [
    {"actor_id": $APP_ID, "actor_type": "Integration", "bypass_mode": "pull_request"}
  ]
}
EOF

cat <<MSG

Done. Confirm in Settings -> Rules -> Rulesets -> main-protection that the App's bypass is
scoped to "Pull requests only" (bypass_mode=pull_request maps there) -- the REST API doesn't
expose every nuance the UI does, worth eyeballing once.

Then point changeflow at it (see README.md "Run changeflow against it").
MSG
