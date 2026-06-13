#!/bin/sh
# GSD seed entrypoint — wraps Archon's own docker-entrypoint.sh.
#
# Why this exists: Archon mounts a named volume (archon_user_home) over
# /home/appuser. That volume SHADOWS the GSD install baked into the image at
# /home/appuser/.claude, and Docker's "copy image content into an empty named
# volume" seeding does NOT fire reliably under Archon's entrypoint — so the
# Claude SDK never finds /gsd-quick or /gsd-phase and reports
# "Unknown command: /gsd-quick".
#
# install-gsd-runtime.sh stashes a pristine GSD tree at /opt/gsd-home/.claude,
# OUTSIDE the volume mount. On every boot this script copies that stash into the
# live volume (additively, never clobbering persisted Claude sessions/auth),
# fixes ownership, then exec's Archon's real entrypoint unchanged.
#
# Runs as root (Archon's entrypoint also starts as root, then drops to appuser
# via gosu). Wired as ENTRYPOINT in docker/Dockerfile.user.
set -eu

STAGING="/opt/gsd-home/.claude"
TARGET="/home/appuser/.claude"
APP_USER="appuser"

if [ -d "$STAGING" ]; then
  if [ ! -e "$TARGET/gsd-core" ]; then
    echo "[gsd-seed] GSD missing in $TARGET — seeding from $STAGING"
    mkdir -p "$TARGET"
    # -a preserve, -n no-clobber: add GSD files, keep any existing user state
    # (sessions, auth) the volume already holds. /gsd-quick resolves from the
    # commands tree regardless of settings.json, so no-clobber is safe.
    cp -an "$STAGING/." "$TARGET/"
    chown -R "$APP_USER:$APP_USER" "$TARGET"
    echo "[gsd-seed] seeded $(find "$TARGET" -iname '*gsd*' 2>/dev/null | wc -l) GSD entries"
  else
    echo "[gsd-seed] GSD already present in $TARGET — skipping"
  fi
else
  echo "[gsd-seed] WARNING: stash $STAGING not found; image may be the plain base (Dockerfile.user not built)" >&2
fi

# Hand off to Archon's real entrypoint (resolved on PATH, as the base image set it).
exec docker-entrypoint.sh "$@"
