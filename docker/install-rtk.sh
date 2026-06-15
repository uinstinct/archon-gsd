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

echo "==> Ensuring rtk installer deps (ca-certificates, curl, tar)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl tar
rm -rf /var/lib/apt/lists/*

# Install via rtk's official script with its documented env overrides. The
# Linux x86_64 asset (rtk-x86_64-unknown-linux-musl.tar.gz) is selected
# automatically. Running as root, so writing to /usr/local/bin needs no sudo.
#
# Fetch install.sh from the ${RTK_VERSION} tag, NOT master: the binary is
# pinned, so the installer that runs as root must be pinned to the same release
# for a reproducible build (a mutable master fetch is a root-level supply-chain
# surface). Download to a variable on its own line first so a curl failure (DNS,
# 404, 5xx, truncation) trips set -e HERE with the real cause, instead of being
# swallowed by `sh -c "$(curl ...)"` — where a failed substitution yields an
# empty string and `sh -c ""` exits 0, mis-reported later as "rtk not found".
echo "==> Installing rtk ${RTK_VERSION} to ${RTK_INSTALL_DIR}"
rtk_installer="$(curl -fsSL "https://raw.githubusercontent.com/rtk-ai/rtk/${RTK_VERSION}/install.sh")"
RTK_VERSION="${RTK_VERSION}" RTK_INSTALL_DIR="${RTK_INSTALL_DIR}" sh -c "$rtk_installer"

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
# Assert the binary that landed is actually the pinned release — "runs" is not
# enough. install.sh is upstream code; a change in how it honors RTK_VERSION
# could install a different version while every other check still passes, making
# the reproducible-build claim silently false. Strip the leading 'v' before
# matching (rtk prints e.g. "rtk 0.42.4", the tag is "v0.42.4").
case "$RTK_VER" in
  *"${RTK_VERSION#v}"*) : ;;
  *) echo "FATAL: installed rtk '$RTK_VER' does not match pinned $RTK_VERSION" >&2; exit 1 ;;
esac
echo "==> rtk $RTK_VER OK at $RTK_BIN"
