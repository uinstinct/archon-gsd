#!/usr/bin/env bash
# create-branch: after the node runs, fix/issue-<N> must exist and be based on
# BASE_BRANCH (the Shell owns branching because GSD's strategy is `none`).
source "$(dirname "$0")/lib/common.sh"

echo "create-branch"

SCRIPT="$(mktemp)"
extract_bash create-branch "$SCRIPT"
# Mirror the executor: the $extract-issue-number.output token is substituted to
# the AI's bare-number output before the bash node runs.
subst "$SCRIPT" '$extract-issue-number.output' '42'

# 1. Creates fix/issue-42 off BASE_BRANCH=main.
repo="$(make_git_fixture main)"
(
  cd "$repo"
  base_tip="$(git rev-parse main)"
  BASE_BRANCH=main bash "$SCRIPT" >/dev/null
  [ "$(git branch --show-current)" = "fix/issue-42" ] \
    && git show-ref --verify --quiet refs/heads/fix/issue-42
) && pass "creates fix/issue-42 and checks it out" \
  || fail "did not create/checkout fix/issue-42"

# 2. The new branch is based on BASE_BRANCH (shares its tip as merge-base).
(
  cd "$repo"
  base_tip="$(git rev-parse main)"
  mb="$(git merge-base main fix/issue-42)"
  [ "$mb" = "$base_tip" ]
) && pass "fix/issue-42 is based on BASE_BRANCH (main)" \
  || fail "fix/issue-42 is not based on main"

# 3. Honours a non-default BASE_BRANCH.
repo2="$(make_git_fixture develop)"
(
  cd "$repo2"
  base_tip="$(git rev-parse develop)"
  BASE_BRANCH=develop bash "$SCRIPT" >/dev/null
  mb="$(git merge-base develop fix/issue-42)"
  [ "$(git branch --show-current)" = "fix/issue-42" ] && [ "$mb" = "$base_tip" ]
) && pass "branches off a non-default BASE_BRANCH (develop)" \
  || fail "did not branch off develop"

# 4. Fails when BASE_BRANCH is unset.
repo3="$(make_git_fixture main)"
(
  cd "$repo3"
  unset BASE_BRANCH || true
  ! bash "$SCRIPT" >/dev/null 2>&1
) && pass "fails when BASE_BRANCH is unset" \
  || fail "should fail with unset BASE_BRANCH"

summary
