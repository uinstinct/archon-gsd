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
# Inputs (env; both optional — absent = leave the ambient identity untouched):
#   COMMIT_AUTHOR_NAME    e.g. "archon-instinct[bot]"
#   COMMIT_AUTHOR_EMAIL   e.g. "1234567+archon-instinct[bot]@users.noreply.github.com"
#
# Test overrides (defaulted to the real container paths):
#   GIT_CONFIG_SYSTEM         system git config file (git honours this natively)
#   CLAUDE_MANAGED_SETTINGS   Claude Code managed-settings.json path
set -eu

MANAGED="${CLAUDE_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"

# 1. Commit author (the bot). git resolves the system config only when no
#    GIT_AUTHOR_* env, repo-local, or ~/.gitconfig identity is set — which is
#    exactly the App-only mode case (Archon sets a worktree-local user.email
#    only for connected per-user installs). Skip when unset so an empty value
#    never produces git's "empty ident name" error at commit time.
if [ -n "${COMMIT_AUTHOR_NAME:-}" ] && [ -n "${COMMIT_AUTHOR_EMAIL:-}" ]; then
  git config --system user.name "${COMMIT_AUTHOR_NAME}"
  git config --system user.email "${COMMIT_AUTHOR_EMAIL}"
  echo "==> Baked commit author: ${COMMIT_AUTHOR_NAME} <${COMMIT_AUTHOR_EMAIL}>"
else
  echo "==> COMMIT_AUTHOR_NAME/EMAIL not set; commits keep the ambient git identity"
fi

# 2. Disable Claude Code's "Co-Authored-By: Claude" / "Generated with Claude
#    Code" commit + PR trailer. managed-settings.json is the highest-precedence
#    Claude settings layer (cannot be overridden by ~/.claude), so the policy
#    holds for every run regardless of what the seeded home volume carries.
mkdir -p "$(dirname "$MANAGED")"
printf '%s\n' '{ "includeCoAuthoredBy": false }' >"$MANAGED"
echo "==> Wrote $MANAGED (includeCoAuthoredBy=false)"
