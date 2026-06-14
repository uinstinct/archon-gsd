#!/usr/bin/env bash
# Install rtk (the "Rust Token Killer") into an Archon container image.
#
# rtk is a single zero-dependency static Rust binary that compresses command
# output to cut the tokens the Engine feeds an LLM. We bake the prebuilt static
# musl asset (it runs fine on the glibc Debian/bun base) so the Engine can route
# commands through it with zero per-boot cost.
#
# It is installed to /usr/local/bin (NOT ~/.local/bin, rtk's install.sh default)
# because Archon mounts the archon_user_home named volume over /home/appuser at
# runtime and the mount SHADOWS anything baked under it (the same rule
# configure-commit-identity.sh and the GSD seed entrypoint work around — see
# docs/adr/0001). /usr/local/bin is already on PATH and outside that mount, so
# rtk survives with no seed-entrypoint change.
#
# This script is shared verbatim by the production image (docker/Dockerfile.user)
# and the CI smoke image (docker/Dockerfile.smoke) so CI proves the exact steps
# the real image runs. Run as root.
set -euo pipefail

RTK_VERSION="${RTK_VERSION:-v0.42.4}"
RTK_INSTALL_DIR="${RTK_INSTALL_DIR:-/usr/local/bin}"

echo "==> Ensuring rtk build deps (ca-certificates, curl, tar)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl tar
rm -rf /var/lib/apt/lists/*

# Install via rtk's official script with its documented env overrides. The
# Linux x86_64 asset (rtk-x86_64-unknown-linux-musl.tar.gz) is selected
# automatically. Running as root, so install.sh's internal sudo (if any) is a
# no-op and writing to /usr/local/bin needs none.
echo "==> Installing rtk ${RTK_VERSION} to ${RTK_INSTALL_DIR}"
RTK_VERSION="${RTK_VERSION}" RTK_INSTALL_DIR="${RTK_INSTALL_DIR}" \
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh)"

# Verification gate (mirror the GSD node>=22 gate): the binary must exist and run
# at the install dir, or fail the build loudly rather than ship a broken image.
RTK_BIN="${RTK_INSTALL_DIR}/rtk"
if [ ! -x "$RTK_BIN" ]; then
  echo "FATAL: rtk not found at $RTK_BIN after install" >&2
  exit 1
fi
if ! RTK_VER="$("$RTK_BIN" --version 2>/dev/null)"; then
  echo "FATAL: $RTK_BIN is present but '--version' did not run" >&2
  exit 1
fi
echo "==> rtk $RTK_VER OK at $RTK_BIN"
