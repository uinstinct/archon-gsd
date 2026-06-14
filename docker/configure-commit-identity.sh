#!/usr/bin/env sh
# Bake the bot's commit identity and disable Claude Code's co-author trailer.
#
# Both pieces of config are written to image-layer paths that live OUTSIDE
# /home/appuser, because Archon mounts the archon_user_home named volume over
# that home at runtime and the mount SHADOWS anything baked under it (the same
# rule the GSD seed entrypoint works around — see docs/adr/0001). System git
# config (/etc/gitconfig) and Claude's managed-settings.json (/etc/claude-code)
# are not under the home, so they survive the mount with no per-boot seeding.
#
# Shared verbatim by docker/Dockerfile.user (the production image) and
# tests/commit-identity.test.sh, which overrides the two paths below to assert
# the behaviour without building an image. Run as root.
#
# Inputs (env):
#   COMMIT_AUTHOR_NAME    e.g. "archon-instinct[bot]" — the only value you must
#                         set. Absent = leave the ambient identity untouched.
#   COMMIT_AUTHOR_EMAIL   optional override. When unset, it is DERIVED from the
#                         name as GitHub's canonical bot no-reply address:
#                         <user-id>+<login>@users.noreply.github.com, where
#                         <login> is COMMIT_AUTHOR_NAME verbatim and <user-id>
#                         comes from the public users API.
#
# Test overrides (defaulted to the real container paths / endpoint):
#   GIT_CONFIG_SYSTEM         system git config file (git honours this natively)
#   CLAUDE_MANAGED_SETTINGS   Claude Code managed-settings.json path
#   GITHUB_API_BASE           users-API base (default https://api.github.com)
set -eu

MANAGED="${CLAUDE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"

# derive_bot_email <login> -> "<user-id>+<login>@users.noreply.github.com"
# Looks up the numeric account id via the public users API. -g disables curl's
# glob parsing so the "[bot]" brackets in the login stay literal. Returns
# non-zero (echoing nothing) when the lookup or id parse fails.
derive_bot_email() {
  login="$1"
  base="${GITHUB_API_BASE:-https://api.github.com}"
  json="$(curl -fsSLg "${base}/users/${login}")" || return 1
  # The first "id": field in the user payload is the account id ("node_id" /
  # "gravatar_id" never match — no quote precedes their "id"). Strip spaces so
  # the grep works on both pretty and compact JSON.
  id="$(printf '%s' "$json" | tr -d ' ' | grep -o '"id":[0-9][0-9]*' | head -n1 | cut -d: -f2)"
  [ -n "$id" ] || return 1
  printf '%s+%s@users.noreply.github.com' "$id" "$login"
}

# 1. Commit author (the bot). git resolves the system config only when no
#    GIT_AUTHOR_* env, repo-local, or ~/.gitconfig identity is set — which is
#    exactly the App-only mode case (Archon sets a worktree-local user.email
#    only for connected per-user installs). Skip when the name is unset so an
#    empty value never produces git's "empty ident name" error at commit time.
if [ -n "${COMMIT_AUTHOR_NAME:-}" ]; then
  if [ -z "${COMMIT_AUTHOR_EMAIL:-}" ]; then
    COMMIT_AUTHOR_EMAIL="$(derive_bot_email "${COMMIT_AUTHOR_NAME}")" || {
      echo "FATAL: could not derive a no-reply email for '${COMMIT_AUTHOR_NAME}'" >&2
      echo "       from the GitHub users API. Set COMMIT_AUTHOR_EMAIL explicitly" >&2
      echo "       in .env, or unset COMMIT_AUTHOR_NAME to keep the ambient identity." >&2
      exit 1
    }
    echo "==> Derived commit email for ${COMMIT_AUTHOR_NAME}: ${COMMIT_AUTHOR_EMAIL}"
  fi
  git config --system user.name "${COMMIT_AUTHOR_NAME}"
  git config --system user.email "${COMMIT_AUTHOR_EMAIL}"
  echo "==> Baked commit author: ${COMMIT_AUTHOR_NAME} <${COMMIT_AUTHOR_EMAIL}>"
else
  echo "==> COMMIT_AUTHOR_NAME not set; commits keep the ambient git identity"
fi
# 2. Disable Claude Code's "Co-Authored-By: Claude" / "Generated with Claude
#    Code" commit + PR trailer. managed-settings.json is the highest-precedence
#    Claude settings layer (cannot be overridden by ~/.claude), so the policy
#    holds for every run regardless of what the seeded home volume carries.
mkdir -p "$(dirname "$MANAGED")"
printf '%s\n' '{ "includeCoAuthoredBy": false }' >"$MANAGED"
echo "==> Wrote $MANAGED (includeCoAuthoredBy=false)"
