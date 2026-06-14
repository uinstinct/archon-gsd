#!/usr/bin/env bash
# Commit-identity test. Runs docker/configure-commit-identity.sh — the exact
# script Dockerfile.user bakes in — against override paths so the behaviour is
# proven without building an image:
#   - GIT_CONFIG_SYSTEM        a temp file standing in for /etc/gitconfig
#   - CLAUDE_MANAGED_SETTINGS  a temp file standing in for the Claude policy
# Then asserts a fresh repo with NO local/global identity (the App-only-mode
# case) resolves the baked author, and that the co-author trailer is disabled.
source "$(dirname "$0")/lib/common.sh"

echo "commit-identity"

SCRIPT="$REPO_ROOT/docker/configure-commit-identity.sh"

NAME="archon-instinct[bot]"
EMAIL="1234567+archon-instinct[bot]@users.noreply.github.com"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SYSCFG="$WORK/gitconfig"
MANAGED="$WORK/managed-settings.json"

# Isolate from the host's real git identity: empty global + XDG, no NOSYSTEM.
export HOME="$WORK/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$WORK/xdg"; mkdir -p "$XDG_CONFIG_HOME"
export GIT_CONFIG_GLOBAL="$WORK/global-gitconfig"; : >"$GIT_CONFIG_GLOBAL"
unset GIT_CONFIG_NOSYSTEM 2>/dev/null || true

# resolve_in_fresh_repo <key> — what `git config <key>` returns in a clean repo
# with only the system file (our SYSCFG) populated, mirroring a fresh worktree.
resolve_in_fresh_repo() {
  local key="$1" repo
  repo="$(mktemp -d)"
  ( cd "$repo" && git init -q && GIT_CONFIG_SYSTEM="$SYSCFG" git config "$key" )
  local rc=$?
  rm -rf "$repo"
  return $rc
}
resolve_val() {
  local key="$1" repo val
  repo="$(mktemp -d)"
  val="$(cd "$repo" && git init -q && GIT_CONFIG_SYSTEM="$SYSCFG" git config "$key" 2>/dev/null || true)"
  rm -rf "$repo"
  printf '%s' "$val"
}

# --- Case A: both author vars set -> baked into system git config -------------
GIT_CONFIG_SYSTEM="$SYSCFG" CLAUDE_MANAGED_SETTINGS="$MANAGED" \
  COMMIT_AUTHOR_NAME="$NAME" COMMIT_AUTHOR_EMAIL="$EMAIL" \
  sh "$SCRIPT" >/dev/null 2>&1 || { fail "script exited non-zero (case A)"; }

[ "$(resolve_val user.name)" = "$NAME" ] \
  && pass "system git user.name resolves to the bot" \
  || fail "user.name = '$(resolve_val user.name)', expected '$NAME'"

[ "$(resolve_val user.email)" = "$EMAIL" ] \
  && pass "system git user.email resolves to the bot no-reply" \
  || fail "user.email = '$(resolve_val user.email)', expected '$EMAIL'"

# Co-author trailer disabled, and the file is valid JSON.
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('includeCoAuthoredBy') is False else 1)" "$MANAGED"; then
  pass "managed-settings.json sets includeCoAuthoredBy=false (valid JSON)"
else
  fail "managed-settings.json missing/!=false or invalid JSON"
fi

# --- Case A2: only the name set -> email derived from the GitHub users API ----
# Point GITHUB_API_BASE at a local fixture (curl reads it via file://) so the
# derivation is proven without the network. The id below is the real account id
# for archon-instinct[bot]; EMAIL above is "<id>+<login>@users.noreply...".
: >"$SYSCFG"; rm -f "$MANAGED"
APIDIR="$WORK/api/users"; mkdir -p "$APIDIR"
printf '{ "login": "%s", "id": 1234567, "node_id": "X", "gravatar_id": "" }\n' "$NAME" >"$APIDIR/$NAME"
GIT_CONFIG_SYSTEM="$SYSCFG" CLAUDE_MANAGED_SETTINGS="$MANAGED" \
  GITHUB_API_BASE="file://$WORK/api" COMMIT_AUTHOR_NAME="$NAME" \
  sh "$SCRIPT" >/dev/null 2>&1 || { fail "script exited non-zero (case A2)"; }

[ "$(resolve_val user.email)" = "$EMAIL" ] \
  && pass "user.email derived from name + api id when EMAIL unset" \
  || fail "derived user.email = '$(resolve_val user.email)', expected '$EMAIL'"

# --- Case A3: only the name set but the lookup fails -> hard error -------------
: >"$SYSCFG"
GIT_CONFIG_SYSTEM="$SYSCFG" CLAUDE_MANAGED_SETTINGS="$MANAGED" \
  GITHUB_API_BASE="file://$WORK/does-not-exist" COMMIT_AUTHOR_NAME="$NAME" \
  sh "$SCRIPT" >/dev/null 2>&1 \
  && fail "script should exit non-zero when the email cannot be derived" \
  || pass "derivation failure is a hard error (no silent ambient fallback)"

# --- Case B: author vars unset -> no system identity, but trailer still off ---
: >"$SYSCFG"; rm -f "$MANAGED"
GIT_CONFIG_SYSTEM="$SYSCFG" CLAUDE_MANAGED_SETTINGS="$MANAGED" \
  sh "$SCRIPT" >/dev/null 2>&1 || { fail "script exited non-zero (case B)"; }

if resolve_in_fresh_repo user.email >/dev/null 2>&1; then
  fail "user.email unexpectedly set when author vars absent"
else
  pass "no system identity written when author vars are unset"
fi
[ -f "$MANAGED" ] \
  && pass "co-author trailer disabled even without author vars" \
  || fail "managed-settings.json not written in case B"

# --- Wiring guards: catch accidental unwiring of the build path --------------
DF="$REPO_ROOT/docker/Dockerfile.user"
grep -q 'configure-commit-identity.sh' "$DF" \
  && grep -q 'COMMIT_AUTHOR_NAME' "$DF" \
  && pass "Dockerfile.user runs configure-commit-identity.sh with the author args" \
  || fail "Dockerfile.user does not wire configure-commit-identity.sh"

OV="$REPO_ROOT/docker-compose.override.yml"
grep -q 'COMMIT_AUTHOR_NAME: ${COMMIT_AUTHOR_NAME' "$OV" \
  && grep -q 'COMMIT_AUTHOR_EMAIL: ${COMMIT_AUTHOR_EMAIL' "$OV" \
  && pass "compose override forwards COMMIT_AUTHOR_* from .env as build args" \
  || fail "compose override does not forward the COMMIT_AUTHOR_* build args"

summary
