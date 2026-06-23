#!/usr/bin/env bash
# Tests for scripts/add-to-archon.sh — the one-liner that drops the Engine files
# into an Archon checkout (issue #8).
#
# These run the installer for real, but point its download base at a file:// URL
# of this repo (ARCHON_GSD_RAW), so no network is touched. They assert the three
# behaviours that matter: a clean install lands all the files, a re-run is a
# no-op, and a pre-existing differing override/Dockerfile.user is preserved with
# the incoming content appended under the merge banner rather than clobbered.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SCRIPT="$REPO_ROOT/scripts/add-to-archon.sh"
RAW="file://$REPO_ROOT"
MERGE_BEGIN="# >>> archon-gsd: incoming content"

# A throwaway "Archon checkout": a dir with a docker-compose.yml so the script
# doesn't warn. Echoes its path.
make_archon_dir() {
  local dir
  dir="$(mktemp -d)"
  : >"$dir/docker-compose.yml"
  echo "$dir"
}

run_installer() { # run_installer <dest> -> writes combined output to $OUT
  OUT="$(ARCHON_GSD_RAW="$RAW" bash "$SCRIPT" "$1" 2>&1)"
}

echo "== add-to-archon.sh =="

# --- fresh install lands every file, with matching content ---------------------
DEST="$(make_archon_dir)"
run_installer "$DEST"
for f in docker-compose.override.yml Dockerfile.user install-gsd-runtime.sh \
         configure-commit-identity.sh gsd-seed-entrypoint.sh log-tail.ts; do
  [ -f "$DEST/$f" ] && pass "fresh: $f written" || fail "fresh: $f missing"
done
cmp -s "$REPO_ROOT/docker-compose.override.yml" "$DEST/docker-compose.override.yml" \
  && pass "fresh: override content matches source" \
  || fail "fresh: override content differs from source"
cmp -s "$REPO_ROOT/docker/Dockerfile.user" "$DEST/Dockerfile.user" \
  && pass "fresh: Dockerfile.user content matches source" \
  || fail "fresh: Dockerfile.user content differs from source"
[ -x "$DEST/install-gsd-runtime.sh" ] \
  && pass "fresh: install-gsd-runtime.sh is executable" \
  || fail "fresh: install-gsd-runtime.sh not executable"
grep -q "headroom:" "$DEST/docker-compose.override.yml" \
  && pass "fresh: headroom sidecar travels with the override" \
  || fail "fresh: headroom sidecar missing from copied override"
grep -qF "$MERGE_BEGIN" "$DEST/docker-compose.override.yml" \
  && fail "fresh: override should NOT carry a merge banner" \
  || pass "fresh: override has no merge banner"

# --- re-running on a current checkout is a no-op -------------------------------
run_installer "$DEST"
echo "$OUT" | grep -q "Already current, skipped:" \
  && pass "re-run: reports files already current" \
  || fail "re-run: did not report skipped files"
grep -qF "$MERGE_BEGIN" "$DEST/docker-compose.override.yml" \
  && fail "re-run: identical override must not gain a merge banner" \
  || pass "re-run: identical override untouched"

# --- pre-existing, differing merge files are preserved + appended -------------
DEST2="$(make_archon_dir)"
printf 'services:\n  app:\n    environment:\n      - MINE=1\n' >"$DEST2/docker-compose.override.yml"
printf 'FROM archon\nRUN echo my-own-layer\n' >"$DEST2/Dockerfile.user"
run_installer "$DEST2"

grep -q "MINE=1" "$DEST2/docker-compose.override.yml" \
  && pass "conflict: user's override content preserved" \
  || fail "conflict: user's override content was clobbered"
grep -qF "$MERGE_BEGIN" "$DEST2/docker-compose.override.yml" \
  && pass "conflict: merge banner appended to override" \
  || fail "conflict: no merge banner in override"
grep -q "log-tail:" "$DEST2/docker-compose.override.yml" \
  && pass "conflict: incoming override content present below banner" \
  || fail "conflict: incoming override content missing"
grep -q "my-own-layer" "$DEST2/Dockerfile.user" \
  && pass "conflict: user's Dockerfile.user preserved" \
  || fail "conflict: user's Dockerfile.user clobbered"
grep -qF "$MERGE_BEGIN" "$DEST2/Dockerfile.user" \
  && pass "conflict: merge banner appended to Dockerfile.user" \
  || fail "conflict: no merge banner in Dockerfile.user"
echo "$OUT" | grep -q "NEEDS MANUAL MERGE:" \
  && pass "conflict: output flags manual merge" \
  || fail "conflict: output did not flag manual merge"

# --- re-running over a pending merge does not stack a second banner -----------
run_installer "$DEST2"
banners="$(grep -cF "$MERGE_BEGIN" "$DEST2/docker-compose.override.yml")"
[ "$banners" -eq 1 ] \
  && pass "conflict re-run: exactly one banner (no double-append)" \
  || fail "conflict re-run: expected 1 banner, found $banners"

rm -rf "$DEST" "$DEST2"
summary
