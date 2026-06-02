# AGENTS.md

Notes to keep OpenCode sessions out of trouble in the SafeLine repo. SafeLine is a self-hosted WAF (Chaitin). This repository ships the Community Edition, the install script, the management services, the MCP server, the SDKs, and the `yanshi` finite-state automaton generator that powers detection signatures.

## Layout

| Path | Language | What it is |
| --- | --- | --- |
| `compose.yaml` | YAML | Docker Compose for the WAF stack: `postgres`, `mgt`, `detect`, `tengine`, `luigi`, `fvm`, `chaos`. |
| `scripts/manage.py` | Python 3 | Install / upgrade / uninstall entrypoint. Pulls images, writes `/data/safeline/compose.yaml`. |
| `management/webserver` | Go | `mgt-api`: Gin REST API + gRPC server. Talks to Postgres and detector. |
| `management/tcontrollerd` | Go | `tcd`: runs inside the Tengine container, generates nginx site configs and reloads nginx. |
| `mcp_server` | Go 1.24 | Model Context Protocol server that calls the SafeLine REST API (own `go.mod`, Dockerfile, docker-compose). |
| `sdk/lua-resty-t1k` | Lua | OpenResty plugin speaking the T1K protocol to the detector. |
| `sdk/kong` | Lua | Kong plugin (rockspecs). |
| `sdk/ingress-nginx` | Lua | ingress-nginx plugin — **DEPRECATED**, see "Data plane migration" below. |
| `sdk/traefik-safeline` | (submodule) | Traefik plugin. |
| `blazehttp` | (submodule) | HTTP parser used by the detector. |
| `yanshi` | C++ | Ragel-like FSA generator with `flex`/`bison` frontend. |
| `k8s/README.md` | Markdown | Top-level entry point for k8s deployment docs (control-plane manifests, deprecated ingress-nginx section now points at `k8s/apisix-controller/`). |
| `k8s/t1k-controller` | Bash + Dockerfile | Legacy data plane: builds an `ingress-nginx` controller image with the t1k plugin pre-installed. **DEPRECATED** — use `k8s/apisix-controller/` for new work. |
| `k8s/apisix-controller` | YAML + Markdown | New data plane: helm values for APISIX + `apisix-ingress-controller`, `ApisixPlugin` CRD templates, demo app, migration guide. Uses the official first-party `chaitin-waf` plugin in the APISIX plugin hub. See "Data plane migration" below. |
| `version.json` | JSON | `latest_version`, `rec_version`, `lts_version`. Keep this in sync when cutting releases. |

## Submodules

`.gitmodules` declares `blazehttp/` and `sdk/traefik-safeline/`. Both directories are empty in a fresh clone until you run `git submodule update --init --recursive`. The detector, Tengine, FVM, and chaos binaries are **not** in this repo — they are closed-source container images referenced by `compose.yaml` (`IMAGE_PREFIX`, `IMAGE_TAG`, `REGION`, `ARCH_SUFFIX`, `RELEASE`).

## Build, test, lint

There is no monorepo build script. Each component has its own.

### `management/` (Go 1.18+)

```bash
cd management
make proto          # regenerate *.pb.go from webserver/proto and tcontrollerd/proto
make build-all      # depends on proto, then builds webserver + tcd into ./build/
make test           # go test -v -p 1 -coverprofile=coverage-management.out ./...
make lint           # runs `go list` (warms the module cache), goimports, then golangci-lint
make clean          # rm -rf build
```

`make build-all` requires the Tengine CI image (`chaitin.cn/ci/golang:1.18`) and `libfvm.so` (a native blob). See `management/webserver/README.md` for the manual `submodule/fvm`, `submodule/libct`, and `submodule/libfvm.so` unpacking dance. The `submodule/` directory is gitignored.

### `mcp_server/`

```bash
cd mcp_server
go mod download
go run main.go --config config.yaml     # or `docker compose -f docker-compose.yml up`
go test ./...                          # only pkg/mcp/schema_test.go is checked in
```

Docker build is the supported path — see its `Dockerfile`. Released as `chaitin/safeline-mcp` (see CI below).

### `yanshi/`

Requires `flex`, `bison`, `libicuuc`, `libreadline`, AddressSanitizer for debug builds.

```bash
cd yanshi
make                  # debug build (-fsanitize=undefined,address) into build/yanshi
make build=release    # optimized build into release/yanshi
make unittest         # builds and runs the unittest/*_test.cc binaries
make distclean        # also removes generated src/lexer.{cc,hh}, src/parser.{cc,hh}
```

Generated sources (`src/lexer.{cc,hh}`, `src/parser.{cc,hh}`) are gitignored — running `make` regenerates them from `lexer.l` and `parser.y`.

### `sdk/lua-resty-t1k`

```bash
cd sdk/lua-resty-t1k
luarocks make         # build/install the rockspec
prove t/              # run the perl-style .t tests
```

## Code generation & generated artifacts

- **Protobuf.** Source files live in `management/{webserver,tcontrollerd}/proto/website/website.proto`. The generated `*.pb.go` files are gitignored. Run `make proto` (or `management/scripts/genproto.sh` from the repo root). Required tooling: `protoc` plus `protoc-gen-go@v1.30.0` and `protoc-gen-go-grpc@v1.3.0`. The script uses `protoc --go_out=paths=source_relative --go-grpc_out=paths=source_relative` and then `goimports -local chaitin.cn -w`.
- **FVM native libs.** `management/webserver/pkg/fvm/fvm.go` and `fsl/` produce FVM bytecode and quote pages. Native headers/libs come from CI artifacts of the `fvm`, `libct`, and `fusion-2` projects and are unpacked into the gitignored `management/webserver/submodule/` tree. Without them `make build-webserver` will fail.
- **yanshi parser/lexer.** Generated by `flex` and `bison` from `yanshi/src/lexer.l` and `yanshi/src/parser.y`.

## Go conventions

- Module path is `chaitin.cn/patronus/safeline-2/...` for both `webserver` and `tcontrollerd`. The `mcp_server` is a separate module at `github.com/chaitin/SafeLine/mcp_server`.
- `goimports -local chaitin.cn` is enforced by `management/Makefile` lint target and the proto regen script. Keep imports grouped: stdlib, third-party, `chaitin.cn/...` last.
- `management/.golangci.yml` enables `deadcode, errcheck, gofmt, goimports, gosimple, govet, ineffassign, staticcheck, structcheck, typecheck, unused, varcheck`. Lint only runs against `webserver/` (`cd webserver && golangci-lint run`).
- Build-time vars `version`, `githash`, `buildstamp`, `goVersion` are stamped via `-ldflags "-X main.buildstamp=$(date +%s) -X main.githash=$(git rev-parse --short=8 HEAD) -X main.version=$(git describe --tags --abbrev=0)"`. Don't add release logic that depends on `git describe` succeeding outside a release branch.
- Service entrypoints:
  - `management/webserver/main.go` — flags `-v`, `-c <config.yml>`, `-gen_certs`, `-show_fsl`, `-push_fsl`, `-fake_logs`, `-reset_user <name>`. Honors `NO_AUTH` and `READ_ONLY` env vars.
  - `management/tcontrollerd/main.go` — flags `-v`, `-t` (runs `nginx -t`), `-r` (runs `nginx -s reload`), `-c <config.yml>`. Connects to `mgt_addr:9002` (gRPC) and runs a 5s control loop.
- Default dev configs are in `management/{webserver,tcontrollerd}/config.yml`; both start with a comment pointing at the production paths in `package/build/...` (not in this repo).

## Architecture map

```
client → safeline-tengine (host network, :80/:443) ─┬─→ safeline-detector (unix sock :8000)
                                                    └─→ safeline-chaos (:10)
                       │
                       └── tcd (in tengine container) ⇄ gRPC :9002 ─→ mgt-api (safeline-mgt)
                                                                          │
                                                                          ├──→ safeline-pg (postgres)
                                                                          ├──→ safeline-fvm (bytecode)
                                                                          └──→ safeline-luigi (background)

External integrators: kong / openresty (lua-resty-t1k) / apisix (chaitin-waf) ──→ safeline-detector via T1K (unix sock or TCP/8000)
                                                                                       or
AI agents: mcp_server (5678) ──HTTPS+token──→ mgt-api REST :1443
```

`compose.yaml` is templated by `scripts/manage.py`; the variables `SUBNET_PREFIX`, `IMAGE_PREFIX`, `IMAGE_TAG`, `POSTGRES_PASSWORD`, `SAFELINE_DIR`, `MGT_PORT`, `ARCH_SUFFIX`, `REGION`, `RELEASE` are all required at deploy time. Defaults: `SAFELINE_DIR=/data/safeline`, `MGT_PORT=9443`, services land on `${SUBNET_PREFIX}.0/24` with fixed `.2` (pg), `.4` (mgt), `.5` (detect), `.7` (luigi), `.8` (fvm), `.10` (chaos).

## CI / release

- The only GitHub Actions workflow is `.github/workflows/slmcp-docker.yml`. It builds and pushes `chaitin/safeline-mcp:{latest,ref}` as multi-arch (linux/amd64,linux/arm64) using Docker buildx and the DockerHub creds in repo secrets `DOCKERIO_USERNAME` / `DOCKERIO_PASSWORD`. Triggers: push to `main`, tag `v*`, or any change under `mcp_server/**`.
- There is no CI for `management/`, `yanshi/`, or `sdk/*`. Those are released as part of the closed-source images and rockspecs.
- When bumping the released WAF image tag, update `version.json` (fields `latest_version`, `rec_version`, and the LTS line separately) and the matching compose image tag.

## Install / manage script

`scripts/manage.py` is the user-facing installer and is shipped standalone. Notes:

- Requires Python 3.5+ and root. Refuses to run on non-Linux, in non-TTY mode, or if the CPU lacks SSSE3.
- Args: `--debug` (verbose logs), `--lts` (track `lts_version`), `--image-clean` (prune images on upgrade), `--en` (international build, switches to `waf.chaitin.com` and English copy), `--patch PATH` (apply a local patch tarball). The script defaults to the Chinese product name "雷池 WAF" and `DOMAIN` is set to `waf.chaitin.cn` unless `--en`.
- The script writes `/etc/safeline/`, `/data/safeline/`, and pulls images. It does not modify this repo's `compose.yaml` — that is a template, not the active deployment.

## Common gotchas

- Don't commit changes under `submodule/` (gitignored in `management/`) or generated `*.pb.go`. The build chain regenerates them.
- `yanshi`'s `lexer.{cc,hh}` and `parser.{cc,hh}` are gitignored; don't commit them after `make`. If they appear in a working tree, run `make distclean`.
- The mgt-api container listens on `1443` inside the compose network; the host port is `${MGT_PORT:-9443}`. The Tengine container uses `network_mode: host`, not the `safeline-ce` bridge — don't move it onto the bridge network.
- The detector defaults to a unix socket (`/resources/detector/snserver.sock`). The Lua plugins document how to switch the detector to TCP/8000 (edit `detector.yml` and expose the port) before they can talk to it.
- License is `LICENSE.md` (custom, not stock MIT/Apache). Keep copyright headers consistent.
- `.github/ISSUE_TEMPLATE/config.yml` disables blank issues and links to the Discord and the CT Stack bypass reporting form. New issues must use one of the templates in `.github/ISSUE_TEMPLATE/`.

## Data plane migration: ingress-nginx → APISIX

`ingress-nginx` was officially retired by Kubernetes SIG Network and the Security Response Committee on 2025-11-11 (https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/). Best-effort maintenance ended **March 2026**; after that there are no security patches.

Consequences in this repo:

- `sdk/ingress-nginx/` and the rockspec there are **frozen at last-published version**. Don't ship new features against them; don't update the rockspec for new ingress-nginx releases.
- `k8s/t1k-controller/` (build.sh, Dockerfile, GHA workflow) targets ingress-nginx as the base image. **It still builds and runs** (pin to `v1.15.0`, NOT `controller-v1.15.1` — the registry uses plain `vX.Y.Z` tags and has no `latest`), but treat the whole subtree as transitional.
- The `docker.io/chaitin/ingress-nginx-controller` image is also based on ingress-nginx and is on the same deprecation clock.

**Target data plane: APISIX** (https://apisix.apache.org/). It's actively maintained, built on OpenResty (so `lua-resty-t1k` can be reused as the underlying T1K client), has its own k8s ingress controller (`apisix-ingress-controller`), and is what new integrations in this repo should target.

What that means for new work:
- Don't add features to `sdk/ingress-nginx/`.
- `k8s/apisix-controller/` is the new home for k8s data-plane work. It uses the **official first-party `chaitin-waf` plugin** from the APISIX plugin hub (https://apisix.apache.org/docs/apisix/plugins/chaitin-waf/) — no custom controller image and no custom Lua plugin build needed. Wires up via the `apisix` and `apisix-ingress-controller` Helm charts; WAF plugin metadata (node list, cluster-wide defaults) is set via `plugin_attr` in chart values, and per-Ingress opt-in is via the `ApisixPlugin` CRD. The design rationale is in `docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md`.
- `sdk/lua-resty-t1k/` is the long-term portable core. Any data plane that supports OpenResty/Lua (APISIX, Kong, OpenResty sidecar) can consume it. APISIX's `chaitin-waf` plugin uses it under the hood.
- `sdk/kong/` and `sdk/traefik-safeline/` are still maintained upstream — keep them as alternatives; don't deprecate them.
</content>
</invoke>