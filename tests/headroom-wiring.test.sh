#!/usr/bin/env bash
# headroom wiring guards. The headroom proxy is a sidecar service carried by
# docker-compose.override.yml (no baked image layer), so the slow container smoke
# build can't catch a broken wiring. These are the cheap, always-run shell-plumbing
# checks that catch the regression: a refactor that drops the proxy sidecar, stops
# pointing Claude Code at it, or — critically — drops ENABLE_TOOL_SEARCH (GH #746),
# which would silently bloat every run and break sub-agents. Mirrors the wiring
# guards in commit-identity.test.sh.
source "$(dirname "$0")/lib/common.sh"

echo "headroom wiring"

OV="$REPO_ROOT/docker-compose.override.yml"

# The proxy sidecar exists and runs `headroom proxy`.
grep -qE '^  headroom:' "$OV" \
  && pass "override defines the headroom sidecar service" \
  || fail "override is missing the headroom sidecar service"
grep -q '"headroom", "proxy"' "$OV" \
  && pass "headroom service runs the proxy entrypoint" \
  || fail "headroom service does not run \`headroom proxy\`"

# The proxy declares a healthcheck on /readyz — the app depends_on it being healthy.
grep -q '/readyz' "$OV" \
  && pass "headroom service healthchecks /readyz" \
  || fail "headroom service has no /readyz healthcheck"

# The app points Claude Code at the proxy.
grep -q 'ANTHROPIC_BASE_URL: http://headroom:8787' "$OV" \
  && pass "app sets ANTHROPIC_BASE_URL at the proxy" \
  || fail "app does not point ANTHROPIC_BASE_URL at http://headroom:8787"

# ENABLE_TOOL_SEARCH=true is mandatory with a custom base URL (GH #746): without
# it Claude Code materializes every tool schema into context and breaks sub-agents.
grep -q 'ENABLE_TOOL_SEARCH: "true"' "$OV" \
  && pass "app sets ENABLE_TOOL_SEARCH=true (GH #746 guard)" \
  || fail "app is missing ENABLE_TOOL_SEARCH=true — sub-agents will break"

# The app fails closed: it waits for the proxy to be healthy before starting.
grep -q 'condition: service_healthy' "$OV" \
  && pass "app depends_on the proxy being healthy (fail-closed)" \
  || fail "app does not wait for the proxy (would stall on a dead proxy)"

summary
