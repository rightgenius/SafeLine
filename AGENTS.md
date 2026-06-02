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
- APISIX chart pinning: the `apisix/apisix` helm chart at `--version 2.14.1` ships `apache/apisix:3.16.0`. The earlier `--version 0.16.0` floating around in older plan drafts is the chart's *internal* `appVersion`, not the chart version — passing it to `helm install` errors out. Always read `helm search repo apisix/apisix --versions` to confirm before pinning.
- The umbrella `apisix/apisix` chart does NOT include `apisix-ingress-controller`. Install it as a separate release: `helm install apisix-ingress-controller apisix/apisix-ingress-controller --version 1.2.0 --set config.apisix.serviceNamespace=ingress-apisix`. The controller chart is GitHub-releases-only (NOT in the helm repo), and `github.com/.../releases/download/` is often unreachable from build networks — mirror it to a private repo in real deployments.
- chaitin-waf plugin metadata: the chart's `pluginAttrs` writes to `plugin_attr` in the static `config.yaml`, which the chaitin-waf plugin does NOT read. The plugin reads its cluster-wide metadata from etcd at `/apisix/admin/plugin_metadata/chaitin-waf`. After `helm install`, POST the seed JSON to the Admin API. See `k8s/apisix-controller/waf-plugin-metadata.json` and README quick-start step 3. Without it, every request to a chaitin-waf-enabled route returns HTTP 500 + `X-APISIX-CHAITIN-WAF: err` (verified on chart 2.14.1 + APISIX 3.16.0).
- The bundled `bitnami/etcd` chart writes its `rootPassword` into the rendered manifest verbatim (not a Secret-backed value). The APISIX admin key is also visible in the rendered `apisix-admin` Secret in plaintext. Both are fine for lab clusters; production must override via an external Secret or move etcd out of the chart.
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
- `k8s/apisix-controller/` is the new home for k8s data-plane work. It uses the **official first-party `chaitin-waf` plugin** from the APISIX plugin hub (https://apisix.apache.org/docs/apisix/plugins/chaitin-waf/) — no custom controller image and no custom Lua plugin build needed. Wires up via the `apisix` and `apisix-ingress-controller` Helm charts; WAF plugin metadata (node list, cluster-wide defaults) is seeded into etcd via the Admin API after `helm install` (see "Common gotchas" — `pluginAttrs` in chart values is **not** the right hook), and per-Ingress opt-in is via the `ApisixPlugin` CRD. The design rationale is in `docs/superpowers/specs/2026-06-02-safeline-k8s-apisix-design.md`.
- `sdk/lua-resty-t1k/` is the long-term portable core. Any data plane that supports OpenResty/Lua (APISIX, Kong, OpenResty sidecar) can consume it. APISIX's `chaitin-waf` plugin uses it under the hood.
- `sdk/kong/` and `sdk/traefik-safeline/` are still maintained upstream — keep them as alternatives; don't deprecate them.

### Validation status

APISIX + chaitin-waf was tested in three tiers. Tier 1 is committed (verifies the install + plugin wiring); Tier 2 and Tier 3 are unverified — anyone touching the data plane should run them.

**Tier 1 — DONE (commit `3a75ef8`).** Verified on OrbStack k8s (1 node, `local-path` SC, default StorageClass), APISIX 3.16.0 + helm chart 2.14.1 + bundled etcd. Tests run, with results:
- `helm template` against `helm-values.yaml` renders the WAF plugin config block correctly (after the chart-key fix `set.plugin_attr` → `pluginAttrs`).
- `helm install apisix apisix/apisix --version 2.14.1` succeeds; pods Ready after image pulls (`apache/apisix:3.16.0` ≈ 480 MB).
- `chaitin-waf:true` confirmed in the APISIX loaded-plugins list (`/apisix/admin/plugins/list`).
- Demo nginx app reachable behind a route created via Admin API; route has chaitin-waf plugin enabled.
- Before seeding `plugin_metadata` in etcd: every request returns HTTP 500 with `X-APISIX-CHAITIN-WAF: err`.
- After seeding (`PUT /apisix/admin/plugin_metadata/chaitin-waf`): every request returns HTTP 200 with `X-APISIX-CHAITIN-WAF: waf-err` (plugin runs, **fail-opens** because no detector is reachable). The `waf-err` vs `unhealthy` distinction matters: `waf-err` = error talking to the WAF server; `unhealthy` = no WAF service available per plugin metadata. Tier 1 only proves the plugin is wired, not that blocking works.

This run caught two real bugs that are now fixed: (1) chart key is `apisix.pluginAttrs`, not `set.plugin_attr` (chart 2.14.1 silently drops the latter); (2) `pluginAttrs` writes to static `plugin_attr`, which chaitin-waf does not read — metadata must go to etcd.

**Tier 2 — TODO. Mock the detector** to verify real `block` and `monitor` behavior without needing a full SafeLine stack. Approximate recipe:
- Run a T1K-protocol fake detector on a `ClusterIP` Service in-cluster, on TCP/8000. The protocol is the same `lua-resty-t1k` client speaks (`sdk/lua-resty-t1k/`); the cheapest mock is a netcat listener that consumes the request and replies with `verdict: allow|block|monitor`. Even a "always return allow" listener is enough to flip Tier 1 from `waf-err` to `unhealthy` and prove the plugin is talking to a server.
- Update `plugin_metadata.chaitin-waf.nodes[0].host` to point at the mock Service, then PUT the metadata to the Admin API.
- Re-run the Tier 1 curl tests; with the mock reachable, `X-APISIX-CHAITIN-WAF: waf-err` should disappear from the headers (or change to `unhealthy` if the mock accepts but returns no verdict).
- Test cases that still need to pass against a real `block` verdict (requires a smarter mock that returns `block` for known-bad payloads):
  - `mode: block` + `?id=1' OR '1'='1` → expect HTTP 403 + JSON block body + `X-APISIX-CHAITIN-WAF: blocked`.
  - `mode: monitor` + same payload → expect HTTP 200 + payload forwarded to upstream + matching log line in the mock's stdout.
  - `mode: off` → plugin bypassed, no plugin overhead, no log, no WAF header.
- Per-route override via `ApisixPlugin` CRD (cluster-wide `monitor`, one Ingress `block`) — revisit once the `apisix-ingress-controller` chart is downloadable; the GitHub-releases tarball timed out from this network so the controller was not installed during Tier 1. Fallback: use Admin API to set per-route plugin config, since `plugin_config_id` references work without the controller.

**Tier 3 — TODO. Full SafeLine stack on k8s.** This is the real validation: deploy detector + mgt + pg + luigi + fvm + chaos from `k8s/README.md` sections 3-8, point `plugin_metadata.chaitin-waf.nodes[0].host` at the detector Service, and re-run Tier 2 against the real detector. Questions Tier 3 must answer:
- Does the k8s Service-discoverable detector behave the same as the docker-compose unix-socket detector? (Detector Service must be on TCP/8000, not unix socket — see "Common gotchas".)
- Does APISIX discover all detector replicas, or does it pin to one? The plugin metadata `nodes[]` is static; for HA you'd need an APISIX `upstream` that load-balances across detector pods (or run a headless Service with per-pod entries in `nodes`).
- Does the mgt control-panel Ingress stay unprotected? The design spec mandates `chaitin-waf` only on user-facing Ingresses. Verify by curling the mgt Ingress with a known-bad payload and confirming it's not blocked.
- Does the demo-app's `ApisixPlugin` (`monitor` mode) actually surface decisions in the mgt console's "logs" tab? (Requires the controller to translate the CRD into a route plugin config; if the controller chart remains un-downloadable, fall back to Admin API + cross-check logs via `etcdctl get /apisix/admin/routes/...`.)
- End-to-end migration dry-run: take the `upgrade-from-ingress-nginx.md` playbook, apply it to a cluster with a real ingress-nginx deployment, and verify the same upstream is now fronted by APISIX with the same WAF behavior.

**How to run Tier 2/3 yourself.** OrbStack on macOS works (used for Tier 1). For fresh starts, `helm uninstall apisix -n ingress-apisix && kubectl delete namespace ingress-apisix demo-app` cleans up. The admin key is in the `apisix-admin` Secret (default `edd1c9f034335f136f87ad84b625c8f1` from chart 2.14.1 — override in production). The admin Service is `apisix-admin.ingress-apisix.svc.cluster.local:9180`. Port-forward to `apisix-gateway` (`kubectl -n ingress-apisix port-forward svc/apisix-gateway 9080:80`) if `LoadBalancer` does not get an external IP (OrbStack typically maps it to a NodePort instead).
</content>
</invoke>