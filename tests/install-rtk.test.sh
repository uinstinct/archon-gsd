#!/usr/bin/env bash
# rtk wiring guards. install-rtk.sh itself needs apt + network + root to run, so
# it is exercised end-to-end only by the (slow) container smoke build. These are
# the cheap, always-run shell-plumbing checks that catch the regression the smoke
# build would otherwise be the sole net for: a refactor that drops the rtk layer
# or stops forwarding the version pin, shipping an image without rtk while no fast
# test fails. Mirrors the wiring guards in commit-identity.test.sh.
source "$(dirname "$0")/lib/common.sh"

echo "install-rtk wiring"

SCRIPT="$REPO_ROOT/docker/install-rtk.sh"

# The installer must pin its fetch to the release tag, not the mutable master
# branch — the binary is pinned, so the root-run installer must be too.
grep -q 'rtk-ai/rtk/${RTK_VERSION}/install.sh' "$SCRIPT" \
  && pass "install-rtk.sh fetches install.sh from the \${RTK_VERSION} tag" \
  || fail "install-rtk.sh does not pin the installer fetch to \${RTK_VERSION}"
grep -q 'refs/heads/master' "$SCRIPT" \
  && fail "install-rtk.sh still fetches the installer from master (unpinned)" \
  || pass "install-rtk.sh no longer fetches the installer from master"

# The gate must assert the installed version matches the pin, not just that the
# binary runs (a different version could land while --version still succeeds).
grep -q 'RTK_VERSION#v' "$SCRIPT" \
  && pass "install-rtk.sh asserts the installed version matches the pin" \
  || fail "install-rtk.sh does not assert the installed version matches the pin"

# Production Dockerfile: COPY+RUN install-rtk.sh with RTK_VERSION wired through.
DFU="$REPO_ROOT/docker/Dockerfile.user"
grep -q 'install-rtk.sh' "$DFU" \
  && grep -q 'RTK_VERSION="${RTK_VERSION}" /usr/local/bin/install-rtk.sh' "$DFU" \
  && pass "Dockerfile.user runs install-rtk.sh with RTK_VERSION" \
  || fail "Dockerfile.user does not wire install-rtk.sh with RTK_VERSION"

# Smoke Dockerfile: same, with the docker/ prefix (build context = repo root).
DFS="$REPO_ROOT/docker/Dockerfile.smoke"
grep -q 'docker/install-rtk.sh' "$DFS" \
  && grep -q 'RTK_VERSION="${RTK_VERSION}" /usr/local/bin/install-rtk.sh' "$DFS" \
  && pass "Dockerfile.smoke runs install-rtk.sh with RTK_VERSION" \
  || fail "Dockerfile.smoke does not wire install-rtk.sh with RTK_VERSION"

# Compose override forwards the rtk pin as a build arg.
OV="$REPO_ROOT/docker-compose.override.yml"
grep -q 'RTK_VERSION:' "$OV" \
  && pass "compose override forwards the RTK_VERSION build arg" \
  || fail "compose override does not forward the RTK_VERSION build arg"

summary
