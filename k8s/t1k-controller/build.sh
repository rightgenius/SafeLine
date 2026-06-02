#!/usr/bin/env bash
#
# Build (or pull) the ingress-nginx controller image with the SafeLine t1k
# plugin baked in. By default we pull the pre-built Chaitin image; set
# BUILD_FROM_SOURCE=true to compile your own from upstream ingress-nginx +
# the ingress-nginx-safeline rockspec.
#
# Default mode (pull official Chaitin image):
#   ./build.sh
#
# Source build mode (needs docker buildx and network to luarocks.org):
#   BUILD_FROM_SOURCE=true ./build.sh
#
# Build for multiple arches (source build only):
#   BUILD_FROM_SOURCE=true PLATFORMS=linux/amd64,linux/arm64 ./build.sh
#
# Tag and push to your own registry:
#   PUSH=true REGISTRY=ghcr.io/your-org ./build.sh
#
# All settings are env-var driven so the script is CI-friendly. Run with
# `set -x` if you need to debug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in <repo>/k8s/t1k-controller/, so the repo root is two levels up.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Help can be printed before we know anything else.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage:
  ./build.sh                              # build (default: pull Chaitin image)
  ./build.sh --check-upstream             # check for newer upstream controller tag
  ./build.sh --check-upstream --upgrade   # if behind, prompt and rebuild
  ./build.sh --print-image-config         # emit docker build args as JSON
                                           # (for CI: pipe to buildx invocation)
  ./build.sh --help

All settings are env-var driven; see README.md. Common ones:
  BUILD_FROM_SOURCE=true|false   (default: false)
  UPSTREAM_TAG=vX.Y.Z            (default: v1.10.1)
  IMAGE_NAME=... IMAGE_TAG=...
  PUSH=true|false REGISTRY=...
  PLATFORMS=linux/amd64,linux/arm64
  LUAROCKS_SERVER=https://luarocks.cn   (for users in CN)
  UPSTREAM_CHECK=auto|skip       (default: auto — warn if behind when source-building)

CI usage: see .github/workflows/build-t1k-controller.yml — GHA invokes
docker/build-push-action directly; build.sh is not used in CI.
EOF
  exit 0
fi

# ---- defaults (override via env) ----
CHAITIN_IMAGE="${CHAITIN_IMAGE:-docker.io/chaitin/ingress-nginx-controller}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-registry.k8s.io/ingress-nginx/controller}"
UPSTREAM_TAG="${UPSTREAM_TAG:-v1.10.1}"
IMAGE_NAME="${IMAGE_NAME:-safeline-t1k-controller}"
IMAGE_TAG="${IMAGE_TAG:-v1.10.1}"
REGISTRY="${REGISTRY:-}"
PUSH="${PUSH:-false}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-false}"
PLATFORMS="${PLATFORMS:-}"               # empty = native arch (faster local dev)
LUAROCKS_VERSION="${LUAROCKS_VERSION:-3.11.1}"
LUAROCKS_SERVER="${LUAROCKS_SERVER:-https://luarocks.org}"
ROCKSPEC="${ROCKSPEC:-}"                 # empty = pick the highest-versioned one in sdk/ingress-nginx/
UPSTREAM_CHECK="${UPSTREAM_CHECK:-auto}" # auto | skip — auto warns if behind when source-building

# ---- derived ----
FULL_IMAGE="$IMAGE_NAME:$IMAGE_TAG"
[[ -n "$REGISTRY" ]] && FULL_IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"

# ---- functions ----
# Fetch the latest upstream ingress-nginx controller release tag from GitHub.
# Prints "vX.Y.Z" to stdout on success, returns 1 on any failure.
fetch_latest_upstream_tag() {
  command -v curl >/dev/null 2>&1 || return 1
  local json tag
  json=$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/kubernetes/ingress-nginx/releases/latest" 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
  else
    tag=$(printf '%s' "$json" \
      | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's/.*"v?([^"]+)".*/\1/')
  fi
  if [[ -n "$tag" ]]; then
    printf 'v%s\n' "${tag#v}"
    return 0
  fi
  return 1
}

# Compare two semver-ish tags. Echoes: same | ahead | behind
compare_tags() {
  local a="${1#v}" b="${2#v}"
  if [[ "$a" == "$b" ]]; then echo "same"; return; fi
  if printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1 | grep -qx "$a"; then
    echo "ahead"
  else
    echo "behind"
  fi
}

# `cmd_check_upstream [--upgrade]`: print current vs latest and (with
# --upgrade on a TTY) optionally re-exec the script with the new tag.
cmd_check_upstream() {
  local do_upgrade=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upgrade|-u) do_upgrade=true; shift ;;
      *) echo "unknown arg: $1" >&2; return 2 ;;
    esac
  done

  echo "==> fetching latest upstream ingress-nginx release..."
  local latest
  if ! latest=$(fetch_latest_upstream_tag); then
    echo "ERROR: could not fetch latest release tag" >&2
    echo "  (no curl, no network, or GitHub rate-limited)" >&2
    echo "  Check manually: https://github.com/kubernetes/ingress-nginx/releases" >&2
    return 1
  fi
  echo "  latest upstream:        $latest"
  echo "  current UPSTREAM_TAG:   v${UPSTREAM_TAG#v}"
  echo

  local status
  status=$(compare_tags "$UPSTREAM_TAG" "$latest")

  case "$status" in
    same)
      echo "==> you are on the latest upstream tag"
      ;;
    ahead)
      echo "==> you are AHEAD of the latest upstream release"
      echo "    (using a pinned/development tag — make sure that's intentional)"
      ;;
    behind)
      echo "==> upstream is NEWER than your current tag"
      echo
      echo "==> to rebuild against the latest tag:"
      echo
      echo "    BUILD_FROM_SOURCE=true UPSTREAM_TAG=$latest ./build.sh"
      echo
      echo "==> then update the helm release (or your controller Deployment):"
      echo
      echo "    helm upgrade ingress-nginx ingress-nginx/ingress-nginx \\"
      echo "      --reuse-values \\"
      echo "      --set controller.image.tag=$latest"
      echo
      echo "==> related links to check while you're at it:"
      echo "    https://github.com/kubernetes/ingress-nginx/security/advisories"
      echo "    https://nginx.org/en/security_advisories.html"
      echo "    https://github.com/kubernetes/ingress-nginx/releases"
      echo

      if [[ "$do_upgrade" == "true" ]]; then
        if [[ ! -t 0 ]]; then
          echo "ERROR: --upgrade needs an interactive TTY" >&2
          return 2
        fi
        local answer
        read -r -p "==> rebuild now with UPSTREAM_TAG=$latest ? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
          echo "==> rebuilding..."
          UPSTREAM_TAG="$latest" \
          BUILD_FROM_SOURCE=true \
          IMAGE_TAG="$latest" \
          exec "$0"
        else
          echo "==> skipped; run the command above when ready"
        fi
      fi
      ;;
  esac
}

# ---- subcommand dispatch (after defaults so UPSTREAM_TAG override works) ----
if [[ "${1:-}" == "--check-upstream" || "${1:-}" == "check" ]]; then
  shift
  cmd_check_upstream "$@"
  exit $?
fi
if [[ "${1:-}" == "--print-image-config" || "${1:-}" == "print-config" ]]; then
  # Print the resolved build config as a single line of KEY=VALUE pairs,
  # prefixed by "OK ". For CI: source this script with `--print-image-config`
  # to get the values. Exits before any preflight / docker work.
  echo "OK UPSTREAM_IMAGE=$UPSTREAM_IMAGE UPSTREAM_TAG=$UPSTREAM_TAG IMAGE_NAME=$IMAGE_NAME IMAGE_TAG=$IMAGE_TAG FULL_IMAGE=$FULL_IMAGE ROCKSPEC=${ROCKSPEC:-}"
  exit 0
fi

if [[ "$BUILD_FROM_SOURCE" = "true" ]]; then
  [[ -f "$SCRIPT_DIR/Dockerfile" ]] || { echo "ERROR: $SCRIPT_DIR/Dockerfile missing"; exit 1; }

  # Pick the rockspec to build against (highest semver in sdk/ingress-nginx/).
  if [[ -z "$ROCKSPEC" ]]; then
    ROCKSPEC=$(ls -1 "$REPO_ROOT/sdk/ingress-nginx"/ingress-nginx-safeline-*-*.rockspec 2>/dev/null \
      | sort -V | tail -1)
  fi
  [[ -f "$ROCKSPEC" ]] || { echo "ERROR: no rockspec found in sdk/ingress-nginx/"; exit 1; }
  ROCKSPEC_NAME="$(basename "$ROCKSPEC")"
  echo "==> rockspec:       $ROCKSPEC_NAME"
fi

# ---- mode: pull official Chaitin image ----
if [[ "$BUILD_FROM_SOURCE" != "true" ]]; then
  echo "==> pulling $CHAITIN_IMAGE:$UPSTREAM_TAG"
  docker pull "$CHAITIN_IMAGE:$UPSTREAM_TAG"
  docker tag "$CHAITIN_IMAGE:$UPSTREAM_TAG" "$FULL_IMAGE"

  if [[ "$PUSH" = "true" ]]; then
    echo "==> pushing $FULL_IMAGE"
    docker push "$FULL_IMAGE"
  fi
  echo "==> done: $FULL_IMAGE"
  exit 0
fi

# ---- mode: build from source ----
# Best-effort: if the user is source-building (the path that pins nginx to
# UPSTREAM_TAG), warn them if there's a newer upstream tag available. Does
# not fail the build — a network blip shouldn't block offline work.
if [[ "$UPSTREAM_CHECK" != "skip" ]] && command -v curl >/dev/null 2>&1; then
  if latest=$(fetch_latest_upstream_tag 2>/dev/null) \
      && [[ "$(compare_tags "$UPSTREAM_TAG" "$latest")" == "behind" ]]; then
    echo
    echo "==> NOTE: UPSTREAM_TAG=v${UPSTREAM_TAG#v} is behind latest $latest"
    echo "    Run './build.sh --check-upstream' for details, or"
    echo "    BUILD_FROM_SOURCE=true UPSTREAM_TAG=$latest ./build.sh"
    echo "    to rebuild now. (Set UPSTREAM_CHECK=skip to silence this.)"
    echo
  fi
fi

BUILD_CTX=$(mktemp -d)
trap 'rm -rf "$BUILD_CTX"' EXIT

cp "$SCRIPT_DIR/Dockerfile" "$BUILD_CTX/Dockerfile"
cp "$ROCKSPEC" "$BUILD_CTX/$ROCKSPEC_NAME"

# Build args vary by platform support
BUILD_ARGS=(
  --build-arg "UPSTREAM_IMAGE=$UPSTREAM_IMAGE"
  --build-arg "UPSTREAM_TAG=$UPSTREAM_TAG"
  --build-arg "LUAROCKS_VERSION=$LUAROCKS_VERSION"
  --build-arg "LUAROCKS_SERVER=$LUAROCKS_SERVER"
  --build-arg "SAFELINE_ROCKSPEC=$ROCKSPEC_NAME"
)

if [[ -n "$PLATFORMS" ]]; then
  echo "==> building for $PLATFORMS via buildx"
  docker buildx create --use --name t1k-builder >/dev/null 2>&1 || docker buildx use t1k-builder
  docker buildx build \
    --platform "$PLATFORMS" \
    "${BUILD_ARGS[@]}" \
    -t "$FULL_IMAGE" \
    --push="$PUSH" \
    "$BUILD_CTX"
else
  echo "==> building for native arch"
  docker build "${BUILD_ARGS[@]}" -t "$FULL_IMAGE" "$BUILD_CTX"
  if [[ "$PUSH" = "true" ]]; then
    echo "==> pushing $FULL_IMAGE"
    docker push "$FULL_IMAGE"
  fi
fi

# ---- post-build verify (best effort) ----
if [[ -z "$PLATFORMS" && "$PUSH" != "true" ]]; then
  echo "==> smoke test: nginx -t inside the image"
  if docker run --rm --entrypoint nginx "$FULL_IMAGE" -t 2>&1 | grep -q "syntax is ok"; then
    echo "==> nginx config: ok"
  else
    echo "WARNING: nginx -t did not return 'syntax is ok'; check the image manually" >&2
  fi
fi

echo "==> done: $FULL_IMAGE"
