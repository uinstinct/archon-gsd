#!/usr/bin/env bash
# Install the GSD (Engine) runtime into an Archon container image.
#
# Two things the stock Archon image lacks (see docs/adr/0001):
#   1. node >= 22  — the stock image is bun-based and purges node, but GSD's
#      gsd-tools.cjs is hardwired to node >= 22.
#   2. a container-global GSD install under the container user's home, so the
#      Claude SDK (settingSources includes 'user') resolves /gsd-quick and
#      /gsd-phase for every freshly cloned target repo.
#
# This script is shared verbatim by the production image (docker/Dockerfile.user,
# FROM archon, deployed into an Archon checkout) and the CI smoke image
# (docker/Dockerfile.smoke, an Archon-like base) so CI proves the exact steps the
# real image runs. Run as root.
set -euo pipefail

GSD_VERSION="${GSD_VERSION:-1.5.0-rc.2}"
APP_USER="${APP_USER:-appuser}"

echo "==> Installing node >= 22 and git"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg git
# NodeSource 22.x — kept (NOT purged) because gsd-tools.cjs needs a real node.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*

NODE_VER="$(node --version)"
NODE_MAJOR="${NODE_VER#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "FATAL: node $NODE_VER installed but GSD needs >= 22" >&2
  exit 1
fi
echo "==> node $NODE_VER OK"

echo "==> Installing GSD $GSD_VERSION container-global for '$APP_USER' (Claude)"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
if [ -z "$APP_HOME" ]; then
  echo "FATAL: user '$APP_USER' not found in this image" >&2
  exit 1
fi
# Global Claude install lands at $APP_HOME/.claude (the Claude SDK 'user' source).
# Both runtime and location are passed explicitly so the installer never prompts.
su -s /bin/sh "$APP_USER" -c \
  "HOME='$APP_HOME' npx --yes '@opengsd/gsd-core@${GSD_VERSION}' --claude --global </dev/null"

echo "==> GSD installed under $APP_HOME/.claude"
