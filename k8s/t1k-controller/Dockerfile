# syntax=docker/dockerfile:1.6
#
# Build the ingress-nginx controller image with the SafeLine t1k plugin
# pre-installed. Used by:
#   - build.sh (local): BUILD_FROM_SOURCE=true ./build.sh
#   - GitHub Actions (CI): .github/workflows/build-t1k-controller.yml
#
# Both paths pass:
#   UPSTREAM_TAG    ingress-nginx controller tag (e.g. controller-v1.15.1)
#   SAFELINE_ROCKSPEC  rockspec filename in the build context
#                     (must be COPY'd into the context before building —
#                      build.sh and the CI workflow both handle that)
#
# Default UPSTREAM_TAG below is intentionally older (v1.10.1) so plain
# `docker build` with no args produces a known-stable image. CI overrides
# it to current upstream.

ARG UPSTREAM_IMAGE=registry.k8s.io/ingress-nginx/controller
ARG UPSTREAM_TAG=v1.10.1
FROM ${UPSTREAM_IMAGE}:${UPSTREAM_TAG}

USER root

# ---- build deps for luarocks ----
# musl-dev is required by luarocks' tiny C portions; the rest are for downloading
# the luarocks tarball and building the plugin.
RUN apk add --no-cache \
        bash \
        gcc \
        make \
        musl-dev \
        unzip \
        wget

# ---- install luarocks ----
ARG LUAROCKS_VERSION=3.11.1
RUN set -eux; \
    cd /tmp; \
    wget -q "https://luarocks.org/releases/luarocks-${LUAROCKS_VERSION}.tar.gz"; \
    tar zxpf "luarocks-${LUAROCKS_VERSION}.tar.gz"; \
    cd "luarocks-${LUAROCKS_VERSION}"; \
    ./configure --lua-version=5.1; \
    make; \
    make install; \
    cd /; \
    rm -rf "/tmp/luarocks-${LUAROCKS_VERSION}" "/tmp/luarocks-${LUAROCKS_VERSION}.tar.gz"

# ---- install the safeline plugin + its lua-resty-t1k dep ----
ARG LUAROCKS_SERVER=https://luarocks.org
ARG SAFELINE_ROCKSPEC=ingress-nginx-safeline-1.0.4-1.rockspec
COPY ${SAFELINE_ROCKSPEC} /tmp/${SAFELINE_ROCKSPEC}
RUN set -eux; \
    luarocks install "/tmp/${SAFELINE_ROCKSPEC}" --server="${LUAROCKS_SERVER}"; \
    rm "/tmp/${SAFELINE_ROCKSPEC}"; \
    # The ingress-nginx plugin framework discovers plugins under
    # /etc/nginx/lua/plugins/ at startup. Symlink in the installed module.
    ln -sf /usr/local/share/lua/5.1/safeline /etc/nginx/lua/plugins/safeline

# ---- sanity check ----
# `luarocks list` should show the safeline module installed.
RUN luarocks list | grep -E "^(ingress-nginx-safeline|lua-resty-t1k)\s" \
    || (echo "ERROR: safeline plugin not installed" >&2; exit 1)

# Drop privileges (matches upstream image default)
USER www-data
