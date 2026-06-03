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

APISIX + chaitin-waf was tested in three tiers. Tier 1 is committed; Tier 2 was skipped (real detector was reachable from the start); Tier 3 is **DONE** on arm64 OrbStack with the chaitin amd64 images running under qemu-user-static — with one important caveat about the mgt Service that anyone deploying on arm64 needs to know.

**Tier 1 — DONE (commit `3a75ef8`).** Verified on OrbStack k8s (1 node, `local-path` SC, default StorageClass), APISIX 3.16.0 + helm chart 2.14.1 + bundled etcd. Tests run, with results:
- `helm template` against `helm-values.yaml` renders the WAF plugin config block correctly (after the chart-key fix `set.plugin_attr` → `pluginAttrs`).
- `helm install apisix apisix/apisix --version 2.14.1` succeeds; pods Ready after image pulls (`apache/apisix:3.16.0` ≈ 480 MB).
- `chaitin-waf:true` confirmed in the APISIX loaded-plugins list (`/apisix/admin/plugins/list`).
- Demo nginx app reachable behind a route created via Admin API; route has chaitin-waf plugin enabled.
- Before seeding `plugin_metadata` in etcd: every request returns HTTP 500 with `X-APISIX-CHAITIN-WAF: err`.
- After seeding (`PUT /apisix/admin/plugin_metadata/chaitin-waf`): every request returns HTTP 200 with `X-APISIX-CHAITIN-WAF: waf-err` (plugin runs, **fail-opens** because no detector is reachable). The `waf-err` vs `unhealthy` distinction matters: `waf-err` = error talking to the WAF server; `unhealthy` = no WAF service available per plugin metadata. Tier 1 only proves the plugin is wired, not that blocking works.

This run caught two real bugs that are now fixed: (1) chart key is `apisix.pluginAttrs`, not `set.plugin_attr` (chart 2.14.1 silently drops the latter); (2) `pluginAttrs` writes to static `plugin_attr`, which chaitin-waf does not read — metadata must go to etcd.

**Tier 2 — SKIPPED.** With Tier 3's real detector reachable from APISIX, a T1K-protocol mock added no extra signal. The mock recipe in the original Tier 2 plan is still valid (netcat listener returning canned verdicts) and is the cheapest way to validate plugin wiring when you don't want to pull the ~280 MB detector image.

**Tier 3 — DONE (this run, commit pending).** Full SafeLine stack on k8s. Test cluster: OrbStack 1 node, k8s 1.33.9+orb1, **arm64** (Apple silicon). The chaitin/safeline-* images are **amd64-only**; OrbStack runs them under `qemu-user-static`, which is fine for the rust/Go binaries that don't bind listener sockets in unusual ways but is the root cause of the mgt issue below. Tag pin: `9.3.6` for everything except `chaitin/safeline-postgres:15.2` (only tag) and `chaitin/safeline-mcp` (skipped).

Results, in the order Tier 3 was meant to answer them:
- **Detector Service-discoverable on TCP**: PASS. `safeline-detector` Service (ClusterIP, port 8000/8001) is reachable from APISIX. The chaitin-waf plugin metadata is seeded with `host: safeline-detector.safeline-ce.svc.cluster.local` (FQDN, not pod IP), and every `X-APISIX-CHAITIN-WAF: yes` header confirms the plugin reached the detector over Service DNS. **Do not** use a node-local pod IP — when the detector restarts the IP changes and APISIX keeps trying the dead address.
- **APISIX blocks real attacks**: PASS. After `PUT /apisix/admin/plugin_metadata/chaitin-waf` with `mode: block` and a route attaching the plugin, the chaitin-waf plugin returns the canonical SafeLine block body on real attacks:
  - `?id=1%27%20OR%20%271%27%3D%271` → `HTTP/1.1 403 Forbidden` + `X-APISIX-CHAITIN-WAF-ACTION: reject` + body `{"code": 403, "success":false, "message": "blocked by Chaitin SafeLine Web Application Firewall", "event_id": "..."}` + `Set-Cookie: sl-session=...`. The `event_id` is what you'd cross-check in the mgt UI's "Attack Logs" tab.
  - `?q=<script>alert(1)</script>` (URL-encoded) → same 403 + reject response.
  - `?file=../../../etc/passwd` → 403 + reject.
  - `GET /` (clean) → 200 + `X-APISIX-CHAITIN-WAF-ACTION: pass`.
  - Monitor mode (per-route) returns the same 200 + `X-APISIX-CHAITIN-WAF-ACTION: pass` for clean and `ACTION: reject` for attacks but with a 200 response (chaitin-waf logs, APISIX forwards). Verified by switching the route's `mode` to `monitor` and re-running.
- **mgt UI stays unprotected**: PASS (by design + verified). Created a second APISIX route `mgt-ui` with `host: mgt.example.com` pointing at `safeline-mgt:1443` and **no chaitin-waf plugin attached**; the response does not carry any `X-APISIX-CHAITIN-WAF-*` headers. (`/api/open/health` returned 502 Bad Gateway during this test because the mgt's Go binary can't bind port 8000 under qemu — see "Known limitations" below — but that's an upstream-connect failure, not a WAF rejection, and crucially no `X-APISIX-CHAITIN-WAF-*` header was present. The point of the test is "is the WAF in the path?", and the answer is "no".)
- **Detector Service discoverability / HA pattern**: documented but not HA-tested. With `replicas: 1` and `strategy: Recreate`, the Service always points to the single current pod; APISIX is fine. For HA, the natural extension is a `headless` Service with per-pod entries in `nodes[]` (the plugin metadata is static so it doesn't auto-update with scale-out), or wrap detector pods behind an APISIX `upstream` instead of putting them in `nodes[]` directly. Neither was verified.
- **End-to-end migration dry-run**: not run against a real `ingress-nginx` deployment, but the APISIX setup was created by exactly the steps in `k8s/apisix-controller/upgrade-from-ingress-nginx.md` (admin API route create, `ApisixPlugin` CRD applied, plugin metadata seeded). Anyone running the playbook against a real `ingress-nginx` cluster can follow the same `helm install apisix` + `PUT /apisix/admin/plugin_metadata/chaitin-waf` + per-route `ApisixPlugin` path and should see the same WAF behavior.

This run caught several real bugs that are now fixed (or documented):
1. **`apiserver/command:` overrides the image's `docker-entrypoint.sh`.** The postgres image's entrypoint runs `initdb` only if k8s lets it. Setting `command: ["postgres", "-c", "max_connections=600"]` replaces the entrypoint entirely, so `initdb` never runs and the data dir stays empty. Fix: pass `-c max_connections=600` as `args:` instead of `command:` so the image's `docker-entrypoint.sh` runs first and then forwards `postgres` as the actual command. Documented inline in the test manifest.
2. **`configMap` mount is read-only on OrbStack, breaking the detector's entrypoint.** The image's `entrypoint.sh` does `chown -Rh detector /resources/detector`, which fails (silently) on a `configMap` mount. Fix: use an `initContainer` to `cp /cfg/detector.yml /resources/detector/detector.yml` into a writable `emptyDir` first.
3. **Detector koopa wrapper self-terminates the snserver every 5 minutes** with `health check failed / max retries exceeded. Terminating` because the detect engine is "de-0 offline" — meaning the engine hasn't received a config push from mgt. On a working k8s cluster (amd64 nodes) the mgt pushes rules on boot and the engine flips to "online". On this arm64 OrbStack test cluster the mgt's Go binary (qemu-emulated amd64) can't bind port 8000 to push rules, so the engine never comes online, and koopa kills snserver after 5 health-check retries. **Workaround used here**: bypass koopa and run `/detector/snserver -c /detector/detector.yml` directly. The detector process stays up indefinitely. This is a Tier 3 test-environment workaround, not a production fix — on amd64 nodes, the standard entrypoint works fine.
4. **k8s `env` does not do shell expansion.** The compose.yaml's `postgres://user:$(POSTGRES_PASSWORD)@host/db` form does not work in k8s — `$(...)` is treated as literal text. Fix: use `valueFrom.secretKeyRef` for the password and inline the rest of the URL, or template the env at apply time. (We inlined the password for the test; production should template.)
5. **FVM port is not 9002.** The fvm image's `/app/config.yml` listens on `0.0.0.0:9004`, not the 9002 the compose network aliases. mgt's HTTP call to fvm is `http://safeline-fvm/skynetinfo` (no explicit port) which the k8s Service maps to whichever `targetPort` you configure. We mapped Service port 80 → targetPort 9004. The fvm is also a gRPC server on 9004 (used by mgt for `AppendFSL`); we exposed both ports.
6. **Chaos exposes 4 different ports** for 4 different services (`challenge-server`, `auth-serve`, `chaos-serve`, `waiting-serve`). mgt talks to chaos on **8088** (the auth-serve default from `yaml:"addr" default:":8088"`) and **8080** (challenge-server). Expose both. Expose 9000 (chaos-serve) too for completeness.
7. **The detector's koopa service-name expectation is `safeline-detector`, not `safeline-detect`.** mgt's hardcoded URL is `http://safeline-detector:8001/update/policy` and the FQDN must match. Renamed the Service from `safeline-detect` → `safeline-detector` in the test manifest.

**Known limitations (this Tier 3 run on arm64 OrbStack):**
- **mgt's API server is unreachable via its own nginx.** The mgt image's `/app/mgt serve` Go binary runs under qemu, and qemu's listener for port 8000 is not visible in the host network namespace. Symptom: `wget https://safeline-mgt:1443/api/open/health` from inside the mgt pod returns `502 Bad Gateway` with `upstream: http://localhost:8000/api/open/health` (the connection refused). This blocks the mgt UI and also prevents the mgt from pushing FSL rules to the detector, which is what causes issue #3 above. **The detector pod still serves T1K traffic correctly on TCP 8000** (verified), so the WAF end-to-end flow works — only the mgt-managed rule updates and the mgt UI are unavailable. On amd64 nodes this is a non-issue.
- **luigi never started.** Same qemu limitation as mgt; the `init.d` script in the luigi image is also amd64-emulated and the luigi binary fails the k8s init-container `until nc -z safeline-mgt 1443` (which mgt's qemu-emulated port also has trouble binding). Not on the Tier 3 critical path — luigi is the background-rule-update worker and the mgt-detector handshake is what actually serves traffic.
- **chaos is up but unauthenticated** (no API token configured in the k8s deployment, which is correct for a first-boot). mgt's calls to chaos hit the right ports, the responses are 401, and mgt retries.
- **`version.json` is out of date.** The repo's `latest_version` / `rec_version` is `v9.2.7` but the registry's latest stable is `9.3.6` (and `9.3.7-rc.2` is in tags). The k8s test manifests pin `9.3.6`. Someone cutting a release should bump `version.json` first; everything else (compose.yaml, helm-values.yaml) uses the image tag and follows `version.json` at release time.

**How to run Tier 3 yourself.** OrbStack on macOS works. For fresh starts, `helm uninstall apisix -n ingress-apisix && kubectl delete namespace ingress-apisix demo-app` cleans up. The admin key is the default `edd1c9f034335f136f87ad84b625c8f1` from chart 2.14.1 — override in production. The admin Service is `apisix-admin.ingress-apisix.svc.cluster.local:9180`. Port-forward to `apisix-gateway` (`kubectl -n ingress-apisix port-forward svc/apisix-gateway 9080:80`) if `LoadBalancer` does not get an external IP (OrbStack typically maps it to a NodePort instead).

The Tier 3 test manifests are checked in to `k8s/apisix-controller/` as a reference: `example-app.yaml` works as-is (the `ApisixPlugin` CRD part needs the controller to translate; without the controller, use the Admin API route create shown in the WAF integration step of the `upgrade-from-ingress-nginx.md`). The chaitin images' default Service ports and env-var quirks are documented inline in the manifest comments.
</content>
</invoke>