#!/usr/bin/env bash
# Runs tests/e2e/run.sh inside a throwaway Docker-in-Docker container, so the
# containers and images already on this machine are never touched.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Git Bash on Windows needs a native path for the bind mount.
if NATIVE_ROOT="$(cd "$ROOT" && pwd -W 2>/dev/null)"; then
  ROOT="$NATIVE_ROOT"
  export MSYS_NO_PATHCONV=1
fi

docker run --rm --privileged -e DOCKER_TLS_CERTDIR= --entrypoint sh \
  -v "$ROOT:/src:ro" "${E2E_DIND_IMAGE:-docker:28-dind}" -ec '
    unset DOCKER_HOST
    dockerd-entrypoint.sh dockerd >/tmp/dockerd.log 2>&1 &
    for attempt in $(seq 1 60); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
    apk add --no-cache bash coreutils findutils git grep iproute2 python3 sed \
      shadow tar util-linux >/dev/null
    bash /src/tests/e2e/run.sh
  '
