#!/usr/bin/env bash
# One-time GitHub-side setup for the ruleset_bypass test target, part 1.
# Requires: gh CLI authenticated (`gh auth login`) with admin on the target owner/org.
#
# NOTE: the branch ruleset (with the App on the bypass list) is created by
# finish-ruleset.sh, not here. GitHub rejects a ruleset bypass_actor for an App that
# isn't installed on the repo yet ("Actor ... integration must be part of the ruleset
# source or owner organization") -- so install the App first, *then* run finish-ruleset.sh.
set -euo pipefail

: "${GH_OWNER:?set GH_OWNER to your github user or org}"
: "${REPO_NAME:=changeflow-test-ruleset-bypass}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-punitlad}"

echo "==> Repo: $GH_OWNER/$REPO_NAME"

if gh repo view "$GH_OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "    already exists, pushing current content"
  git remote add origin "https://github.com/$GH_OWNER/$REPO_NAME.git" 2>/dev/null || true
  git push -u origin main
else
  echo "    creating + pushing"
  gh repo create "$GH_OWNER/$REPO_NAME" --public --source=. --remote=origin --push
fi

echo "==> Creating 'production' environment with $REVIEWER_LOGIN as required reviewer"
REVIEWER_ID=$(gh api "users/$REVIEWER_LOGIN" --jq .id)
gh api -X PUT "repos/$GH_OWNER/$REPO_NAME/environments/production" --input - >/dev/null <<EOF
{
  "reviewers": [{"type": "User", "id": $REVIEWER_ID}],
  "deployment_branch_policy": null
}
EOF

cat <<MSG

Done with part 1. Before the ruleset can be created:

  1. Install the GitHub App on this repo:
     https://github.com/settings/apps/my-changeflow-app -> Install App -> $GH_OWNER/$REPO_NAME
     (GitHub rejects adding an App as a ruleset bypass actor until it's installed on the repo.)

  2. Then run:
     GH_OWNER=$GH_OWNER REPO_NAME=$REPO_NAME APP_ID=<numeric-app-id> ./finish-ruleset.sh
MSG
