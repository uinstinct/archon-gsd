# Custom Archon image carrying the GSD (Engine) runtime.
#
# Extends the locally-built `archon` base image (built by `docker compose build`
# in the Archon checkout — same convention as Archon's Dockerfile.user.example)
# and layers on node >= 22 plus a container-global GSD install under the appuser
# home. See docs/adr/0001 and CONTEXT.md ("Custom image").
#
# Build (from this repo root, with the `archon` base already built):
#   docker build -f docker/Dockerfile -t archon-gsd .
#
# Wire it into Archon's stack by pointing the app service at `archon-gsd`
# (e.g. a docker-compose.override.yml `image: archon-gsd`, or copy
# docker/install-gsd-runtime.sh into Archon's gitignored Dockerfile.user).
ARG BASE_IMAGE=archon
FROM ${BASE_IMAGE}

# Pin the Engine version (re-confirm against upstream if gsd-core moves; the
# integration was investigated against 1.5.0-rc.2). Override with --build-arg.
ARG GSD_VERSION=1.5.0-rc.2

USER root
COPY docker/install-gsd-runtime.sh /usr/local/bin/install-gsd-runtime.sh
RUN chmod +x /usr/local/bin/install-gsd-runtime.sh \
    && GSD_VERSION="${GSD_VERSION}" APP_USER=appuser /usr/local/bin/install-gsd-runtime.sh

# Archon's entrypoint starts as root and drops to appuser via gosu; leave the
# final USER as root so that contract is unchanged.
